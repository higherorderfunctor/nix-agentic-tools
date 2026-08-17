# Codex-specific factory-of-factory.
{
  getEnv ? builtins.getEnv,
  lib,
  pkgs,
  ...
}: let
  agent = import ../../../lib/ai/agent.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  sharedHooks = import ../../../lib/ai/hooks.nix {inherit lib;};
  codexExtracted = builtins.fromJSON (builtins.readFile ../../../overlays/chatgpt-codex-extracted.json);
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  # Launcher wrapper — see ./wrapPackage.nix for why Codex needs one at all.
  wrapCodexPackage = import ./wrapPackage.nix {inherit lib pkgs;};

  # Everything destined for Codex's own process environment: the merged
  # `environmentVariables` pool plus `ai.shell`. Codex reads `SHELL` from its
  # process environment and has no config key for it — `shell_environment_policy`
  # governs what SPAWNED commands inherit, which is a different thing.
  #
  # Ordering is the contract, and it is the same one Claude and Kiro use:
  # module-contributed defaults first, the consumer's own pool LAST, so an
  # explicit `environmentVariables.SHELL` wins.
  #
  # This previously applied `resolvedShell` last, on the reasoning that the
  # typed option is the more specific surface. That was defensible in
  # isolation and wrong in aggregate: Claude (`settings.env`, mkDefault) and
  # Kiro both let the explicit entry win, so the same two-key config resolved
  # differently depending on which runtime the consumer happened to name.
  # One rule everywhere beats a better rule in one place.
  codexPackageFor = cfg: moduleEnvironmentVariables: mergedEnvironmentVariables: resolvedShell:
    wrapCodexPackage {
      inherit (cfg) package;
      environmentVariables =
        moduleEnvironmentVariables
        // lib.optionalAttrs (resolvedShell != null) {
          SHELL = lib.getExe resolvedShell;
        }
        // mergedEnvironmentVariables;
    };
  jsonFormat = pkgs.formats.json {};
  tomlReconciler = ../../../lib/ai/reconcile-toml.py;
  tomlFormat = pkgs.formats.toml {};
  # tomlkit is intentional rather than stdlib tomllib: tomllib cannot write,
  # while round-tripping through a plain dict would discard native comments and
  # ordering in the shared user config. Project config below still uses the
  # normal pure Nix TOML generator because that file has one owner.
  tomlPython = pkgs.python3.withPackages (pythonPackages: [pythonPackages.tomlkit]);

  stableFeatureNames = map (feature: feature.name) (
    builtins.filter (feature: feature.maturity == "stable") codexExtracted.features
  );
  reasoningEffortLevels = lib.unique (
    lib.concatMap (model: model.reasoningLevels) codexExtracted.models
  );
  # These are closed CLI vocabularies, not manual guesses. The extractor
  # already fails if either sentinel disappears or changes shape; consuming the
  # same records here removes a second hard-coded list that could otherwise
  # keep evaluating after a Codex update changed the accepted values.
  rootFlagValues = name: let
    matches = builtins.filter (flag: builtins.elem name flag.names) codexExtracted.cli.globalFlags;
    matchCount = builtins.length matches;
  in
    if matchCount == 1
    then (builtins.head matches).acceptedValues
    else throw "ai.codex expected exactly one extracted global flag record for ${name}, found ${toString matchCount}";
  approvalPolicyNames = rootFlagValues "--ask-for-approval";
  sandboxModeNames = rootFlagValues "--sandbox";
  codexAgentType = agent.mkSemanticAgentType tomlFormat.type;
  codexHookHandlerType = lib.types.submodule {
    freeformType = jsonFormat.type;
    options = {
      additionalContextLimit = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Approximate token threshold for large additionalContext output; zero disables truncation.";
      };
      command = lib.mkOption {
        type = sharedHooks.commandType;
        description = "Command executed for this hook; packages resolve to their executable store path.";
      };
      commandWindows = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Windows-only command override.";
      };
      statusMessage = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional status text displayed while the hook runs.";
      };
      timeout = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Per-handler timeout in seconds.";
      };
      type = lib.mkOption {
        type = lib.types.enum ["command"];
        default = "command";
        description = "Codex currently executes command handlers only.";
      };
    };
  };
  codexHookMatcherBlockType = lib.types.submodule {
    options = {
      hooks = lib.mkOption {
        type = lib.types.listOf codexHookHandlerType;
        default = [];
        description = "Command handlers Codex runs for this matcher group.";
      };
      matcher = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional regular-expression matcher restricting this hook group.";
      };
    };
  };
  approvalPolicyType =
    lib.types.either
    (lib.types.enum approvalPolicyNames)
    (lib.types.submodule {
      options.granular =
        lib.genAttrs [
          "mcp_elicitations"
          "request_permissions"
          "rules"
          "sandbox_approval"
          "skill_approval"
        ] (category:
          lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Whether the `${category}` prompt category requires user approval.";
          });
    });
  filesystemAccessType = lib.types.enum ["deny" "read" "write"];
  networkAccessType = lib.types.enum ["allow" "deny"];
  permissionFilesystemType = lib.types.submodule {
    freeformType = lib.types.attrsOf (
      lib.types.either filesystemAccessType (lib.types.attrsOf filesystemAccessType)
    );
    options.glob_scan_max_depth = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Maximum depth for expanding deny-read glob patterns before sandbox startup.";
    };
  };
  permissionNetworkType = lib.types.submodule {
    options = {
      allow_local_binding = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether sandboxed commands may bind loopback network listeners.";
      };
      allow_upstream_proxy = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether sandboxed commands may use an upstream network proxy.";
      };
      dangerously_allow_all_unix_sockets = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether to bypass Unix-socket restrictions for this permission profile.";
      };
      dangerously_allow_non_loopback_proxy = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether the sandbox proxy may listen on non-loopback interfaces.";
      };
      domains = lib.mkOption {
        type = lib.types.attrsOf networkAccessType;
        default = {};
        description = "Per-domain allow or deny decisions for sandboxed network access.";
      };
      enable_socks5 = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether the sandbox exposes its SOCKS5 proxy.";
      };
      enable_socks5_udp = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether the sandbox's SOCKS5 proxy permits UDP associations.";
      };
      enabled = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether network access is enabled for this permission profile.";
      };
      mode = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["full" "limited"]);
        default = null;
        description = "Network-isolation mode for this permission profile.";
      };
      proxy_url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Explicit HTTP proxy URL used by sandboxed commands.";
      };
      socks_url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Explicit SOCKS proxy URL used by sandboxed commands.";
      };
      unix_sockets = lib.mkOption {
        type = lib.types.attrsOf networkAccessType;
        default = {};
        description = "Per-path allow or deny decisions for Unix socket access.";
      };
    };
  };
  permissionProfileType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Human-readable purpose of this named permission profile.";
      };
      extends = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Parent named profile or the :read-only or :workspace built-in.";
      };
      filesystem = lib.mkOption {
        type = lib.types.nullOr permissionFilesystemType;
        default = null;
        description = "Filesystem policy, including path-specific read and write access.";
      };
      network = lib.mkOption {
        type = lib.types.nullOr permissionNetworkType;
        default = null;
        description = "Network, proxy, domain, and socket policy.";
      };
      workspace_roots = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = {};
        description = "Additional workspace roots and whether each is writable.";
      };
    };
  };
  codexSettingsType = lib.types.submodule {
    freeformType = tomlFormat.type;
    options = {
      agents = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          freeformType = tomlFormat.type;
          options = {
            default_subagent_model = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Default model identifier used for spawned Codex subagents.";
            };
            default_subagent_reasoning_effort = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum reasoningEffortLevels);
              default = null;
              description = "Default reasoning effort used for spawned Codex subagents.";
            };
            enabled = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether Codex multi-agent functionality is enabled.";
            };
            interrupt_message = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether Codex sends an interruption message when stopping a subagent.";
            };
            max_concurrent_threads_per_session = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.positive;
              default = null;
              description = "Maximum concurrent agent threads allowed in one Codex session.";
            };
          };
        });
        default = null;
        description = "Global Codex multi-agent defaults and optional native role declarations.";
      };
      allow_login_shell = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Whether shell tools may invoke login shells.";
      };
      approval_policy = lib.mkOption {
        type = lib.types.nullOr approvalPolicyType;
        default = null;
        description = "When Codex pauses for approval, either as a preset or granular prompt-category policy.";
      };
      approvals_reviewer = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["auto_review" "user"]);
        default = null;
        description = "Who reviews eligible interactive approval requests; this does not change the sandbox boundary.";
      };
      default_permissions = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Named or built-in permission profile Codex applies by default. Do not combine this permission model with sandbox_mode/sandbox_workspace_write in any loaded config layer.";
      };
      features = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          freeformType = lib.types.attrsOf lib.types.bool;
          options = lib.genAttrs stableFeatureNames (name:
            lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether Codex enables the extracted stable `${name}` feature.";
            });
        });
        default = null;
        description = ''
          Codex feature toggles. Stable flags extracted from the pinned
          binary are typed; additional boolean flags remain available
          for experimental and forward-compatible use.
        '';
      };
      model = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Default Codex model. The pinned binary's model catalog is a
          non-enforcing hint because account and provider availability
          can add valid model identifiers dynamically.
        '';
      };
      model_reasoning_effort = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum reasoningEffortLevels);
        default = null;
        description = ''
          Default reasoning effort for supported models. Values come
          from the model metadata extracted from the pinned binary.
        '';
      };
      personality = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["friendly" "none" "pragmatic"]);
        default = null;
        description = "Default communication style for supported models.";
      };
      permissions = lib.mkOption {
        type = lib.types.attrsOf permissionProfileType;
        default = {};
        description = "Named least-privilege filesystem and network permission profiles. Profiles with the same name merge across Codex config layers.";
      };
      projects = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options.trust_level = lib.mkOption {
            type = lib.types.enum ["trusted" "untrusted"];
            description = "Whether Codex loads project-scoped .codex configuration, hooks, and rules for this path.";
          };
        });
        default = {};
        description = "User-level project trust declarations. Devenv rejects this bootstrap-global setting only in project config.toml, not in named user profiles.";
      };
      sandbox_mode = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum sandboxModeNames);
        default = null;
        description = "OS-enforced filesystem and network sandbox policy for model-generated commands.";
      };
      sandbox_workspace_write = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            exclude_slash_tmp = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether `/tmp` is excluded from workspace-write sandbox access.";
            };
            exclude_tmpdir_env_var = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether the directory named by TMPDIR is excluded from workspace-write access.";
            };
            network_access = lib.mkOption {
              type = lib.types.nullOr lib.types.bool;
              default = null;
              description = "Whether workspace-write sandboxed commands may access the network.";
            };
            writable_roots = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Additional writable roots granted to workspace-write sandboxed commands.";
            };
          };
        });
        default = null;
        description = "Workspace-write sandbox refinements; effective only with sandbox_mode = \"workspace-write\".";
      };
      web_search = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["cached" "disabled" "indexed" "live"]);
        default = null;
        description = "Codex web-search mode.";
      };
    };
  };
  applyWorkspaceWriteRoots = settings: writableRoots: let
    workspaceSettings = settings.sandbox_workspace_write;
    existingRoots =
      if workspaceSettings == null
      then []
      else workspaceSettings.writable_roots;
  in
    if settings.sandbox_mode == "workspace-write" && writableRoots != []
    then
      settings
      // {
        sandbox_workspace_write =
          (lib.optionalAttrs (workspaceSettings != null) workspaceSettings)
          // {writable_roots = lib.unique (existingRoots ++ writableRoots);};
      }
    else settings;
  applyIntegrationRoots = settings: integrationRoots: let
    selectedPermissionName = settings.default_permissions;
    hasSelectedCustomProfile =
      selectedPermissionName
      != null
      && !lib.hasPrefix ":" selectedPermissionName;
    selectedProfile = settings.permissions.${selectedPermissionName} or {};
    selectedFilesystem =
      if (selectedProfile.filesystem or null) == null
      then {}
      else selectedProfile.filesystem;
    integrationFilesystem = lib.genAttrs (lib.unique integrationRoots) (_: "write");
  in
    if settings.sandbox_mode == "workspace-write" && integrationRoots != []
    then applyWorkspaceWriteRoots settings integrationRoots
    else if hasSelectedCustomProfile && integrationRoots != []
    then
      settings
      // {
        permissions =
          settings.permissions
          // {
            ${selectedPermissionName} =
              selectedProfile
              // {
                # A profile can be defined in a lower Codex config layer and
                # receive this layer's integration roots by name. An explicit
                # rule in this settings tree at the same path still wins;
                # normal Codex precedence applies between emitted files.
                filesystem = integrationFilesystem // selectedFilesystem;
              };
          };
      }
    else settings;
  hasPermissionProfiles = settings:
    helpers.filterNulls (lib.filterAttrs
      (name: _: builtins.elem name ["default_permissions" "permissions"])
      settings)
    != {};

  renderCodexServer = name: server: let
    rendered = removeAttrs (lib.ai.renderServer pkgs name server) ["type"];
    native = helpers.filterNulls (server.codex or {});
    translated =
      lib.optionalAttrs ((native.auth or null) != null) {inherit (native) auth;}
      // lib.optionalAttrs ((native.bearerTokenEnvVar or null) != null) {bearer_token_env_var = native.bearerTokenEnvVar;}
      // lib.optionalAttrs ((native.cwd or null) != null) {inherit (native) cwd;}
      // lib.optionalAttrs ((native.defaultToolsApprovalMode or null) != null) {default_tools_approval_mode = native.defaultToolsApprovalMode;}
      // lib.optionalAttrs ((native.disabledTools or []) != []) {disabled_tools = native.disabledTools;}
      // lib.optionalAttrs ((native.enabled or null) != null) {inherit (native) enabled;}
      // lib.optionalAttrs ((native.enabledTools or []) != []) {enabled_tools = native.enabledTools;}
      // lib.optionalAttrs ((native.envHttpHeaders or {}) != {}) {env_http_headers = native.envHttpHeaders;}
      // lib.optionalAttrs ((native.envVars or []) != []) {env_vars = native.envVars;}
      // lib.optionalAttrs ((native.experimentalEnvironment or null) != null) {experimental_environment = native.experimentalEnvironment;}
      // lib.optionalAttrs ((native.httpHeaders or {}) != {}) {http_headers = native.httpHeaders;}
      // lib.optionalAttrs ((native.oauthResource or null) != null) {oauth_resource = native.oauthResource;}
      // lib.optionalAttrs ((native.required or null) != null) {inherit (native) required;}
      // lib.optionalAttrs ((native.scopes or []) != []) {inherit (native) scopes;}
      // lib.optionalAttrs ((native.startupTimeoutSec or null) != null) {startup_timeout_sec = native.startupTimeoutSec;}
      // lib.optionalAttrs ((native.toolTimeoutSec or null) != null) {tool_timeout_sec = native.toolTimeoutSec;}
      // lib.optionalAttrs ((native.tools or {}) != {}) {
        tools = lib.mapAttrs (_: tool: {approval_mode = tool.approvalMode;}) native.tools;
      };
  in
    removeAttrs native [
      "auth"
      "bearerTokenEnvVar"
      "cwd"
      "defaultToolsApprovalMode"
      "disabledTools"
      "enabled"
      "enabledTools"
      "envHttpHeaders"
      "envVars"
      "experimentalEnvironment"
      "httpHeaders"
      "oauthResource"
      "required"
      "scopes"
      "startupTimeoutSec"
      "toolTimeoutSec"
      "tools"
    ]
    // translated
    // rendered;

  projectIgnoredKeys = [
    "apps_mcp_product_sku"
    "chatgpt_base_url"
    "experimental_realtime_ws_base_url"
    "model_provider"
    "model_providers"
    "notify"
    "openai_base_url"
    "otel"
    "profile"
    "profiles"
    "projects"
  ];

  renderScope = matcher:
    lib.optionalString (matcher != null) (
      "_Apply this guidance only when working with files matching: "
      + lib.concatMapStringsSep ", " (path: "`${path}`") matcher
      + "_\n\n"
    );

  mkRuleBody = _name: rule:
    renderScope rule.matcher
    + lib.ai.transformers.agentsmd.render {
      text = aiCommon.readContent rule;
    };

  isExecpolicyPathLike = content:
    builtins.isPath content
    || (
      builtins.isString content
      && lib.hasPrefix "/" content
    );

  isExecpolicySource = content: let
    pathType = builtins.readFileType content;
  in
    isExecpolicyPathLike content
    && builtins.pathExists content
    && (
      pathType
      == "regular"
      || (
        pathType
        == "symlink"
        && builtins.pathExists content
        && !builtins.pathExists "${toString content}/."
      )
    );

  mkExecpolicyEntries = prefix:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${prefix}/rules/${name}.rules" (
        if isExecpolicySource content
        then {source = content;}
        else {text = content;}
      ));

  mkExecpolicyAssertions = rules:
    lib.mapAttrsToList (name: _: {
      assertion =
        name
        != ""
        && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null
        && !lib.hasSuffix ".rules" name;
      message = "ai.codex.execpolicyRules.${name} must be a safe filename stem without a .rules suffix";
    })
    rules
    ++ lib.mapAttrsToList (name: content: {
      assertion = !isExecpolicyPathLike content || isExecpolicySource content;
      message = "ai.codex.execpolicyRules.${name} path sources must be existing regular files or symlinks to existing files, not missing paths or directories";
    })
    rules;

  mkSandboxModelAssertion = optionPath: settings: {
    assertion =
      !(
        settings.sandbox_mode
        != null
        || settings.sandbox_workspace_write != null
      )
      || !hasPermissionProfiles settings;
    message = "${optionPath} must use either sandbox_mode/sandbox_workspace_write or default_permissions/permissions, never both";
  };

  # CLI config profiles are whole extra files selected with `codex --profile`.
  # Keep this separate surface locked until its cross-layer lifecycle is
  # needed and tested. It is not the `[permissions.<name>]` model above: named
  # permission tables merge normally across the user and project base files.
  mkProfileAssertions = profiles:
    [
      {
        assertion = profiles == {};
        message = "ai.codex.profiles is locked out: a named profile layer silently overrides legacy sandbox settings in the user config beneath it. See the lockout comment in packages/chatgpt-codex/lib/mkCodex.nix.";
      }
    ]
    ++ lib.concatLists (lib.mapAttrsToList (name: settings: [
        {
          assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
          message = "ai.codex.profiles.${name} must start with a letter or number and contain only letters, numbers, hyphens, and underscores";
        }
        (mkSandboxModelAssertion "ai.codex.profiles.${name}" settings)
      ])
      profiles);

  mkProfileSources = profiles:
    lib.mapAttrs (name: settings:
      tomlFormat.generate "codex-profile-${name}.toml" (helpers.filterNulls settings))
    profiles;

  mkProfileEntries = prefix: profiles:
    lib.mapAttrs' (name: source:
      lib.nameValuePair "${prefix}/${name}.config.toml" {
        inherit source;
      })
    (mkProfileSources profiles);

  mkDevenvProfileMaterializer = {
    configDir,
    profiles,
  }: let
    sources = mkProfileSources profiles;
    desiredAssignments = lib.concatStrings (lib.mapAttrsToList (name: source: ''
        desired_targets[${lib.escapeShellArg name}]=${lib.escapeShellArg source}
      '')
      sources);
  in
    pkgs.writeShellApplication {
      name = "codex-devenv-profile-materializer";
      bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
      text = ''
        shopt -s inherit_errexit 2>/dev/null || :

        if [ -n "''${CODEX_HOME:-}" ]; then
          profile_dir="$CODEX_HOME"
        else
          profile_dir="$HOME"/${lib.escapeShellArg configDir}
        fi

        state_base="''${XDG_STATE_HOME:-$HOME/.local/state}"
        if common_dir="$(${pkgs.git}/bin/git -C "$DEVENV_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
          owner_key="$common_dir"
        else
          owner_key="$DEVENV_ROOT"
        fi
        owner_hash="$(${pkgs.coreutils}/bin/sha256sum <<<"$owner_key")"
        owner_id="''${owner_hash%% *}"
        state_dir="$state_base/nix-agentic-tools/codex-profiles/$owner_id"
        manifest="$state_dir/manifest"
        next_manifest="$state_dir/manifest.next.$$"

        declare -A desired_targets=()
        declare -A previous_targets=()
        declare -A should_manage=()
        ${desiredAssignments}

        # Whole-file profiles remain locked out. Avoid manufacturing a lock
        # directory for the ordinary empty case: doing so would force every
        # sandboxed devenv invocation to grant the shared parent containing
        # every repository's ownership state.
        if [ "''${#desired_targets[@]}" -eq 0 ] && [ ! -f "$manifest" ]; then
          exit 0
        fi

        ${pkgs.coreutils}/bin/mkdir -p "$state_dir"
        exec {profile_lock_fd}> "$state_dir/lock"
        ${lib.getExe pkgs.flock} "$profile_lock_fd"

        ${pkgs.coreutils}/bin/mkdir -p "$profile_dir"

        if [ -f "$manifest" ]; then
          while IFS=$'\t' read -r name target; do
            if [ -n "$name" ]; then
              previous_targets["$name"]="$target"
            fi
          done < "$manifest"
        fi

        # Reject every collision before pruning or replacing anything. A
        # failed shell entry must leave the previous owned generation intact.
        for name in "''${!desired_targets[@]}"; do
          source_path="''${desired_targets[$name]}"
          destination="$profile_dir/$name.config.toml"

          if [[ -n ''${previous_targets[$name]+present} ]] \
            && [ -L "$destination" ] \
            && [ "$(${pkgs.coreutils}/bin/readlink "$destination")" = "''${previous_targets[$name]}" ]; then
            should_manage["$name"]=true
          elif [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
            should_manage["$name"]=true
          elif ${pkgs.diffutils}/bin/cmp -s "$source_path" "$destination"; then
            should_manage["$name"]=false
          else
            printf '%s\n' \
              "error: refusing to replace externally managed Codex profile $destination" \
              "Choose a unique ai.codex.profiles name or remove the conflicting file." >&2
            exit 1
          fi
        done

        for name in "''${!previous_targets[@]}"; do
          if [[ -z ''${desired_targets[$name]+present} ]]; then
            destination="$profile_dir/$name.config.toml"
            if [ -L "$destination" ] && [ "$(${pkgs.coreutils}/bin/readlink "$destination")" = "''${previous_targets[$name]}" ]; then
              ${pkgs.coreutils}/bin/rm -f "$destination"
            fi
          fi
        done

        : > "$next_manifest"
        cleanup() {
          ${pkgs.coreutils}/bin/rm -f "$next_manifest"
        }
        trap cleanup EXIT

        for name in "''${!desired_targets[@]}"; do
          source_path="''${desired_targets[$name]}"
          destination="$profile_dir/$name.config.toml"

          if [ "''${should_manage[$name]}" = true ]; then
            ${pkgs.coreutils}/bin/ln -sfn "$source_path" "$destination"
            printf '%s\t%s\n' "$name" "$source_path" >> "$next_manifest"
          fi
        done

        ${pkgs.coreutils}/bin/mv -f "$next_manifest" "$manifest"
        trap - EXIT
      '';
    };

  reservedAgentKeys = ["description" "developer_instructions" "name"];

  mkAgentAssertions = agents:
    lib.mapAttrsToList (name: value: {
      assertion =
        agent.isSemantic value
        && name != ""
        && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null
        && !lib.hasSuffix ".toml" name
        && lib.intersectLists reservedAgentKeys (builtins.attrNames (value.codex or {})) == [];
      message = ''
        Codex agent '${name}' must use the portable { description,
        instructions, tools?, codex? } form, have a safe filename stem without
        a .toml suffix, and keep name/description/developer_instructions out of
        the codex extension. Codex ignores the portable tools allowlist because
        its agent format has no equivalent field.
      '';
    })
    agents;

  mkAgentEntries = prefix: agents:
    lib.mapAttrs' (name: value:
      lib.nameValuePair "${prefix}/agents/${name}.toml" {
        source = tomlFormat.generate "codex-agent-${name}.toml" (agent.renderCodex name value);
      })
    (lib.filterAttrs (_: agent.isSemantic) agents);

  renderHooks = hooks:
    lib.mapAttrs (_event: blocks:
      map (block:
        lib.optionalAttrs (block.matcher != null) {inherit (block) matcher;}
        // {
          hooks = map (handler: lib.filterAttrs (_: value: value != null) handler) block.hooks;
        })
      blocks)
    hooks;

  mkAgentsMd = {
    mergedContext,
    mergedRules,
  }:
    lib.ai.transformers.agentsmd.renderKeyed {
      context = aiCommon.readContent mergedContext;
      rules = lib.mapAttrs mkRuleBody mergedRules;
    };

  mkSizeAssertion = {
    cfg,
    finalEntry,
  }: let
    finalText =
      if finalEntry == null
      then null
      else finalEntry.text or null;
    renderedBytes =
      if finalText == null
      then 0
      else builtins.stringLength finalText;
  in {
    # Store-backed sources stay lazy: reading a derivation output here would
    # introduce IFD. Inline generated/replacement content is checked after B7
    # arbitration; tombstones and source entries do not force discarded text.
    assertion = finalText == null || renderedBytes <= cfg.projectDocMaxBytes;
    message = ''
      Codex AGENTS.md renders to ${toString renderedBytes} bytes, exceeding
      ai.codex.projectDocMaxBytes (${toString cfg.projectDocMaxBytes} bytes).
      Trim or replace the final inline content, or raise
      ai.codex.projectDocMaxBytes.
    '';
  };
