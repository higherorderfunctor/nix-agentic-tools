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
  contentScope = import ../lib/contentScope.nix {inherit lib;};
  records = import ../lib/integrations.nix;
  runtimes = program.supportedRuntimes;
  cacheRoot = cacheLocation {inherit config lib;};
  customizePackage = import ../lib/withGrammars.nix {inherit lib pkgs;};

  featurePaths = {
    instructions = ["instructions" "cli"];
    mcp = ["mcp"];
    subagent = ["subagent"];
  };
  optInFeatures = ["instructions" "subagent"];

  featureEnabled = portable: override: featureName: let
    path = featurePaths.${featureName};
    portableFeature = (lib.getAttrFromPath path portable).enable;
    runtimeFeature = (lib.getAttrFromPath path override).enable;
  in
    if runtimeFeature != null
    then runtimeFeature
    else if lib.elem featureName optInFeatures
    then
      if override.enable == false
      then false
      else portableFeature
    else if override.enable != null
    then override.enable
    else if portableFeature != null
    then portableFeature
    else portable.enable;

  mkState = runtime: let
    portable = config.ai.programs.semble;
    override = config.ai.${runtime}.programs.semble;
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
    selected = featureName: featureEnabled portable override featureName;
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
      ;
    integrationActive = lib.any selected ["instructions" "mcp" "subagent"];
  };

  states = lib.genAttrs runtimes mkState;
  stateList = lib.attrValues states;
  activeStates = builtins.filter (state: state.integrationActive) stateList;
  integrationActive = activeStates != [];
  codexSelected = lib.any states.codex.selected ["instructions" "mcp" "subagent"];
  packageKey = package: builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (toString package));
  variantKeys = lib.unique (map (state: packageKey state.customizedPackage) activeStates);
  variantCount = lib.length variantKeys;
  variants =
    builtins.listToAttrs
    (map (state: let
        key = packageKey state.customizedPackage;
        variantCache =
          if variantCount == 1
          then cacheRoot
          else "${cacheRoot}/variants/${builtins.substring 0 16 key}";
        wrappedPackage =
          if !relocatesCache
          then state.customizedPackage
          else
            pkgs.symlinkJoin {
              name = "${lib.getName state.customizedPackage}-wrapped";
              paths = [state.customizedPackage];
              nativeBuildInputs = [pkgs.makeWrapper];
              passthru = state.customizedPackage.passthru or {};
              postBuild = ''
                for bin in "$out"/bin/*; do
                  wrapProgram "$bin" \
                    --set SEMBLE_CACHE_LOCATION ${lib.escapeShellArg variantCache}
                done
              '';
            };
      in {
        name = key;
        value = {
          cacheDir = variantCache;
          package = state.customizedPackage;
          inherit wrappedPackage;
        };
      })
      activeStates);
  variantFor = state: variants.${packageKey state.customizedPackage};
  statePackage = state: (variantFor state).wrappedPackage;
  multiVariant = variantCount > 1;
  commandFor = state:
    if multiVariant
    then "semble-${state.runtime}"
    else "semble";
  recordsFor = state: records.forCommand (commandFor state);

  installedPackage =
    if !multiVariant
    then statePackage (builtins.head activeStates)
    else let
      canonicalState = builtins.head activeStates;
      canonicalPackage = statePackage canonicalState;
      runtimeLinks =
        lib.concatMapStringsSep "\n" (state: ''
          ${pkgs.coreutils}/bin/ln -s ${statePackage state}/bin/semble "$out/bin/semble-${state.runtime}"
        '')
        activeStates;
    in
      pkgs.runCommand "semble-program-variants" {
        passthru = {
          sembleCacheLocations = lib.genAttrs (map (state: state.runtime) activeStates) (runtime: (variantFor states.${runtime}).cacheDir);
          sembleRuntimePackages = lib.genAttrs (map (state: state.runtime) activeStates) (runtime: statePackage states.${runtime});
        };
      } ''
        ${pkgs.coreutils}/bin/mkdir -p "$out/bin"
        for bin in ${canonicalPackage}/bin/*; do
          ${pkgs.coreutils}/bin/ln -s "$bin" "$out/bin/$(basename "$bin")"
        done
        ${runtimeLinks}
      '';

  cacheGuard = pkgs.writeShellApplication {
    name = "semble-cache-guard";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      ${lib.concatMapStringsSep "\n" (variant: ''
        cache_dir=${lib.escapeShellArg variant.cacheDir}
        expected=${lib.escapeShellArg (toString variant.package)}
        stamp="$cache_dir/.nix-package"
        previous=

        ${pkgs.coreutils}/bin/mkdir -p "$cache_dir"
        if [ -r "$stamp" ]; then
          IFS= read -r previous < "$stamp" || :
        fi

        if [ "$previous" != "$expected" ]; then
          printf 'Semble package changed; clearing indexes in %s\n' "$cache_dir"
          SEMBLE_CACHE_LOCATION="$cache_dir" \
            ${variant.package}/bin/semble clear index >/dev/null

          temporary="$(${pkgs.coreutils}/bin/mktemp "$cache_dir/.nix-package.XXXXXX")"
          trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT
          printf '%s\n' "$expected" > "$temporary"
          ${pkgs.coreutils}/bin/mv -f "$temporary" "$stamp"
          trap - EXIT
        fi
      '') (lib.attrValues variants)}
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
    args = contentScope.toArgs state.cfg.mcp.content;
    command = "${statePackage state}/bin/semble-mcp";
    type = "stdio";
  };

  agentRecord = state: let
    interfaceRecords =
      if state.cfg.subagent.interface == "mcp"
      then records.mcp
      else recordsFor state;
    base =
      if state.runtime == "kiro"
      then interfaceRecords.kiroAgent
      else interfaceRecords.semanticAgent;
  in
    base
    // lib.optionalAttrs (state.runtime == "kiro" && state.cfg.subagent.interface == "mcp") {
      includeMcpJson = false;
      mcpServers.semble = mcpEntry state;
    };

  runtimeConfig = runtime: let
    state = states.${runtime};
  in
    lib.mkMerge [
      (lib.mkIf (state.selected "instructions") {
        ai.${runtime}.rules.semble = lib.mkDefault (recordsFor state).rule;
      })
      (lib.mkIf (state.selected "mcp" && state.cfg.mcp.rootExposure) {
        ai.${runtime}.mcpServers.semble = lib.mkDefault (mcpEntry state);
      })
      (lib.mkIf (state.selected "subagent") {
        # Both records are typed attrsets (Kiro's shape differs from the
        # portable semantic one, but neither is pre-rendered). Default the
        # whole entry so a consumer can replace it atomically. Claude/Codex
        # agents are normalized nullable entries and also accept null
        # tombstones; Kiro's runtime-native agent pool is replace-only.
        ai.${runtime}.agents.semble-search = lib.mkDefault (agentRecord state);
      })
    ];
in {
  imports = [program.module];

  config = lib.mkMerge (
    [
      {
        assertions = lib.concatMap (state:
          [
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
          ]
          ++ map (message: {
            assertion = false;
            inherit message;
          }) (contentScope.errors state.cfg.mcp.content)
          ++ lib.optional (state.selected "subagent" && state.cfg.subagent.interface == "mcp") {
            assertion = state.selected "mcp";
            message = "ai.${state.runtime}.programs.semble.subagent.interface = \"mcp\" requires the Semble MCP integration for the same runtime.";
          }
          ++ lib.optionals (state.selected "mcp" && !state.cfg.mcp.rootExposure) [
            {
              assertion = state.runtime == "kiro";
              message = "ai.${state.runtime}.programs.semble.mcp.rootExposure = false is unsupported: only Kiro can attach a Semble MCP server to a named agent without exposing it to the root session.";
            }
            {
              assertion = state.selected "subagent" && state.cfg.subagent.interface == "mcp";
              message = "ai.${state.runtime}.programs.semble.mcp.rootExposure = false requires an enabled MCP-backed Semble subagent for the same runtime.";
            }
          ])
        stateList;
      }
      (lib.mkIf integrationActive
        (lib.mkMerge [
          (installPackages [installedPackage])
          (installCacheInvalidation {
            inherit cacheGuard lib;
          })
        ]))
      # Uniform across backends now that the location is a plain value rather
      # than a round-trip through the shell environment.
      (lib.mkIf codexSelected {
        ai.codex.internal._integration_writable_roots = lib.mkAfter [(variantFor states.codex).cacheDir];
      })
    ]
    ++ map runtimeConfig runtimes
  );
}
