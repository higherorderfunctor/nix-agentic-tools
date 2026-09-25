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
  options,
  pkgs,
  ...
}: let
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  program = programFactory.mkProgram (import ./options.nix {inherit lib pkgs;});
  customization = import ../lib/customization.nix {inherit lib;};
  records = import ../lib/integrations.nix;
  runtimes = program.supportedRuntimes;
  cacheRoot = cacheLocation {inherit config lib;};
  customizePackage = import ../lib/customizePackage.nix {inherit lib pkgs;};

  featurePaths = {
    instructions = ["cli" "instructions"];
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

  # The customization checks, shared by every runtime state and by
  # `finalPackage`, which is built from the portable config.
  mkCustomization = cfg: let
    spec = customization.normalize {inherit (cfg) defaultContent defaultModel grammars models pathMappings;};
    packageCustomizable = customization.isVanilla spec || cfg.package ? overridePythonAttrs;
    errors =
      customization.errors spec
      ++ lib.optional (!packageCustomizable)
      "Semble grammar, path-mapping or model customization requires `package` to expose overridePythonAttrs.";
  in {
    inherit errors;
    customizationWarnings = customization.warnings spec;
    customizedPackage =
      if errors == []
      then customizePackage cfg.package spec
      else cfg.package;
  };

  mkState = runtime: let
    portable = config.ai.programs.semble;
    override = config.ai.${runtime}.programs.semble;
    cfg = program.resolve config runtime;
    selected = featureName: featureEnabled portable override featureName;
  in
    mkCustomization cfg
    // {
      inherit
        cfg
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
  # One installed variant per distinct customized package. A package that no
  # active runtime uses (only `finalPackage` can ask for one) gets its own
  # package-keyed cache directory, so it never shares an index with another.
  mkVariant = package: let
    key = packageKey package;
    cacheDir =
      if variantCount == 1 && lib.elem key variantKeys
      then cacheRoot
      else "${cacheRoot}/variants/${builtins.substring 0 16 key}";
    launcherArgs =
      ["--unset" "PYTHONPATH"]
      ++ lib.optionals relocatesCache ["--set" "SEMBLE_CACHE_LOCATION" cacheDir];
  in {
    inherit cacheDir package;
    # Every installed package, vanilla included, goes through this launcher
    # set rather than being installed as-is, for two Python reasons:
    #
    # - It carries ONLY `bin/`. Semble is a Python application, and nixpkgs
    #   propagates a Python application's whole closure plus the interpreter
    #   (`nix-support/propagated-build-inputs`). In a devenv shell, Python's
    #   setup hook turns that into PYTHONPATH entries for numpy, tokenizers,
    #   huggingface-hub and the rest, ahead of the project's own virtualenv.
    #   A launcher with no `lib/` and no `nix-support/` leaks nothing.
    # - Each launcher unsets PYTHONPATH. nixpkgs' entry point appends the
    #   app's own site-packages AFTER PYTHONPATH, so any `semble` (or numpy)
    #   the calling shell exports would shadow Semble's own.
    #
    # The upstream derivation is untouched; only these launchers are new.
    wrappedPackage =
      pkgs.runCommand "${lib.getName package}-wrapped" {
        nativeBuildInputs = [pkgs.makeWrapper];
        passthru = (package.passthru or {}) // {unwrapped = package;};
        meta = lib.optionalAttrs (package.meta ? mainProgram) {inherit (package.meta) mainProgram;};
      } ''
        mkdir -p "$out/bin"
        for bin in ${package}/bin/*; do
          makeWrapper "$bin" "$out/bin/$(basename "$bin")" ${lib.escapeShellArgs launcherArgs}
        done
      '';
  };
  variants =
    builtins.listToAttrs
    (map (state: {
        name = packageKey state.customizedPackage;
        value = mkVariant state.customizedPackage;
      })
      activeStates);
  variantFor = state: variants.${packageKey state.customizedPackage};
  statePackage = state: (variantFor state).wrappedPackage;
  multiVariant = variantCount > 1;
  commandFor = state:
    if multiVariant
    then "semble-${state.runtime}"
    else "semble";
  routingFor = state: {inherit (state.cfg) defaultContent models;};
  recordsFor = state:
    records.forCli {
      command = commandFor state;
      routing = routingFor state;
    };

  # The package `semble` resolves to for the portable config, with the same
  # cache relocation as the installed launcher.
  portablePackage = (mkCustomization config.ai.programs.semble).customizedPackage;
  finalPackage = (variants.${packageKey portablePackage} or (mkVariant portablePackage)).wrappedPackage;

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
            ${variant.wrappedPackage}/bin/semble clear index >/dev/null

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

  # The MCP server routes each call by content from the package's own table,
  # so it takes no arguments.
  mcpEntry = state: {
    args = [];
    command = "${statePackage state}/bin/semble-mcp";
    type = "stdio";
  };

  mcpSubagent = state: state.selected "subagent" && state.cfg.subagent.interface == "mcp";

  agentRecord = state: let
    interfaceRecords =
      if state.cfg.subagent.interface == "mcp"
      then records.forMcp (routingFor state)
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
        ai.${runtime}.rules.semble = lib.mapAttrs (_: lib.mkDefault) (recordsFor state).rule;
      })
      # An MCP-backed subagent with `mcp` off keeps its server private to the
      # agent: only Kiro can do that, and an assertion rejects the others.
      (lib.mkIf (state.selected "mcp") {
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

  # An MCP caller passes `content` as one category or "all", or omits it for
  # `defaultContent`; an enabled model for any other set is unreachable there.
  mcpWarnings = state:
    lib.optionals (state.selected "mcp" || mcpSubagent state)
    (lib.concatLists (lib.imap1 (index: entry:
      lib.optional (entry.enable && !(records.mcpReachable (routingFor state) entry.content))
      "`models.${toString index}` (content ${lib.concatStringsSep " " (lib.toList entry.content)}) is unreachable through MCP: an MCP call's `content` is one category or \"all\", and this set is not `defaultContent` either. Only the CLI can select it.")
    state.cfg.models));

  # Warnings for active runtimes, one line per distinct message.
  warningMessages = let
    byMessage =
      lib.foldl' (acc: state:
        lib.foldl' (inner: message: inner // {${message} = (inner.${message} or []) ++ [state.runtime];}) acc (state.customizationWarnings ++ mcpWarnings state))
      {}
      activeStates;
  in
    lib.mapAttrsToList (message: runtimes: "ai.programs.semble (${lib.concatStringsSep ", " runtimes}): ${message}") byMessage;
in {
  imports = [program.module];

  # A second declaration of the portable program option, so the factory does
  # not generate a per-runtime override for this read-only value.
  options.ai.programs.semble = lib.mkOption {
    type = lib.types.submodule {
      options.finalPackage = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        description = ''
          The Semble package built from the portable `ai.programs.semble`
          config: grammars, path mappings and model routing applied, with the
          module's cache location baked in.
        '';
      };
    };
  };

  config = lib.mkMerge (
    [
      ({
          ai.programs.semble = {inherit finalPackage;};
          assertions = lib.concatMap (state:
            map (message: {
              assertion = false;
              message = "ai.${state.runtime}.programs.semble: ${message}";
            })
            state.errors
            ++ lib.optional (mcpSubagent state && !(state.selected "mcp")) {
              assertion = state.runtime == "kiro";
              message = "ai.${state.runtime}.programs.semble: subagent.interface = \"mcp\" with mcp.enable = false needs an MCP server private to the agent, which only Kiro supports. ${state.runtime} cannot scope a server to one agent: enable mcp or use subagent.interface = \"cli\".";
            })
          stateList;
        }
        // lib.optionalAttrs (options ? warnings) {
          warnings = warningMessages;
        })
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