in
  lib.ai.app.mkAiApp {
    # Carried as DATA, not a module argument — see mkAiApp.nix.
    inherit pkgs;
    name = "codex";
    contextFilename = "AGENTS.md";
    supportedPools = [
      "agents"
      "context"
      "environmentVariables"
      "hooks"
      "mcpServers"
      "rules"
      "settings"
      "shell"
      "skills"
    ];
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults.package = pkgs.ai.chatgpt-codex;

    options = {
      # Baked into the launcher wrapper (./wrapPackage.nix), so the value
      # lands on Codex's own process and the commands it spawns — never in
      # the project shell or the user's session. Codex has no config-file
      # surface for its process environment; `shell_environment_policy`
      # filters what SPAWNED commands inherit, which is a different thing.
      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
        default = {};
        description = "Environment variables baked into the codex launcher wrapper. Scoped to the Codex process and the commands it spawns; never exported into the project shell. Null suppresses a root entry at the same key.";
      };
      configDir = lib.mkOption {
        type = lib.types.addCheck lib.types.str (value:
          value
          != ""
          && !(lib.hasPrefix "/" value)
          && !(builtins.elem ".." (lib.splitString "/" value)));
        default = ".codex";
        description = ''
          Codex configuration directory relative to HOME. Home Manager writes
          global AGENTS.md here; devenv uses project-root AGENTS.md instead.
        '';
      };
      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr codexAgentType);
        default = {};
        description = ''
          Codex-specific semantic agents replace portable `ai.agents` entries
          at the same key; null suppresses an inherited agent. Each record
          becomes one standalone TOML layer under the active config directory's
          `agents/` child. Put normal Codex config keys such as model,
          model_reasoning_effort, sandbox_mode, mcp_servers, and skills.config
          under the record's `codex` extension.
        '';
      };
      execpolicyRules = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = {};
        description = ''
          Codex command-execution policy written as Starlark `.rules` files.
          This is separate from Markdown `ai.rules`, which contributes durable
          guidance to AGENTS.md.
        '';
        example = lib.literalExpression ''
          {
            git-read = ./git-read.rules;
          }
        '';
      };
      hooks = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf codexHookMatcherBlockType);
        default = {};
        description = ''
          Codex-native lifecycle hook map appended after portable `ai.hooks`
          matcher groups and emitted as `hooks.json`. Event keys are soft for
          forward compatibility. Command handlers additionally type Codex's
          commandWindows, statusMessage, and additionalContextLimit fields;
          other JSON-compatible fields remain available as a native escape
          hatch. Codex treats user/project hooks as non-managed: review and
          trust each generated definition's current hash with `/hooks` before
          it will run.
        '';
      };
      profiles = lib.mkOption {
        type = lib.types.attrsOf codexSettingsType;
        default = {};
        description = ''
          LOCKED OUT. Setting this fails evaluation. These are whole extra
          config files selected by `codex --profile`; they are unrelated to
          the mergeable `[permissions.<name>]` tables in nativeSettings. Keep
          using nativeSettings unless a separate CLI config layer is required.

          Named user configuration layers written as
          `''${configDir}/<name>.config.toml` and selected explicitly with
          `codex --profile <name>`. Codex 0.134.0 and later no longer support
          nested `[profiles]` tables or a persistent default selector.
          Home Manager links these whole-file user layers directly. Devenv
          materializes the same whole-file artifacts into the user CODEX_HOME
          before shell entry because Codex does not discover named profiles in
          trusted project configuration. Known settings are typed identically
          to `ai.codex.nativeSettings`; unknown TOML-compatible keys remain available.
        '';
      };
      projectDocMaxBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 32768;
        description = ''
          Maximum byte size of the generated Codex AGENTS.md. Evaluation fails
          before Codex can silently truncate content beyond this limit.
        '';
      };
      nativeSettings = lib.mkOption {
        type = codexSettingsType;
        default = {};
        description = ''
          Codex config.toml settings. Common stable keys are typed; unknown
          TOML-compatible keys are accepted as a native escape hatch. Home
          Manager reconciles declared leaves into writable user config, while
          devenv statically writes trusted-project config and rejects keys
          Codex ignores at project scope.
        '';
      };
    };

    hm.config = {
      config,
      cfg,
      mergedRules,
      mergedServers,
      mergedSkills,
      mergedAgents,
      mergedEnvironmentVariables,
      moduleEnvironmentVariables,
      resolvedShell,
      mergedContext,
      hasMergedContext,
      topHooks,
      resolvedSettings,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit mergedContext mergedRules;};
      hasAgentsMdContent = hasMergedContext || mergedRules != {};
      agentsMdTarget = "${cfg.configDir}/${cfg.context.filename}";
      configFile = "${cfg.configDir}/config.toml";
      finalAgentsMdEntry = cfg.files.${agentsMdTarget} or null;
      hasNativeMcpServers = cfg.nativeSettings ? mcp_servers;
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      settings = helpers.filterNulls ((applyIntegrationRoots cfg.nativeSettings cfg.internal._integration_writable_roots)
        // lib.optionalAttrs (mergedServers != {}) {
          mcp_servers = lib.mapAttrs renderCodexServer mergedServers;
        });
      settingsStateName = "codex-config-${builtins.hashString "sha256" configFile}";
    in {
      # Codex has no named Markdown rule surface, so context and rules are
      # composed first and the resulting AGENTS.md enters the runtime file map
      # as one replaceable default.
      ai.codex = {
        files = lib.mkIf hasAgentsMdContent {
          ${agentsMdTarget} = lib.mkDefault (
            if agentsMd == ""
            then null
            else {text = agentsMd;}
          );
        };
        internal._integration_writable_roots = lib.mkIf cfg.enable (lib.mkAfter ["${config.xdg.cacheHome}/nix"]);
        nativeSettings = lib.mkIf (resolvedSettings.reasoningEffort != null) {
          model_reasoning_effort = lib.mkDefault resolvedSettings.reasoningEffort;
        };
      };
      assertions =
        mkAgentAssertions mergedAgents
        ++ mkExecpolicyAssertions cfg.execpolicyRules
        ++ mkProfileAssertions cfg.profiles
        ++ [
          (mkSizeAssertion {
            inherit cfg;
            finalEntry = finalAgentsMdEntry;
          })
          {
            assertion = mergedServers == {} || !hasNativeMcpServers;
            message = "ai.codex.nativeSettings.mcp_servers cannot be combined with ai.mcpServers/ai.codex.mcpServers; declare native extensions under each server's codex block";
          }
          {
            inherit (mkSandboxModelAssertion "ai.codex.nativeSettings" cfg.nativeSettings) assertion message;
          }
          {
            assertion = !(cfg.execpolicyRules ? default);
            message = "ai.codex.execpolicyRules.default is reserved in Home Manager because Codex writes user allow-list decisions to rules/default.rules; choose another rule filename";
          }
          {
            assertion = effectiveHooks == {} || !(cfg.nativeSettings ? hooks);
            message = "ai.hooks/ai.codex.hooks cannot be combined with ai.codex.nativeSettings.hooks; choose hooks.json fanout or inline config.toml hooks for this layer";
          }
        ];
      home = {
        # Unlike the trusted-project file below, the user config is not wholly
        # declarative: Codex's trust prompt persists ad-hoc project decisions
        # via config/batchWrite into this exact config.toml. A home.file symlink
        # makes that required native write target a read-only Nix store path.
        # Reconcile only Nix-owned leaves instead, preserving Codex-owned
        # trust/MCP/feature siblings and leaving a writable 0600 regular file.
        #
        # This activation is deliberately present even for `settings = {}`.
        # Its prior-generation leaf manifest is what lets an empty/new
        # generation retract settings Nix used to own without deleting native
        # state. On a first empty generation the reconciler is a strict no-op.
        activation.codexSettingsReconcile = lib.hm.dag.entryAfter ["linkGeneration"] (helpers.mkTomlSettingsActivationScript {
          inherit configFile;
          python = tomlPython;
          reconciler = tomlReconciler;
          settingsJson = builtins.toJSON settings;
          stateName = settingsStateName;
        });
        file = lib.mkMerge [
          (helpers.mkSkillEntries ".agents" mergedSkills)
          (mkAgentEntries cfg.configDir mergedAgents)
          (mkExecpolicyEntries cfg.configDir cfg.execpolicyRules)
          # Profile files are declarative layers selected by an explicit CLI
          # flag; unlike the base user config, no native writer or required
          # runtime state shares them. Static per-file ownership therefore
          # remains the honest lifecycle and keeps removal semantics native to
          # Home Manager.
          (mkProfileEntries cfg.configDir cfg.profiles)
          (lib.mkIf (effectiveHooks != {}) {
            "${cfg.configDir}/hooks.json".source = jsonFormat.generate "codex-hooks.json" {hooks = renderHooks effectiveHooks;};
          })
        ];
        packages = [(codexPackageFor cfg moduleEnvironmentVariables mergedEnvironmentVariables resolvedShell)];
      };
    };

    devenv.config = {
      config,
      cfg,
      mergedRules,
      mergedServers,
      mergedSkills,
      mergedAgents,
      mergedEnvironmentVariables,
      moduleEnvironmentVariables,
      resolvedShell,
      mergedContext,
      hasMergedContext,
      topHooks,
      resolvedSettings,
      ...
    }: let
      hasNativeMcpServers = cfg.nativeSettings ? mcp_servers;
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      settings = helpers.filterNulls ((applyIntegrationRoots (applyWorkspaceWriteRoots cfg.nativeSettings ["${config.devenv.root}/.git"]) cfg.internal._integration_writable_roots)
        // lib.optionalAttrs (mergedServers != {}) {
          mcp_servers = lib.mapAttrs renderCodexServer mergedServers;
        });
      ignoredSettings = lib.intersectLists projectIgnoredKeys (builtins.attrNames settings);
      profileMaterializer = mkDevenvProfileMaterializer {
        inherit (cfg) configDir profiles;
      };
      environmentCacheHome = getEnv "XDG_CACHE_HOME";
      environmentHome = getEnv "HOME";
      effectiveCacheHome =
        if environmentCacheHome != ""
        then environmentCacheHome
        else if environmentHome != ""
        then "${environmentHome}/.cache"
        else null;
      nixCacheRoot =
        if effectiveCacheHome != null
        then "${effectiveCacheHome}/nix"
        else null;
      treefmtCacheRoot =
        if lib.attrByPath ["treefmt" "enable"] false config && effectiveCacheHome != null
        then "${effectiveCacheHome}/treefmt"
        else null;
      agentsMdRules = lib.mapAttrs mkRuleBody mergedRules;
    in {
      ai = {
        codex.internal._integration_writable_roots = lib.mkIf cfg.enable (lib.mkAfter (
          lib.optional (nixCacheRoot != null) nixCacheRoot
          ++ lib.optional (treefmtCacheRoot != null) treefmtCacheRoot
        ));
        codex.nativeSettings = lib.mkIf (resolvedSettings.reasoningEffort != null) {
          model_reasoning_effort = lib.mkDefault resolvedSettings.reasoningEffort;
        };
        internal.agentsMd.${cfg.context.filename} =
          {
            hasContent = lib.mkDefault (hasMergedContext || mergedRules != {});
            maxBytes = cfg.projectDocMaxBytes;
            rules = agentsMdRules;
          }
          // lib.optionalAttrs hasMergedContext {
            context = aiCommon.readContent mergedContext;
          };
      };
      assertions =
        mkAgentAssertions mergedAgents
        ++ mkExecpolicyAssertions cfg.execpolicyRules
        ++ mkProfileAssertions cfg.profiles
        ++ [
          {
            assertion = mergedServers == {} || !hasNativeMcpServers;
            message = "ai.codex.nativeSettings.mcp_servers cannot be combined with ai.mcpServers/ai.codex.mcpServers; declare native extensions under each server's codex block";
          }
          {
            inherit (mkSandboxModelAssertion "ai.codex.nativeSettings" cfg.nativeSettings) assertion message;
          }
          {
            assertion = ignoredSettings == [];
            message = ''
              ai.codex.nativeSettings contains keys Codex ignores in project config:
              ${lib.concatStringsSep ", " ignoredSettings}. Move them to the
              Home Manager user-level configuration.
            '';
          }
          {
            assertion = effectiveHooks == {} || !(cfg.nativeSettings ? hooks);
            message = "ai.hooks/ai.codex.hooks cannot be combined with ai.codex.nativeSettings.hooks; choose hooks.json fanout or inline config.toml hooks for this layer";
          }
        ];
      files = lib.mkMerge [
        (helpers.mkDevenvSkillEntries ".agents" mergedSkills)
        (mkAgentEntries ".codex" mergedAgents)
        (mkExecpolicyEntries ".codex" cfg.execpolicyRules)
        (lib.mkIf (effectiveHooks != {}) {
          ".codex/hooks.json".source = jsonFormat.generate "codex-project-hooks.json" {hooks = renderHooks effectiveHooks;};
        })
        (lib.mkIf (settings != {}) {
          # Project config stays wholly Nix-owned: it is already trust-gated,
          # and no project-local Codex writer has been observed. Keep this
          # static until evidence shows required runtime state shares the file.
          ".codex/config.toml".source = tomlFormat.generate "codex-project-config.toml" settings;
        })
      ];
      packages = [(codexPackageFor cfg moduleEnvironmentVariables mergedEnvironmentVariables resolvedShell)];
      tasks."ai:codex:materialize-profiles" = {
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exec ${lib.getExe profileMaterializer}
        '';
        before = ["devenv:enterShell"];
      };
    };
  }
