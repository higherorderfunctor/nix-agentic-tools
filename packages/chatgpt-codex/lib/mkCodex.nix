# Codex-specific factory-of-factory.
{
  lib,
  pkgs,
  ...
}: let
  agent = import ../../../lib/ai/agent.nix {inherit lib;};
  sharedHooks = import ../../../lib/ai/hooks.nix {inherit lib;};
  codexExtracted = builtins.fromJSON (builtins.readFile ../../../overlays/chatgpt-codex-extracted.json);
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  jsonFormat = pkgs.formats.json {};
  tomlFormat = pkgs.formats.toml {};

  stableFeatureNames = map (feature: feature.name) (
    builtins.filter (feature: feature.maturity == "stable") codexExtracted.features
  );
  reasoningEffortLevels = lib.unique (
    lib.concatMap (model: model.reasoningLevels) codexExtracted.models
  );
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
      };
      matcher = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };
  approvalPolicyType =
    lib.types.either
    (lib.types.enum ["never" "on-request" "untrusted"])
    (lib.types.submodule {
      options.granular =
        lib.genAttrs [
          "mcp_elicitations"
          "request_permissions"
          "rules"
          "sandbox_approval"
          "skill_approval"
        ] (_:
          lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
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
      };
      allow_upstream_proxy = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      dangerously_allow_all_unix_sockets = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      dangerously_allow_non_loopback_proxy = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      domains = lib.mkOption {
        type = lib.types.attrsOf networkAccessType;
        default = {};
      };
      enable_socks5 = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      enable_socks5_udp = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      enabled = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
      };
      mode = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["full" "limited"]);
        default = null;
      };
      proxy_url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      socks_url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      unix_sockets = lib.mkOption {
        type = lib.types.attrsOf networkAccessType;
        default = {};
      };
    };
  };
  permissionProfileType = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      extends = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Parent named profile or the :read-only or :workspace built-in.";
      };
      filesystem = lib.mkOption {
        type = lib.types.nullOr permissionFilesystemType;
        default = null;
      };
      network = lib.mkOption {
        type = lib.types.nullOr permissionNetworkType;
        default = null;
      };
      workspace_roots = lib.mkOption {
        type = lib.types.attrsOf lib.types.bool;
        default = {};
      };
    };
  };
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

  resolveText = value:
    if builtins.isPath value
    then builtins.readFile value
    else value;

  renderScope = paths:
    lib.optionalString (paths != null && paths != []) (
      "_Apply this guidance only when working with files matching: "
      + lib.concatMapStringsSep ", " (path: "`${path}`") paths
      + "_\n\n"
    );

  shouldRender = _name: fragment:
    (fragment.paths or null) == null || !(fragment.skipIfUnsupported or false);

  renderFragment = fragment:
    renderScope (fragment.paths or null)
    + lib.ai.transformers.agentsmd.render (fragment
      // {text = resolveText fragment.text;});

  mkInstructionChunk = instruction:
    lib.optionalString (instruction ? name) "<!-- instruction: ${instruction.name} -->\n"
    + renderFragment instruction;

  mkRuleChunk = name: rule:
    "<!-- rule: ${name} -->\n"
    + renderFragment rule;

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
        instructions, codex? } form, have a safe filename stem without a
        .toml suffix, and keep name/description/developer_instructions out of
        the codex extension.
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
    cfg,
    mergedInstructions,
    mergedRules,
    topContext,
  }: let
    effectiveContext =
      if cfg.context != null
      then cfg.context
      else topContext;
    contextText =
      if effectiveContext == null
      then ""
      else resolveText effectiveContext;
    instructionChunks =
      map mkInstructionChunk
      (builtins.filter (shouldRender null) mergedInstructions);
    ruleChunks =
      lib.mapAttrsToList mkRuleChunk
      (lib.filterAttrs shouldRender mergedRules);
    chunks =
      lib.optional (contextText != "") contextText
      ++ instructionChunks
      ++ ruleChunks;
  in
    builtins.concatStringsSep "\n\n" chunks;

  mkSizeAssertion = {
    agentsMd,
    cfg,
    mergedInstructions,
    mergedRules,
    topContext,
  }: let
    effectiveContext =
      if cfg.context != null
      then cfg.context
      else topContext;
    size = text: builtins.stringLength (resolveText text);
    contextContribution =
      lib.optional (effectiveContext != null && resolveText effectiveContext != "")
      "context=${toString (size effectiveContext)} bytes";
    instructionContributions =
      lib.imap0 (index: instruction: "instruction:${instruction.name or (toString index)}=${toString (builtins.stringLength (mkInstructionChunk instruction))} bytes")
      (builtins.filter (shouldRender null) mergedInstructions);
    ruleContributions =
      lib.mapAttrsToList (name: rule: "rule:${name}=${toString (builtins.stringLength (mkRuleChunk name rule))} bytes")
      (lib.filterAttrs shouldRender mergedRules);
    renderedBytes = builtins.stringLength agentsMd;
  in {
    assertion = renderedBytes <= cfg.projectDocMaxBytes;
    message = ''
      Codex AGENTS.md renders to ${toString renderedBytes} bytes, exceeding
      ai.codex.projectDocMaxBytes (${toString cfg.projectDocMaxBytes} bytes).
      Contributions: ${lib.concatStringsSep ", " (contextContribution ++ instructionContributions ++ ruleContributions)}.
      Trim the contributing content or raise ai.codex.projectDocMaxBytes.
    '';
  };

  mkPathAssertions = {
    mergedInstructions,
    mergedRules,
  }:
    lib.imap0 (index: instruction: {
      assertion = (instruction.paths or null) != [];
      message = "ai.codex.instructions[${toString index}].paths must be null or a non-empty list";
    })
    mergedInstructions
    ++ lib.mapAttrsToList (name: rule: {
      assertion = rule.paths != [];
      message = "ai.codex.rules.${name}.paths must be null or a non-empty list";
    })
    mergedRules;
