# Kimchi-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Kimchi AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# Kimchi has distinct user and project config namespaces. Home Manager writes
# ~/.config/kimchi/{config.json,harness/}; devenv writes only Kimchi's native
# project paths under the repository root. Both backends reconcile the three
# mutable JSON documents (config.json, harness settings, mcp.json) by leaf; the
# remaining files are immutable and symlink-readable.
{
  lib,
  pkgs,
  ...
}: let
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  aiCommon = import ../../../lib/ai/ai-common.nix {inherit lib;};
  dirHelpers = import ../../../lib/ai/dir-helpers.nix {inherit lib;};
  mcpLib = import ../../../lib/mcp.nix {inherit lib;};
  sharedHooks = import ../../../lib/ai/hooks.nix {inherit lib;};
  userScopeOnlyHarnessSettingKeys = import ./user-scope-only-harness-settings.nix;

  # pi 0.85.1 derives CONFIG_DIR_NAME from Kimchi's packaged piConfig.configDir.
  # That fixed project namespace is independent of ai.kimchi.configDir, which
  # selects the Home Manager output root.
  projectHarnessDir = ".config/kimchi/harness";
  projectContextFilename = "AGENTS.md";

  # Kimchi 1.1.30 reads each modelRoles value as a provider/model string, and
  # for delegable roles also a non-empty list of them; orchestrator and
  # compactor take one string only. Any other shape is discarded with a
  # warning at runtime (src/extensions/orchestration/model-roles.ts:83-91,
  # 117-122 and 144-181), so the module rejects it at evaluation instead.
  roleModelType = lib.types.addCheck lib.types.str (value: builtins.match "[[:space:]]*" value == null);
  roleModelsType = lib.types.addCheck (lib.types.listOf roleModelType) (values: values != []);
  modelRoleNames = ["builder" "compactor" "explorer" "judge" "orchestrator" "planner" "researcher" "reviewer"];
  singleModelRoles = ["compactor" "orchestrator"];

  # Kimchi 1.1.30's lifecycle events, FULL_COMMAND_HOOK_EVENTS
  # (src/extensions/hook-adapters/discovery.ts:29-50). Every portable event
  # except PermissionRequest is among them, and the reader skips an event
  # outside this list without a word (:131).
  hookEvents = [
    "MessageEnd"
    "MessageStart"
    "ModelSelect"
    "Notification"
    "PostCompact"
    "PostToolBatch"
    "PostToolUse"
    "PostToolUseFailure"
    "PreCompact"
    "PreToolUse"
    "SessionEnd"
    "SessionStart"
    "Stop"
    "StopFail"
    "SubagentStart"
    "SubagentStop"
    "TaskCompleted"
    "TurnStart"
    "UserBash"
    "UserPromptSubmit"
  ];
  # Shared groups first, Kimchi's own appended, restricted to the events
  # Kimchi reads: the one portable event it lacks is warned about in
  # lib/ai/delivery-warnings.nix instead of written.
  projectHooksFor = {
    cfg,
    topHooks,
  }:
    lib.filterAttrs (event: blocks: builtins.elem event hookEvents && blocks != [])
    (sharedHooks.merge topHooks cfg.hooks);
  hasHookHandlers = hooks: lib.any (lib.any (block: block.hooks != [])) (builtins.attrValues hooks);

  # The delivery function and package hook need the same settings, env and
  # context values from merged inputs; prepare them once.
  mkPrep = {
    cfg,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables ? {},
    mergedContext,
    requiredProjectRoot ? null,
  }: let
    contextEntry = aiCommon.contentFileEntry mergedContext;

    # Non-secret env vars — baked into the wrapper via `--set`.
    kimchiEnvVars =
      lib.optionalAttrs cfg.noUpdateCheck {KIMCHI_NO_UPDATE_CHECK = "1";}
      // lib.optionalAttrs (cfg.telemetry != null) {
        KIMCHI_TELEMETRY_ENABLED =
          if cfg.telemetry
          then "1"
          else "0";
      };
    # Module-contributed defaults (e.g. the sandbox-safe GIT_SSH_COMMAND) sit
    # UNDER the consumer's pool, matching every other harness. `kimchiEnvVars`
    # stays last: those are derived from typed options, not free-form entries.
    effectiveEnvVars = moduleEnvironmentVariables // mergedEnvironmentVariables // kimchiEnvVars;

    # The Cast AI key is a secret: read it from its decrypted file (or
    # helper) at launch via the repo's shared credential snippet, so it is
    # never serialized into the world-readable /nix/store. Same mechanism
    # the MCP servers use (lib/mcp.nix); sops-nix / agenix agnostic.
    credSnippet =
      if cfg.apiKey != null
      then mcpLib.mkCredentialsSnippet pkgs {apiKey.envVar = "KIMCHI_API_KEY";} {inherit (cfg) apiKey;}
      else "";

    # Kimchi resolves project config, MCP servers, and harness settings from
    # process.cwd() exactly. Changing cwd here would also change the directory
    # seen by Kimchi's tools, so reject descendant launches instead.
    exactCwdGuard = lib.optionalString (requiredProjectRoot != null) ''
      kimchi_project_root=${lib.escapeShellArg requiredProjectRoot}
      if [ "$(${pkgs.coreutils}/bin/realpath -- "$PWD")" != "$(${pkgs.coreutils}/bin/realpath -- "$kimchi_project_root")" ]; then
        printf '%s\n' "Kimchi project files are configured at $kimchi_project_root; run kimchi from that devenv root." >&2
        exit 1
      fi
    '';

    # wrapProgram args: `--set` for non-secret env, `--run` for the
    # runtime secret export. Joined with a single space on the continued
    # line — never a backslash-newline, which breaks multi-arg wrapping.
    wrapArgs =
      lib.mapAttrsToList (k: v: "--set ${lib.escapeShellArg k} ${lib.escapeShellArg v}") effectiveEnvVars
      ++ lib.optional (exactCwdGuard != "") "--run ${lib.escapeShellArg exactCwdGuard}"
      ++ lib.optional (credSnippet != "") "--run ${lib.escapeShellArg credSnippet}";

    wrappedPackage = pkgs.symlinkJoin {
      name = "kimchi-wrapped";
      paths = [cfg.package];
      nativeBuildInputs = [pkgs.makeWrapper];
      postBuild = lib.optionalString (wrapArgs != []) ''
        wrapProgram $out/bin/kimchi \
          ${lib.concatStringsSep " " wrapArgs}
      '';
    };
  in {
    inherit contextEntry;
    filteredSettings = aiCommon.filterNulls cfg.native.settings;
    filteredHarnessSettings = aiCommon.filterNulls cfg.native.harnessSettings;
    package =
      if wrapArgs != []
      then wrappedPackage
      else cfg.package;
  };
  # Both backends install the same prepared wrapper (env + the runtime secret,
  # which is cat'd at launch so it never enters the store). Handed to the
  # shared transform's `installPackage` hook, which owns the `home.packages` /
  # `packages` lowering. The second `mkPrep` application re-evaluates (Nix caches
  # thunks, not function applications at distinct call sites) but
  # yields the identical derivation, so it adds no build.
  kimchiInstallPackage = {
    cfg,
    mergedContext,
    mergedEnvironmentVariables,
    moduleEnvironmentVariables,
    ...
  }:
    (mkPrep {inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;}).package;

  kimchiDevenvInstallPackage = {
    cfg,
    config,
    mergedAgents,
    mergedContext,
    mergedEnvironmentVariables,
    mergedServers,
    moduleEnvironmentVariables,
    topHooks,
    ...
  }: let
    hasExactCwdProjectFiles =
      aiCommon.filterNulls cfg.nativeSettings
      != {}
      || aiCommon.filterNulls cfg.harnessSettings != {}
      || mergedServers != {}
      || mergedAgents != {}
      || hasHookHandlers (projectHooksFor {inherit cfg topHooks;});
  in
    (mkPrep {
      inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;
      requiredProjectRoot =
        if hasExactCwdProjectFiles
        then config.devenv.root
        else null;
    }).package;
  # One delivery description for both backends. The two former callback bodies
  # were near-duplicates: they differed only in which native sink each wrote,
  # which is exactly the decision the delivery layer now makes from the
  # consumer facts below.
  kimchiDelivery = backend: {
    cfg,
    config,
    hasMergedContext,
    mergedAgents,
    mergedContext,
    mergedEnvironmentVariables,
    mergedServers,
    mergedSkills,
    moduleEnvironmentVariables,
    resolvedSettings,
    topHooks,
    ...
  }: let
    prep = mkPrep {inherit cfg mergedContext mergedEnvironmentVariables moduleEnvironmentVariables;};
    inherit (prep) contextEntry filteredHarnessSettings filteredSettings;
    isDevenv = backend == "devenv";
    configPath =
      if isDevenv
      then ".kimchi/config.json"
      else "${cfg.configDir}/config.json";
    harness =
      if isDevenv
      then projectHarnessDir
      else "${cfg.configDir}/harness";
    harnessSettingsPath = "${harness}/settings.json";
    mcpPath =
      if isDevenv
      then ".kimchi/mcp.json"
      else "${harness}/mcp.json";
    skillRoot =
      if isDevenv
      then ".kimchi"
      else harness;
    # Kimchi 1.1.30 loads `<agentDir>/agents/*.md` and a trusted project's
    # `.kimchi/agents/*.md` (src/extensions/agents/personas/custom-agents.ts:21-35).
    agentsDir =
      if isDevenv
      then ".kimchi/agents"
      else "${harness}/agents";
    unknownModelRoles = lib.subtractLists modelRoleNames (builtins.attrNames cfg.harnessSettings.modelRoles);
    listedSingleModelRoles = builtins.filter (role: builtins.isList (cfg.harnessSettings.modelRoles.${role} or null)) singleModelRoles;
    userScopeOnlyHarnessSettings = lib.intersectLists userScopeOnlyHarnessSettingKeys (builtins.attrNames filteredHarnessSettings);
    # Home Manager's ledger identity predates project-path delivery and is an
    # upgrade contract: keep hashing configDir so a new generation retracts
    # leaves owned before this port. Devenv has no prior Kimchi reconciliation
    # ledger and keys its new ownership records by the actual project path.
    ledgerIdentity = path:
      builtins.hashString "sha256" (
        if isDevenv
        then path
        else cfg.configDir
      );
    ledgerFor = name: path: "json-settings/kimchi-${name}-${ledgerIdentity path}.json";
    agentsLedger = "materialize/kimchi-agents-${ledgerIdentity agentsDir}.manifest";
    # A semantic record's `tools` names Claude/Copilot tools (`Read`), while
    # Kimchi compares its own lowercase builtins exactly
    # (src/extensions/agents/personas/agent-types.ts:12). Dropping the list
    # would widen the agent to every tool, and translating it would fail
    # silently on the first unmatched name, so the record is rejected instead.
    toolAgents = builtins.attrNames (lib.filterAttrs (_: value: lib.ai.agent.isSemantic value && (value.tools or null) != null && value.tools != []) mergedAgents);
    # Root Markdown is written for Claude and Copilot. Kimchi reads the same
    # file differently: `name:` is ignored, `model: sonnet` becomes a Kimchi
    # model id, and `tools:` is matched against its lowercase builtins
    # (custom-agents.ts:52-85,125-132). Only a portable record crosses over;
    # Markdown under ai.kimchi.agents is Kimchi's own.
    rootMarkdownAgents = builtins.attrNames (lib.filterAttrs (name: value: value != null && !(lib.ai.agent.isSemantic value) && !(cfg.agents ? ${name})) config.ai.agents);
    # Kimchi rewrites all three of its JSON documents while it runs —
    # `/multi-model` and `kimchi resources` write `harness/settings.json`, and
    # MCP edits rename a temporary over `mcp.json` (see below) — so the only
    # way to keep both sides' edits is to own the declared leaves inside them.
    # A reconciled document is declared even when it has no leaves at all:
    # an empty declaration RETIRES whatever the previous generation owned,
    # which is the whole reason the writer is an identity rather than a
    # product of the files that happen to exist, on either backend.
    document = {
      entry,
      ledger,
      path,
      value,
    }: {
      ai.kimchi.files.${path} = {
        inherit entry ledger;
        # `value` IS the content form for this entry, so the text/source form
        # must be off: an entry may enable exactly one.
        content = {
          enable = false;
          inherit value;
        };
        facts.harnessWrites = true;
        format = "json";
      };
    };
  in
    lib.mkMerge [
      # Three writers, three entry names — deliberately NOT one bundle of
      # several targets: nothing orders these against each other, and each
      # name is a consumer-visible ordering contract.
      {
        assertions =
          [
            {
              assertion = unknownModelRoles == [];
              message = "ai.kimchi.harnessSettings.modelRoles has unknown roles: ${lib.concatStringsSep ", " unknownModelRoles}. Kimchi 1.1.30 accepts only ${lib.concatStringsSep ", " modelRoleNames}.";
            }
            {
              assertion = listedSingleModelRoles == [];
              message = "ai.kimchi.harnessSettings.modelRoles.${lib.concatStringsSep ", " listedSingleModelRoles} must be a single provider/model string; Kimchi ignores a list there.";
            }
          ]
          ++ [
            {
              assertion = toolAgents == [];
              message = "ai.kimchi agents ${lib.concatStringsSep ", " toolAgents} carry a `tools` allowlist in Claude/Copilot tool names, which Kimchi does not read (it matches its lowercase builtins read, bash, edit, write, grep, find, ls exactly). Set ai.kimchi.agents.<name> to native Kimchi Markdown with its own `tools:` line, or to null.";
            }
            {
              assertion = rootMarkdownAgents == [];
              message = "ai.agents ${lib.concatStringsSep ", " rootMarkdownAgents} are Markdown written for Claude/Copilot, which Kimchi misreads (`name:` ignored, `model:` taken as a Kimchi model id, `tools:` matched against its lowercase builtins). Set ai.kimchi.agents.<name> to native Kimchi Markdown, a portable { description, instructions } record, or null.";
            }
          ]
          ++ lib.optional isDevenv {
            assertion = userScopeOnlyHarnessSettings == [];
            message = ''
              ai.kimchi.harnessSettings contains settings Kimchi reads only from user scope: ${lib.concatStringsSep ", " userScopeOnlyHarnessSettings}.
              Under devenv, either set with HM, or configure inside the harness so it writes to user global.
              Home Manager delivers these declaratively by reconciling config.json and harness/settings.json; a /nix/store symlink would break Kimchi's runtime writes. Configuring inside Kimchi persists the decision or setting in its user-global harness files.
            '';
          };
        ai.kimchi.activation = {
          kimchiConfigMerge = {
            # Devenv requires a namespace; HM ordering names stay stable.
            entry = {
              devenv = "ai:kimchi:config-merge";
              hm = "kimchiConfigMerge";
            };
            ledgers.${ledgerFor "config" configPath} = {
              codec = "json";
              path = configPath;
            };
          };
          kimchiHarnessSettingsMerge = {
            entry = {
              devenv = "ai:kimchi:harness-settings-merge";
              hm = "kimchiHarnessSettingsMerge";
            };
            ledgers.${ledgerFor "harness-settings" harnessSettingsPath} = {
              codec = "json";
              path = harnessSettingsPath;
            };
          };
          kimchiMcpMerge = {
            entry = {
              devenv = "ai:kimchi:mcp-merge";
              hm = "kimchiMcpMerge";
            };
            ledgers.${ledgerFor "mcp" mcpPath} = {
              codec = "json";
              path = mcpPath;
            };
          };
          # A directory of whole files; Home Manager needs the second entry
          # that deletes a retired real file before checkLinkTargets.
          kimchiAgents = {
            entry = {
              devenv = "ai:kimchi:agents";
              hm = "kimchiAgents";
            };
            ledgers.${agentsLedger} = {
              codec = "dir";
              path = agentsDir;
            };
            pruneEntry = "kimchiAgentsPrune";
          };
        };
      }

      # pi 0.85.1's ThinkingLevel is a superset of the normalized enum and
      # pi reads `defaultThinkingLevel` from the merged user and project
      # harness settings, so the lowering is lossless on both backends. It is
      # a default: an explicit native harness value wins.
      (lib.mkIf (resolvedSettings.reasoningEffort != null) {
        ai.kimchi.harnessSettings.defaultThinkingLevel = lib.mkDefault resolvedSettings.reasoningEffort;
      })

      (document {
        entry = "kimchiConfigMerge";
        ledger = ledgerFor "config" configPath;
        path = configPath;
        value = filteredSettings;
      })

      (document {
        entry = "kimchiHarnessSettingsMerge";
        ledger = ledgerFor "harness-settings" harnessSettingsPath;
        path = harnessSettingsPath;
        value = filteredHarnessSettings;
      })

      # mcp.json — Claude-compatible format, and harness-written. Kimchi
      # 1.1.30 writes the user file from its first-run migration
      # (src/setup-wizard.ts:117-137) and ACP import
      # (src/modes/acp/ext-methods/import-apply.ts:289, via src/config/json.ts:154-159), and `/mcp
      # enable|disable` writes the project file through its patched
      # pi-mcp-adapter 2.34.0 (config.ts:1142-1147). Every one of them renames a
      # temporary over the path, which silently replaces a store symlink, so
      # the declared servers are owned by leaf: a migrated server or a
      # `disabled` toggle is an unowned sibling the reconciler keeps.
      (document {
        entry = "kimchiMcpMerge";
        ledger = ledgerFor "mcp" mcpPath;
        path = mcpPath;
        value = lib.optionalAttrs (mergedServers != {}) {
          mcpServers = lib.mapAttrs (name: lib.ai.renderServer pkgs name) mergedServers;
        };
      })

      # User harness context stays runtime-owned. Project context joins the one
      # shared repository AGENTS.md owner used by Codex and Kiro.
      (lib.mkIf hasMergedContext (
        if isDevenv
        then {
          ai.internal.agentsMd.${projectContextFilename} = {
            context = aiCommon.readContent mergedContext;
            hasContent = true;
          };
        }
        else {
          ai.kimchi.files."${harness}/${cfg.context.filename}" = contextEntry;
        }
      ))

      # agents/<name>.md — one real file per agent, in a real directory.
      # Kimchi's /agents Edit, Disable and Enable writeFileSync the file in
      # place, and Create and Eject write new ones beside it
      # (src/extensions/agents/index.ts:2556-2874). A store symlink, or the
      # layer's default read-only copy, would turn each of those into
      # EROFS/EACCES. The rule's harness-writes answer, `shared`, owns leaves
      # inside a JSON or TOML document and Markdown has none, so the method is
      # stated per file: an owned copy the user can write. The next activation
      # backs an edited file up and restores the declaration; a file Kimchi
      # created is an unowned sibling and is never touched.
      (lib.mkIf (cfg.agentsDir != null) {
        ai.kimchi.agents = lib.mapAttrs (_: lib.mkDefault) (dirHelpers.agentsFromDir cfg.agentsDir);
      })
      {
        ai.kimchi.files = lib.mapAttrs' (name: value: let
          rendered = lib.ai.agent.renderKimchi name value;
        in
          lib.nameValuePair "${agentsDir}/${name}.md" {
            content = lib.mkDefault (
              if builtins.isPath rendered
              then {source = rendered;}
              else {text = rendered;}
            );
            entry = "kimchiAgents";
            ledger = agentsLedger;
            method = lib.mkDefault "copy-ro";
            mode = lib.mkDefault "0644";
          })
        mergedAgents;
      }

      # .kimchi/hooks.json — devenv only, because Kimchi reads lifecycle hooks
      # from a trusted project's .kimchi/ and has no user-scope file
      # (src/extensions/kimchi-hooks/definition.ts:25-37). Kimchi never writes
      # it, so it takes the default facts and lands as a symlink. Home Manager
      # declares nothing here; its policy row warns instead. The bash-hook
      # directory is not this surface: those scripts filter the bash tool only.
      (let
        projectHooks = projectHooksFor {inherit cfg topHooks;};
      in
        lib.mkIf (isDevenv && hasHookHandlers projectHooks) {
          ai.kimchi.files.".kimchi/hooks.json" = {
            content.value.hooks = sharedHooks.render projectHooks;
            format = "json";
          };
        })

      # harness/skills/ — one entry per skill tree; Home Manager expands the
      # directory and the router expands it for devenv.
      (lib.mkIf (mergedSkills != {}) {
        ai.kimchi.files = helpers.mkSkillFiles {
          configDir = skillRoot;
          skills = mergedSkills;
        };
      })
    ];
