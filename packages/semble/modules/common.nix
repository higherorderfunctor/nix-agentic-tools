{
  # Where this backend keeps semble's cache. Both backends answer; only a
  # backend that MOVES the cache off semble's own default has to tell semble
  # about it (see `relocatesCache`).
  cacheLocation,
  installCacheInvalidation,
  installPackages,
  # True when `cacheLocation` is a relocation rather than semble's default.
  # Relocating means semble must be told, and the only honest place to put
  # that is the process that reads it. This module does not write the shell
  # environment on either backend: devenv's `env` attrset would export the
  # value into the project shell, handing it to the developer's own session
  # and every other process running there, not just semble.
  relocatesCache ? false,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  program = programFactory.mkProgram (import ./options.nix {inherit lib pkgs;});
  records = import ../lib/integrations.nix;
  runtimes = program.supportedRuntimes;
  cacheDir = cacheLocation {inherit config lib;};
  customizePackage = import ../lib/withGrammars.nix {inherit lib pkgs;};

  featureEnabled = cfg: feature:
    if feature.enable != null
    then feature.enable
    else cfg.enable;

  mkState = runtime: let
    cfg = program.resolve config runtime;
    grammarLanguages = map (grammar: grammar.language or "") cfg.grammars;
    mappingPatterns = lib.concatMap (mapping: mapping.patterns) cfg.mcp.pathMappings;
    packageCustomizable = (cfg.grammars == [] && cfg.mcp.pathMappings == []) || cfg.package ? overridePythonAttrs;
    grammarLanguagesValid = lib.all (language: language != "") grammarLanguages;
    grammarLanguagesUnique = lib.length (lib.unique grammarLanguages) == lib.length grammarLanguages;
    pathMappingsValid = lib.all (mapping: mapping.language != "" && mapping.patterns != [] && lib.all (pattern: pattern != "") mapping.patterns) cfg.mcp.pathMappings;
    pathMappingPatternsUnique = lib.length (lib.unique mappingPatterns) == lib.length mappingPatterns;
    customizationValid = packageCustomizable && grammarLanguagesValid && grammarLanguagesUnique && pathMappingsValid && pathMappingPatternsUnique;
    customizedPackage =
      if customizationValid
      then customizePackage cfg.package cfg.grammars cfg.mcp.pathMappings
      else cfg.package;
    semblePackage =
      if !relocatesCache
      then customizedPackage
      else
        pkgs.symlinkJoin {
          # Name the wrapper after its input so package overrides remain
          # observable in module evaluation and generated store paths.
          name = "${lib.getName customizedPackage}-wrapped";
          paths = [customizedPackage];
          nativeBuildInputs = [pkgs.makeWrapper];
          passthru = customizedPackage.passthru or {};
          postBuild = ''
            for bin in "$out"/bin/*; do
              wrapProgram "$bin" \
                --set SEMBLE_CACHE_LOCATION ${lib.escapeShellArg cacheDir}
            done
          '';
        };
    selected = feature: featureEnabled cfg feature;
  in {
    inherit
      cfg
      customizedPackage
      grammarLanguagesUnique
      grammarLanguagesValid
      packageCustomizable
      pathMappingPatternsUnique
      pathMappingsValid
      runtime
      selected
      semblePackage
      ;
    integrationActive = lib.any selected [cfg.instructions cfg.mcp cfg.subagent];
  };

  states = lib.genAttrs runtimes mkState;
  stateList = lib.attrValues states;
  activeStates = builtins.filter (state: state.integrationActive) stateList;
  integrationActive = activeStates != [];
  codexSelected = lib.any states.codex.selected [
    states.codex.cfg.instructions
    states.codex.cfg.mcp
    states.codex.cfg.subagent
  ];
  uniquePackages = packages:
    lib.attrValues (builtins.listToAttrs (map (package: {
        name = builtins.unsafeDiscardStringContext (toString package);
        value = package;
      })
      packages));
  activePackages = uniquePackages (map (state: state.semblePackage) activeStates);
  activeCustomizedPackages = uniquePackages (map (state: state.customizedPackage) activeStates);
  cacheGuardPackage =
    if activeCustomizedPackages == []
    then states.claude.customizedPackage
    else builtins.head activeCustomizedPackages;
  expectedPackages = lib.concatStringsSep ":" (map toString activeCustomizedPackages);

  cacheGuard = pkgs.writeShellApplication {
    name = "semble-cache-guard";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      cache_dir=${lib.escapeShellArg cacheDir}
      expected=${lib.escapeShellArg expectedPackages}
      stamp="$cache_dir/.nix-package"
      previous=

      ${pkgs.coreutils}/bin/mkdir -p "$cache_dir"
      if [ -r "$stamp" ]; then
        IFS= read -r previous < "$stamp" || :
      fi

      if [ "$previous" != "$expected" ]; then
        printf 'Semble package changed; clearing indexes in %s\n' "$cache_dir"
        SEMBLE_CACHE_LOCATION="$cache_dir" \
          ${cacheGuardPackage}/bin/semble clear index >/dev/null

        temporary="$(${pkgs.coreutils}/bin/mktemp "$cache_dir/.nix-package.XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT
        printf '%s\n' "$expected" > "$temporary"
        ${pkgs.coreutils}/bin/mv -f "$temporary" "$stamp"
        trap - EXIT
      fi
    '';
  };

  # A relocating backend relocates UNCONDITIONALLY. The intent is a
  # project-local cache, full stop — nothing about it is Codex-specific.
  #
  # It read otherwise until 2026-08-10 only because the `SEMBLE_CACHE_LOCATION`
  # write happened to live inside the codex-cache hook, which is gated on
  # `codexSelected`. The cache therefore moved depending on whether CODEX was
  # enabled: semble for Claude alone got the XDG default, the same project with
  # Codex on got the project-local one. That was an artifact of where the write
  # sat, and the operator confirmed the project-local cache was always the
  # point; Codex merely inherited the write path by being co-located with it.
  #
  # Granting Codex the writable root DOES stay gated on `codexSelected` below.
  # That gate is real: it is about Codex's sandbox, not about where semble
  # keeps its index.

  mcpEntry = state: {
    args = lib.optionals (state.cfg.mcp.content != "code") ["--content" state.cfg.mcp.content];
    command = "${state.semblePackage}/bin/semble-mcp";
    type = "stdio";
  };

  runtimeConfig = runtime: let
    state = states.${runtime};
  in
    lib.mkMerge [
      (lib.mkIf (state.selected state.cfg.instructions) {
        ai.${runtime}.rules.semble = lib.mkDefault records.rule;
      })
      (lib.mkIf (state.selected state.cfg.mcp) {
        ai.${runtime}.mcpServers.semble = lib.mkDefault (mcpEntry state);
      })
      (lib.mkIf (state.selected state.cfg.subagent) {
        # Both records are typed attrsets (Kiro's shape differs from the
        # portable semantic one, but neither is pre-rendered). Default the
        # whole entry so a consumer can replace it atomically. Claude/Codex
        # agents are normalized nullable entries and also accept null
        # tombstones; Kiro's runtime-native agent pool is replace-only.
        ai.${runtime}.agents.semble-search = lib.mkDefault (
          if runtime == "kiro"
          then records.kiroAgent
          else records.semanticAgent
        );
      })
    ];
in {
  imports = [program.module];

  config = lib.mkMerge (
    [
      {
        assertions =
          lib.concatMap (state: [
            {
              assertion = state.packageCustomizable;
              message = "ai.${state.runtime}.programs.semble grammar or path customization requires package to expose overridePythonAttrs.";
            }
            {
              assertion = state.grammarLanguagesValid;
              message = "ai.${state.runtime}.programs.semble.grammars packages must expose a non-empty language attribute.";
            }
            {
              assertion = state.grammarLanguagesUnique;
              message = "ai.${state.runtime}.programs.semble.grammars language names must be unique.";
            }
            {
              assertion = state.pathMappingsValid;
              message = "ai.${state.runtime}.programs.semble.mcp.pathMappings entries require a non-empty language and at least one non-empty pattern.";
            }
            {
              assertion = state.pathMappingPatternsUnique;
              message = "ai.${state.runtime}.programs.semble.mcp.pathMappings patterns must be unique.";
            }
          ])
          stateList;
      }
      (lib.mkIf integrationActive
        (lib.mkMerge [
          (installPackages activePackages)
          (installCacheInvalidation {
            inherit cacheGuard lib;
          })
        ]))
      # Uniform across backends now that the location is a plain value rather
      # than a round-trip through the shell environment.
      (lib.mkIf codexSelected {
        ai.codex.internal._integration_writable_roots = lib.mkAfter [cacheDir];
      })
    ]
    ++ map runtimeConfig runtimes
  );
}