in
  lib.ai.app.mkAiApp {
    name = "codex";
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults.package = pkgs.ai.chatgpt-codex;

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
      context = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
        default = null;
        description = ''
          Codex-specific global context. When null, falls back to top-level
          `ai.context`.
        '';
        example = lib.literalExpression "./codex-context.md";
      };
      agents = lib.mkOption {
        type = lib.types.attrsOf codexAgentType;
        default = {};
        description = ''
          Codex-specific semantic agents merged with portable `ai.agents`;
          collisions fail. Each record becomes one standalone TOML layer under
          the active config directory's `agents/` child. Put normal Codex
          config keys such as model, model_reasoning_effort, sandbox_mode,
          mcp_servers, and skills.config under the record's `codex` extension.
        '';
      };
      execpolicyRules = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
        default = {};
        description = ''
          Codex command-execution policy written as Starlark `.rules` files.
          This is separate from Markdown `ai.rules`, which contributes durable
          instructions to AGENTS.md.
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
      projectDocMaxBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 32768;
        description = ''
          Maximum byte size of the generated Codex AGENTS.md. Evaluation fails
          before Codex can silently truncate content beyond this limit.
        '';
      };
      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = tomlFormat.type;
          options = {
            agents = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                freeformType = tomlFormat.type;
                options = {
                  default_subagent_model = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                  };
                  default_subagent_reasoning_effort = lib.mkOption {
                    type = lib.types.nullOr (lib.types.enum reasoningEffortLevels);
                    default = null;
                  };
                  enabled = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                  };
                  interrupt_message = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                  };
                  max_concurrent_threads_per_session = lib.mkOption {
                    type = lib.types.nullOr lib.types.ints.positive;
                    default = null;
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
              description = "Named or built-in beta permission profile Codex applies by default.";
            };
            features = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                freeformType = lib.types.attrsOf lib.types.bool;
                options = lib.genAttrs stableFeatureNames (_:
                  lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
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
              description = "Beta named least-privilege filesystem and network permission profiles.";
            };
            projects = lib.mkOption {
              type = lib.types.attrsOf (lib.types.submodule {
                options.trust_level = lib.mkOption {
                  type = lib.types.enum ["trusted" "untrusted"];
                  description = "Whether Codex loads project-scoped .codex configuration, hooks, and rules for this path.";
                };
              });
              default = {};
              description = "User-level project trust declarations. Devenv rejects this bootstrap-global setting.";
            };
            sandbox_mode = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["danger-full-access" "read-only" "workspace-write"]);
              default = null;
              description = "OS-enforced filesystem and network sandbox policy for model-generated commands.";
            };
            sandbox_workspace_write = lib.mkOption {
              type = lib.types.nullOr (lib.types.submodule {
                options = {
                  exclude_slash_tmp = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                  };
                  exclude_tmpdir_env_var = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                  };
                  network_access = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                  };
                  writable_roots = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [];
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
        default = {};
        description = ''
          Codex config.toml settings. Common stable keys are typed; unknown
          TOML-compatible keys are accepted as a native escape hatch. Home
          Manager writes user config, while devenv writes trusted-project
          config and rejects keys Codex ignores at project scope.
        '';
      };
    };

    hm.config = {
      cfg,
      mergedInstructions,
      mergedRules,
      mergedServers,
      mergedSkills,
      mergedAgents,
      topContext,
      topHooks,
      topSettings,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit cfg mergedInstructions mergedRules topContext;};
      hasNativeMcpServers = cfg.settings ? mcp_servers;
      hasLegacySandbox =
        cfg.settings.sandbox_mode
        != null
        || cfg.settings.sandbox_workspace_write != null;
      usesPermissionProfiles = hasPermissionProfiles cfg.settings;
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      settings = helpers.filterNulls (cfg.settings
        // lib.optionalAttrs (mergedServers != {}) {
          mcp_servers = lib.mapAttrs renderCodexServer mergedServers;
        });
    in {
      ai.codex.settings = lib.mkIf (topSettings.reasoningEffort != null) {
        model_reasoning_effort = lib.mkDefault topSettings.reasoningEffort;
      };
      assertions =
        mkPathAssertions {inherit mergedInstructions mergedRules;}
        ++ mkAgentAssertions mergedAgents
        ++ mkExecpolicyAssertions cfg.execpolicyRules
        ++ [
          (mkSizeAssertion {inherit agentsMd cfg mergedInstructions mergedRules topContext;})
          {
            assertion = mergedServers == {} || !hasNativeMcpServers;
            message = "ai.codex.settings.mcp_servers cannot be combined with ai.mcpServers/ai.codex.mcpServers; declare native extensions under each server's codex block";
          }
          {
            assertion = !hasLegacySandbox || !usesPermissionProfiles;
            message = "ai.codex.settings must use either sandbox_mode/sandbox_workspace_write or default_permissions/permissions, never both";
          }
          {
            assertion = !(cfg.execpolicyRules ? default);
            message = "ai.codex.execpolicyRules.default is reserved in Home Manager because Codex writes user allow-list decisions to rules/default.rules; choose another rule filename";
          }
          {
            assertion = effectiveHooks == {} || !(cfg.settings ? hooks);
            message = "ai.hooks/ai.codex.hooks cannot be combined with ai.codex.settings.hooks; choose hooks.json fanout or inline config.toml hooks for this layer";
          }
        ];
      home.file = lib.mkMerge [
        (lib.mkIf (agentsMd != "") {
          "${cfg.configDir}/AGENTS.md".text = agentsMd;
        })
        (helpers.mkSkillEntries ".agents" mergedSkills)
        (mkAgentEntries cfg.configDir mergedAgents)
        (mkExecpolicyEntries cfg.configDir cfg.execpolicyRules)
        (lib.mkIf (effectiveHooks != {}) {
          "${cfg.configDir}/hooks.json".source = jsonFormat.generate "codex-hooks.json" {hooks = renderHooks effectiveHooks;};
        })
        (lib.mkIf (settings != {}) {
          "${cfg.configDir}/config.toml".source = tomlFormat.generate "codex-config.toml" settings;
        })
      ];
      home.packages = [cfg.package];
    };

    devenv.config = {
      cfg,
      mergedInstructions,
      mergedRules,
      mergedServers,
      mergedSkills,
      mergedAgents,
      topContext,
      topHooks,
      topSettings,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit cfg mergedInstructions mergedRules topContext;};
      hasNativeMcpServers = cfg.settings ? mcp_servers;
      hasLegacySandbox =
        cfg.settings.sandbox_mode
        != null
        || cfg.settings.sandbox_workspace_write != null;
      usesPermissionProfiles = hasPermissionProfiles cfg.settings;
      effectiveHooks = sharedHooks.merge topHooks cfg.hooks;
      settings = helpers.filterNulls (cfg.settings
        // lib.optionalAttrs (mergedServers != {}) {
          mcp_servers = lib.mapAttrs renderCodexServer mergedServers;
        });
      ignoredSettings = lib.intersectLists projectIgnoredKeys (builtins.attrNames settings);
    in {
      ai.codex.settings = lib.mkIf (topSettings.reasoningEffort != null) {
        model_reasoning_effort = lib.mkDefault topSettings.reasoningEffort;
      };
      assertions =
        mkPathAssertions {inherit mergedInstructions mergedRules;}
        ++ mkAgentAssertions mergedAgents
        ++ mkExecpolicyAssertions cfg.execpolicyRules
        ++ [
          (mkSizeAssertion {inherit agentsMd cfg mergedInstructions mergedRules topContext;})
          {
            assertion = mergedServers == {} || !hasNativeMcpServers;
            message = "ai.codex.settings.mcp_servers cannot be combined with ai.mcpServers/ai.codex.mcpServers; declare native extensions under each server's codex block";
          }
          {
            assertion = !hasLegacySandbox || !usesPermissionProfiles;
            message = "ai.codex.settings must use either sandbox_mode/sandbox_workspace_write or default_permissions/permissions, never both";
          }
          {
            assertion = ignoredSettings == [];
            message = ''
              ai.codex.settings contains keys Codex ignores in project config:
              ${lib.concatStringsSep ", " ignoredSettings}. Move them to the
              Home Manager user-level configuration.
            '';
          }
          {
            assertion = effectiveHooks == {} || !(cfg.settings ? hooks);
            message = "ai.hooks/ai.codex.hooks cannot be combined with ai.codex.settings.hooks; choose hooks.json fanout or inline config.toml hooks for this layer";
          }
        ];
      files = lib.mkMerge [
        (lib.mkIf (agentsMd != "") {
          "AGENTS.md".text = agentsMd;
        })
        (helpers.mkDevenvSkillEntries ".agents" mergedSkills)
        (mkAgentEntries ".codex" mergedAgents)
        (mkExecpolicyEntries ".codex" cfg.execpolicyRules)
        (lib.mkIf (effectiveHooks != {}) {
          ".codex/hooks.json".source = jsonFormat.generate "codex-project-hooks.json" {hooks = renderHooks effectiveHooks;};
        })
        (lib.mkIf (settings != {}) {
          ".codex/config.toml".source = tomlFormat.generate "codex-project-config.toml" settings;
        })
      ];
      packages = [cfg.package];
    };
  }
