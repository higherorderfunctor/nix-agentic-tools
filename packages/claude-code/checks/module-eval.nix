# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest ownedDocument;
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
  # Refuses an absent or blank body, so a renamed writer fails the check
  # instead of passing it with an empty string.
  unpinWriter = result:
    lib.attrByPath ["home" "activation" "claudeUnpinLaunchEffort" "text"]
    (throw "module-test: config.home.activation.claudeUnpinLaunchEffort.text is missing")
    result.config;
in {
  checks = {
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
    # per-app one contributed by mkAiApp. It does NOT verify the claude
    # module's internal mergedServers fanout computation. Fanout correctness
    # is tested in checks/ai-factory/factory-eval.nix via factory-mkAiApp-fanout-*.
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
        ruleFile = evaluated.config.files.".claude/rules/named-rule.md" or null;
      in
        lib.hasInfix "CONTEXT-BASELINE-TOKEN." composed
        && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." composed)
        && !(lib.hasInfix "NAMED-RULE-BODY-TOKEN." composed)
        && ruleFile != null
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (ruleFile.text or "")
        && evaluated.config.files ? ".claude/rules/unnamed.md"
    );

    # ── Task 3 (A2): Claude HM/devenv fanout absorption ────────────
    module-claude-hm-delegates-programs-claude-code = mkTest "claude-hm-delegates-programs-claude-code" (
      let
        result = evalHm {
          ai.claude.enable = true;
        };
      in
        result.config.programs.claude-code.enable or false
    );

    # HM: native settings reach the upstream settings option through the
    # delivery entry, including nested permission leaves.
    module-claude-hm-settings-reach-upstream = mkTest "claude-hm-settings-reach-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings = {
              effortLevel = "medium";
              permissions.allow = ["Read"];
            };
          };
        };
        upstreamSettings = result.config.programs.claude-code.settings;
      in
        (upstreamSettings.effortLevel or null)
        == "medium"
        && ((upstreamSettings.permissions.allow or []) == ["Read"])
    );

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

    # Valid effortLevel reaches upstream.
    module-claude-hm-effort-level-valid-reaches-upstream = mkTest "claude-hm-effort-level-valid-reaches-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.effortLevel = "xhigh";
          };
        };
      in
        (result.config.programs.claude-code.settings.effortLevel or null) == "xhigh"
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

    # Valid tui renderer reaches upstream (typed nullOr enum).
    module-claude-hm-tui-valid-reaches-upstream = mkTest "claude-hm-tui-valid-reaches-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.tui = "fullscreen";
          };
        };
      in
        (result.config.programs.claude-code.settings.tui or null) == "fullscreen"
    );

    # Attribution: `false` coerces to "" at the type layer (disables the
    # commit trailer) and survives the null-filter (filterNulls keeps "").
    module-claude-hm-attribution-false-disables-reaches-upstream = mkTest "claude-hm-attribution-false-disables-reaches-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = false;
          };
        };
      in
        (result.config.programs.claude-code.settings.attribution.commit or null) == ""
    );

    # Attribution: a custom string passes through unchanged.
    module-claude-hm-attribution-string-reaches-upstream = mkTest "claude-hm-attribution-string-reaches-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.attribution.pr = "Reviewed-by: me";
          };
        };
      in
        (result.config.programs.claude-code.settings.attribution.pr or null) == "Reviewed-by: me"
    );

    # Attribution: `true` coerces to null -> filtered; the attribution block
    # collapses to empty and is dropped entirely (Claude keeps its defaults).
    module-claude-hm-attribution-true-filtered = mkTest "claude-hm-attribution-true-filtered" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = true;
          };
        };
        s = result.config.programs.claude-code.settings;
      in
        !(s ? attribution)
    );

    # Null typed keys are filtered out — upstream never sees the typed keys
    # when unset, and the undocumented `ultracode` key is never written unless
    # ultracodeOnLaunch is set.
    module-claude-hm-null-settings-filtered = mkTest "claude-hm-null-settings-filtered" (
      let
        result = evalHm {ai.claude.enable = true;};
        s = result.config.programs.claude-code.settings;
      in
        !(s ? attribution)
        && !(s ? effortLevel)
        && !(s ? model)
        && !(s ? tui)
        && !(s ? enableWorkflows)
        && !(s ? workflowKeywordTriggerEnabled)
        && !(s ? ultracode)
    );

    # Valid enableWorkflows reaches upstream (typed nullOr bool).
    module-claude-hm-enable-workflows-valid-reaches-upstream = mkTest "claude-hm-enable-workflows-valid-reaches-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.enableWorkflows = true;
          };
        };
      in
        (result.config.programs.claude-code.settings.enableWorkflows or null) == true
    );

    # Valid workflowKeywordTriggerEnabled reaches upstream (typed nullOr bool);
    # `false` survives the null-filter (filterNulls drops null, keeps false).
    module-claude-hm-workflow-keyword-trigger-valid-reaches-upstream = mkTest "claude-hm-workflow-keyword-trigger-valid-reaches-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.workflowKeywordTriggerEnabled = false;
          };
        };
        s = result.config.programs.claude-code.settings;
      in
        (s ? workflowKeywordTriggerEnabled)
        && s.workflowKeywordTriggerEnabled == false
    );

    # Meta option: ultracodeOnLaunch = true writes both the undocumented
    # `ultracode` key and the `enableWorkflows` master toggle to upstream.
    module-claude-hm-ultracode-on-launch-writes-settings = mkTest "claude-hm-ultracode-on-launch-writes-settings" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
          };
        };
        s = result.config.programs.claude-code.settings;
      in
        (s.ultracode or null) == true && (s.enableWorkflows or null) == true
    );

    # Meta option uses mkDefault, so an explicit native.settings.ultracode = false
    # wins over ultracodeOnLaunch, and the false survives the null-filter.
    module-claude-hm-ultracode-on-launch-explicit-false-wins = mkTest "claude-hm-ultracode-on-launch-explicit-false-wins" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
            native.settings.ultracode = false;
          };
        };
        s = result.config.programs.claude-code.settings;
      in
        (s ? ultracode) && s.ultracode == false
    );

    # Negative invariant: ultracodeOnLaunch writes ONLY ultracode +
    # enableWorkflows. It must NOT set effortLevel (ultracode implies xhigh) or
    # workflowKeywordTriggerEnabled (orthogonal per-turn key). Guards against a
    # future fan-out accidentally over-reaching.
    module-claude-hm-ultracode-on-launch-omits-orthogonal-keys = mkTest "claude-hm-ultracode-on-launch-omits-orthogonal-keys" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
          };
        };
        s = result.config.programs.claude-code.settings;
      in
        !(s ? effortLevel) && !(s ? workflowKeywordTriggerEnabled)
    );

    # Soft-enum model: an arbitrary (unknown) id is accepted and reaches upstream.
    module-claude-hm-model-soft-enum-accepts-arbitrary = mkTest "claude-hm-model-soft-enum-accepts-arbitrary" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            native.settings.model = "some-future-model";
          };
        };
      in
        (result.config.programs.claude-code.settings.model or null) == "some-future-model"
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

    module-claude-hm-delegates-skills-to-upstream = mkTest "claude-hm-delegates-skills-to-upstream" (
      let
        result = evalHm {
          ai.claude.enable = true;
          ai.skills.stack-fix = ../../stacked-workflows/skills/stack-fix;
        };
      in
        result.config.programs.claude-code.skills ? stack-fix
    );

    # Settings carries the settings, permissions and typed-hook surfaces;
    # script hooks have their own upstream option. None may gain a second
    # writer in home.file when the factory moves onto the delivery layer.
    module-claude-hm-delivery-delegates-upstream-surfaces = mkTest "claude-hm-delivery-delegates-upstream-surfaces" (
      let
        result =
          (evalHm {
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
          }).config;
        delegated = {
          ".claude/agents" = "agents";
          ".claude/hooks" = "hooks";
          ".claude/settings.json" = "settings";
          ".claude/skills" = "skills";
          ".claude/skills/claude-code-home-manager/.lsp.json" = "lspServers";
          ".claude/skills/claude-code-home-manager/.mcp.json" = "mcpServers";
        };
      in
        lib.all (path: let
          entry = result.ai.claude.files.${path};
        in
          entry.method
          == "upstream"
          && entry.sink == ["programs" "claude-code" delegated.${path}]
          && entry.content.value == result.programs.claude-code.${delegated.${path}}
          && !(result.home.file ? ${path}))
        (lib.attrNames delegated)
        && result.programs.claude-code.settings.permissions.allow == ["Read"]
        && handlerCommands result.programs.claude-code.settings.hooks.PreToolUse == ["true"]
    );

    module-claude-hm-upstream-overrides-generated-defaults = mkTest "claude-hm-upstream-overrides-generated-defaults" (
      let
        result =
          (evalHm {
            ai = {
              claude.enable = true;
              mcpServers.probe.command = "probe";
              skills = {
                kept = ./fixtures/claude-skills/skill-a;
                replaced = ./fixtures/claude-skills/skill-a;
              };
            };
            programs.claude-code = {
              settings.env.ENABLE_LSP_TOOL = "0";
              skills.replaced = ./fixtures/claude-skills/skill-b;
            };
          }).config.programs.claude-code;
      in
        result.settings.env.ENABLE_LSP_TOOL
        == "0"
        && result.skills.kept == ./fixtures/claude-skills/skill-a
        && result.skills.replaced == ./fixtures/claude-skills/skill-b
    );

    module-claude-devenv-delegates-claude-code = mkTest "claude-devenv-delegates-claude-code" (
      let
        result = evalDevenv {
          ai.claude.enable = true;
        };
      in
        result.config.claude.code.enable or false
    );

    # Devenv: cfg.native.settings gap write — non-hook/non-mcpServers keys land
    # in files.".claude/settings.json".json. Module-system attrs merge with
    # upstream's hook write (not exercised here; upstream claude.code is
    # stubbed to `attrsOf anything`) produces a single settings.json on
    # disk in production.
    module-claude-devenv-settings-gap-writes-effort-level = mkTest "claude-devenv-settings-gap-writes-effort-level" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            native.settings.effortLevel = "medium";
          };
        };
        settingsFile = result.config.files.".claude/settings.json" or null;
      in
        settingsFile
        != null
        && (settingsFile.json.effortLevel or null) == "medium"
    );

    # Devenv: `env` flows through the gap write (no longer short-circuited
    # to a non-existent claude.code.env option).
    module-claude-devenv-settings-gap-writes-env = mkTest "claude-devenv-settings-gap-writes-env" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            native.settings.env.FOO = "bar";
          };
        };
        settingsFile = result.config.files.".claude/settings.json" or null;
      in
        settingsFile
        != null
        && (settingsFile.json.env.FOO or null) == "bar"
    );

    # Devenv: typed enableWorkflows flows through the gap write into
    # files.".claude/settings.json".json (parity with the HM typed key).
    module-claude-devenv-settings-gap-writes-enable-workflows = mkTest "claude-devenv-settings-gap-writes-enable-workflows" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            native.settings.enableWorkflows = true;
          };
        };
        settingsFile = result.config.files.".claude/settings.json" or null;
      in
        settingsFile
        != null
        && (settingsFile.json.enableWorkflows or null) == true
    );

    # Devenv: attribution `false` flows through the gap write as "" into
    # files.".claude/settings.json".json.attribution (parity with HM).
    module-claude-devenv-settings-gap-writes-attribution = mkTest "claude-devenv-settings-gap-writes-attribution" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = false;
          };
        };
        settingsFile = result.config.files.".claude/settings.json" or null;
      in
        settingsFile
        != null
        && (settingsFile.json.attribution.commit or null) == ""
    );

    # Devenv: ultracodeOnLaunch = true writes both ultracode and
    # enableWorkflows into the gap-written settings.json (parity with HM).
    module-claude-devenv-ultracode-on-launch-writes-settings = mkTest "claude-devenv-ultracode-on-launch-writes-settings" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
          };
        };
        settingsFile = result.config.files.".claude/settings.json" or null;
      in
        settingsFile
        != null
        && (settingsFile.json.ultracode or null) == true
        && (settingsFile.json.enableWorkflows or null) == true
    );

    # Devenv parity for the mkDefault override: an explicit native.settings.ultracode =
    # false wins over ultracodeOnLaunch and survives the gap-write null-filter.
    module-claude-devenv-ultracode-on-launch-explicit-false-wins = mkTest "claude-devenv-ultracode-on-launch-explicit-false-wins" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
            native.settings.ultracode = false;
          };
        };
        settingsFile = result.config.files.".claude/settings.json" or null;
      in
        settingsFile
        != null
        && (settingsFile.json ? ultracode)
        && settingsFile.json.ultracode == false
    );

    # Devenv: the legacy `native.settings.hooks` escape hatch lowers verbatim into
    # files.".claude/settings.json".json.hooks — NOT claude.code.hooks anymore
    # (approach B). Composes with the typed event map via the formats.json merge.
    module-claude-devenv-settings-hooks-escape-hatch = mkTest "claude-devenv-settings-hooks-escape-hatch" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            native.settings.hooks.PreToolUse = [{matcher = "Bash";}];
          };
        };
        settingsHooks = ((result.config.files.".claude/settings.json" or {}).json or {}).hooks or {};
      in
        ((builtins.head (settingsHooks.PreToolUse or [])).matcher or null)
        == "Bash"
        && !(result.config.claude.code ? hooks)
    );

    # Devenv: empty ai.claude.native.settings produces no gap file (lib.mkIf
    # gate on hasGapSettings).
    #
    # The heron_brook mitigation writes hooks into the same settings.json through
    # a DIFFERENT writer, so it must stay off here for this test to be about the
    # gap writer's own mkIf gate. That is now the default, so no explicit opt-out
    # is needed — but if delegationClampMitigation ever becomes default-on again, this test
    # will start failing for a reason that has nothing to do with the gap writer.
    # `gitSshConfigWorkaround` is the second such writer and it IS default-on:
    # devenv has no `programs.git`, so the sandbox-safe SSH command reaches
    # Claude through `settings.env.GIT_SSH_COMMAND` — which makes settings
    # non-empty and would fail this test for a reason that has nothing to do
    # with the gap writer. Opted out here so the assertion stays about the
    # writer's own gate. The workaround's own delivery is covered by
    # `module-ai-git-ssh-default-follows-harnesses`.
    module-claude-devenv-settings-empty-no-gap-file = mkTest "claude-devenv-settings-empty-no-gap-file" (
      let
        result = evalDevenv {
          ai.claude.enable = true;
          ai.gitSshConfigWorkaround = false;
        };
      in
        !(result.config.files ? ".claude/settings.json")
    );

    # Devenv: typed ai.claude.mcpServers entries are RENDERED before they
    # reach upstream `claude.code.mcpServers` (parity with the HM branch).
    # Upstream's devenv server submodule has no `package` option, so a raw
    # typed entry fails its strict type in a real devenv eval ("The option
    # 'claude.code.mcpServers.<name>.package' does not exist") — the stub
    # here is `attrsOf anything`, so the load-bearing assertion is that the
    # rendered shape carries NO raw `package` key and the derived
    # command/args. Uses a real server name (context7-mcp) so renderServer's
    # package branch (loadServer + mode-string args) is exercised end-to-end.
    module-claude-devenv-mcp-servers-rendered = mkTest "claude-devenv-mcp-servers-rendered" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            mcpServers.context7-mcp.package = pkgs.hello;
          };
        };
        rendered = (result.config.claude.code.mcpServers or {})."context7-mcp" or null;
      in
        rendered
        != null
        && !(rendered ? package)
        && rendered.type == "stdio"
        && lib.hasSuffix "/bin/hello" rendered.command
        && lib.take 2 rendered.args == ["--transport" "stdio"]
    );

    # Devenv/HM parity: the SAME typed config yields the SAME rendered
    # server attrset on both backends (programs.claude-code.mcpServers vs
    # claude.code.mcpServers) — the render is shared (lib.ai.renderServer),
    # so any divergence is a factory regression. `==` is decidable over
    # context-carrying strings (store paths in command/env).
    module-claude-devenv-mcp-servers-hm-parity = mkTest "claude-devenv-mcp-servers-hm-parity" (
      let
        cfg = {
          ai.claude = {
            enable = true;
            mcpServers.context7-mcp.package = pkgs.hello;
          };
        };
        hmServers = (evalHm cfg).config.programs.claude-code.mcpServers or {};
        dvServers = (evalDevenv cfg).config.claude.code.mcpServers or {};
      in
        hmServers
        != {}
        && hmServers == dvServers
    );

    module-claude-hm-sets-lsp-env-when-servers-present = mkTest "claude-hm-sets-lsp-env-when-servers-present" (
      let
        result = evalHm {
          ai.claude.enable = true;
          ai.mcpServers.test-server = {
            type = "stdio";
            package = pkgs.hello;
            command = "hello";
          };
        };
      in
        (result.config.programs.claude-code.settings.env.ENABLE_LSP_TOOL or null) == "1"
    );

    # ── Task 5 (A4b): Claude launch-effort unpin reconciler ────────

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

    # One runtime corpus covers the document codec plus actual HM activations
    # and devenv tasks. Every empty generation is evaluated and executed,
    # so a missing writer cannot satisfy the N-to-0 check.
    module-json-settings-reconciliation = let
      mkCase = name: configFile: first: second: native: render: {
        inherit configFile first name native second;
        scripts = map render [first second {}];
      };
      mkDevenvCase = {
        configFile,
        empty ? {},
        entry,
        first,
        native,
        option,
        runtime,
        second,
      }: let
        render = extra:
          (evalDevenv (lib.recursiveUpdate {ai.${runtime}.enable = true;} extra)).config.tasks.${entry}.exec;
      in {
        inherit configFile empty first native second;
        backend = "devenv";
        name = "${runtime}-${lib.concatStringsSep "-" option}-devenv";
        scripts =
          map (settings: render (lib.setAttrByPath (["ai" runtime] ++ option) settings)) [first second {}]
          # Kimchi's config defaults still claim skillPaths = []. Suppressing
          # its file must retire even that last leaf without losing the writer.
          ++ lib.optional (empty != {}) (render {ai.${runtime}.files.${configFile} = lib.mkForce null;});
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
            # A real delivery description exercises the codec's unusual keys
            # through the same writer path as every runtime-owned document.
              (evalHm {
                ai.claude = {
                  enable = true;
                  activation.documentCodecTest.ledgers."json-settings/document-codec-test.json" = {
                    codec = "json";
                    path = ".settings with spaces/config.json";
                  };
                  files.".settings with spaces/config.json" = {
                    content.value = settings;
                    entry = "documentCodecTest";
                    facts.harnessWrites = true;
                    format = "json";
                    ledger = "json-settings/document-codec-test.json";
                  };
                };
              }).config.home.activation.documentCodecTest.text))
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
        (mkCase "kiro" ".kiro/settings/cli.json" {
            "chat.defaultModel" = "claude-sonnet-4";
            "chat.modelDefaults"."claude-opus-4.8".effort = "high";
          } {
            "chat.defaultModel" = "claude-opus-4.8";
          } {
            "chat.modelDefaults".native.effort = "low";
            "native.setting" = "survives";
          } (settings:
            (evalHm {
              ai.kiro = {
                enable = true;
                native.settings = {
                  chat.defaultModel = settings."chat.defaultModel" or null;
                  chat.modelDefaults = settings."chat.modelDefaults" or {};
                };
              };
            }).config.home.activation.kiroSettingsMerge.text))
        (mkDevenvCase {
          configFile = ".config/github-copilot/settings.json";
          entry = "ai:copilot:settings-merge";
          first = {
            model = "first";
            preferences.managed = true;
          };
          native = {
            preferences.native = "survives";
            trusted_folders = ["native-folder"];
          };
          option = ["native" "settings"];
          runtime = "copilot";
          second.model = "second";
        })
        (mkDevenvCase {
          configFile = ".config/kimchi/config.json";
          empty.skillPaths = [];
          entry = "ai:kimchi:config-merge";
          first = {
            llmEndpoint = "https://first.invalid";
            preferences.managed = true;
            skillPaths = ["managed-skill"];
          };
          native.preferences.native = "survives";
          option = ["native" "settings"];
          runtime = "kimchi";
          second = {
            llmEndpoint = "https://second.invalid";
            skillPaths = [];
          };
        })
        (mkDevenvCase {
          configFile = ".config/kimchi/harness/settings.json";
          entry = "ai:kimchi:harness-settings-merge";
          first.resources = {
            managed = true;
            retained = true;
          };
          native.resources.native = true;
          option = ["native" "harnessSettings"];
          runtime = "kimchi";
          second.resources.retained = false;
        })
        (mkDevenvCase {
          configFile = ".kiro/settings/cli.json";
          entry = "ai:kiro:settings-merge";
          first = {
            "chat.enableTangentMode" = true;
            "chat.modelDefaults"."claude-opus-4.8".effort = "high";
          };
          native = {
            "chat.modelDefaults".native.effort = "low";
            "native.setting" = "survives";
          };
          option = ["native" "settings"];
          runtime = "kiro";
          second."chat.enableTangentMode" = false;
        })
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

    # HM: ai.claude.plugins routes to programs.claude-code.plugins as an
    # ATTRSET, key and value intact. The per-entry mkDefault in mkClaude
    # must resolve away, leaving the bare source.
    module-claude-hm-plugins-route-to-upstream = mkTest "claude-hm-plugins-route-to-upstream" (
      let
        src = ../../stacked-workflows/skills/stack-fix;
        result = evalHm {
          ai.claude = {
            enable = true;
            plugins.my-plugin = src;
          };
        };
        upstream = result.config.programs.claude-code.plugins or {};
      in
        lib.attrNames upstream == ["my-plugin"] && upstream.my-plugin == src
    );

    # HM: the ATTRIBUTE NAME — not the source's base name — is what becomes
    # the plugin's on-disk directory name. This is the whole point of the
    # list → attrset conversion: upstream's list form derives each name from
    # `baseNameOf` the entry, so a bare flake-input store path yields an
    # unstable `<hash>-source` that is renamed by every unrelated input bump.
    #
    # Upstream (home-manager modules/programs/claude-code, verified at rev
    # cbb77679) consumes the attrset via `lib.mapAttrsToList mkPluginEntry`
    # and links each entry at `<configDir>/skills/<name>`, so the key here IS
    # the delivered directory name. Our boundary is the key handed to
    # upstream; this asserts a key that shares nothing with its value's store
    # base name still arrives verbatim, and that no name is derived from the
    # source.
    module-claude-hm-plugins-key-is-directory-name = mkTest "claude-hm-plugins-key-is-directory-name" (
      let
        # A package whose store base name (…-hello-<version>) is nothing like
        # the key, standing in for a flake-input root.
        pluginPkg = pkgs.hello;
        result = evalHm {
          ai.claude = {
            enable = true;
            plugins.remember = pluginPkg;
          };
        };
        upstream = result.config.programs.claude-code.plugins or {};
        # `unsafeDiscardStringContext` mirrors upstream's own
        # `derivePluginName`; without it the store-path context makes this
        # illegal to use as an attribute name.
        derivedName =
          builtins.unsafeDiscardStringContext (baseNameOf (toString pluginPkg));
      in
        lib.attrNames upstream
        == ["remember"]
        && upstream.remember == pluginPkg
        && !(upstream ? ${derivedName})
    );

    # HM: ai.claude.marketplaces routes to programs.claude-code.marketplaces
    # via identity translation. Regression guard.
    module-claude-hm-marketplaces-route-to-upstream = mkTest "claude-hm-marketplaces-route-to-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            marketplaces.my-shelf = ../../stacked-workflows/skills/stack-fix;
          };
        };
        upstream = result.config.programs.claude-code.marketplaces or {};
      in
        upstream ? my-shelf
    );

    # HM: ai.claude.outputStyles routes to programs.claude-code.outputStyles.
    module-claude-hm-output-styles-route-to-upstream = mkTest "claude-hm-output-styles-route-to-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            outputStyles.concise = "Keep answers under 3 sentences.";
          };
        };
        upstream = result.config.programs.claude-code.outputStyles or {};
      in
        (upstream.concise or null) == "Keep answers under 3 sentences."
    );

    # HM: top-level ai.lspServers fans out to Claude's programs.claude-code.lspServers.
    # Closes the LSP fanout story — Claude now receives the merged pool via
    # upstream HM's own surface (upstream writes into ~/.claude/settings.json).
    module-claude-hm-top-level-lsp-fanout = mkTest "claude-hm-top-level-lsp-fanout" (
      let
        result = evalHm {
          ai.claude.enable = true;
          ai.lspServers.nixd = {
            command = "nixd";
            args = [];
          };
        };
        upstream = result.config.programs.claude-code.lspServers or {};
      in
        (upstream.nixd.command or null) == "nixd"
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
        upstream = result.config.programs.claude-code.lspServers or {};
      in
        (upstream.nixd.command or null) == "nixd-claude-specific"
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
        upstream = result.config.programs.claude-code.lspServers or {};
        entry = upstream.go or {};
      in
        (entry.command or null)
        == "gopls"
        && ((entry.extensionToLanguage or {}).".go" or null)
        == "go"
    );

    # HM: top-level ai.agents fans out to Claude's programs.claude-code.agents.
    module-claude-hm-top-level-agents-fanout = mkTest "claude-hm-top-level-agents-fanout" (
      let
        result = evalHm {
          ai.claude.enable = true;
          ai.agents.reviewer = "# Reviewer\n\nReview carefully.";
        };
        upstream = result.config.programs.claude-code.agents or {};
      in
        (upstream.reviewer or null)
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
        upstream = result.config.programs.claude-code.agents or {};
      in
        (upstream.reviewer or null) == "# Claude-specific"
    );

    # HM: ai.claude.commands routes to programs.claude-code.commands via
    # identity translation. Claude-only — Kiro and Copilot have no
    # commands concept, so no top-level fanout.
    module-claude-hm-commands-route-to-upstream = mkTest "claude-hm-commands-route-to-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            commands.fix-issue = "# Fix issue\n\nSteps…";
          };
        };
        upstream = result.config.programs.claude-code.commands or {};
      in
        (upstream.fix-issue or null) == "# Fix issue\n\nSteps…"
    );

    # HM: ai.claude.hookScripts (inline script bodies) routes to
    # programs.claude-code.hooks via identity translation.
    module-claude-hm-hookscripts-route-to-upstream = mkTest "claude-hm-hookscripts-route-to-upstream" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            hookScripts.pre-edit = "#!/usr/bin/env bash\necho edit\n";
          };
        };
        upstream = result.config.programs.claude-code.hooks or {};
      in
        (upstream.pre-edit or null) == "#!/usr/bin/env bash\necho edit\n"
    );

    # HM: the typed ai.claude.hooks event map lowers into
    # programs.claude-code.settings.hooks via the shared helper.
    module-claude-hm-hooks-lower-to-settings = mkTest "claude-hm-hooks-lower-to-settings" (
      let
        result = evalHm {
          ai.claude = {
            enable = true;
            hooks.PreToolUse = [
              {
                matcher = "Bash";
                hooks = [{command = "validate";}];
              }
            ];
          };
        };
        settingsHooks = result.config.programs.claude-code.settings.hooks;
        block = builtins.head (settingsHooks.PreToolUse or []);
        handler = builtins.head (block.hooks or []);
      in
        block.matcher == "Bash" && handler.command == "validate" && handler.type == "command"
    );

    # ── heron_brook delegation clamp mitigation ──────────────────
    # OPT-IN is the requirement: a bare `enable = true` must carry NEITHER hook.
    # Asserting both are absent also pins the all-or-nothing property — emitting
    # only the PreCompact half would leave a hook clearing a marker nothing ever
    # writes, inert but confusing to find in a settings.json you never asked to
    # be modified.
    module-claude-hm-delegation-clamp-default-off = mkTest "claude-hm-delegation-clamp-default-off" (
      let
        bareSettings = (evalHm {ai.claude.enable = true;}).config.programs.claude-code.settings;
        result = evalHm {
          ai.claude = {
            enable = true;
            hooks.PreToolUse = [{hooks = [{command = "consumer-control";}];}];
          };
        };
        clamp = result.config.ai.claude.delegationClampMitigation;
        settingsHooks = result.config.programs.claude-code.settings.hooks;
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
        settingsHooks = result.config.programs.claude-code.settings.hooks;
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
        settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
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
        settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
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
        settingsHooks = (result.config.programs.claude-code.settings or {}).hooks or {};
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
        settingsJson = (result.config.files.".claude/settings.json" or {}).json or {};
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
        blocks = result.config.programs.claude-code.settings.hooks.UserPromptSubmit or [];
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
        bareSettings = (evalHm {ai.claude.enable = true;}).config.programs.claude-code.settings;
        result = evalHm {
          ai.claude = {
            enable = true;
            hooks.PreToolUse = [{hooks = [{command = "consumer-control";}];}];
          };
        };
        settingsHooks = result.config.programs.claude-code.settings.hooks;
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
        blocks = result.config.programs.claude-code.settings.hooks.PreToolUse or [];
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
        settingsJson = (result.config.files.".claude/settings.json" or {}).json or {};
        offResult = evalDevenv {
          ai.claude = {
            enable = true;
            hooks.PreToolUse = [{hooks = [{command = "consumer-control";}];}];
          };
        };
        bareSettings = (evalDevenv {ai.claude.enable = true;}).config.files.".claude/settings.json".json;
        offJson = offResult.config.files.".claude/settings.json".json;
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
        blocks = result.config.programs.claude-code.settings.hooks.PreToolUse or [];
        cmds = handlerCommands blocks;
      in
        builtins.elem "consumer-hook" cmds
        && builtins.any (lib.hasInfix "claude-memory-collision-guard") cmds
    );

    # Compose-not-clobber invariant (decision #3): settings.json's formats.json
    # merge CONCATENATES same-event hook lists across writers, so the typed event
    # map and the legacy settings.hooks escape hatch coexist. Asserted against the
    # REAL type — the module-eval `attrsOf anything` stub throws on this merge where
    # formats.json concatenates, so it cannot model it. Mirrors the factory pattern:
    # a whole `settings =` write plus a nested `settings.hooks =` write (both
    # backends lower this way).
    module-claude-hooks-settings-json-compose = mkTest "claude-hooks-settings-json-compose" (
      let
        jsonType = (pkgs.formats.json {}).type;
        ev = lib.evalModules {
          modules = [
            {options.settings = lib.mkOption {type = jsonType;};}
            {config.settings = {hooks.PreToolUse = [{matcher = "legacy";}];};}
            {config.settings.hooks.PreToolUse = [{matcher = "typed";}];}
          ];
        };
        matchers = map (b: b.matcher or null) ev.config.settings.hooks.PreToolUse;
      in
        builtins.length matchers == 2 && builtins.elem "legacy" matchers && builtins.elem "typed" matchers
    );

    # Devenv: hookScripts → a `.claude/hooks/<name>` file; the legacy
    # native.settings.hooks escape hatch → settings.json.hooks (verbatim). Neither feeds
    # claude.code.hooks anymore (approach B — the old type-invalid mis-feed is gone).
    module-claude-devenv-hookscripts-and-settings-split = mkTest "claude-devenv-hookscripts-and-settings-split" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            native.settings.hooks.from-settings = [{matcher = "X";}];
            hookScripts.from-top = "#!/usr/bin/env bash\necho from-top\n";
          };
        };
        settingsHooks = ((result.config.files.".claude/settings.json" or {}).json or {}).hooks or {};
        scriptFile = result.config.files.".claude/hooks/from-top" or null;
      in
        (settingsHooks.from-settings or null)
        != null
        && scriptFile != null
        && (scriptFile.text or null) == "#!/usr/bin/env bash\necho from-top\n"
        && !(result.config.claude.code ? hooks)
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

    # Devenv: the typed ai.claude.hooks event map lowers into
    # files.".claude/settings.json".json.hooks via the shared helper
    # (approach B — no claude.code.hooks records).
    module-claude-devenv-hooks-lower-to-settings = mkTest "claude-devenv-hooks-lower-to-settings" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            hooks.PreToolUse = [
              {
                matcher = "Bash";
                hooks = [{command = "validate";}];
              }
            ];
          };
        };
        settingsJson = (result.config.files.".claude/settings.json" or {}).json or {};
        block = builtins.head (settingsJson.hooks.PreToolUse or []);
        handler = builtins.head (block.hooks or []);
      in
        block.matcher == "Bash" && handler.command == "validate" && handler.type == "command"
    );

    # Devenv: hookScripts (inline bodies) become standalone
    # .claude/hooks/<name> files (greenfield; NOT claude.code.hooks).
    module-claude-devenv-hookscripts-write-files = mkTest "claude-devenv-hookscripts-write-files" (
      let
        result = evalDevenv {
          ai.claude = {
            enable = true;
            hookScripts.my-hook = "#!/usr/bin/env bash\nexit 0\n";
          };
        };
        f = result.config.files.".claude/hooks/my-hook" or null;
      in
        f != null && (f.text or null) == "#!/usr/bin/env bash\nexit 0\n"
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
        upstream = result.config.programs.claude-code.skills or {};
      in
        upstream ? skill-a && upstream ? skill-b
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
        upstream = result.config.programs.claude-code.skills or {};
      in
        upstream ? skill-a && !(upstream ? skill-b)
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
        upstream = result.config.programs.claude-code.skills or {};
      in
        upstream.skill-a == ./fixtures/claude-skills/skill-a
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
        upstream = result.config.programs.claude-code.agents or {};
      in
        upstream ? agent-one && upstream ? agent-two
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
        upstream = result.config.programs.claude-code.agents or {};
      in
        upstream ? agent-one && !(upstream ? agent-two)
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
        upstream = result.config.programs.claude-code.agents or {};
      in
        upstream.agent-one == ./fixtures/claude-agents/agent-one.md
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
        upstream = result.config.programs.claude-code.hooks or {};
      in
        upstream ? pre-edit && upstream ? post-edit
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
        upstream = result.config.programs.claude-code.hooks or {};
      in
        upstream ? pre-edit && !(upstream ? post-edit)
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
        upstream = result.config.programs.claude-code.hooks or {};
      in
        upstream.pre-edit == "explicit override"
    );

    # Devenv parity — hookScriptsDir feeds the greenfield .claude/hooks/<name>
    # files (approach B; devenv has no programs.claude-code.hooks equivalent).
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
  };
}