in
  lib.ai.app.mkRuntime {
    # Carried as DATA, not a module argument — see mkRuntime.nix.
    inherit pkgs;
    name = "kimchi";
    contextFilename = projectContextFilename;
    contextDescription = ''
      Kimchi-specific context appended after `ai.context`. Home Manager emits
      the configured filename under its harness directory, although pinned
      Kimchi discovers only `AGENTS.md` there unless the package is overridden
      compatibly. Devenv always writes project-root `AGENTS.md`.
    '';
    supportedPools = [
      "agents"
      "context"
      "environmentVariables"
      "hooks"
      "mcpServers"
      "settings"
      "skills"
    ];
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults = {
      package = pkgs.ai.kimchi;
      outputPath = null;
    };
    options = {
      agents = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.ai.agent.agentType);
        default = {};
        description = ''
          Kimchi agents, one `<name>.md` each: Home Manager writes
          `<configDir>/harness/agents/`, devenv a trusted project's
          `.kimchi/agents/`. A portable `{ description, instructions }` record
          renders to Kimchi frontmatter plus body; Markdown here is Kimchi's
          own and lands verbatim. Entries replace root `ai.agents` at the same
          key and null suppresses one. Root Markdown and a record's
          Claude/Copilot `tools` list have no Kimchi reading and fail
          evaluation, naming this option as the remedy. Each file is a real,
          writable copy so Kimchi's /agents commands can edit it; the next
          activation backs such an edit up and restores the declaration.
        '';
      };

      agentsDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = "Directory of Kimchi-native `.md` agent files, expanded into `ai.kimchi.agents` keyed by basename minus `.md`.";
      };

      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".config/kimchi";
        description = ''
          Home Manager output directory relative to HOME. The pinned Kimchi
          discovers only the default location; a non-default value requires a
          compatible package override. Devenv uses fixed project paths.
        '';
      };

      native.settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            telemetry = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {
                  enabled = lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                    description = "Enable telemetry reporting in config.json.";
                  };
                };
              };
              default = {};
              description = "Telemetry settings.";
            };
            llmEndpoint = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "LLM endpoint override.";
            };
            skillPaths = lib.mkOption {
              type = lib.types.nullOr (lib.types.listOf lib.types.str);
              default = null;
              description = ''
                Skill search paths. Null leaves the key out, so project config
                inherits the user's global list; Kimchi reads
                `project.skillPaths ?? global.skillPaths`, so an explicit list,
                empty included, replaces it.
              '';
            };
            preferences = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                options = {};
              };
              default = {};
              description = "User preferences (freeform).";
            };
          };
        };
        default = {};
        description = ''
          Kimchi settings reconciled by leaf in <configDir>/config.json on Home
          Manager activation or .kimchi/config.json on devenv shell entry. API
          keys should be injected through the environment instead.
        '';
      };

      native.harnessSettings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = (pkgs.formats.json {}).type;
          options = {
            modelRoles = lib.mkOption {
              type = lib.types.attrsOf (lib.types.either roleModelType roleModelsType);
              default = {};
              example = {
                builder = ["anthropic/claude-sonnet-4-5" "openai/gpt-4o"];
                orchestrator = "anthropic/claude-sonnet-4-5";
              };
              description = ''
                Model role assignments as provider/model strings, or for
                delegable roles a non-empty list of them. Roles:
                ${lib.concatStringsSep ", " modelRoleNames}; orchestrator and
                compactor take one string.
              '';
            };
            resources = lib.mkOption {
              type = lib.types.attrsOf lib.types.bool;
              default = {};
              description = "Resource toggles (e.g. hooks.bash, tools.web_search).";
            };
          };
        };
        default = {};
        description = ''
          Harness settings reconciled by leaf in
          <configDir>/harness/settings.json on Home Manager activation or
          .config/kimchi/harness/settings.json on devenv shell entry. Kimchi
          mutates the user file at runtime, so both backends preserve unowned
          settings and retract retired leaves.
        '';
      };

      environmentVariables = lib.mkOption {
        type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
        default = {};
        description = "Environment variables exported when launching kimchi. Null suppresses a root entry at the same key.";
      };

      hooks = lib.mkOption {
        type = sharedHooks.mkHooksType hookEvents;
        default = {};
        apply = lib.filterAttrs (_event: blocks: blocks != []);
        description = ''
          Kimchi lifecycle hooks appended after the shared `ai.hooks` matcher
          groups, over Kimchi's own event set. Devenv writes both into
          `.kimchi/hooks.json`, which Kimchi reads only in a trusted project
          and from the exact devenv root. Home Manager delivers nothing and
          warns: Kimchi has no user-scope lifecycle hook file. `ai.hooks`'
          PermissionRequest is not a Kimchi event, so it is left out with a
          warning. If Kimchi's opt-in Claude Code hook adapter is enabled, a
          shared hook that also reaches `.claude/settings.json` fires twice.
        '';
      };

      # Cast AI key — a runtime credential (file | helper), exported as
      # KIMCHI_API_KEY at launch. Reuses the repo's shared MCP credential
      # pattern (lib/mcp.nix) so the secret is read from its decrypted file
      # at runtime and never lands in the /nix/store. Set exactly one of
      # apiKey.file (sops-nix/agenix path) or apiKey.helper.
      apiKey = mcpLib.mkCredentialsOption "KIMCHI_API_KEY";

      noUpdateCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Disable background self-update probe via KIMCHI_NO_UPDATE_CHECK.";
      };

      telemetry = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Override telemetry via KIMCHI_TELEMETRY_ENABLED env var.";
      };
    };

    devenv = {
      config = kimchiDelivery "devenv";
      installPackage = kimchiDevenvInstallPackage;
    };
    hm = {
      config = kimchiDelivery "hm";
      installPackage = kimchiInstallPackage;
    };
  }
