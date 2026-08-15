{
  # Where this backend keeps semble's cache. Both backends answer; only a
  # backend that MOVES the cache off semble's own default has to tell semble
  # about it (see `relocatesCache`).
  cacheLocation,
  installCacheInvalidation,
  installPackage,
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
  cfg = config.semble;
  grammarLanguages = map (grammar: grammar.language or "") cfg.grammars;
  grammarLanguagesValid = lib.all (language: language != "") grammarLanguages;
  grammarLanguagesUnique = lib.length (lib.unique grammarLanguages) == lib.length grammarLanguages;
  mappingPatterns = lib.concatMap (mapping: mapping.patterns) cfg.pathMappings;
  pathMappingsValid = lib.all (mapping: mapping.language != "" && mapping.patterns != [] && lib.all (pattern: pattern != "") mapping.patterns) cfg.pathMappings;
  pathMappingPatternsUnique = lib.length (lib.unique mappingPatterns) == lib.length mappingPatterns;
  packageCustomizable = (cfg.grammars == [] && cfg.pathMappings == []) || cfg.package ? overridePythonAttrs;
  records = import ../lib/integrations.nix;
  runtimes = ["claude" "codex" "kiro"];

  featureEnabled = feature:
    if feature.enable != null
    then feature.enable
    else cfg.enable;
  featureRuntimes = feature:
    if feature.runtimes != null
    then feature.runtimes
    else cfg.runtimes;
  selected = runtime: feature:
    featureEnabled feature && lib.elem runtime (featureRuntimes feature);
  featureActive = feature:
    featureEnabled feature && featureRuntimes feature != [];
  integrationActive =
    featureActive cfg.instructions
    || featureActive cfg.mcp
    || featureActive cfg.subagent;
  codexSelected = lib.any (feature: selected "codex" feature) [
    cfg.instructions
    cfg.mcp
    cfg.subagent
  ];
  mkDefaultRecursive = lib.mapAttrsRecursive (_path: lib.mkDefault);

  cacheDir = cacheLocation {inherit config lib;};
  customizePackage = import ../lib/withGrammars.nix {inherit lib pkgs;};
  customizedPackage =
    if packageCustomizable && grammarLanguagesValid && grammarLanguagesUnique && pathMappingsValid && pathMappingPatternsUnique
    then customizePackage cfg.package cfg.grammars cfg.pathMappings
    else cfg.package;

  cacheGuard = pkgs.writeShellApplication {
    name = "semble-cache-guard";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      cache_dir=${lib.escapeShellArg cacheDir}
      expected=${lib.escapeShellArg "${customizedPackage}"}
      stamp="$cache_dir/.nix-package"
      previous=

      ${pkgs.coreutils}/bin/mkdir -p "$cache_dir"
      if [ -r "$stamp" ]; then
        IFS= read -r previous < "$stamp" || :
      fi

      if [ "$previous" != "$expected" ]; then
        printf 'Semble package changed; clearing indexes in %s\n' "$cache_dir"
        SEMBLE_CACHE_LOCATION="$cache_dir" \
          ${customizedPackage}/bin/semble clear index >/dev/null

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

  # Wrapped once, for every entry point, so `semble` and `semble-mcp` cannot
  # disagree about where the cache lives — and so the MCP server needs no
  # `env` block of its own, since its command already carries the setting.
  semblePackage =
    if !relocatesCache
    then customizedPackage
    else
      pkgs.symlinkJoin {
        # Named after what it wraps, so a `semble.package` override stays
        # OBSERVABLE once the package is no longer installed bare. A fixed
        # name would make the override untestable — the wrapped derivation
        # would look identical whatever went into it.
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

  mcpEntry = {
    args = lib.optionals (cfg.mcp.content != "code") ["--content" cfg.mcp.content];
    command = "${semblePackage}/bin/semble-mcp";
    type = "stdio";
  };

  runtimeConfig = runtime: let
    instruction =
      if runtime == "kiro"
      then records.kiroInstruction
      else records.instruction;
  in
    lib.mkMerge [
      (lib.mkIf (selected runtime cfg.instructions) {
        ai.${runtime}.instructions = [instruction];
      })
      (lib.mkIf (selected runtime cfg.mcp) {
        ai.${runtime}.mcpServers.semble = mkDefaultRecursive mcpEntry;
      })
      (lib.mkIf (selected runtime cfg.subagent) {
        # Both records are now typed attrsets (Kiro's shape differs from the
        # portable semantic one, but neither is pre-rendered), so the same
        # per-leaf mkDefault applies to each.
        ai.${runtime}.agents.semble-search = mkDefaultRecursive (
          if runtime == "kiro"
          then records.kiroAgent
          else records.semanticAgent
        );
      })
    ];
in {
  imports = [(import ./options.nix {inherit lib pkgs;})];

  config = lib.mkMerge (
    [
      {
        assertions = [
          {
            assertion = packageCustomizable;
            message = "semble grammar or path customization requires semble.package to expose overridePythonAttrs.";
          }
          {
            assertion = grammarLanguagesValid;
            message = "semble.grammars packages must expose a non-empty language attribute.";
          }
          {
            assertion = grammarLanguagesUnique;
            message = "semble.grammars language names must be unique.";
          }
          {
            assertion = pathMappingsValid;
            message = "semble.pathMappings entries require a non-empty language and at least one non-empty pattern.";
          }
          {
            assertion = pathMappingPatternsUnique;
            message = "semble.pathMappings patterns must be unique.";
          }
        ];
      }
      (lib.mkIf integrationActive
        (lib.mkMerge [
          (installPackage semblePackage)
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
