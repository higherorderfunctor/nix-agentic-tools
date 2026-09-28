# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) claudeMcpPath claudeMcpServers claudeSettings evalDevenv evalDevenvModules evalHm evalHmModules mkTest ownPlan ownedDocument;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) claudeAssertionFails claudeAssertionsPass claudeKnownKeysCfg claudeNestedTypoCfg handlerCommands hasClampHook hasGuardHook;
  delegationClampMitigationDefaultProse = ''
    Standing request from me, the user: you have my permission to use subagents
    (the Agent/Task tool), workflows, and deep research whenever they fit the
    task at hand. Treat this as the request that any "unless the user requested
    it" condition is asking for — it is granted, now and for the rest of this
    session. Use your own judgment about when they actually fit; this grants
    permission, it does not oblige you to delegate.
  '';
  unpinDocument = ownedDocument "claude" ".claude.json";
  # A contract both backends deliver alike, stated once and evaluated on each:
  # `eval` evaluates a configuration (`evalModules` a list of modules), `files`
  # reads its symlink sink, `mcpPath` is where Claude's MCP servers land, and
  # `upstreamEnable` is the enable option of the backend's own Claude module.
  backends = {
    devenv = {
      eval = evalDevenv;
      evalModules = evalDevenvModules;
      files = config: config.files;
      mcpPath = claudeMcpPath "devenv";
      upstreamEnable = ["claude" "code" "enable"];
    };
    hm = {
      eval = evalHm;
      evalModules = evalHmModules;
      files = config: config.home.file;
      mcpPath = claudeMcpPath "hm";
      upstreamEnable = ["programs" "claude-code" "enable"];
    };
  };
  # `ai.claude` beside a stand-in for the backend's own Claude module, whose
  # enable option is set to `upstream`.
  evalWithUpstream = arm: upstream:
    arm.evalModules [
      {options = lib.setAttrByPath arm.upstreamEnable (lib.mkEnableOption "the upstream Claude module");}
      {config = lib.recursiveUpdate {ai.claude.enable = true;} (lib.setAttrByPath arm.upstreamEnable upstream);}
    ];
  perBackend = name: test:
    lib.mapAttrs' (backend: arm:
      lib.nameValuePair "module-claude-${backend}-${name}"
      (mkTest "claude-${backend}-${name}" (test arm)))
    backends;
  # The settings.json document one configuration declares, on one backend.
  settingsOf = arm: config: claudeSettings (arm.eval config);
  families = {
    # ── Per-backend families ─────────────────────────────────────────
    # Both backends write ONE settings.json document the same way, so each of
    # these contracts is stated once and evaluated on each backend.
    checks = lib.mergeAttrsList [
      # The backend's own Claude module writes the same files, so enabling it
      # beside `ai.claude` fails evaluation and names the option to disable.
      (perBackend "upstream-module-both-enabled-asserted" (arm:
        claudeAssertionFails
        "ai.claude.enable and ${lib.concatStringsSep "." arm.upstreamEnable} cannot both be on: each writes Claude's files, and they cannot share them. Disable one of the two."
        (evalWithUpstream arm true)))

      # `ai.claude` alone passes, whether the upstream module is imported and
      # off or not imported at all.
      (perBackend "upstream-module-alone-passes" (arm:
        claudeAssertionsPass (evalWithUpstream arm false)
        && claudeAssertionsPass (arm.eval {ai.claude.enable = true;})))

      # Native settings reach the document, including nested permission leaves,
      # and the document names its JSON schema for editors.
      (perBackend "settings-reach-document" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings = {
              effortLevel = "medium";
              permissions.allow = ["Read"];
            };
          };
        };
      in
        settings.effortLevel
        == "medium"
        && settings.permissions.allow == ["Read"]
        && settings."$schema" == "https://json.schemastore.org/claude-code-settings.json"))

      # `env` is a freeform container and rides the same document.
      (perBackend "settings-env-written" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.env.FOO = "bar";
          };
        }).env.FOO
        == "bar"))

      (perBackend "effort-level-valid-written" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.effortLevel = "xhigh";
          };
        }).effortLevel
        == "xhigh"))

      # Typed nullOr enum.
      (perBackend "tui-valid-written" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.tui = "fullscreen";
          };
        }).tui
        == "fullscreen"))

      # Attribution: `false` coerces to "" at the type layer (disables the
      # commit trailer) and survives the null-filter (filterNulls keeps "").
      (perBackend "attribution-false-disables" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = false;
          };
        }).attribution.commit
        == ""))

      # Attribution: a custom string passes through unchanged.
      (perBackend "attribution-string-written" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.attribution.pr = "Reviewed-by: me";
          };
        }).attribution.pr
        == "Reviewed-by: me"))

      # Attribution: `true` coerces to null -> filtered; the attribution block
      # collapses to empty and is dropped entirely (Claude keeps its defaults).
      (perBackend "attribution-true-filtered" (arm:
        !(settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = true;
          };
        } ? attribution)))

      # Null typed keys are filtered out, and the undocumented `ultracode` key is
      # never written unless ultracodeOnLaunch is set.
      (perBackend "null-settings-filtered" (arm: let
        settings = settingsOf arm {ai.claude.enable = true;};
      in
        lib.all (key: !(settings ? ${key})) ["attribution" "effortLevel" "enableWorkflows" "model" "tui" "ultracode" "workflowKeywordTriggerEnabled"]))

      # Typed nullOr bool.
      (perBackend "enable-workflows-written" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.enableWorkflows = true;
          };
        }).enableWorkflows))

      # `false` survives the null-filter (filterNulls drops null, keeps false).
      (perBackend "workflow-keyword-trigger-false-written" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.workflowKeywordTriggerEnabled = false;
          };
        };
      in
        settings ? workflowKeywordTriggerEnabled && !settings.workflowKeywordTriggerEnabled))

      # Meta option: ultracodeOnLaunch writes the undocumented `ultracode` key
      # and the `enableWorkflows` master toggle — and ONLY those: not effortLevel
      # (ultracode implies xhigh) nor workflowKeywordTriggerEnabled (orthogonal
      # per-turn key).
      (perBackend "ultracode-on-launch-writes-settings" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
          };
        };
      in
        settings.ultracode
        && settings.enableWorkflows
        && !(settings ? effortLevel)
        && !(settings ? workflowKeywordTriggerEnabled)))

      # The meta option writes at mkDefault, so an explicit
      # native.settings.ultracode = false wins and survives the null-filter.
      (perBackend "ultracode-on-launch-explicit-false-wins" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
            native.settings.ultracode = false;
          };
        };
      in
        settings ? ultracode && !settings.ultracode))

      # Soft-enum model: an arbitrary (unknown) id is accepted and written.
      (perBackend "model-soft-enum-accepts-arbitrary" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.model = "some-future-model";
          };
        }).model
        == "some-future-model"))

      # The typed ai.claude.hooks event map lowers into settings.json.hooks.
      (perBackend "hooks-lower-to-settings" (arm: let
        block =
          lib.head
          (settingsOf arm {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [
                {
                  matcher = "Bash";
                  hooks = [{command = "validate";}];
                }
              ];
            };
          })
        .hooks
        .PreToolUse;
        handler = lib.head block.hooks;
      in
        block.matcher == "Bash" && handler.command == "validate" && handler.type == "command"))

      # The legacy `native.settings.hooks` escape hatch lowers verbatim into
      # settings.json.hooks, composing with the typed event map through the
      # per-event join in mkClaude.nix (zipAttrsWith concatLists).
      (perBackend "settings-hooks-escape-hatch" (arm: let
        hooks =
          (settingsOf arm {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [{hooks = [{command = "typed";}];}];
              native.settings.hooks.PreToolUse = [{matcher = "Bash";}];
            };
          })
        .hooks
        .PreToolUse;
      in
        lib.any (block: (block.matcher or null) == "Bash") hooks
        && handlerCommands (lib.filter (block: block ? hooks) hooks) == ["typed"]))

      # hookScripts land as executable `.claude/hooks/<name>` links; they are
      # never merged into settings.json, which keeps its own hooks.
      (perBackend "hookscripts-land-as-executable-files" (arm: let
        result = arm.eval {
          ai.claude = {
            enable = true;
            hookScripts.my-hook = "#!/usr/bin/env bash\nexit 0\n";
            native.settings.hooks.from-settings = [{matcher = "X";}];
          };
        };
        file = (arm.files result.config).".claude/hooks/my-hook" or {};
      in
        (file.text or null)
        == "#!/usr/bin/env bash\nexit 0\n"
        && file.executable
        && (claudeSettings result).hooks ? from-settings))

      # commands and outputStyles land as `.claude/<dir>/<name>.md` on both
      # backends: text inline, a path as a link to its source.
      (perBackend "commands-and-output-styles-land-as-files" (arm: let
        files =
          arm.files
          (arm.eval {
            ai.claude = {
              enable = true;
              commands.fix-issue = "# Fix issue\n\nSteps…";
              outputStyles = {
                concise = "Keep answers under 3 sentences.";
                linked = ./fixtures/claude-agents/agent-one.md;
              };
            };
          }).config;
      in
        files.".claude/commands/fix-issue.md".text
        == "# Fix issue\n\nSteps…"
        && files.".claude/output-styles/concise.md".text == "Keep answers under 3 sentences."
        && files.".claude/output-styles/linked.md".source == ./fixtures/claude-agents/agent-one.md))

      # A marketplace is announced in settings.json on both backends, and
      # Claude registers it from there.
      (perBackend "marketplaces-land-in-settings" (arm: let
        src = ../../stacked-workflows/skills/stack-fix;
        result = arm.eval {
          ai.claude = {
            enable = true;
            marketplaces.my-shelf = src;
          };
        };
      in
        (claudeSettings result).extraKnownMarketplaces.my-shelf
        == {
          source = {
            source = "directory";
            path = "${src}";
          };
        }))

      # Settings and MCP servers are configuration: Nix owns each whole file
      # and the backend links it read-only. No writer reconciles either, so an
      # in-app change does not persist, and disabling Claude drops the link.
      (perBackend "settings-and-mcp-are-read-only-links" (arm: let
        cfg = enable: {
          ai.claude = {
            inherit enable;
            mcpServers.remote = {
              type = "http";
              url = "https://example.invalid/mcp";
            };
            native.settings.effortLevel = "low";
          };
        };
        on = arm.eval (cfg true);
        off = arm.eval (cfg false);
        paths = [".claude/settings.json" arm.mcpPath];
      in
        lib.all (path: (arm.files on.config) ? ${path} && !((arm.files off.config) ? ${path})) paths
        && lib.all (path: on.config.ai.claude.files.${path}.facts.harnessWrites != true) paths
        && lib.all (writer: writer.ledgers == {} || lib.all (ledger: !(lib.elem ledger.path paths)) (lib.attrValues writer.ledgers))
        (lib.attrValues on.config.ai.claude.activation)))

      # Nothing set, nothing written: an empty settings.json would still
      # shadow a project's own committed file on devenv.
      # `gitSshConfigWorkaround` would put GIT_SSH_COMMAND in `env` on devenv
      # (it has no `programs.git`), so it is off to keep the document empty.
      (perBackend "settings-empty-writes-no-file" (arm:
        !((arm.files
          (arm.eval {
            ai.claude.enable = true;
            ai.gitSshConfigWorkaround = false;
          }).config)
          ? ".claude/settings.json")))
    ];
  };
  # The Home Manager personal plugin's LSP file, as the value it renders.
  pluginLsp = result: result.config.ai.claude.files.".claude/skills/home-manager/.lsp.json".content.value or {};
  # Refuses an absent or blank body, so a renamed writer fails the check
  # instead of passing it with an empty string.
  unpinWriter = result:
    lib.attrByPath ["home" "activation" "claudeUnpinLaunchEffort" "text"]
    (throw "module-test: config.home.activation.claudeUnpinLaunchEffort.text is missing")
    result.config;
