# Codex-specific factory-of-factory.
{
  getEnv ? builtins.getEnv,
  lib,
  pkgs,
  resolveGitCommonDir ? import ./resolveGitCommonDir.nix {inherit lib;},
  ...
}: let
  agent = import ../../../lib/ai/agent.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  sharedHooks = import ../../../lib/ai/hooks.nix {inherit lib;};
  codexExtracted = builtins.fromJSON (builtins.readFile ../extracted.json);
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  # Codex's launcher, installed by both backends. Codex takes its
  # command shell from `SHELL` in its OWN process environment (via
  # `portable_pty`) and has no config key for it: `shell_environment_policy`
  # filters what SPAWNED commands inherit, which is a different thing. So the
  # launcher is the only declarative place for it and for the rest of the
  # environment pool. When `SHELL` is unset or not executable Codex falls back
  # to the PASSWORD-DATABASE shell, so leaving it unset is not neutral. With
  # no extra environment, the project-document preflight still needs a wrapper
  # on both backends. The preflight is local and never starts a Codex session.
  #
  # devenv's launcher also always passes `--no-daemon`, the one flag that both
  # skips auto-start AND refuses to attach to a daemon already running. A
  # daemon is shared by every client and keeps the environment of whoever
  # started it (codex-rs/app-server-daemon/README.md, rust-v0.157.1), and it
  # runs the package Home Manager selected, so without the flag a project
  # session would run its tools in another shell's environment and on another
  # version. Clap accepts the root flag before every subcommand; `codex agents`,
  # `codex queue` and `--remote` then refuse to run, and `codex remote-control`
  # and `codex app-server daemon …` ignore it and still reach the user daemon.
  # The flags live in launcher-flags.nix, which extraction reconciliation also
  # reads, so it fails if upstream drops one from the root command. devenv's
  # launcher also carries the trust of the project hooks it generates
  # (`hookTrustFor`), as a session flag: Codex reads hook trust only from user
  # config and session flags, and devenv never writes the user's config.
  launcherFlags = import ./launcher-flags.nix;
  codexInstallPackage = {
    backend,
    cfg,
    launcherEnvironment,
    ...
  } @ args: let
    hookTrust = hookTrustFor args;
    package = cfg.package.launcherPackage or cfg.package;
  in
    lib.ai.mkLauncher pkgs {
      environmentVariables = launcherEnvironment;
      exe = "codex";
      flags = lib.optionals (backend == "devenv") (
        lib.concatMap (flag: ["--add-flags" flag]) launcherFlags.devenv
        ++ lib.optionals (hookTrust != {}) (
          lib.concatMap (flag: ["--add-flag" flag]) launcherFlags.hookTrust
          ++ ["--add-flag" (lib.escapeShellArg (hookTrustOverride hookTrust))]
        )
      );
      name = "chatgpt-codex-wrapped";
      inherit package;
      preflight = import ./projectDocPreflight.nix pkgs;
    };
  daemonSelect = import ./daemonSelect.nix pkgs;
  permissionLayersNotice = import ./permissionLayersNotice.nix pkgs;
  projectTrustNotice = import ./projectTrustNotice.nix pkgs;
  runtimeFiles = import ../../../lib/ai/runtime-files.nix {inherit lib;};
  packageLayout = import ./packageLayout.nix;
  jsonFormat = pkgs.formats.json {};
  tomlFormat = pkgs.formats.toml {};

  # Codex 0.147.0 ignores Layout B (a real skill directory containing
  # symlinked files), although it does discover a symlinked skill directory.
  # This migration validates every target before changing any of them. Desired
  # store links are unlinked for safe replacement; legacy real directories are
  # moved intact to a recoverable state backup. User-owned or otherwise
  # surprising content fails loudly.
  skillLinkMigrator = pkgs.writeShellApplication {
    name = "codex-migrate-skill-links";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    runtimeInputs = [pkgs.coreutils pkgs.findutils];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :

      nat_skill_backup_root="$1"
      shift
      nat_skill_has_legacy=0

      # Phase 1: validate the complete target set. Do not partially dismantle
      # managed links and only then discover user-owned content in a later
      # target or leaf.
      for nat_skill_dir in "$@"; do
        nat_skill_parent="$(${pkgs.coreutils}/bin/dirname "$nat_skill_dir")"
        nat_agents_parent="$(${pkgs.coreutils}/bin/dirname "$nat_skill_parent")"
        for nat_skill_ancestor in "$nat_agents_parent" "$nat_skill_parent"; do
          if [ -L "$nat_skill_ancestor" ]; then
            echo "ERROR: refusing to traverse symlinked Codex skill parent $nat_skill_ancestor" >&2
            false
          elif [ -e "$nat_skill_ancestor" ] && [ ! -d "$nat_skill_ancestor" ]; then
            echo "ERROR: refusing to traverse non-directory Codex skill parent $nat_skill_ancestor" >&2
            false
          fi
        done

        if [ -L "$nat_skill_dir" ]; then
          nat_skill_target="$(${pkgs.coreutils}/bin/readlink "$nat_skill_dir")"
          case "$nat_skill_target" in
            /nix/store/*) ;;
            *)
              echo "ERROR: refusing to replace non-store skill link $nat_skill_dir -> $nat_skill_target" >&2
              false
              ;;
          esac
        elif [ -d "$nat_skill_dir" ]; then
          nat_skill_has_legacy=1
          nat_skill_blocked=0
          while IFS= read -r -d "" nat_skill_entry; do
            if [ -L "$nat_skill_entry" ]; then
              nat_skill_target="$(${pkgs.coreutils}/bin/readlink "$nat_skill_entry")"
              case "$nat_skill_target" in
                /nix/store/*) ;;
                *)
                  echo "ERROR: refusing to migrate non-store skill link $nat_skill_entry -> $nat_skill_target" >&2
                  nat_skill_blocked=1
                  ;;
              esac
            elif [ ! -d "$nat_skill_entry" ]; then
              echo "ERROR: refusing to migrate user-owned skill entry $nat_skill_entry" >&2
              nat_skill_blocked=1
            fi
          done < <(${pkgs.findutils}/bin/find "$nat_skill_dir" -print0)

          if [ "$nat_skill_blocked" -ne 0 ]; then
            false
          fi

          nat_skill_backup="$nat_skill_backup_root/$(${pkgs.coreutils}/bin/basename "$nat_skill_dir")"
          if [ -e "$nat_skill_backup" ] || [ -L "$nat_skill_backup" ]; then
            echo "ERROR: refusing to overwrite existing Codex skill migration backup $nat_skill_backup" >&2
            false
          fi
        elif [ -e "$nat_skill_dir" ]; then
          echo "ERROR: refusing to replace non-directory skill target $nat_skill_dir" >&2
          false
        fi
      done

      # Phase 2: every target is safe. Preserve the old directory wholesale so
      # even intentionally empty subdirectories remain recoverable.
      if [ "$nat_skill_has_legacy" -ne 0 ]; then
        ${pkgs.coreutils}/bin/mkdir -p "$nat_skill_backup_root"
      fi
      for nat_skill_dir in "$@"; do
        if [ -L "$nat_skill_dir" ]; then
          ${pkgs.coreutils}/bin/rm -f -- "$nat_skill_dir"
        elif [ -d "$nat_skill_dir" ]; then
          nat_skill_backup="$nat_skill_backup_root/$(${pkgs.coreutils}/bin/basename "$nat_skill_dir")"
          ${pkgs.coreutils}/bin/mv -- "$nat_skill_dir" "$nat_skill_backup"
          echo "Backed up legacy Codex skill directory to $nat_skill_backup" >&2
        fi
      done
    '';
  };

  skillTargets = root: skills:
    map (name: "${root}/${name}") (builtins.attrNames skills);

  skillNameSafe = name:
    builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;

  mkSkillNameAssertions = skills:
    map (name: {
      assertion = skillNameSafe name;
      message = "Codex skill names must be single safe path components beginning with an alphanumeric character; invalid name: '${name}'";
    }) (builtins.attrNames skills);

  normalizeCodexSkills = skills:
    lib.mapAttrs (name: content:
      if (builtins.readFileType content) == "directory"
      then content
      else
        pkgs.runCommand "codex-skill-${builtins.hashString "sha256" name}" {} ''
          ${pkgs.coreutils}/bin/mkdir -p "$out"
          ${pkgs.coreutils}/bin/cp "${content}" "$out/SKILL.md"
        '')
    skills;

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
  # One native Codex role file: freeform TOML with the three keys every role
  # file needs. `name` defaults to the key. The other two default to null,
  # which means unset: a native-only record must set them, an assertion
  # rejects the null, and the null is never rendered.
  codexAgentRequiredFields = ["description" "developer_instructions"];
  codexAgentRecord = lib.types.submodule ({name, ...}: {
    freeformType = tomlFormat.type;
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = name;
        defaultText = lib.literalExpression "<name>";
        description = "Role name. Defaults to the attribute key, which is also the filename stem.";
      };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Guidance for selecting the role. Required by Codex role files.";
      };
      developer_instructions = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The role's instructions. Required by Codex role files.";
      };
    };
  });
  # The portable command handler plus Codex's own fields; other JSON fields
  # remain a native escape hatch through the freeform tail.
  codexHookHandlerType = aiTypes.extendSubmodule sharedHooks.portableHandlerType {
    freeformType = jsonFormat.type;
    options = {
      additionalContextLimit = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Approximate token threshold for large additionalContext output; zero disables truncation.";
      };
      commandWindows = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional Windows-only command override.";
      };
      statusMessage = lib.mkOption {
        type = aiTypes.optionalTextSource {
          description = "the status text displayed while the hook runs";
          enableDefault = false;
        };
        default = {};
        description = "Optional status text displayed while the hook runs.";
      };
    };
  };
  codexHookMatcherBlockType = sharedHooks.mkMatcherBlockType {
    handler = codexHookHandlerType;
    hooks = "Command handlers Codex runs for this matcher group.";
    matcher = "Optional regular-expression matcher restricting this hook group.";
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
        description = "User-level project trust, keyed by absolute path. A main-checkout entry covers linked worktrees; an empty worktree entry does not revoke it. An explicit worktree trust_level takes precedence. With Home Manager this is the only trust Codex keeps, because its trust prompt cannot write the Nix-owned user config.toml. Devenv rejects this bootstrap-global setting in project config.toml.";
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
  applyNamedPermissionRoots = settings: permissionRoots: let
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
    integrationFilesystem = lib.genAttrs (lib.unique permissionRoots) (_: "write");
  in
    if hasSelectedCustomProfile && permissionRoots != []
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
  applyIntegrationRoots = settings: integrationRoots:
    if settings.sandbox_mode == "workspace-write" && integrationRoots != []
    then applyWorkspaceWriteRoots settings integrationRoots
    else applyNamedPermissionRoots settings integrationRoots;
  hasPermissionProfiles = settings:
    aiCommon.filterNulls (lib.filterAttrs
      (name: _: builtins.elem name ["default_permissions" "permissions"])
      settings)
    != {};

  renderCodexServer = name: server: let
    rendered = removeAttrs (lib.ai.renderServer pkgs name server) ["type"];
    native = aiCommon.filterNulls (server.codex or {});
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

  # Codex's PROJECT_LOCAL_CONFIG_DENYLIST (config/src/loader/mod.rs).
  # cspell:ignore webrtc
  projectIgnoredKeys = [
    "apps_mcp_product_sku"
    "chatgpt_base_url"
    "experimental_realtime_webrtc_call_base_url"
    "experimental_realtime_ws_base_url"
    "model_provider"
    "model_providers"
    "notify"
    "openai_base_url"
    "otel"
    "profile"
    "profiles"
    "projects"
    "responses_api_metadata"
  ];

  # Codex's own default for `project_doc_max_bytes`: it reads at most this
  # many bytes of a project document and silently drops the rest.
  codexProjectDocMaxBytes = 32768;

  agentsMdUnits = mergedRules:
    lib.ai.transformers.agentsmd.agentsMdUnits {
      inherit (aiCommon) readContent resolveInclusion;
      rules = mergedRules;
      runtime = "codex";
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

  # Codex's execpolicy loader keeps a `rules/*.rules` entry only when
  # `DirEntry::file_type().is_file()` — which does not follow symlinks — so a
  # linked rule is skipped without a word ("loaded 0 .rules files"; codex-rs
  # core/src/exec_policy.rs, 0.156.0; CS-J9). The rules are therefore real
  # read-only copies on both backends, claimed file by file: Codex writes its
  # own `rules/default.rules` beside them, which a directory claim would delete.
  execpolicyLedger = "materialize/codex-execpolicy.manifest";
  execpolicyWriter = "materialize-codex-execpolicy-write";
  # Project config has a fixed native root; configDir customizes the user
  # layer only. Keep agents, hooks and execpolicy beside their config.
  nativeDirFor = backend: cfg:
    if backend == "hm"
    then cfg.configDir
    else ".codex";
  # The one AGENTS.md every context and rule unit lands in: the user file on
  # Home Manager, the shared repository key on devenv. The emitters and
  # `contentTargets` both read it.
  agentsMdPath = backend: cfg:
    if backend == "hm"
    then "${cfg.configDir}/${cfg.context.filename}"
    else cfg.context.filename;
  # The copies are ledger-owned, and nothing but this writer retracts them.
  # Declared outside the enable gate, and whether or not any rule is, so both
  # N→0 and the generation that DISABLES Codex drain what the previous one
  # wrote: an `allow` policy must not outlive its declaration for a codex
  # still on PATH. While disabled the adapter hands the writer no files, so it
  # only removes what the ledger recorded.
  codexExecpolicyWriterConfig = {
    backend,
    cfg,
    ...
  }: {
    ai.codex.activation.${execpolicyWriter} = {
      entry = {
        devenv = "ai:codex:materialize-execpolicy";
        hm = execpolicyWriter;
      };
      ledgers.${execpolicyLedger} = {
        codec = "dir";
        path = "${nativeDirFor backend cfg}/rules";
      };
      pruneEntry.hm = "materialize-codex-execpolicy-prune";
      runWhenDisabled = true;
    };
  };
  # Home Manager owns the user-scope daemon state under the Codex home: which
  # package the shared daemon runs (daemonSelect.nix) and the daemon's
  # settings.json. devenv writes neither; see its assertions.
  #
  # settings.json is all configuration (remote control, launch feature
  # overrides, shutdown grace, the updater), rendered from
  # `native.daemonSettings`. Codex saves it by writing a temporary and
  # renaming it over the path (settings.rs, rust-v0.157.1), which replaces a
  # store symlink with a real file and fails the next switch's link check. So
  # it is a read-only copy in a directory ledger that claims only that file,
  # beside the lock and pid files the daemon keeps there: an in-app change
  # lasts until the next activation, which backs it up and restores the
  # declaration. The pin's `updater.autoUpdateEnabled = false` is the second
  # guard, beside a selection the updater already rejects; Codex re-reads it
  # on every updater tick (update_loop.rs), so it also retires an updater left
  # running by an earlier upstream selection.
  #
  # Both writers run while disabled, so the generation that disables Codex or
  # the pin releases a store selection before GC can leave it dangling, and
  # the one that disables Codex retracts the copy.
  daemonSelectWriter = "codexDaemonSelect";
  daemonSettingsFile = cfg: "${cfg.configDir}/app-server-daemon/settings.json";
  daemonSettingsManifest = "materialize/codex-daemon-settings.manifest";
  daemonSettingsWriter = "materialize-codex-daemon-settings";
  # Only the layout the selector can release: a package whose complete Codex
  # package sits anywhere else would be pinned and then never unpinned.
  hasDaemonLayout = cfg:
    cfg.package
    != null
    && (cfg.package.passthru.codexPackage.root or null) == packageLayout.root;
  # `pinDaemonToPackage` is Home Manager-only; `or false` keeps this callable
  # from a devenv `cfg`, which has no such attribute at all.
  isDaemonPinned = cfg: cfg.enable && (cfg.pinDaemonToPackage or false) && hasDaemonLayout cfg;
  codexDaemonWriterConfig = {
    backend,
    cfg,
    ...
  }:
    lib.optionalAttrs (backend == "hm") {
      ai.codex.activation = {
        ${daemonSelectWriter} = {
          # The router supplies strict mode, the scoped subshell and the final
          # newline, so the command ends at its last character.
          command = ''run ${lib.getExe daemonSelect} "$HOME"/${lib.escapeShellArg cfg.configDir} ${lib.escapeShellArg (
              lib.optionalString (isDaemonPinned cfg) "${cfg.package}/${cfg.package.passthru.codexPackage.root}"
            )}'';
          runWhenDisabled = true;
        };
        ${daemonSettingsWriter} = {
          ledgers.${daemonSettingsManifest} = {
            codec = "dir";
            path = dirOf (daemonSettingsFile cfg);
          };
          pruneEntry = "${daemonSettingsWriter}-prune";
          runWhenDisabled = true;
        };
      };
    };
  mkExecpolicyEntries = prefix:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${prefix}/rules/${name}.rules" {
        entry = execpolicyWriter;
        facts.symlinkReadable = false;
        ledger = execpolicyLedger;
        # Every path-like value is a `source`, valid or not: `text` is a
        # string, so a directory or missing path typed as text fails eval
        # before mkExecpolicyAssertions can name what is wrong with it.
        content = lib.mkDefault (
          {
            _generated = true;
            _surface = "settings";
          }
          // (
            if isExecpolicyPathLike content
            then {source = content;}
            else {text = content;}
          )
        );
        # Source files retain their mode; inline policy is non-executable.
        executable =
          if isExecpolicyPathLike content
          then null
          else false;
      });

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

  # Every emitted agent (native record or raw TOML) becomes `<name>.toml`.
  # A native record's `description` and `developer_instructions` default to
  # null, so a native-only record that omits one would ship a role file
  # Codex rejects; the second assertion names the gap.
  mkAgentAssertions = {
    nativeAgents,
    rawAgents,
  }:
    lib.mapAttrsToList (name: _: {
      assertion =
        name
        != ""
        && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null
        && !lib.hasSuffix ".toml" name;
      message = "Codex agent '${name}' needs a safe filename stem without a .toml suffix.";
    }) (rawAgents // nativeAgents)
    ++ lib.mapAttrsToList (name: record: let
      missing = builtins.filter (field: record.${field} == null) codexAgentRequiredFields;
    in {
      assertion = missing == [];
      message = "${lib.showOption ["ai" "codex" "native" "agents" name]} is missing ${lib.concatStringsSep " and " missing}, which every Codex role file requires. Set them there, or define a normalized ${lib.showOption ["ai" "codex" "agents" name]} that supplies them.";
    })
    nativeAgents;

  # Codex reads `[mcp_servers.<name>.oauth] client_secret` as of rust-v0.158.0
  # (codex-rs/config/src/mcp_types.rs, McpServerOAuthConfig) and has no
  # environment-variable or file reference for it: `codex mcp add
  # --oauth-client-secret` writes the literal. Every declared route renders
  # through the store (the read-only config.toml on both backends, and the
  # agent layers), so each is refused rather than warned about.
  #
  # `tables` maps the option path of one server table to `{ agentScoped, table }`,
  # where `agentScoped` marks a table declared under
  # `ai.codex.native.agents.<name>.mcp_servers`.
  mkOAuthClientSecretAssertions = tables:
    lib.mapAttrsToList (optionPath: {
      agentScoped,
      table,
    }: {
      assertion = !(lib.hasAttrByPath ["oauth" "client_secret"] table);
      message =
        ''
          ${optionPath}.oauth.client_secret would copy an OAuth client secret
          into the world-readable Nix store: Codex reads it only as a literal in
          its config and has no environment-variable or file reference for it.
        ''
        + (
          if agentScoped
          then ''
            Remove it. Codex role layers ignore mcp_servers, so this server never
            takes effect from an agent either way: declare it at top level
            (ai.mcpServers or ai.codex.mcpServers) without a client secret.
          ''
          else ''
            Remove it. Codex takes this secret only as a literal in config.toml,
            so a confidential OAuth client can't be declared through Nix. For a
            server that accepts a static credential, set proxy.enable with the
            credential under proxy.headers (Home Manager's local credential proxy,
            so Codex sees only a loopback URL), or name an environment variable
            with codex.bearerTokenEnvVar or codex.envHttpHeaders.
          ''
        );
    })
    tables;

  # Server tables that lower into `[mcp_servers.<name>]`, keyed by the option
  # path that declares each one. A per-runtime entry replaces a root entry at
  # the same key, so its path names the declaration that actually renders.
  # Agent layers are included although rust-v0.158.0 discards `mcp_servers`
  # from a role file (codex-rs/core/src/agent/role_tests.rs,
  # apply_role_cannot_expand_parent_authority): the file is in the store all
  # the same.
  oauthSecretTables = {
    cfg,
    mergedServers,
  }: let
    owner = pool: name:
      if (cfg.${pool}.${name} or null) != null
      then "ai.codex.${pool}"
      else "ai.${pool}";
    serverTables = agentScoped: prefix: servers:
      lib.optionalAttrs (builtins.isAttrs servers)
      (lib.mapAttrs' (name: table: lib.nameValuePair "${prefix}.${name}" {inherit agentScoped table;}) servers);
  in
    lib.mapAttrs' (name: server:
      lib.nameValuePair "${owner "mcpServers" name}.${name}.codex" {
        agentScoped = false;
        table = server.codex or {};
      })
    mergedServers
    // serverTables false "ai.codex.native.settings.mcp_servers" (cfg.native.settings.mcp_servers or {})
    // lib.concatMapAttrs (name: value:
      serverTables true "ai.codex.native.agents.${name}.mcp_servers" (value.mcp_servers or {}))
    cfg.native.agents;

  # A native record renders to TOML; a raw entry is a TOML file already.
  # TOML has no null, so an unset required field is dropped rather than
  # rendered, in case a backend renders files before it checks assertions.
  mkAgentEntries = prefix: {
    nativeAgents,
    rawAgents,
  }: let
    dropUnset = lib.filterAttrs (field: value: !(builtins.elem field codexAgentRequiredFields && value == null));
    entry = name: content:
      lib.nameValuePair "${prefix}/agents/${name}.toml" {
        content = lib.mkDefault ({
            _generated = true;
            _surface = "agents";
          }
          // content);
        format = lib.mkDefault "toml";
        executable = null;
      };
  in
    lib.mapAttrs' (name: record: entry name {source = tomlFormat.generate "codex-agent-${name}.toml" (dropUnset record);}) nativeAgents
    // lib.mapAttrs' (name: value: entry name (agent.fileContent value)) rawAgents;

  # Lower Codex's typed statusMessage to its text, then render through the
  # shared renderer, which drops a null field. A portable handler has no such
  # field, so it lowers as a disabled one.
  renderHooks = hooks:
    sharedHooks.render (lib.mapAttrs (_event:
      map (block:
        block
        // {
          hooks = map (handler:
            handler
            // {
              statusMessage = aiTypes.enabledTextOrNull (handler.statusMessage or {enable = false;});
            })
          block.hooks;
        }))
    hooks);

  # Codex runs a user or project hook only while `hooks.state."<key>"` in a
  # USER config layer or a `-c` session flag carries its current hash
  # (hooks/src/config_rules.rs, hooks/src/engine/discovery.rs; rust-v0.158.0).
  # `/hooks` records that trust by writing user config.toml, which Nix owns
  # read-only, so Nix derives the same state for every generated handler:
  # Home Manager writes it into user config.toml, and devenv's launcher passes
  # it as one `-c` flag. The key is `<hooks.json path>:<event label>:<group
  # index>:<handler index>`. The hash is `sha256:` over the compact, key-sorted
  # JSON of the handler as Codex normalizes it (`hook_hash`,
  # `version_for_toml`): a matcher only on events that take one, the default
  # or clamped timeout, `async`, and a non-default `additionalContextLimit`
  # only on events that can emit context. `builtins.toJSON` emits exactly that
  # JSON. chatgpt-codex-hook-trust compares keys and hashes with the pinned
  # binary's own `hooks/list`.
  hookEventLabels = {
    Interrupt = "interrupt";
    PermissionRequest = "permission_request";
    PostCompact = "post_compact";
    PostToolUse = "post_tool_use";
    PreCompact = "pre_compact";
    PreToolUse = "pre_tool_use";
    SessionEnd = "session_end";
    SessionStart = "session_start";
    Stop = "stop";
    SubagentStart = "subagent_start";
    SubagentStop = "subagent_stop";
    UserPromptSubmit = "user_prompt_submit";
  };
  hookHandlerIdentity = event: handler: let
    timeout = handler.timeout or null;
    contextLimit = handler.additionalContextLimit or null;
  in
    {
      inherit (handler) command type;
      async = handler.async or false;
      timeout =
        if builtins.elem event ["Interrupt" "SessionEnd"]
        then
          lib.min 3 (lib.max 1 (
            if timeout == null
            then 1
            else timeout
          ))
        else if timeout == null
        then 600
        else timeout;
    }
    // lib.optionalAttrs (handler ? statusMessage) {inherit (handler) statusMessage;}
    // lib.optionalAttrs (
      contextLimit
      != null
      && contextLimit != 2500
      && builtins.elem event ["PostToolUse" "PreToolUse" "SessionStart" "SubagentStart" "UserPromptSubmit"]
    ) {additionalContextLimit = contextLimit;};
  hookTrustState = hooksFile: hooks:
    builtins.listToAttrs (lib.concatLists (lib.mapAttrsToList (event: groups:
      lib.optionals (hookEventLabels ? ${event}) (lib.concatLists (lib.imap0 (groupIndex: group:
        lib.imap0 (handlerIndex: handler:
          lib.nameValuePair "${hooksFile}:${hookEventLabels.${event}}:${toString groupIndex}:${toString handlerIndex}" {
            trusted_hash =
              "sha256:"
              + builtins.hashString "sha256" (builtins.toJSON (
                {
                  event_name = hookEventLabels.${event};
                  hooks = [(hookHandlerIdentity event handler)];
                }
                // lib.optionalAttrs (group ? matcher && !builtins.elem event ["Interrupt" "Stop" "UserPromptSubmit"]) {
                  inherit (group) matcher;
                }
              ));
          })
        group.hooks)
      groups)))
    (renderHooks hooks)));
  effectiveHooksOf = cfg: topHooks: sharedHooks.merge topHooks cfg.hooks;
  # The hooks.json Codex discovers for each backend, by the absolute path it
  # keys hook state with: the user layer's Codex home, or the project root's
  # `.codex`.
  hookTrustFor = {
    backend,
    cfg,
    config,
    topHooks,
    ...
  }:
    hookTrustState "${
      if backend == "hm"
      then config.home.homeDirectory
      else config.devenv.root
    }/${nativeDirFor backend cfg}/hooks.json" (effectiveHooksOf cfg topHooks);
  # One `-c` value for the whole table: Codex splits an override's key path at
  # every dot, so the state keys, which are paths, travel quoted inside an
  # inline TOML table (JSON string escapes are valid TOML basic strings).
  hookTrustOverride = state:
    "hooks.state={"
    + lib.concatStringsSep ", " (lib.mapAttrsToList (key: value: "${builtins.toJSON key} = {trusted_hash = ${builtins.toJSON value.trusted_hash}}") state)
    + "}";

  mkAgentsMd = {
    mergedContext,
    mergedRules,
  }:
    lib.ai.transformers.agentsmd.renderKeyed ({
        context = aiCommon.readContent mergedContext;
      }
      // agentsMdUnits mergedRules);
in
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
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
    defaults = {
      package = pkgs.ai.chatgpt-codex;
      packageText = import ../../../lib/ai/nat-package-text.nix {inherit lib;} "chatgpt-codex";
    };
    # The native agent layer (see mkRuntime.nix): each normalized agent
    # lowers into `ai.codex.native.agents.<name>`, one standalone TOML role
    # layer. `tools` is dropped: Codex role files have no allowlist field.
    # The builder declares `agents`, `agentsDir` (`.toml` role files here) and
    # `environmentVariables` (baked into the launcher, never the project
    # shell).
    agentNativeType = codexAgentRecord;
    agentTransformer = agent.renderCodex;
    agentsDirSuffixes = [".toml"];
    agentsDescriptionSuffix = "Each agent becomes one standalone TOML role layer under the active config directory's `agents/` child. Normal Codex config keys such as model, model_reasoning_effort, sandbox_mode, and skills.config go on `ai.codex.native.agents.<name>`. A raw entry is delivered verbatim and is not scanned for `mcp_servers.*.oauth.client_secret`. Codex role layers ignore mcp_servers (rust-v0.158.0), so declare MCP servers at top level instead.";

    options = {
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
          hatch. Codex runs a user or project hook only once its current hash
          is trusted, and Nix declares that trust for every generated handler:
          Home Manager writes it under `hooks.state` in user config.toml, and
          devenv's launcher passes it as a `-c` session flag. `/hooks` cannot
          record trust itself, because user config.toml is Nix-owned.
        '';
      };
      # `profiles` was removed in 2026-09-19. It was locked out from the day
      # it landed and cannot restrict Codex skill or AGENTS.md discovery.
      projectDocMaxBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = codexProjectDocMaxBytes;
        description = ''
          Maximum byte size of the Codex AGENTS.md, generated or a replacement
          you supply. The build of the delivery tree (formatted when a type is
          selected, or measured without formatting when it is `raw`, including
          a replacement that states no `format`) fails before Codex
          can silently truncate content beyond this limit. A value
          other than Codex's own default (32768) is also written to Codex's
          `project_doc_max_bytes` at default priority, so Codex reads as much
          as this limit admits. On devenv that key lands in the project's
          `.codex/config.toml`, which Codex applies only in a trusted project.
          Every module-provided Codex launcher warns on stderr when its
          project documentation exceeds the effective byte budget, including in
          repositories without devenv.
          Home Manager writes the key to user config, which no trust gates.
        '';
      };
      native.settings = lib.mkOption {
        type = codexSettingsType;
        default = {};
        description = ''
          Codex config.toml settings. Common stable keys are typed; unknown
          TOML-compatible keys are accepted as a native escape hatch. Both
          backends deliver the file as a read-only store symlink: Home Manager
          always owns user `config.toml`, and devenv writes the trusted
          project's `.codex/config.toml` when something is declared and
          rejects keys Codex ignores at project scope. Codex refuses to save
          an in-app change (`/model`, `/experimental`, `codex mcp add`, the
          trust prompt) into a Nix-owned file, so declare those here. Model and
          reasoning effort are omitted unless declared, leaving Codex’s lower
          config layers or built-in defaults to supply them. Normalized
          reasoning effort lowers to `model_reasoning_effort` at default
          priority; explicit native values override it.
        '';
      };
      native.daemonSettings = lib.mkOption {
        inherit (jsonFormat) type;
        default = {};
        example = {remoteControlEnabled = true;};
        description = ''
          The shared app-server daemon's `app-server-daemon/settings.json`
          under `configDir` (remoteControlEnabled, featureOverrides,
          shutdownGraceSeconds, updater), as a read-only copy Home Manager
          always owns. Codex's own saves (`codex app-server daemon
          enable-remote-control`, a daemon start with different launch
          features) last until the next activation, which backs the file up
          and restores the declaration. `pinDaemonToPackage` defaults
          `updater.autoUpdateEnabled` to false. Home Manager only: the file is
          user-global, and devenv, which runs Codex with `--no-daemon`, rejects
          a non-empty value.
        '';
      };
    };

    # Home Manager only: devenv always runs Codex with `--no-daemon`, so there
    # is no daemon for this to pin, and the option does not exist there at
    # all — setting it under `ai.codex.*` on devenv is an unknown-option
    # error rather than a rejected value.
    hm.options.pinDaemonToPackage = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run Codex's shared app-server daemon from `ai.codex.package`. Home
        Manager points `packages/app-server-daemon/current` in the Codex
        home at the package, defaults
        `native.daemonSettings.updater.autoUpdateEnabled` to false, and on a
        switch that changes the package stops the daemon so the next launch
        starts the new one.
        `false` releases the selection and restores upstream's copy and
        hourly self-update. That copy is taken from this package, whose
        executables and patched voice and zsh resources are dynamically
        linked against store paths nothing roots from the copy: it breaks
        after garbage collection until upstream's updater replaces it. Home
        Manager only.
      '';
    };

    installPackage = codexInstallPackage;
    contentTargets = {
      backend,
      cfg,
      mergedRules,
      ...
    }: {
      context = agentsMdPath backend cfg;
      rules = lib.mapAttrs (_name: _rule: agentsMdPath backend cfg) mergedRules;
    };
    migrationConfig = args:
      lib.mkMerge [
        (codexDaemonWriterConfig args)
        (codexExecpolicyWriterConfig args)
      ];
    # Every rule, scope-prefixed or indexed, under Codex's size limit.
    sharedAgentsMd = {
      cfg,
      mergedRules,
      ...
    }:
      {
        key = agentsMdPath "devenv" cfg;
        maxBytes = cfg.projectDocMaxBytes;
      }
      // agentsMdUnits mergedRules;
    config = {
      backend,
      cfg,
      config,
      hasMergedContext,
      mergedContext,
      mergedRules,
      mergedServers,
      mergedSkills,
      nativeAgents,
      options,
      rawAgents,
      resolvedSettings,
      topHooks,
      ...
    } @ args: let
      isHm = backend == "hm";
      nativeDir = nativeDirFor backend cfg;
      configFile = "${nativeDir}/config.toml";
      agentsMd = mkAgentsMd {inherit mergedContext mergedRules;};
      hasAgentsMdContent = hasMergedContext || mergedRules != {};
      agentsMdTarget = agentsMdPath "hm" cfg;
      hasNativeMcpServers = cfg.native.settings ? mcp_servers;
      effectiveHooks = effectiveHooksOf cfg topHooks;
      # Inline hook events and hooks.json are two representations of one
      # layer; the trust table beside them is neither.
      nativeHooks = cfg.native.settings.hooks or {};
      nativeHookEvents =
        if builtins.isAttrs nativeHooks
        then builtins.attrNames (removeAttrs nativeHooks ["state"])
        else ["hooks"];
      configuredGitRoot = lib.attrByPath ["git" "root"] null config;
      gitRoot =
        if configuredGitRoot != null
        then configuredGitRoot
        else config.devenv.root;
      gitCommonDir = resolveGitCommonDir gitRoot;
      legacySettings =
        if isHm
        then cfg.native.settings
        else applyWorkspaceWriteRoots cfg.native.settings ["${config.devenv.root}/.git"];
      integrationSettings = applyIntegrationRoots legacySettings cfg.internal._integration_writable_roots;
      permissionSettings =
        if isHm
        then integrationSettings
        else applyNamedPermissionRoots integrationSettings (lib.optional (gitCommonDir != null) gitCommonDir);
      # Home Manager's user config.toml also carries the trust of the hooks it
      # generates, beside any `hooks.state` declared for other hooks (see
      # `hookTrustFor`); devenv's launcher carries its own.
      hookTrust = hookTrustFor args;
      settings = lib.recursiveUpdate (aiCommon.filterNulls (permissionSettings
        // lib.optionalAttrs (mergedServers != {}) {
          mcp_servers = lib.mapAttrs renderCodexServer mergedServers;
        })) (lib.optionalAttrs (isHm && hookTrust != {}) {hooks.state = hookTrust;});
      ignoredSettings = lib.intersectLists projectIgnoredKeys (builtins.attrNames settings);
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
      codexSkillNames = builtins.attrNames mergedSkills;
      codexSkillTargets = skillTargets "${config.devenv.root}/.agents/skills" mergedSkills;
      # An unsafe skill name is reported by `mkSkillNameAssertions`, and
      # keeping it OUT of the file map is what lets that assertion be the
      # diagnostic: a traversing name reaches the map's own path validation
      # first otherwise, and that throw names neither the skill nor the option
      # that set it.
      codexSkills = normalizeCodexSkills (lib.filterAttrs (name: _source: skillNameSafe name) mergedSkills);
      skillBackupRoot =
        if isHm
        then "\${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/codex-skill-layout-b"
        else "${config.devenv.state}/nix-agentic-tools/codex-skill-layout-b";
    in
      lib.mkMerge [
        {
          ai.codex.internal._integration_writable_roots = lib.mkIf cfg.enable (lib.mkAfter (
            if isHm
            then ["${config.xdg.cacheHome}/nix"]
            else
              lib.optional (nixCacheRoot != null) nixCacheRoot
              ++ lib.optional (treefmtCacheRoot != null) treefmtCacheRoot
          ));
        }
        {
          ai.codex.native.settings = lib.mkMerge [
            (lib.mkIf (resolvedSettings.reasoningEffort != null) {
              model_reasoning_effort = lib.mkDefault resolvedSettings.reasoningEffort;
            })
            # The byte limit alone would let a raised limit pass the build
            # while Codex still truncated at its own default. Codex honors
            # this key from a trusted project's `.codex/config.toml` as well
            # as from user config (measured with `codex debug prompt-input`
            # on an 88 KB AGENTS.md: 744 of 2000 lines by default, all 2000
            # with the key raised).
            (lib.mkIf (cfg.projectDocMaxBytes != codexProjectDocMaxBytes) {
              project_doc_max_bytes = lib.mkDefault cfg.projectDocMaxBytes;
            })
          ];
          # `pinDaemonToPackage` is Home Manager-only (see its option), so this
          # must not force `options.ai.codex.pinDaemonToPackage` under devenv,
          # where neither it nor `cfg.pinDaemonToPackage` exist — the `isHm`
          # guard keeps the inner list a thunk devenv's branch never forces.
          # Default priority (unset) stays silent; an explicit `true` with no
          # package to pin warns once.
          warnings = lib.optionals (options ? warnings) (lib.optionals isHm (
            lib.optional
            (cfg.package == null && cfg.pinDaemonToPackage && options.ai.codex.pinDaemonToPackage.highestPrio < 1500)
            "ai.codex.package is null, so ai.codex.pinDaemonToPackage is inert: there is no package to pin the daemon to."
          ));
          assertions =
            mkAgentAssertions {inherit nativeAgents rawAgents;}
            ++ mkExecpolicyAssertions cfg.execpolicyRules
            ++ mkOAuthClientSecretAssertions (oauthSecretTables {inherit cfg mergedServers;})
            ++ mkSkillNameAssertions mergedSkills
            ++ [
              {
                assertion = mergedServers == {} || !hasNativeMcpServers;
                message = "ai.codex.native.settings.mcp_servers cannot be combined with ai.mcpServers/ai.codex.mcpServers; declare native extensions under each server's codex block";
              }
              {
                inherit (mkSandboxModelAssertion "ai.codex.native.settings" cfg.native.settings) assertion message;
              }
              {
                assertion = effectiveHooks == {} || nativeHookEvents == [];
                message = "ai.hooks/ai.codex.hooks cannot be combined with inline hook events in ai.codex.native.settings.hooks; choose hooks.json fanout or inline config.toml hooks for this layer (hooks.state may accompany either)";
              }
            ]
            ++ lib.optionals isHm [
              {
                assertion = !(cfg.execpolicyRules ? default);
                message = "ai.codex.execpolicyRules.default is reserved in Home Manager because Codex writes user allow-list decisions to rules/default.rules; choose another rule filename";
              }
              {
                # A null `package` is covered by the inert-setting warning
                # below, not this assertion — it must not fire on null alone.
                assertion = !cfg.pinDaemonToPackage || cfg.package == null || hasDaemonLayout cfg;
                message = "ai.codex.pinDaemonToPackage needs ai.codex.package to carry upstream's complete Codex package at ${packageLayout.root} (passthru.codexPackage.root), as this flake's chatgpt-codex does. Set ai.codex.package to that package, or set ai.codex.pinDaemonToPackage = false to leave the daemon to upstream's own copy and updater.";
              }
            ]
            ++ lib.optionals (!isHm) [
              # The launcher's `--no-daemon` makes both of these no-ops in a
              # project, so each is refused rather than silently dropped.
              {
                assertion = lib.attrByPath ["features" "daemon_auto_start"] null settings != true;
                message = ''
                  ai.codex.native.settings.features.daemon_auto_start = true has no
                  effect under devenv: its Codex launcher always passes --no-daemon,
                  so tool calls run in the project shell's environment. Enable the
                  daemon in the Home Manager user-level configuration.
                '';
              }
              {
                assertion = cfg.native.daemonSettings == {};
                message = ''
                  ai.codex.native.daemonSettings is Home Manager-only: the daemon's
                  settings.json lives in the user's Codex home, which devenv never
                  writes, and devenv's Codex launcher always passes --no-daemon.
                  Move it to the Home Manager user-level configuration.
                '';
              }
              {
                assertion = !(builtins.isAttrs nativeHooks && nativeHooks ? state);
                message = ''
                  ai.codex.native.settings.hooks.state has no effect in project
                  config.toml: Codex reads hook trust only from user config and
                  session flags. devenv's launcher already trusts the hooks it
                  generates; declare trust for any other hook with Home Manager.
                '';
              }
              {
                assertion = ignoredSettings == [];
                message = ''
                  ai.codex.native.settings contains keys Codex ignores in project config:
                  ${lib.concatStringsSep ", " ignoredSettings}. Move them to the
                  Home Manager user-level configuration.
                '';
              }
            ];
        }
        {
          ai.codex.files = lib.mkMerge [
            (mkAgentEntries nativeDir {inherit nativeAgents rawAgents;})
            (mkExecpolicyEntries nativeDir cfg.execpolicyRules)
            (lib.mkIf (effectiveHooks != {}) {
              "${nativeDir}/hooks.json" = {
                content = lib.mkDefault {
                  _generated = true;
                  _surface = "hooks";
                  source = jsonFormat.generate (
                    if isHm
                    then "codex-hooks.json"
                    else "codex-project-hooks.json"
                  ) {hooks = renderHooks effectiveHooks;};
                };
                format = lib.mkDefault "json";
                executable = null;
              };
            })
            # Codex discovers a skill when the skill DIRECTORY is itself a
            # symlink, and not when the backend creates a real directory of
            # symlinked leaves — a measured consumer fact, and the whole reason
            # this runtime delivers a directory source with `recursive` off.
            # `normalizeCodexSkills` wraps single-file skills into directories.
            (helpers.mkSkillFiles {
              configDir = ".agents";
              recursive = false;
              skills = codexSkills;
            })
          ];
        }
        {
          ai.codex.activation.codexMigrateSkillLinks = lib.mkIf (mergedSkills != {}) (
            {
              # The router supplies strict mode and the scoped subshell. End
              # each command at its last character: it also supplies a newline.
              command =
                if isHm
                then ''
                  nat_codex_skill_targets=()
                  for nat_codex_skill_name in ${lib.escapeShellArgs codexSkillNames}; do
                    nat_codex_skill_targets+=("$HOME/.agents/skills/$nat_codex_skill_name")
                  done
                  run ${lib.getExe skillLinkMigrator} "${skillBackupRoot}" "''${nat_codex_skill_targets[@]}"''
                else ''exec ${lib.getExe skillLinkMigrator} ${lib.escapeShellArg skillBackupRoot} ${lib.escapeShellArgs codexSkillTargets}'';
              entry = {
                devenv = "ai:codex:migrate-skill-links";
                hm = "codexMigrateSkillLinks";
              };
            }
            # HM must move old directories before its collision check, without
            # waiting for link generation. devenv uses the default file/shell
            # edges, including the adapter's conditional devenv:files edge.
            // lib.optionalAttrs isHm {
              after = [];
              before = ["linkCheck"];
            }
          );
        }

        {
          # config.toml, user or project: one entry, delivered as a store
          # symlink. Every Codex config writer resolves the link and writes a
          # temporary beside its store target (utils/path-utils,
          # `write_atomically`), so an in-app save fails with "failed to
          # persist config … Permission denied" rather than diverging from the
          # declaration; chatgpt-codex-readonly-config holds that. Ordinary
          # leaves, not a whole-content default, so a consumer extending the
          # document keeps the generated siblings. Home Manager always owns the
          # user file; devenv writes the project file only when something is
          # declared.
          ai.codex.files.${configFile} = lib.mkIf (isHm || settings != {}) {
            content = {
              _generated = true;
              _surface = "settings";
              value = settings;
            };
            format = "toml";
          };
        }

        (lib.optionalAttrs (!isHm && options ? enterShell) {
          enterShell = lib.mkIf (cfg.files ? ${configFile} && runtimeFiles.isLive cfg.files.${configFile}) ''
            ${lib.getExe projectTrustNotice} "$DEVENV_ROOT"
            ${lib.getExe permissionLayersNotice} "$DEVENV_ROOT"/${lib.escapeShellArg configFile}
          '';
        })

        (lib.optionalAttrs isHm (lib.mkMerge [
          {
            # See `daemonSettingsWriter`.
            ai.codex.files.${daemonSettingsFile cfg} = {
              content = {
                _generated = true;
                _surface = "settings";
                value = cfg.native.daemonSettings;
              };
              entry = daemonSettingsWriter;
              format = "json";
              ledger = daemonSettingsManifest;
              method = "copy-ro";
            };
            ai.codex.native.daemonSettings = lib.mkIf cfg.pinDaemonToPackage {
              updater.autoUpdateEnabled = lib.mkDefault false;
            };
          }
          {
            # A daemon keeps the environment of whichever client started it,
            # and serves every later client with it: per-client environment
            # isolation is not provided (codex-rs/app-server-daemon/README.md,
            # rust-v0.157.1). With sessions open across several direnv or
            # devenv projects, the first launch would decide the tool
            # environment of all of them, so auto-start is opt-in here.
            ai.codex.native.settings.features.daemon_auto_start = lib.mkDefault false;
          }
          {
            # Codex silently drops whatever is past this. Keyed by path, so
            # the file checked is whichever one wins at `.codex/AGENTS.md`,
            # a consumer's replacement included. On devenv the shared
            # AGENTS.md owner carries the limit (`sharedAgentsMd`).
            ai.codex._maxBytes.${agentsMdTarget} = {
              bytes = cfg.projectDocMaxBytes;
              hint = "Trim or replace the final content, or raise ai.codex.projectDocMaxBytes.";
            };
          }
          (lib.mkIf hasAgentsMdContent {
            # The ONE generated entry whose priority stays on the whole entry
            # rather than moving onto `content`. Deciding between enabled and
            # empty generated content reads the COMPOSED body, and the body may
            # come from a store source a consumer has already replaced. The
            # `mkDefault` wrapper lets priority filtering discard that source
            # unread. A consumer defining only a sibling field therefore must
            # also restate content; validation diagnoses an empty survivor.
            ai.codex.files.${agentsMdTarget} = lib.mkDefault (
              if agentsMd == ""
              then {
                content = {
                  _generated = true;
                  _surface = "context";
                  enable = false;
                  text = agentsMd;
                };
                format = "markdown";
              }
              else {
                content = {
                  _generated = true;
                  _surface = "context";
                  enable = true;
                  text = agentsMd;
                };
                format = "markdown";
              }
            );
          })
        ]))
      ];
  }
