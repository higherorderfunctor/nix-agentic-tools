{
  cacheLocation,
  installCacheInvalidation,
  installPackages,
}: {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  programFactory = import ../../../lib/ai/program.nix {inherit lib;};
  program = programFactory.mkProgram (import ./options.nix {
    ai = config.ai.internal.packages;
    inherit lib;
  });
  customization = import ../lib/customization.nix {inherit lib;};
  records = import ../lib/integrations.nix;
  runtimes = program.supportedRuntimes;
  cacheRoot = cacheLocation {inherit config lib;};
  launcher = import ../lib/launcher.nix {inherit lib pkgs;};
  defaultSpec = customization.normalize {};

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

  # Validation also feeds module assertions, so invalid specs use the default
  # config for launcher construction until those assertions report the errors.
  configState = cfg: let
    requested = customization.normalize {inherit (cfg) defaultContent defaultModel grammars models pathMappings;};
    validationErrors = customization.errors requested;
    errors =
      validationErrors
      ++ lib.optionals (validationErrors == []) (customization.schemaErrors cfg.package requested);
    spec =
      if errors == []
      then requested
      else defaultSpec;
  in {
    inherit cfg errors spec;
    customizationWarnings = customization.warnings requested;
  };

  mkState = runtime: let
    portable = config.ai.programs.semble;
    override = config.ai.programs.semble.runtimes.${runtime};
    cfg = program.resolve config runtime;
    selected = featureName: featureEnabled portable override featureName;
  in
    configState cfg
    // {
      inherit runtime selected;
      integrationActive = lib.any selected ["instructions" "mcp" "subagent"];
    };

  states = lib.genAttrs runtimes mkState;
  stateList = lib.attrValues states;
  activeStates = builtins.filter (state: state.integrationActive) stateList;
  integrationActive = activeStates != [];
  codexSelected = lib.any states.codex.selected ["instructions" "mcp" "subagent"];
  configKey = state: builtins.hashString "sha256" (builtins.unsafeDiscardStringContext "${toString state.cfg.package}\n${builtins.toJSON (customization.config state.spec)}");
  variantKeys = lib.unique (map configKey activeStates);
  variantCount = lib.length variantKeys;
  # Each distinct config gets a launcher and its own cache. The package stamp
  # still records the underlying Semble build, independent of runtime config.
  mkVariant = state: let
    key = configKey state;
    cacheDir =
      if variantCount == 1 && lib.elem key variantKeys
      then cacheRoot
      else "${cacheRoot}/variants/${builtins.substring 0 16 key}";
    package = state.cfg.package;
  in {
    inherit cacheDir package;
    wrappedPackage = launcher {
      inherit cacheDir package;
      inherit (state) spec;
    };
  };
  variants = builtins.listToAttrs (map (state: {
      name = configKey state;
      value = mkVariant state;
    })
    activeStates);
  variantFor = state: variants.${configKey state};
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
  portableState = configState config.ai.programs.semble;
  finalPackage = (variants.${configKey portableState} or (mkVariant portableState)).wrappedPackage;

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
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
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

  # Both backends bake their owned cache location into the launcher. Codex's
  # writable root remains gated below because it only serves that sandbox.
  # MCP routes calls using the same runtime JSON as the CLI.
  mcpEntry = state: {
    args = [];
    command = "${statePackage state}/bin/semble-mcp";
    type = "stdio";
  };

  mcpSubagent = state: state.selected "subagent" && state.cfg.subagent.interface == "mcp";

  interfaceRecords = state:
    if state.cfg.subagent.interface == "mcp"
    then records.forMcp (routingFor state)
    else recordsFor state;

  # The Kiro-only part of the subagent: the native fields the portable record
  # does not lower (capability-tag tools and, for the MCP interface, an
  # agent-scoped server). Description and prompt come from the portable one.
  kiroAgentFields = state:
    removeAttrs (interfaceRecords state).kiroAgent ["description" "prompt"]
    // lib.optionalAttrs (state.cfg.subagent.interface == "mcp") {
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
      # Every runtime takes the portable record on its own pool, defaulted
      # whole, so a consumer value replaces it atomically, null suppresses
      # it, and it replaces a same-key root agent the same way everywhere.
      # Kiro adds its native fields on `native.agents` one `mkDefault` per
      # field: a whole-entry default there would be discarded by the
      # lowered record. They follow the portable record, so a Kiro null
      # removes the whole agent rather than leaving one with no prompt.
      (lib.mkIf (state.selected "subagent") (lib.mkMerge ([
          {ai.${runtime}.agents.semble-search = lib.mkDefault (interfaceRecords state).semanticAgent;}
        ]
        ++ lib.optional (runtime == "kiro") (lib.mkIf ((config.ai.kiro.agents.semble-search or null) != null) {
          ai.kiro.native.agents.semble-search = lib.mapAttrs (_: lib.mkDefault) (kiroAgentFields state);
        }))))
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

  # Portable-only leaves extend the plain program option tree without
  # generating per-runtime overrides.
  options.ai.programs.semble = {
    finalPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = ''
        The Semble launcher configured from the portable `ai.programs.semble`
        config: grammars, path mappings and model routing applied, with the
        module's cache location baked in.
      '';
    };
    # Portable only: installation is one decision for the whole backend, so
    # a per-runtime override would be a silent no-op.
    install = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to install the Semble launchers and the cache guard that
        clears stale indexes. With false, every runtime still gets its
        selected Semble rule and agents, so the instruction files do not
        depend on where the package is installed; the `semble` command must
        then come from elsewhere. An MCP server or MCP-backed subagent still
        references the package's store path.
      '';
    };
  };

  config = lib.mkMerge (
    [
      ({
          ai.programs.semble = {inherit finalPackage;};
          assertions = lib.concatMap (state:
            map (message: {
              assertion = false;
              message = "ai.programs.semble.runtimes.${state.runtime}: ${message}";
            })
            state.errors
            ++ lib.optional (mcpSubagent state && !(state.selected "mcp")) {
              assertion = state.runtime == "kiro";
              message = "ai.programs.semble.runtimes.${state.runtime}: subagent.interface = \"mcp\" with mcp.enable = false needs an MCP server private to the agent, which only Kiro supports. ${state.runtime} cannot scope a server to one agent: enable mcp or use subagent.interface = \"cli\".";
            })
          stateList;
        }
        // lib.optionalAttrs (options ? warnings) {
          warnings = warningMessages;
        })
      (lib.mkIf (integrationActive && config.ai.programs.semble.install)
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