in {
  checks =
    {
      module-claude-default-disabled = mkTest "claude-default-disabled" (
        !(evalHm {}).config.ai.claude.enable
        && !(evalDevenv {}).config.ai.claude.enable
      );

      module-claude-enable-toggles = mkTest "claude-enable-toggles" (
        let
          ev = evalHm {ai.claude.enable = true;};
        in
          ev.config.ai.claude.enable
      );

      # NOTE: this test verifies that the shared ai.mcpServers pool ACCEPTS
      # an entry when a package module (claude) is also loaded — i.e. no type
      # conflicts between sharedOptions.nix's mcpServers declaration and the
      # per-app one contributed by mkRuntime. It does NOT verify the claude
      # module's internal mergedServers fanout computation. Fanout correctness
      # is tested in checks/ai-factory/factory-eval.nix via factory-mkRuntime-fanout-*.
      # A true end-to-end fanout test requires the rendering pipeline landed
      # in a later milestone (writing mergedServers into home.file output).
      module-claude-shared-mcp-pool-accepted = mkTest "claude-shared-mcp-pool-accepted" (
        let
          evaluated = evalHm {
            ai.claude.enable = true;
            ai.mcpServers.testServer = {
              type = "stdio";
              package = pkgs.hello;
              command = "hello";
            };
          };
        in
          evaluated.config.ai.mcpServers ? testServer
      );

      module-claude-shared-rule-emits-native-file = mkTest "claude-shared-rule-emits-native-file" (
        let
          evaluated = evalHm {
            ai = {
              claude.enable = true;
              rules.search = {
                text = "Always use rg instead of grep.";
                description = "Grep replacement";
              };
            };
          };
          rule = evaluated.config.home.file.".claude/rules/search.md".text;
        in
          lib.hasInfix "Always use rg instead of grep." rule
          && lib.hasInfix "description: Grep replacement" rule
      );

      module-claude-no-guidance-no-file = mkTest "claude-no-guidance-no-file" (
        let
          evaluated = evalHm {ai.claude.enable = true;};
          # With no rules and no context merged, nothing enters the final file map.
        in
          !(evaluated.config.home.file ? ".claude/CLAUDE.md")
      );

      module-claude-per-app-rule-emits-native-file = mkTest "claude-per-app-rule-emits-native-file" (
        let
          evaluated = evalHm {
            ai.claude = {
              enable = true;
              rules.claude-only = {
                text = "Claude-specific rule.";
                description = "Claude only";
              };
            };
          };
          rule = evaluated.config.home.file.".claude/rules/claude-only.md".text;
        in
          lib.hasInfix "Claude-specific rule." rule
      );

      # Claude HM emits context and each keyed rule through ai.claude.files before
      # the generic backend sink.
      module-claude-hm-context-and-rules = mkTest "claude-hm-context-and-rules" (
        let
          evaluated = evalHm {
            ai = {
              claude = {
                enable = true;
                context.text = "CONTEXT-BASELINE-TOKEN.";
              };
              rules = {
                named-rule = {
                  text = "NAMED-RULE-BODY-TOKEN.";
                  matcher = ["src/**"];
                };
                unnamed = {
                  text = "UNNAMED-INSTR-TOKEN.";
                  description = "unnamed always-on";
                };
              };
            };
          };
          aggregate = evaluated.config.home.file.".claude/CLAUDE.md" or null;
          ruleFile = evaluated.config.home.file.".claude/rules/named-rule.md" or null;
        in
          aggregate.text
          == evaluated.config.ai.claude.files.".claude/CLAUDE.md".content.text
          && aggregate.text == "CONTEXT-BASELINE-TOKEN."
          && ruleFile != null
          && ruleFile.text == evaluated.config.ai.claude.files.".claude/rules/named-rule.md".content.text
          && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (ruleFile.text or "")
          && evaluated.config.home.file ? ".claude/rules/unnamed.md"
      );

      # Claude devenv writes context to `.claude/CLAUDE.md` and keeps every rule in
      # its own native file, without duplicating rule bodies into the context file.
      module-claude-devenv-context-and-rules = mkTest "claude-devenv-context-and-rules" (
        let
          evaluated = evalDevenv {
            ai = {
              claude = {
                enable = true;
                context.text = "CONTEXT-BASELINE-TOKEN.";
              };
              rules = {
                named-rule = {
                  text = "NAMED-RULE-BODY-TOKEN.";
                  matcher = ["src/**"];
                };
                unnamed = {
                  text = "UNNAMED-INSTR-TOKEN.";
                  description = "unnamed always-on";
                };
              };
            };
          };
          composed = (evaluated.config.files.".claude/CLAUDE.md" or {}).text or "";
          # Project rules are read-only copies, not links: see mkClaude's rules
          # entry. The copy writer's plan is where their bytes are.
          rules = (lib.head (ownPlan "claude" "ai:claude:materialize-rules" evaluated).targets).units;
        in
          lib.hasInfix "CONTEXT-BASELINE-TOKEN." composed
          && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." composed)
          && !(lib.hasInfix "NAMED-RULE-BODY-TOKEN." composed)
          && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (rules."named-rule.md".text or "")
          && rules ? "unnamed.md"
      );

      # Strict enum: an invalid effortLevel must throw at eval.
      # ── Settings document ──────────────────────────────────────────
      # Strict enum: an invalid effortLevel must throw at eval.
      module-claude-hm-effort-level-rejects-invalid = mkTest "claude-hm-effort-level-rejects-invalid" (
        let
          attempt = builtins.tryEval (
            let
              ev = evalHm {
                ai.claude = {
                  enable = true;
                  native.settings.effortLevel = "ultra";
                };
              };
            in
              builtins.deepSeq ev.config.ai.claude.native.settings.effortLevel
              ev.config.ai.claude.native.settings.effortLevel
          );
        in
          attempt.success == false
      );

      # Strict enum: an invalid tui renderer must throw at eval.
      module-claude-hm-tui-rejects-invalid = mkTest "claude-hm-tui-rejects-invalid" (
        let
          attempt = builtins.tryEval (
            let
              ev = evalHm {
                ai.claude = {
                  enable = true;
                  native.settings.tui = "curses";
                };
              };
            in
              builtins.deepSeq ev.config.ai.claude.native.settings.tui
              ev.config.ai.claude.native.settings.tui
          );
        in
          attempt.success == false
      );

      module-claude-hm-writes-rule-file = mkTest "claude-hm-writes-rule-file" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.rules.my-rule = {
              matcher = ["src/**"];
              text = "Always use strict mode.";
            };
          };
          ruleFile = result.config.home.file.".claude/rules/my-rule.md" or null;
        in
          ruleFile
          != null
          && lib.hasInfix "Always use strict mode" (ruleFile.text or "")
      );

      # Skills land as links under ~/.claude/skills, a directory's leaves each.
      module-claude-hm-skills-land-as-files = mkTest "claude-hm-skills-land-as-files" (
        let
          src = ../../stacked-workflows/skills/stack-fix;
          file =
            (evalHm {
              ai.claude.enable = true;
              ai.skills.stack-fix = src;
            }).config.home.file.".claude/skills/stack-fix" or {
            };
        in
          (file.source or null) == src && (file.recursive or false)
      );

      # Every Claude surface lands as its own file: the Markdown and script
      # surfaces, the personal plugin, and settings.json carrying settings,
      # permissions and typed hooks.
      module-claude-hm-delivery-lands-surfaces-as-files = mkTest "claude-hm-delivery-lands-surfaces-as-files" (
        let
          result = evalHm {
            ai = {
              agents.probe = "probe agent";
              claude = {
                enable = true;
                hookScripts.probe = "probe script";
                native.settings.permissions.allow = ["Read"];
              };
              hooks.PreToolUse = [{hooks = [{command = "true";}];}];
              lspServers.probe.command = "probe";
              mcpServers.probe.command = "probe";
              skills.probe = ./fixtures/claude-skills/skill-a;
            };
          };
          inherit (result) config;
          settings = claudeSettings result;
        in
          lib.all (path: config.home.file ? ${path}) [
            ".claude/agents/probe.md"
            ".claude/hooks/probe"
            ".claude/skills/home-manager/.claude-plugin/plugin.json"
            ".claude/skills/home-manager/.lsp.json"
            ".claude/skills/home-manager/.mcp.json"
            ".claude/settings.json"
            ".claude/skills/probe"
          ]
          && settings.permissions.allow == ["Read"]
          && handlerCommands settings.hooks.PreToolUse == ["true"]
      );

      # The personal plugin's manifest names it `hm`, which is the MCP tool
      # namespace (`mcp__plugin_hm_<server>__<tool>`) consumers may have pinned.
      # No manifest at all when the plugin carries neither MCP nor LSP servers.
      module-claude-hm-personal-plugin-manifest-is-hm = mkTest "claude-hm-personal-plugin-manifest-is-hm" (
        let
          manifest = ".claude/skills/home-manager/.claude-plugin/plugin.json";
          withServers =
            (evalHm {
              ai.claude.enable = true;
              ai.mcpServers.probe.command = "probe";
            }).config;
          bare = (evalHm {ai.claude.enable = true;}).config;
        in
          withServers.ai.claude.files.${manifest}.content.value
          == {name = "hm";}
          && !(bare.home.file ? ${manifest})
      );

      # A consumer's own settings leaf beats the leaf the module generates at
      # `mkDefault`, and the rest of the generated document survives it.
      module-claude-hm-consumer-overrides-generated-defaults = mkTest "claude-hm-consumer-overrides-generated-defaults" (
        let
          settings = claudeSettings (evalHm {
            ai = {
              claude = {
                enable = true;
                native.settings.env.ENABLE_LSP_TOOL = "0";
                ultracodeOnLaunch = true;
              };
              lspServers.probe.command = "probe";
            };
          });
        in
          settings.env.ENABLE_LSP_TOOL == "0" && settings.enableWorkflows
      );

      # Devenv: typed ai.claude.mcpServers entries are RENDERED into the project
      # .mcp.json: no raw `package` key, and the derived command/args.
      # Uses a real server name (context7-mcp) so renderServer's package branch
      # (loadServer + mode-string args) is exercised end-to-end.
      module-claude-devenv-mcp-servers-rendered = mkTest "claude-devenv-mcp-servers-rendered" (
        let
          result = evalDevenv {
            ai.claude = {
              enable = true;
              mcpServers.context7-mcp.package = pkgs.hello;
            };
          };
          rendered = (claudeMcpServers "devenv" result)."context7-mcp" or null;
        in
          rendered
          != null
          && !(rendered ? package)
          && rendered.type == "stdio"
          && lib.hasSuffix "/bin/hello" rendered.command
          && lib.take 2 rendered.args == ["--transport" "stdio"]
      );

      # Devenv/HM parity: the SAME typed config yields the SAME rendered server
      # attrset on both backends (the HM personal plugin's .mcp.json vs the
      # project .mcp.json) — the render is shared (lib.ai.renderServer), so any
      # divergence is a factory regression. `==` is decidable over
      # context-carrying strings (store paths in command/env).
      module-claude-devenv-mcp-servers-hm-parity = mkTest "claude-devenv-mcp-servers-hm-parity" (
        let
          cfg = {
            ai.claude = {
              enable = true;
              mcpServers.context7-mcp.package = pkgs.hello;
            };
          };
          hmServers = claudeMcpServers "hm" (evalHm cfg);
          dvServers = claudeMcpServers "devenv" (evalDevenv cfg);
        in
          hmServers
          != {}
          && hmServers == dvServers
      );

      # The LSP tool flag follows LSP servers only: an MCP server alone gives
      # Claude's LSP tool nothing to read.
      module-claude-hm-sets-lsp-env-when-lsp-servers-present = mkTest "claude-hm-sets-lsp-env-when-lsp-servers-present" (
        let
          lspEnv = servers: (claudeSettings (evalHm {ai = {claude.enable = true;} // servers;})).env.ENABLE_LSP_TOOL or null;
        in
          lspEnv {lspServers.nixd.command = "nixd";}
          == "1"
          && lspEnv {
            mcpServers.test-server = {
              type = "stdio";
              package = pkgs.hello;
              command = "hello";
            };
          }
          == null
      );

      # ── Claude launch-effort unpin reconciler ──────────────────────

      # Default reconciler: flags from the committed sidecar are reconciled into
      # ~/.claude.json. The declared leaves and the document they land in are
      # read from `_reconciledDocuments`, not from the activation body: the
      # reconciler carries them as data in a store plan, so the body names only
      # the plan. The ledger path IS asserted here — it is the live migration
      # contract that every previously written ownership record hangs off.
      module-claude-hm-reconciles-unpin-launch-effort = mkTest "claude-hm-reconciles-unpin-launch-effort" (
        let
          result = evalHm {ai.claude.enable = true;};
          document = unpinDocument result;
        in
          lib.hasInfix "--phase all" (unpinWriter result)
          && document.ledger == "json-settings/claude-unpin-launch-effort.json"
          && document.value.unpinOpus48LaunchEffort
      );

      # Emptied flag map: the writer is still emitted, declaring zero leaves, so
      # the prior generation's flags are retired rather than left behind.
      module-claude-hm-unpin-empty-emits-writer = mkTest "claude-hm-unpin-empty-emits-writer" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.claude.unpinLaunchEffort = lib.mkForce {};
          };
        in
          lib.hasInfix "--phase all" (unpinWriter result)
          && (unpinDocument result).value == {}
      );

      # A key set false is still written (re-pins that model deliberately).
      module-claude-hm-unpin-false-key-written = mkTest "claude-hm-unpin-false-key-written" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.claude.unpinLaunchEffort.unpinOpus48LaunchEffort = false;
          };
        in
          (unpinDocument result).value.unpinOpus48LaunchEffort == false
      );

      # One runtime corpus covers the document codec plus actual HM activations.
      # Every empty generation is evaluated and executed, so a missing writer
      # cannot satisfy the N-to-0 check.
      #
      # `harness.hmLib` rather than `lib`: `own` places its entry with
      # `lib.hm.dag`, which only the harness stubs.
      module-json-settings-reconciliation = let
        helpers = import ../../../lib/ai/hm-helpers.nix {lib = harness.hmLib;};
        # Every `render` here reads an HM activation entry's `.text`, which
        # expects home-manager's `run` helper already in scope.
        mkCase = name: configFile: first: second: native: render: {
          inherit configFile first name native second;
          scripts = map (settings: harness.hmRunShim + render settings) [first second {}];
        };
        cases = [
          (mkCase "document" ".settings with spaces/config.json" {
              array = [{enabled = true;}];
              "dot.key" = true;
              nested.managed = true;
              nullable = null;
              retained = 1;
              shape = "scalar";
            } {
              retained = 2;
              shape.child = true;
            } {
              nested.native = "survives";
              oauthAccount.token = "native-test-token";
            } (settings:
              # The codec, not a caller: a space in the path, a dotted key, a
              # null leaf, an array and a scalar/table transition, none of which
              # any real caller declares all at once. `runtime` only decides
              # where the eval-visible record lands, and this case reads the
              # writer alone.
                (helpers.mkOwnBundle {
                  backend = "hm";
                  declared.".settings with spaces/config.json" = settings;
                  entryNames.write = "documentCodecTest";
                  python = pkgs.python3;
                  runtime = "claude";
                  targets = [
                    {
                      codec = "json";
                      ledger = "json-settings/document-codec-test.json";
                      path = ".settings with spaces/config.json";
                      units.text = builtins.toJSON settings;
                    }
                  ];
                  inherit pkgs;
                })
            .home
            .activation
            .documentCodecTest
            .text))
          (mkCase "claude" ".claude.json" {
              unpinFirstLaunchEffort = true;
              unpinSecondLaunchEffort = true;
            } {
              unpinSecondLaunchEffort = false;
            } {
              oauthAccount.token = "native-test-token";
              unpinNativeLaunchEffort = true;
            } (settings:
              (evalHm {
                ai.claude = {
                  enable = true;
                  unpinLaunchEffort = lib.mkForce settings;
                };
              }).config.home.activation.claudeUnpinLaunchEffort.text))
        ];
      in
        pkgs.runCommand "module-test-json-settings-reconciliation" {} ''
          ${pkgs.python3}/bin/python ${./json-settings-runtime.py} \
            ${pkgs.writeText "json-settings-cases.json" (builtins.toJSON cases)} \
            ${pkgs.bash}/bin/bash
          touch "$out"
        '';

      # ── Attrs-shape ai.rules / ai.<cli>.rules (unified transformer) ───

      # Claude HM: top-level ai.rules → .claude/rules/<name>.md with paths frontmatter.
      module-claude-hm-writes-rules-from-top-level = mkTest "claude-hm-writes-rules-from-top-level" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.rules.code-style = {
              matcher = ["src/**"];
              text = "Use consistent formatting.";
            };
          };
          ruleFile = result.config.home.file.".claude/rules/code-style.md" or null;
        in
          ruleFile
          != null
          && lib.hasInfix "Use consistent formatting" (ruleFile.text or "")
          && lib.hasInfix "paths:" (ruleFile.text or "")
          && lib.hasInfix "src/**" (ruleFile.text or "")
      );

      # Rules with null paths → unconditional (no frontmatter scoping).
      module-claude-hm-rules-null-paths-no-frontmatter = mkTest "claude-hm-rules-null-paths-no-frontmatter" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.rules.always-on.text = "Loaded unconditionally.";
          };
          ruleFile = result.config.home.file.".claude/rules/always-on.md" or null;
        in
          ruleFile
          != null
          && lib.hasInfix "Loaded unconditionally." ruleFile.text
          && !(lib.hasInfix "paths:" ruleFile.text)
      );

      # HM: each plugin lands as ONE directory link at ~/.claude/skills/<key>,
      # never as a tree of leaves: Claude's agents/ and commands/ scanners take
      # regular files only.
      module-claude-hm-plugins-land-as-files = mkTest "claude-hm-plugins-land-as-files" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              plugins.my-plugin = ../../stacked-workflows/skills/stack-fix;
            };
          };
          file = result.config.home.file.".claude/skills/my-plugin" or {};
        in
          lib.isDerivation (file.source or null)
          && file.source.name == "claude-code-plugin-my-plugin"
          && !(file.recursive or false)
      );

      # HM: the ATTRIBUTE NAME — not the source's base name — is the plugin's
      # on-disk directory name and synthesized manifest name. A bare flake-input
      # store path would otherwise yield an unstable `<hash>-source` renamed by
      # every unrelated input bump.
      module-claude-hm-plugins-key-is-directory-name = mkTest "claude-hm-plugins-key-is-directory-name" (
        let
          # A package whose store base name (…-hello-<version>) is nothing like
          # the key, standing in for a flake-input root.
          pluginPkg = pkgs.hello;
          files =
            (evalHm {
              ai.claude = {
                enable = true;
                plugins.remember = pluginPkg;
              };
            }).config.home.file;
          derivedName =
            builtins.unsafeDiscardStringContext (baseNameOf (toString pluginPkg));
        in
          files ? ".claude/skills/remember"
          && !(files ? ".claude/skills/${derivedName}")
      );

      # A plugin key that another ~/.claude/skills/<name> owner already uses
      # fails evaluation instead of silently shadowing it.
      module-claude-hm-plugins-collision-asserted = mkTest "claude-hm-plugins-collision-asserted" (
        let
          failing = cfg: lib.any (a: !a.assertion && lib.hasInfix "ai.claude.plugins" a.message) (evalHm cfg).config.assertions;
          src = ../../stacked-workflows/skills/stack-fix;
        in
          failing {
            ai.claude = {
              enable = true;
              plugins.home-manager = src;
            };
          }
          && failing {
            ai.claude = {
              enable = true;
              plugins.probe = src;
              # A single-file skill: a directory skill would already collide
              # with the plugin's own entry in the file map.
              skills.probe = ./fixtures/claude-skills/skill-a/SKILL.md;
            };
          }
          && !(failing {
            ai.claude = {
              enable = true;
              plugins.probe = src;
            };
          })
      );

      # A skill named like the personal plugin would share its directory, so it
      # fails evaluation while the plugin has files to deliver.
      module-claude-hm-skill-personal-plugin-collision-asserted = mkTest "claude-hm-skill-personal-plugin-collision-asserted" (
        let
          failing = cfg: lib.any (a: !a.assertion && lib.hasInfix "ai.skills.home-manager" a.message) (evalHm cfg).config.assertions;
          skill = {
            ai.claude = {
              enable = true;
              skills.home-manager = ./fixtures/claude-skills/skill-a/SKILL.md;
            };
          };
        in
          failing (lib.recursiveUpdate skill {
            ai.claude.mcpServers.remote = {
              type = "http";
              url = "https://example.invalid/mcp";
            };
          })
          && !(failing skill)
      );

      # HM: top-level ai.lspServers fans out to the personal plugin's .lsp.json,
      # which is delivered as a link.
      module-claude-hm-top-level-lsp-fanout = mkTest "claude-hm-top-level-lsp-fanout" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.lspServers.nixd = {
              command = "nixd";
              args = [];
            };
          };
        in
          ((pluginLsp result).nixd.command or null)
          == "nixd"
          && result.config.home.file ? ".claude/skills/home-manager/.lsp.json"
      );

      # HM: ai.claude.lspServers per-CLI overrides top-level ai.lspServers on
      # name collision. Claude-specific override wins.
      module-claude-hm-per-cli-lsp-overrides-top-level = mkTest "claude-hm-per-cli-lsp-overrides-top-level" (
        let
          result = evalHm {
            ai = {
              claude.enable = true;
              lspServers.nixd = {
                command = "nixd-top-level";
              };
              claude.lspServers.nixd = {
                command = "nixd-claude-specific";
              };
            };
          };
        in
          ((pluginLsp result).nixd.command or null) == "nixd-claude-specific"
      );

      # Claude HM: typed LSP with `extensions` emits extensionToLanguage
      # mapping via mkClaudeLspConfig.
      module-claude-hm-lsp-extension-to-language = mkTest "claude-hm-lsp-extension-to-language" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              lspServers.go = {
                command = "gopls";
                args = ["serve"];
                extensions = ["go"];
              };
            };
          };
          entry = (pluginLsp result).go or {};
        in
          (entry.command or null)
          == "gopls"
          && ((entry.extensionToLanguage or {}).".go" or null)
          == "go"
      );

      # HM: top-level ai.agents fans out to ~/.claude/agents/<name>.md.
      module-claude-hm-top-level-agents-fanout = mkTest "claude-hm-top-level-agents-fanout" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.agents.reviewer = "# Reviewer\n\nReview carefully.";
          };
        in
          (result.config.home.file.".claude/agents/reviewer.md".text or null)
          == "# Reviewer\n\nReview carefully."
      );

      # Precedence: ai.claude.agents wins over ai.agents on name collision.
      module-claude-hm-per-cli-agents-wins = mkTest "claude-hm-per-cli-agents-wins" (
        let
          result = evalHm {
            ai = {
              claude.enable = true;
              agents.reviewer = "# Top-level";
              claude.agents.reviewer = "# Claude-specific";
            };
          };
        in
          (result.config.home.file.".claude/agents/reviewer.md".text or null) == "# Claude-specific"
      );

      # ── heron_brook delegation clamp mitigation ──────────────────
      # OPT-IN is the requirement: a bare `enable = true` must carry NEITHER hook.
      # Asserting both are absent also pins the all-or-nothing property — emitting
      # only the PreCompact half would leave a hook clearing a marker nothing ever
      # writes, inert but confusing to find in a settings.json you never asked to
      # be modified.
      module-claude-hm-delegation-clamp-default-off = mkTest "claude-hm-delegation-clamp-default-off" (
        let
          bareSettings = claudeSettings (evalHm {ai.claude.enable = true;});
          result = evalHm {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [{hooks = [{command = "consumer-control";}];}];
            };
          };
          clamp = result.config.ai.claude.delegationClampMitigation;
          settingsHooks = (claudeSettings result).hooks;
        in
          !clamp.enable
          && !(bareSettings ? hooks)
          && builtins.elem "consumer-control" (handlerCommands settingsHooks.PreToolUse)
          && !(settingsHooks ? UserPromptSubmit)
          && !(settingsHooks ? PreCompact)
      );

      # Opting in must produce BOTH hooks: the injector and the PreCompact re-arm.
      # Compaction is the one event that erases the injected context, so an injector
      # without the re-arm silently loses the mitigation on the first compaction.
      module-claude-hm-delegation-clamp-enable-keeps-default-prose = mkTest "claude-hm-delegation-clamp-enable-keeps-default-prose" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              delegationClampMitigation.enable = true;
            };
          };
          clamp = result.config.ai.claude.delegationClampMitigation;
          settingsHooks = (claudeSettings result).hooks;
        in
          clamp.text
          == delegationClampMitigationDefaultProse
          && hasClampHook (settingsHooks.UserPromptSubmit or [])
          && hasClampHook (settingsHooks.PreCompact or [])
      );

      # Explicit inline content is an opt-in by itself. This closes the old dead-config
      # hole where a consumer could customize the prose without separately setting the
      # bespoke mitigation flag and silently get no hook.
      module-claude-hm-delegation-clamp-text-auto-enables = mkTest "claude-hm-delegation-clamp-text-auto-enables" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              delegationClampMitigation.text = "custom prose";
            };
          };
          clamp = result.config.ai.claude.delegationClampMitigation;
          settingsHooks = (claudeSettings result).hooks or {};
        in
          clamp.enable
          && clamp.text == "custom prose"
          && hasClampHook (settingsHooks.UserPromptSubmit or [])
          && hasClampHook (settingsHooks.PreCompact or [])
      );

      # An explicit false beats content's automatic enablement. This lets consumers
      # stage custom prose without either hook appearing in settings.json until they
      # deliberately activate the mitigation.
      module-claude-hm-delegation-clamp-custom-text-explicitly-disabled = mkTest "claude-hm-delegation-clamp-custom-text-explicitly-disabled" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              delegationClampMitigation = {
                enable = false;
                text = "custom prose";
              };
            };
          };
          clamp = result.config.ai.claude.delegationClampMitigation;
          settingsHooks = (claudeSettings result).hooks or {};
        in
          !clamp.enable
          && clamp.text == "custom prose"
          && (settingsHooks.UserPromptSubmit or []) == []
          && (settingsHooks.PreCompact or []) == []
      );

      # A source definition has the same auto-enable behavior, and its contents beat
      # the default-priority inline prose supplied by the submodule definition.
      module-claude-hm-delegation-clamp-source-auto-enables = mkTest "claude-hm-delegation-clamp-source-auto-enables" (
        let
          sourceProse = "source-backed custom prose\n";
          result = evalHm {
            ai.claude = {
              enable = true;
              delegationClampMitigation.source = builtins.toFile "delegation-clamp-source.md" sourceProse;
            };
          };
          clamp = result.config.ai.claude.delegationClampMitigation;
          settingsHooks = (claudeSettings result).hooks or {};
        in
          clamp.enable
          && clamp.text == sourceProse
          && hasClampHook (settingsHooks.UserPromptSubmit or [])
          && hasClampHook (settingsHooks.PreCompact or [])
      );

      # Devenv parity — same two hooks behind the same flag, per the config-parity rule.
      module-claude-devenv-delegation-clamp-opt-in = mkTest "claude-devenv-delegation-clamp-opt-in" (
        let
          result = evalDevenv {
            ai.claude = {
              enable = true;
              delegationClampMitigation.enable = true;
            };
          };
          settingsJson = claudeSettings result;
        in
          hasClampHook (settingsJson.hooks.UserPromptSubmit or [])
          && hasClampHook (settingsJson.hooks.PreCompact or [])
      );

      # Compose-not-clobber. The mitigation is emitted as a DEFINITION of
      # ai.claude.hooks, never as that option's `default` — a default is discarded
      # wholesale the moment a consumer defines the option at all, which would have
      # silently disabled the mitigation for exactly the consumers who use hooks most.
      # This test is what pins that choice down.
      module-claude-delegation-clamp-composes-with-consumer-hook = mkTest "claude-delegation-clamp-composes-with-consumer-hook" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              delegationClampMitigation.enable = true;
              hooks.UserPromptSubmit = [{hooks = [{command = "consumer-hook";}];}];
            };
          };
          blocks = (claudeSettings result).hooks.UserPromptSubmit or [];
          cmds = handlerCommands blocks;
        in
          builtins.elem "consumer-hook" cmds
          && builtins.any (lib.hasInfix "claude-delegation-clamp") cmds
      );

      # ── memory-collision guard (ai.claude.memoryCollisionGuard) ───────
      # Default-OFF is the requirement here, and it is the exact inverse of the
      # delegation clamp's above. This hook DENIES a tool call, so shipping it on by
      # default would block writes for every consumer who never asked for it.
      module-claude-hm-memory-collision-guard-default-off = mkTest "claude-hm-memory-collision-guard-default-off" (
        let
          bareSettings = claudeSettings (evalHm {ai.claude.enable = true;});
          result = evalHm {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [{hooks = [{command = "consumer-control";}];}];
            };
          };
          settingsHooks = (claudeSettings result).hooks;
        in
          !(bareSettings ? hooks)
          && builtins.elem "consumer-control" (handlerCommands settingsHooks.PreToolUse)
          && hasGuardHook settingsHooks.PreToolUse == false
      );

      # Opting in must produce a PreToolUse entry matching the write-shaped tools. The
      # matcher is asserted because it is half the filter: the script's path test is the
      # other half, and a matcher regression would spawn the hook on every tool call.
      module-claude-hm-memory-collision-guard-opt-in = mkTest "claude-hm-memory-collision-guard-opt-in" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              memoryCollisionGuard.enable = true;
            };
          };
          blocks = (claudeSettings result).hooks.PreToolUse or [];
          guardBlocks = builtins.filter (b: hasGuardHook [b]) blocks;
        in
          builtins.length guardBlocks
          == 1
          && (builtins.head guardBlocks).matcher == "Write|Edit"
      );

      # Devenv parity — same hook, same default, per the repo's config-parity rule.
      module-claude-devenv-memory-collision-guard-opt-in = mkTest "claude-devenv-memory-collision-guard-opt-in" (
        let
          result = evalDevenv {
            ai.claude = {
              enable = true;
              memoryCollisionGuard.enable = true;
            };
          };
          settingsJson = claudeSettings result;
          offResult = evalDevenv {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [{hooks = [{command = "consumer-control";}];}];
            };
          };
          bareSettings = claudeSettings (evalDevenv {ai.claude.enable = true;});
          offJson = claudeSettings offResult;
        in
          hasGuardHook (settingsJson.hooks.PreToolUse or [])
          && !(bareSettings ? hooks)
          && builtins.elem "consumer-control" (handlerCommands offJson.hooks.PreToolUse)
          && hasGuardHook offJson.hooks.PreToolUse == false
      );

      # Compose-not-clobber, same reasoning as the clamp's: emitted as a DEFINITION of
      # ai.claude.hooks rather than as that option's `default`, so a consumer who
      # defines PreToolUse for their own reasons keeps both.
      module-claude-memory-collision-guard-composes-with-consumer-hook = mkTest "claude-memory-collision-guard-composes-with-consumer-hook" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              memoryCollisionGuard.enable = true;
              hooks.PreToolUse = [
                {
                  matcher = "Bash";
                  hooks = [{command = "consumer-hook";}];
                }
              ];
            };
          };
          blocks = (claudeSettings result).hooks.PreToolUse or [];
          cmds = handlerCommands blocks;
        in
          builtins.elem "consumer-hook" cmds
          && builtins.any (lib.hasInfix "claude-memory-collision-guard") cmds
      );

      # Typed ai.claude.hooks event map: accepts the settings.json-shaped
      # per-event structure (soft-enum event key → list of matcher blocks →
      # list of typed handlers) and carries it through. No lowering asserted
      # here — that is Commit 3/4.
      module-claude-hooks-typed-event-map = mkTest "claude-hooks-typed-event-map" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [
                {
                  matcher = "Bash";
                  hooks = [{command = "true";}];
                }
              ];
            };
          };
          block = builtins.head (result.config.ai.claude.hooks.PreToolUse or []);
          handler = builtins.head (block.hooks or []);
        in
          block.matcher == "Bash" && handler.command == "true" && handler.type == "command"
      );

      # S1: a handler `command` accepts a package and coerces to its getExe path
      # (its supporting files ride the /nix/store closure at absolute paths).
      module-claude-hooks-command-accepts-package = mkTest "claude-hooks-command-accepts-package" (
        let
          pkg = pkgs.writeShellApplication {
            name = "demo-hook";
            text = "exit 0";
          };
          result = evalHm {
            ai.claude = {
              enable = true;
              hooks.PostToolUse = [{hooks = [{command = pkg;}];}];
            };
          };
          handler = builtins.head (builtins.head result.config.ai.claude.hooks.PostToolUse).hooks;
        in
          builtins.isString handler.command && lib.hasSuffix "/bin/demo-hook" handler.command
      );

      module-claude-hooks-command-resolves-package-pname = mkTest "claude-hooks-command-resolves-package-pname" (
        let
          pkg = pkgs.runCommand "demo-hook-no-main-program" {pname = "demo-hook";} ''
            mkdir -p "$out/bin"
            touch "$out/bin/demo-hook"
          '';
          result = evalHm {
            ai.claude = {
              enable = true;
              hooks.PostToolUse = [{hooks = [{command = pkg;}];}];
            };
          };
          handler = builtins.head (builtins.head result.config.ai.claude.hooks.PostToolUse).hooks;
        in
          builtins.isString handler.command && lib.hasSuffix "/bin/demo-hook" handler.command
      );

      # ── ai.*.skillsDir Dir helper ──────────────────────────────
      # Directory-of-directories; each immediate subdir becomes a
      # skill. See lib/ai/dir-helpers.nix:skillsFromDir.

      # Path-only form fans every subdir into ai.claude.skills.
      module-claude-skillsdir-path-form = mkTest "claude-skillsdir-path-form" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              skillsDir = ./fixtures/claude-skills;
            };
          };
          files = result.config.home.file;
        in
          files ? ".claude/skills/skill-a" && files ? ".claude/skills/skill-b"
      );

      # Submodule form with a filter that excludes skill-b.
      module-claude-skillsdir-filter = mkTest "claude-skillsdir-filter" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              skillsDir = {
                path = ./fixtures/claude-skills;
                filter = name: name == "skill-a";
              };
            };
          };
          files = result.config.home.file;
        in
          files ? ".claude/skills/skill-a" && !(files ? ".claude/skills/skill-b")
      );

      # A per-runtime directory-generated entry replaces the same-key root entry.
      module-claude-skillsdir-entry-replaces-root-single = mkTest "claude-skillsdir-entry-replaces-root-single" (
        let
          result = evalHm {
            ai.skills.skill-a = ./fixtures/claude-skills/skill-b;
            ai.claude = {
              enable = true;
              skillsDir = ./fixtures/claude-skills;
            };
          };
        in
          result.config.home.file.".claude/skills/skill-a".source == ./fixtures/claude-skills/skill-a
      );

      # ── ai.*.agentsDir Dir helper ──────────────────────────────
      # Legacy Markdown directories are Claude + Copilot only. Codex is excluded
      # because its agents are semantic records rendered to standalone TOML; Kiro
      # is excluded because these are Markdown while Kiro's agents are JSON, and
      # its tool tags are a different vocabulary (separate `ai.kiro.agents` /
      # `ai.kiro.agentsDir` surfaces handle that).

      # Path-only form: `ai.claude.agentsDir = ./fixtures/claude-agents;`
      # expands to two entries (agent-one, agent-two). Emission lands
      # at `.claude/agents/<name>.md` via the existing per-agent file
      # emission in mkClaude.
      module-claude-agentsdir-path-form = mkTest "claude-agentsdir-path-form" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              agentsDir = ./fixtures/claude-agents;
            };
          };
          files = result.config.home.file;
        in
          files ? ".claude/agents/agent-one.md" && files ? ".claude/agents/agent-two.md"
      );

      # Submodule form with filter.
      module-claude-agentsdir-filter = mkTest "claude-agentsdir-filter" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              agentsDir = {
                path = ./fixtures/claude-agents;
                filter = name: name == "agent-one.md";
              };
            };
          };
          files = result.config.home.file;
        in
          files ? ".claude/agents/agent-one.md" && !(files ? ".claude/agents/agent-two.md")
      );

      # A per-runtime directory-generated entry replaces the same-key root entry.
      module-claude-agentsdir-entry-replaces-root-single = mkTest "claude-agentsdir-entry-replaces-root-single" (
        let
          result = evalHm {
            ai.agents.agent-one = "Explicit top-level agent";
            ai.claude = {
              enable = true;
              agentsDir = ./fixtures/claude-agents;
            };
          };
        in
          result.config.home.file.".claude/agents/agent-one.md".source == ./fixtures/claude-agents/agent-one.md
      );

      # Devenv parity: agents land at project `.claude/agents/<name>.md` through
      # the same renderer as Home Manager's. A semantic root record renders
      # frontmatter + body; a per-runtime null tombstone suppresses a root entry;
      # nothing warns about an undelivered surface.
      module-claude-devenv-agents = mkTest "claude-devenv-agents" (
        let
          result = evalDevenv {
            ai = {
              agents = {
                probe = {
                  description = "Probe agent.";
                  instructions.text = "PROBE-AGENT-BODY-TOKEN.";
                };
                # A store-path STRING, as a flake input yields: a source, the
                # way Home Manager's `isPathLike` classifies it.
                store-string = "${./fixtures/claude-agents}/agent-one.md";
                suppressed = "Suppressed agent.";
              };
              claude = {
                enable = true;
                agents.suppressed = null;
              };
            };
          };
          text = (result.config.files.".claude/agents/probe.md" or {}).text or "";
          storeString = result.config.files.".claude/agents/store-string.md" or {};
        in
          toString (storeString.source or "")
          == "${./fixtures/claude-agents}/agent-one.md"
          && (storeString.text or null) == null
          && lib.hasInfix "name: \"probe\"" text
          && lib.hasInfix "description: \"Probe agent.\"" text
          && lib.hasInfix "PROBE-AGENT-BODY-TOKEN." text
          && !(result.config.files ? ".claude/agents/suppressed.md")
          && !(lib.any (lib.hasInfix "agents") result.config.warnings)
      );

      # Devenv parity for `agentsDir`: each `.md` becomes a path-valued agent
      # delivered as its own file, with no undelivered-surface warning.
      module-claude-devenv-agentsdir = mkTest "claude-devenv-agentsdir" (
        let
          result = evalDevenv {
            ai.claude = {
              enable = true;
              agentsDir = {
                path = ./fixtures/claude-agents;
                filter = name: name == "agent-one.md";
              };
            };
          };
          file = result.config.files.".claude/agents/agent-one.md" or {};
          # The same directory as a store-path string, as a flake input yields.
          fromString = evalDevenv {
            ai.claude = {
              enable = true;
              agentsDir = {
                path = "${./fixtures/claude-agents}";
                filter = name: name == "agent-one.md";
              };
            };
          };
          stringFile = fromString.config.files.".claude/agents/agent-one.md" or {};
        in
          (file.source or null)
          == ./fixtures/claude-agents/agent-one.md
          && toString (stringFile.source or "") == "${./fixtures/claude-agents}/agent-one.md"
          && (stringFile.text or null) == null
          && !(result.config.files ? ".claude/agents/agent-two.md")
          && !(lib.any (lib.hasInfix "agentsDir") result.config.warnings)
      );

      # ── ai.claude.hookScriptsDir Dir helper ────────────────────
      # Claude-only per plan §5 (hook scripts are a Claude-specific
      # concept). See lib/ai/dir-helpers.nix:hooksFromDir. Default
      # filter is always-true — hook files are typically
      # extensionless shell scripts, so no `.md`-like suffix strip.

      module-claude-hookscriptsdir-path-form = mkTest "claude-hookscriptsdir-path-form" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              hookScriptsDir = ./fixtures/claude-hooks;
            };
          };
          files = result.config.home.file;
        in
          files ? ".claude/hooks/pre-edit" && files ? ".claude/hooks/post-edit"
      );

      # Filter excludes post-edit.
      module-claude-hookscriptsdir-filter = mkTest "claude-hookscriptsdir-filter" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              hookScriptsDir = {
                path = ./fixtures/claude-hooks;
                filter = name: name == "pre-edit";
              };
            };
          };
          files = result.config.home.file;
        in
          files ? ".claude/hooks/pre-edit" && !(files ? ".claude/hooks/post-edit")
      );

      # Collision: Dir-generated vs explicit `ai.claude.hookScripts.<name>`
      # is NOT a shared-pool collision (hook scripts have no top-level pool),
      # so the module system handles it via the `attrsOf lines` merge.
      # The Dir expansion uses mkDefault so explicit entries win.
      module-claude-hookscriptsdir-explicit-wins-within-layer = mkTest "claude-hookscriptsdir-explicit-wins-within-layer" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              hookScripts.pre-edit = "explicit override";
              hookScriptsDir = ./fixtures/claude-hooks;
            };
          };
        in
          result.config.home.file.".claude/hooks/pre-edit".text == "explicit override"
      );

      # Devenv parity — hookScriptsDir feeds the same .claude/hooks/<name> files.
      module-claude-devenv-hookscriptsdir-path-form = mkTest "claude-devenv-hookscriptsdir-path-form" (
        let
          result = evalDevenv {
            ai.claude = {
              enable = true;
              hookScriptsDir = ./fixtures/claude-hooks;
            };
          };
          files = result.config.files or {};
        in
          files ? ".claude/hooks/pre-edit" && files ? ".claude/hooks/post-edit"
      );

      module-claude-hm-rule-sourcepath-rejected = mkTest "claude-hm-rule-sourcepath-rejected" (
        let
          attempt = builtins.tryEval (let
            r = evalHm {
              ai.claude = {
                enable = true;
                rules.my-rule = {
                  text = "body";
                  sourcePath = "/abs/path/to/my-rule.md";
                };
              };
            };
          in
            builtins.deepSeq r.config.ai.claude.rules.my-rule true);
        in
          !attempt.success
      );

      module-claude-unrecognized-settings-known-keys-accepted = mkTest "claude-unrecognized-settings-known-keys-accepted" (
        claudeAssertionsPass (evalHm claudeKnownKeysCfg)
        && claudeAssertionsPass (evalDevenv claudeKnownKeysCfg)
      );

      module-claude-unrecognized-settings-nested-typo-rejected = mkTest "claude-unrecognized-settings-nested-typo-rejected" (
        claudeAssertionFails "permissions.alow" (evalHm claudeNestedTypoCfg)
        && claudeAssertionFails "permissions.alow" (evalDevenv claudeNestedTypoCfg)
      );

      # The allowlist is a per-key opt-out, and an entry is a full dotted path —
      # so the same nested typo passes once it is named.
      module-claude-unrecognized-settings-allowlist-rescues-typo = mkTest "claude-unrecognized-settings-allowlist-rescues-typo" (
        let
          cfg =
            lib.recursiveUpdate claudeNestedTypoCfg
            {ai.claude.allowUnrecognizedSettings = ["permissions.alow"];};
        in
          claudeAssertionsPass (evalHm cfg) && claudeAssertionsPass (evalDevenv cfg)
      );

      # A redundant entry is a HARD FAILURE, not a warning: `ultracode` is declared
      # by the packaged binary, so the entry suppresses nothing — and left in place
      # it is a standing opt-out that silently re-opens the typo hole for that one
      # key the day upstream renames it.
      module-claude-unrecognized-settings-redundant-allowlist-rejected = mkTest "claude-unrecognized-settings-redundant-allowlist-rejected" (
        let
          cfg = {
            ai.claude = {
              enable = true;
              allowUnrecognizedSettings = ["ultracode"];
            };
          };
        in
          claudeAssertionFails "allowUnrecognizedSettings" (evalHm cfg)
          && claudeAssertionFails "allowUnrecognizedSettings" (evalDevenv cfg)
      );
    }
    // families.checks;
}
