# End-to-end module eval tests. Each test evaluates the full HM module
# (sharedOptions + every package's modules/homeManager) against a
# synthetic config and asserts the resulting option tree + config.
{
  lib,
  pkgs,
  ...
}: let
  # Stub home-manager's lib.hm.dag.* so activation scripts can be
  # declared without importing home-manager. The real activation
  # entries run in a real HM eval context; this is enough to prove
  # the option tree + config block assemble correctly.
  #
  # lib.ai.* mirrors the flake's `baseLib` shape: mcp helpers,
  # fragment helpers, and the app factory primitives are all nested
  # under `lib.ai.*`. No top-level `lib.<helper>` exports exist.
  mcpLib = import ./../lib/mcp.nix {inherit lib;};
  aiBase = import ./../lib/ai {inherit lib;};
  hmLib =
    lib
    // {
      ai =
        aiBase
        // {
          inherit (mcpLib) loadServer mkPackageEntry mkStdioEntry mkHttpEntry mkStdioConfig renderServer;
        };
      hm = {
        dag = {
          entryAfter = _: text: {inherit text;};
          entryBefore = _: text: {inherit text;};
        };
      };
    };

  # Stub HM options so the config callback in mkClaude.nix can set
  # home.activation.* and home.file.* without importing all of
  # home-manager. The assertions only check ai.* values; these stubs
  # prevent "option does not exist" errors on the side-effect attrs.
  hmStubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      home = {
        activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        file = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        packages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
        };
      };
      programs.git.settings = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      systemd.user.services = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      # Stub config.lib so factory code using config.lib.file.mkOutOfStoreSymlink
      # doesn't error at eval time. Real HM injects this; the module-eval
      # harness otherwise has no config.lib. Identity: the mkOutOfStoreSymlink
      # stub returns its input unchanged — tests assert on .source-vs-.text
      # structure, not the exact symlink-marker shape.
      lib = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {
          file.mkOutOfStoreSymlink = path: path;
        };
      };
      # programs.claude-code is collapsed to attrsOf anything —
      # upstream options aren't in our doc scope (options-doc filters
      # to `ai.*` prefixes), and the stub's only job is to absorb
      # whatever our factory writes. Per-option typed stubs had to be
      # extended every time we added a new `ai.claude.*` route; this
      # freeform form is future-proof.
      programs.claude-code = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
    };
  };

  # Stub devenv's files option + per-ecosystem upstream options so
  # the config callbacks in the factory can set files.* /
  # claude.code.* / copilot.* / kiro.* without importing devenv.
  devenvStubs = {
    options = {
      assertions = lib.mkOption {
        type = lib.types.listOf lib.types.anything;
        default = [];
      };
      env = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = {};
      };
      files = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      packages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [];
      };
      claude.code = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      copilot = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
      kiro = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = {};
      };
    };
  };

  # Stub pkgs.ai with minimal placeholders so factory defaults that
  # reference pkgs.ai.claude-code (default package) can resolve at
  # eval time. The real derivations live in the overlay; here we only
  # need values that stringify cleanly and support passthru access.
  aiStubs =
    (pkgs.ai or {})
    // {
      claude-code = pkgs.ai.claude-code or pkgs.hello;
      copilot-cli = pkgs.ai.copilot-cli or pkgs.hello;
      kiro-cli = pkgs.ai.kiro-cli or pkgs.hello;
      mcpServers = pkgs.ai.mcpServers or {};
      lspServers = pkgs.ai.lspServers or {};
    };

  evalHm = config:
    lib.evalModules {
      specialArgs = {
        lib = hmLib;
        pkgs = pkgs // {ai = aiStubs;};
        inherit (hmLib) hm;
      };
      modules = [
        ./../lib/ai/sharedOptions.nix
        ./../packages/claude-code/modules/homeManager
        ./../packages/copilot-cli/modules/homeManager
        ./../packages/kiro-cli/modules/homeManager
        ./../packages/mcp-services/modules/homeManager
        ./../packages/stacked-workflows/modules/homeManager
        hmStubs
        {inherit config;}
      ];
    };

  evalDevenv = config:
    lib.evalModules {
      specialArgs = {
        lib = hmLib;
        pkgs = pkgs // {ai = pkgs.ai or {};};
      };
      modules = [
        ./../lib/ai/sharedOptions.nix
        ./../packages/claude-code/modules/devenv
        ./../packages/copilot-cli/modules/devenv
        ./../packages/kiro-cli/modules/devenv
        ./../packages/stacked-workflows/modules/devenv
        devenvStubs
        {inherit config;}
      ];
    };

  mkTest = name: assertion:
    pkgs.runCommand "module-test-${name}" {} ''
      ${
        if assertion
        then ''echo "PASS: ${name}" > $out''
        else throw "FAIL: ${name}"
      }
    '';
in {
  module-claude-default-disabled = mkTest "claude-default-disabled" (!(evalHm {}).config.ai.claude.enable);

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
  # is tested in checks/factory-eval.nix via factory-mkAiApp-fanout-*.
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

  # Matches the module-claude-shared-mcp-pool-accepted naming precedent:
  # this test verifies the shared ai.mcpServers pool ACCEPTS a context7
  # entry alongside a loaded claude module without type conflicts. It
  # does NOT verify the claude module's internal mergedServers fanout
  # computation — that's covered in checks/factory-eval.nix via the
  # factory-mkAiApp-fanout-* tests.
  module-context7-shared-mcp-pool-accepted = mkTest "context7-shared-mcp-pool-accepted" (
    let
      evaluated = evalHm {
        ai.claude.enable = true;
        ai.mcpServers.ctx = {
          type = "stdio";
          package = pkgs.ai.mcpServers.context7-mcp or pkgs.hello;
          command = "context7-mcp";
        };
      };
    in
      evaluated.config.ai.mcpServers ? ctx
  );

  module-context7-factory-call = mkTest "context7-factory-call" (
    let
      mkContext7 = import ./../packages/context7-mcp/lib/mkContext7.nix;
      result = mkContext7 {
        lib = hmLib;
        pkgs = pkgs // {ai = pkgs.ai or {};};
      } {};
    in
      result.type == "stdio"
  );

  module-copilot-default-disabled = mkTest "copilot-default-disabled" (!(evalHm {}).config.ai.copilot.enable);

  module-kiro-default-disabled = mkTest "kiro-default-disabled" (!(evalHm {}).config.ai.kiro.enable);

  module-all-three-enabled = mkTest "all-three-enabled" (
    let
      evaluated = evalHm {
        ai = {
          claude.enable = true;
          copilot.enable = true;
          kiro.enable = true;
        };
      };
    in
      evaluated.config.ai.claude.enable
      && evaluated.config.ai.copilot.enable
      && evaluated.config.ai.kiro.enable
  );

  # ── Baseline instruction rendering ──────────────────────────────
  # Verify that mkAiApp's baseline render pipeline produces a
  # home.file entry at the app's outputPath when instructions are
  # merged from the shared pool. This covers the end-to-end path:
  # sharedOptions.ai.instructions -> mkAiApp's mergedInstructions
  # -> transformers.markdown.render -> home.file.<outputPath>.text
  module-claude-instructions-rendered-to-home-file = mkTest "claude-instructions-rendered-to-home-file" (
    let
      evaluated = evalHm {
        ai = {
          claude.enable = true;
          instructions = [
            {
              text = "Always use rg instead of grep.";
              description = "Grep replacement";
            }
          ];
        };
      };
      outputPath = ".claude/CLAUDE.md";
      file = evaluated.config.home.file.${outputPath} or null;
    in
      file
      != null
      && file ? text
      && lib.hasInfix "Always use rg instead of grep." file.text
      && lib.hasInfix "description: Grep replacement" file.text
  );

  module-claude-no-instructions-no-file = mkTest "claude-no-instructions-no-file" (
    let
      evaluated = evalHm {ai.claude.enable = true;};
      # With no instructions merged, mkAiApp should NOT write the
      # baseline home.file entry for Claude's CLAUDE.md path.
    in
      !(evaluated.config.home.file ? ".claude/CLAUDE.md")
  );

  module-claude-per-app-instructions-rendered = mkTest "claude-per-app-instructions-rendered" (
    let
      evaluated = evalHm {
        ai.claude = {
          enable = true;
          instructions = [
            {
              text = "Claude-specific rule.";
              description = "Claude only";
            }
          ];
        };
      };
      file = evaluated.config.home.file.".claude/CLAUDE.md" or null;
    in
      file
      != null
      && lib.hasInfix "Claude-specific rule." file.text
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

  # HM: ai.claude.settings.<key> reaches programs.claude-code.settings.<key>
  # via the transitional raw-inherit in mkClaude.nix. Regression guard for
  # the inherit; will update to assert translation semantics when HM migrates
  # to the devenv pattern.
  module-claude-hm-settings-reach-upstream = mkTest "claude-hm-settings-reach-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          settings = {
            effortLevel = "medium";
            permissions.allow = ["Read"];
          };
        };
      };
      upstreamSettings = result.config.programs.claude-code.settings or {};
    in
      (upstreamSettings.effortLevel or null)
      == "medium"
      && ((upstreamSettings.permissions.allow or []) == ["Read"])
  );

  module-claude-hm-writes-instruction-rule-file = mkTest "claude-hm-writes-instruction-rule-file" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.instructions = [
          {
            name = "my-rule";
            text = "Always use strict mode.";
            paths = ["src/**"];
          }
        ];
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
        ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
      };
    in
      result.config.programs.claude-code.skills ? stack-fix
  );

  module-claude-devenv-delegates-claude-code = mkTest "claude-devenv-delegates-claude-code" (
    let
      result = evalDevenv {
        ai.claude.enable = true;
      };
    in
      result.config.claude.code.enable or false
  );

  # Devenv: cfg.settings gap write — non-hook/non-mcpServers keys land
  # in files.".claude/settings.json".json. Module-system attrs merge with
  # upstream's hook write (not exercised here; upstream claude.code is
  # stubbed to `attrsOf anything`) produces a single settings.json on
  # disk in production.
  module-claude-devenv-settings-gap-writes-effort-level = mkTest "claude-devenv-settings-gap-writes-effort-level" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.effortLevel = "medium";
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
          settings.env.FOO = "bar";
        };
      };
      settingsFile = result.config.files.".claude/settings.json" or null;
    in
      settingsFile
      != null
      && (settingsFile.json.env.FOO or null) == "bar"
  );

  # Devenv: `hooks` routes to claude.code.hooks (upstream-owned) and is
  # excluded from the gap write.
  module-claude-devenv-settings-hooks-route-to-upstream = mkTest "claude-devenv-settings-hooks-route-to-upstream" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.hooks.PreToolUse = [{matcher = "Bash";}];
        };
      };
      upstreamHooks = result.config.claude.code.hooks or {};
      gapJson = (result.config.files.".claude/settings.json" or {}).json or null;
    in
      (upstreamHooks.PreToolUse or null)
      != null
      && (gapJson == null || !(gapJson ? hooks))
  );

  # Devenv: empty ai.claude.settings produces no gap file (lib.mkIf
  # gate on hasGapSettings).
  module-claude-devenv-settings-empty-no-gap-file = mkTest "claude-devenv-settings-empty-no-gap-file" (
    let
      result = evalDevenv {
        ai.claude.enable = true;
      };
    in
      !(result.config.files ? ".claude/settings.json")
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

  # ── Task 4 (A3): Copilot HM/devenv fanout absorption ──────────
  module-copilot-hm-wraps-package = mkTest "copilot-hm-wraps-package" (
    let
      result = evalHm {
        ai.copilot.enable = true;
      };
      packages = result.config.home.packages or [];
    in
      builtins.length packages >= 1
  );

  module-copilot-hm-writes-settings-json-activation = mkTest "copilot-hm-writes-settings-json-activation" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.copilot.settings.model = "gpt-4";
      };
      activation = result.config.home.activation.copilotSettingsMerge or null;
    in
      activation
      != null
      && lib.hasInfix "gpt-4" (activation.text or "")
      && lib.hasInfix "jq" (activation.text or "")
  );

  module-copilot-hm-writes-mcp-config-json = mkTest "copilot-hm-writes-mcp-config-json" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      mcpFile = result.config.home.file.".copilot/mcp-config.json" or null;
    in
      mcpFile
      != null
      && lib.hasInfix "test-server" (mcpFile.text or "")
  );

  module-copilot-hm-writes-instruction-files = mkTest "copilot-hm-writes-instruction-files" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.instructions = [
          {
            name = "my-rule";
            text = "Be concise.";
            paths = ["src/**"];
          }
        ];
      };
      instrFile = result.config.home.file.".github/instructions/my-rule.instructions.md" or null;
    in
      instrFile
      != null
      && lib.hasInfix "Be concise" (instrFile.text or "")
  );

  module-copilot-hm-writes-skills = mkTest "copilot-hm-writes-skills" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
      };
      skillEntry = result.config.home.file.".copilot/skills/stack-fix" or null;
    in
      skillEntry != null
  );

  module-copilot-devenv-writes-mcp-config = mkTest "copilot-devenv-writes-mcp-config" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
    in
      result.config.files ? ".config/github-copilot/mcp-config.json"
  );

  # ── Task 4b: Copilot feature-gap closure ───────────────────────
  # lspServers → lsp-config.json (HM and devenv).
  module-copilot-hm-writes-lsp-config-json = mkTest "copilot-hm-writes-lsp-config-json" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
          };
        };
      };
      lspFile = result.config.home.file.".copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  module-copilot-devenv-writes-lsp-config-json = mkTest "copilot-devenv-writes-lsp-config-json" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
          };
        };
      };
      lspFile = result.config.files.".config/github-copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  # environmentVariables → devenv env blob (native) and HM wrapper.
  module-copilot-devenv-env-blob-populated = mkTest "copilot-devenv-env-blob-populated" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
        };
      };
    in
      (result.config.env.COPILOT_MODEL or null) == "claude-sonnet-4"
  );

  # HM wrapper injects --additional-mcp-config flag when MCP servers
  # are present. We assert that home.packages contains exactly one
  # entry (the wrapped derivation) and that it carries the expected
  # name — the stub can't introspect postBuild content, but a named
  # symlinkJoin is a strong signal the wrapper fired.
  module-copilot-hm-wrapper-injects-mcp-config-flag = mkTest "copilot-hm-wrapper-injects-mcp-config-flag" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "copilot-cli-wrapped"
  );

  module-copilot-hm-wrapper-exports-env-vars = mkTest "copilot-hm-wrapper-exports-env-vars" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          environmentVariables.COPILOT_MODEL = "claude-sonnet-4";
        };
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "copilot-cli-wrapped"
  );

  # No wrapper when there's nothing to wrap (no env vars, no MCP
  # servers) — we should get the raw package through.
  module-copilot-hm-no-wrapper-when-nothing-to-wrap = mkTest "copilot-hm-no-wrapper-when-nothing-to-wrap" (
    let
      result = evalHm {
        ai.copilot.enable = true;
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") != "copilot-cli-wrapped"
  );

  # agents → per-file writes under configDir.
  module-copilot-hm-writes-agent-files = mkTest "copilot-hm-writes-agent-files" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          agents.reviewer = "# Reviewer\n\nReview code carefully.";
        };
      };
      agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Review code carefully" (agentFile.text or "")
  );

  module-copilot-devenv-writes-agent-files = mkTest "copilot-devenv-writes-agent-files" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          agents.reviewer = "# Reviewer\n\nReview code carefully.";
        };
      };
      agentFile = result.config.files.".github/agents/reviewer.agent.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Review code carefully" (agentFile.text or "")
  );

  module-kiro-instructions-rendered = mkTest "kiro-instructions-rendered" (
    let
      evaluated = evalHm {
        ai.kiro = {
          enable = true;
          instructions = [
            {
              text = "Kiro steering content.";
              description = "Kiro steering";
            }
          ];
        };
      };
      # Kiro's outputPath is ".config/kiro/steering/" (directory-ish
      # but currently treated as a single path by the baseline).
      file = evaluated.config.home.file.".config/kiro/steering/" or null;
    in
      file
      != null
      && lib.hasInfix "Kiro steering content." file.text
  );

  # ── Task 5 (A4): Kiro HM/devenv fanout absorption ────────────

  # HM: package installation — verify home.packages populated.
  module-kiro-hm-wraps-package = mkTest "kiro-hm-wraps-package" (
    let
      result = evalHm {
        ai.kiro.enable = true;
      };
      packages = result.config.home.packages or [];
    in
      builtins.length packages >= 1
  );

  # HM: settings activation merge — verify activation script
  # contains jq merge and settings content.
  module-kiro-hm-writes-settings-activation = mkTest "kiro-hm-writes-settings-activation" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          settings.chat.defaultModel = "claude-sonnet-4";
        };
      };
      activation = result.config.home.activation.kiroSettingsMerge or null;
    in
      activation
      != null
      && lib.hasInfix "claude-sonnet-4" (activation.text or "")
      && lib.hasInfix "jq" (activation.text or "")
  );

  # HM: mcp.json — verify mergedServers writes mcp config.
  module-kiro-hm-writes-mcp-json = mkTest "kiro-hm-writes-mcp-json" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
      mcpFile = result.config.home.file.".kiro/settings/mcp.json" or null;
    in
      mcpFile
      != null
      && lib.hasInfix "test-server" (mcpFile.text or "")
  );

  # HM: lsp.json — verify LSP server config write.
  module-kiro-hm-writes-lsp-json = mkTest "kiro-hm-writes-lsp-json" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          lspServers.nix = {
            command = "nixd";
            args = [];
          };
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # HM: per-instruction steering files with kiro transformer frontmatter.
  # Verifies the kiro transformer emits `inclusion:` and `name:` fields.
  module-kiro-hm-writes-steering-files = mkTest "kiro-hm-writes-steering-files" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          instructions = [
            {
              name = "my-steering";
              text = "Use strict mode always.";
              paths = ["src/**" "tests/**"];
            }
          ];
        };
      };
      steeringFile = result.config.home.file.".kiro/steering/my-steering.md" or null;
    in
      steeringFile
      != null
      && lib.hasInfix "Use strict mode always" (steeringFile.text or "")
      && lib.hasInfix "inclusion: fileMatch" (steeringFile.text or "")
      && lib.hasInfix "name: my-steering" (steeringFile.text or "")
      # CRITICAL: fileMatchPattern MUST be a YAML array for multi-element
      # paths, not a comma-joined string.
      && lib.hasInfix "fileMatchPattern: [" (steeringFile.text or "")
  );

  # HM: per-CLI context → `.kiro/steering/<contextFilename>` (default AGENTS.md).
  module-kiro-hm-writes-context = mkTest "kiro-hm-writes-context" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          context = "Project conventions go here.";
        };
      };
      contextFile = result.config.home.file.".kiro/steering/AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Project conventions" (contextFile.text or "")
  );

  # HM: top-level ai.context fans out to kiro when per-CLI unset.
  module-kiro-hm-top-level-context-fallback = mkTest "kiro-hm-top-level-context-fallback" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.context = "Top-level context flows everywhere.";
      };
      contextFile = result.config.home.file.".kiro/steering/AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Top-level context" (contextFile.text or "")
  );

  # HM: per-CLI context wins over top-level when both set.
  module-kiro-hm-per-cli-context-precedence = mkTest "kiro-hm-per-cli-context-precedence" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          context = "Per-CLI wins.";
        };
        ai.context = "Top-level loses.";
      };
      contextFile = result.config.home.file.".kiro/steering/AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Per-CLI wins" (contextFile.text or "")
      && !(lib.hasInfix "Top-level loses" (contextFile.text or ""))
  );

  # HM: contextFilename override redirects the context emission.
  module-kiro-hm-context-filename-override = mkTest "kiro-hm-context-filename-override" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          context = "Custom filename.";
          contextFilename = "custom.md";
        };
      };
      customFile = result.config.home.file.".kiro/steering/custom.md" or null;
      agentsFile = result.config.home.file.".kiro/steering/AGENTS.md" or null;
    in
      customFile != null && agentsFile == null
  );

  # HM: skills fanout via mkSkillEntries.
  module-kiro-hm-writes-skills = mkTest "kiro-hm-writes-skills" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.skills.stack-fix = ./../packages/stacked-workflows/skills/stack-fix;
      };
      skillEntry = result.config.home.file.".kiro/skills/stack-fix" or null;
    in
      skillEntry != null
  );

  # HM: wrapper injects env vars. When env vars are set, the
  # installed package should be the wrapped derivation.
  module-kiro-hm-wrapper-exports-env-vars = mkTest "kiro-hm-wrapper-exports-env-vars" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          environmentVariables.KIRO_LOG_LEVEL = "debug";
        };
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "kiro-cli-wrapped"
  );

  # HM: no wrapper when nothing to wrap.
  module-kiro-hm-no-wrapper-when-nothing-to-wrap = mkTest "kiro-hm-no-wrapper-when-nothing-to-wrap" (
    let
      result = evalHm {
        ai.kiro.enable = true;
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") != "kiro-cli-wrapped"
  );

  # HM: agent JSON files written under configDir/agents/.
  module-kiro-hm-writes-agent-files = mkTest "kiro-hm-writes-agent-files" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          agents.reviewer = ''{"role": "reviewer"}'';
        };
      };
      agentFile = result.config.home.file.".kiro/agents/reviewer.json" or null;
    in
      agentFile != null
  );

  # HM: hook JSON files written under configDir/hooks/.
  module-kiro-hm-writes-hook-files = mkTest "kiro-hm-writes-hook-files" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          hooks.pre-commit = ''{"event": "pre-commit"}'';
        };
      };
      hookFile = result.config.home.file.".kiro/hooks/pre-commit.json" or null;
    in
      hookFile != null
  );

  # Devenv: mcp.json write.
  module-kiro-devenv-writes-mcp-json = mkTest "kiro-devenv-writes-mcp-json" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.mcpServers.test-server = {
          type = "stdio";
          package = pkgs.hello;
          command = "hello";
        };
      };
    in
      result.config.files ? ".kiro/settings/mcp.json"
  );

  # Devenv: lsp.json write.
  module-kiro-devenv-writes-lsp-json = mkTest "kiro-devenv-writes-lsp-json" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          lspServers.nix = {
            command = "nixd";
            args = [];
          };
        };
      };
      lspFile = result.config.files.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # Devenv: environment variables populate the env blob.
  module-kiro-devenv-env-blob-populated = mkTest "kiro-devenv-env-blob-populated" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          environmentVariables.KIRO_LOG_LEVEL = "debug";
        };
      };
    in
      (result.config.env.KIRO_LOG_LEVEL or null) == "debug"
  );

  # Devenv: settings/cli.json static write.
  module-kiro-devenv-writes-settings-json = mkTest "kiro-devenv-writes-settings-json" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          settings.telemetry.enabled = false;
        };
      };
      settingsFile = result.config.files.".kiro/settings/cli.json" or null;
    in
      settingsFile
      != null
      && lib.hasInfix "telemetry" (settingsFile.text or "")
  );

  # Devenv: per-CLI context → `.kiro/steering/<contextFilename>` (parity with HM).
  module-kiro-devenv-writes-context = mkTest "kiro-devenv-writes-context" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          context = "Project conventions go here.";
        };
      };
      contextFile = result.config.files.".kiro/steering/AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Project conventions" (contextFile.text or "")
  );

  # Devenv: top-level ai.context fans to kiro when per-CLI unset.
  module-kiro-devenv-top-level-context-fallback = mkTest "kiro-devenv-top-level-context-fallback" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.context = "Top-level context flows everywhere.";
      };
      contextFile = result.config.files.".kiro/steering/AGENTS.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Top-level context" (contextFile.text or "")
  );

  # Devenv: agent files written.
  module-kiro-devenv-writes-agent-files = mkTest "kiro-devenv-writes-agent-files" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          agents.reviewer = ''{"role": "reviewer"}'';
        };
      };
      agentFile = result.config.files.".kiro/agents/reviewer.json" or null;
    in
      agentFile
      != null
      && lib.hasInfix "reviewer" (agentFile.text or "")
  );

  # Devenv: hook files written.
  module-kiro-devenv-writes-hook-files = mkTest "kiro-devenv-writes-hook-files" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          hooks.pre-commit = ''{"event": "pre-commit"}'';
        };
      };
      hookFile = result.config.files.".kiro/hooks/pre-commit.json" or null;
    in
      hookFile
      != null
      && lib.hasInfix "pre-commit" (hookFile.text or "")
  );

  # ── Task 7 (A6): Stacked-workflows HM module absorption ────────

  # Default disabled — stacked-workflows.enable defaults to false.
  module-sws-default-disabled = mkTest "sws-default-disabled" (
    let
      result = evalHm {};
    in
      !(result.config.stacked-workflows.enable or true)
  );

  # Devenv scope: when stacked-workflows is enabled IN THE DEVENV MODULE,
  # skills contribute to ai.skills (which each enabled CLI fans out at
  # project-local scope). Must be evalDevenv — the HM module no longer
  # contributes skills (they leaked to personal ~/.claude/skills/*).
  module-sws-devenv-enable-sets-ai-skills = mkTest "sws-devenv-enable-sets-ai-skills" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
    in
      result.config.ai.skills ? sws-stack-fix
      && result.config.ai.skills ? sws-stack-plan
      && result.config.ai.skills ? sws-stack-split
      && result.config.ai.skills ? sws-stack-submit
      && result.config.ai.skills ? sws-stack-summary
      && result.config.ai.skills ? sws-stack-test
  );

  # Devenv scope: instructions landed in the devenv pool.
  module-sws-devenv-enable-sets-ai-instructions = mkTest "sws-devenv-enable-sets-ai-instructions" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      inherit (result.config.ai) instructions;
      swsEntries = builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
    in
      builtins.length swsEntries == 1
  );

  # Regression guard: HM scope MUST NOT contribute sws skills.
  # The earlier HM contribution leaked to ~/.claude/skills/sws-*.
  module-sws-hm-no-skills-leak = mkTest "sws-hm-no-skills-leak" (
    let
      result = evalHm {stacked-workflows.enable = true;};
    in
      !(result.config.ai.skills ? sws-stack-fix)
      && !(result.config.ai.skills ? sws-stack-plan)
  );

  # Regression guard: HM scope MUST NOT contribute sws instructions.
  module-sws-hm-no-instructions-leak = mkTest "sws-hm-no-instructions-leak" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      inherit (result.config.ai) instructions;
      swsEntries = builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
    in
      builtins.length swsEntries == 0
  );

  # Git config applies when preset is "minimal".
  module-sws-git-config-minimal = mkTest "sws-git-config-minimal" (
    let
      result = evalHm {
        stacked-workflows = {
          enable = true;
          gitPreset = "minimal";
        };
      };
      gitSettings = result.config.programs.git.settings;
    in
      (gitSettings ? branchless)
      && (gitSettings ? pull)
      && (gitSettings ? rebase)
  );

  # Git config applies when preset is "full" (includes extended settings).
  module-sws-git-config-full = mkTest "sws-git-config-full" (
    let
      result = evalHm {
        stacked-workflows = {
          enable = true;
          gitPreset = "full";
        };
      };
      gitSettings = result.config.programs.git.settings;
    in
      (gitSettings ? branchless)
      && (gitSettings ? diff)
      && (gitSettings ? fetch)
      && (gitSettings ? push)
      && (gitSettings ? revise)
  );

  # Git config NOT set when preset is "none".
  module-sws-git-config-none = mkTest "sws-git-config-none" (
    let
      result = evalHm {
        stacked-workflows = {
          enable = true;
          gitPreset = "none";
        };
      };
      gitSettings = result.config.programs.git.settings;
    in
      !(gitSettings ? branchless)
  );

  # Devenv scope: reference files written under .claude/references/.
  # Were previously written at HM scope (~/.claude/references/), leaked
  # to personal scope — moved to devenv alongside skills/instructions.
  module-sws-devenv-reference-files-written = mkTest "sws-devenv-reference-files-written" (
    let
      result = evalDevenv {stacked-workflows.enable = true;};
      inherit (result.config) files;
    in
      files ? ".claude/references/philosophy.md"
      && files ? ".claude/references/git-absorb.md"
  );

  # Regression guard: HM scope MUST NOT write sws reference files.
  module-sws-hm-no-reference-leak = mkTest "sws-hm-no-reference-leak" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      files = result.config.home.file;
    in
      !(files ? ".claude/references/philosophy.md")
  );

  # ── services.mcp-servers module ──────────────────────────────────

  # Default: all servers are disabled.
  module-mcp-services-default-disabled = mkTest "mcp-services-default-disabled" (
    let
      result = evalHm {};
      inherit (result.config.services.mcp-servers) servers;
    in
      !(servers.context7-mcp.enable or true)
      && !(servers.github-mcp.enable or true)
      && !(servers.serena-mcp.enable or true)
  );

  # Server option tree has expected structure.
  module-mcp-services-option-tree = mkTest "mcp-services-option-tree" (
    let
      result = evalHm {};
      inherit (result.config.services.mcp-servers) servers;
    in
      servers ? context7-mcp
      && servers ? effect-mcp
      && servers ? fetch-mcp
      && servers ? git-intel-mcp
      && servers ? git-mcp
      && servers ? github-mcp
      && servers ? kagi-mcp
      && servers ? nixos-mcp
      && servers ? openmemory-mcp
      && servers ? sequential-thinking-mcp
      && servers ? serena-mcp
      && servers ? sympy-mcp
  );

  # tools output is empty when no servers enabled.
  module-mcp-services-tools-empty-when-disabled = mkTest "mcp-services-tools-empty-when-disabled" (
    let
      result = evalHm {};
    in
      result.config.services.mcp-servers.tools == {}
  );

  # mcpConfig output is empty when no servers enabled.
  module-mcp-services-mcpconfig-empty-when-disabled = mkTest "mcp-services-mcpconfig-empty-when-disabled" (
    let
      result = evalHm {};
    in
      result.config.services.mcp-servers.mcpConfig.mcpServers == {}
  );

  # ── Attrs-shape ai.rules / ai.<cli>.rules (unified transformer) ───

  # Claude HM: top-level ai.rules → .claude/rules/<name>.md with paths frontmatter.
  module-claude-hm-writes-rules-from-top-level = mkTest "claude-hm-writes-rules-from-top-level" (
    let
      result = evalHm {
        ai.claude.enable = true;
        ai.rules.code-style = {
          text = "Use consistent formatting.";
          paths = ["src/**"];
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

  # Kiro HM: top-level ai.rules → .kiro/steering/<name>.md with inclusion frontmatter.
  module-kiro-hm-writes-rules-from-top-level = mkTest "kiro-hm-writes-rules-from-top-level" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.rules.testing = {
          text = "Write tests for all new features.";
          paths = ["**/*.test.*"];
        };
      };
      ruleFile = result.config.home.file.".kiro/steering/testing.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Write tests for all new features" (ruleFile.text or "")
      && lib.hasInfix "inclusion: fileMatch" (ruleFile.text or "")
  );

  # Copilot HM: top-level ai.rules → .github/instructions/<name>.instructions.md.
  module-copilot-hm-writes-rules-from-top-level = mkTest "copilot-hm-writes-rules-from-top-level" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.rules.security = {
          text = "Validate all user input.";
          paths = ["**/*.ts"];
        };
      };
      ruleFile = result.config.home.file.".github/instructions/security.instructions.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Validate all user input" (ruleFile.text or "")
      && lib.hasInfix "applyTo:" (ruleFile.text or "")
  );

  # Per-CLI rules merge with top-level; per-CLI wins on collision.
  module-kiro-hm-per-cli-rules-wins = mkTest "kiro-hm-per-cli-rules-wins" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rules.same-name.text = "Per-CLI wins.";
        };
        ai.rules.same-name.text = "Top-level loses.";
      };
      ruleFile = result.config.home.file.".kiro/steering/same-name.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Per-CLI wins" (ruleFile.text or "")
      && !(lib.hasInfix "Top-level loses" (ruleFile.text or ""))
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
      ruleFile != null && !(lib.hasInfix "paths:" (ruleFile.text or ""))
  );

  # Devenv parity: Kiro devenv emits ai.rules to steering files.
  module-kiro-devenv-writes-rules = mkTest "kiro-devenv-writes-rules" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.rules.testing = {
          text = "Write tests.";
          paths = ["**/*.test.*"];
        };
      };
      ruleFile = result.config.files.".kiro/steering/testing.md" or null;
    in
      ruleFile
      != null
      && lib.hasInfix "Write tests" (ruleFile.text or "")
  );

  # Copilot HM: per-CLI context → `<configDir>/<contextFilename>`.
  module-copilot-hm-writes-context = mkTest "copilot-hm-writes-context" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          context = "Copilot-specific context.";
        };
      };
      contextFile =
        result.config.home.file.".copilot/copilot-instructions.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Copilot-specific context" (contextFile.text or "")
  );

  # Copilot HM: top-level ai.context fans out when per-CLI unset.
  module-copilot-hm-top-level-context-fallback = mkTest "copilot-hm-top-level-context-fallback" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.context = "Top-level context flows everywhere.";
      };
      contextFile =
        result.config.home.file.".copilot/copilot-instructions.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Top-level context" (contextFile.text or "")
  );

  # Copilot devenv parity.
  module-copilot-devenv-writes-context = mkTest "copilot-devenv-writes-context" (
    let
      result = evalDevenv {
        ai.copilot = {
          enable = true;
          context = "Copilot devenv context.";
        };
      };
      contextFile =
        result.config.files.".github/copilot-instructions.md" or null;
    in
      contextFile
      != null
      && lib.hasInfix "Copilot devenv context" (contextFile.text or "")
  );

  # HM: ai.claude.marketplaces routes to programs.claude-code.marketplaces
  # via identity translation. Regression guard.
  module-claude-hm-marketplaces-route-to-upstream = mkTest "claude-hm-marketplaces-route-to-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          marketplaces.my-shelf = ./../packages/stacked-workflows/skills/stack-fix;
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

  # HM: top-level ai.lspServers fans out to Kiro's settings/lsp.json.
  module-kiro-hm-top-level-lsp-fanout = mkTest "kiro-hm-top-level-lsp-fanout" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.lspServers.nixd = {
          command = "nixd";
          args = [];
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # Devenv: top-level ai.lspServers fans out to Kiro's settings/lsp.json.
  module-kiro-devenv-top-level-lsp-fanout = mkTest "kiro-devenv-top-level-lsp-fanout" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.lspServers.nixd = {
          command = "nixd";
          args = [];
        };
      };
      lspFile = result.config.files.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd" (lspFile.text or "")
  );

  # HM: top-level ai.lspServers fans out to Copilot's lsp-config.json.
  module-copilot-hm-top-level-lsp-fanout = mkTest "copilot-hm-top-level-lsp-fanout" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.lspServers.typescript = {
          command = "typescript-language-server";
          args = ["--stdio"];
        };
      };
      lspFile = result.config.home.file.".copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  # Devenv: top-level ai.lspServers fans out to Copilot's lsp-config.json.
  module-copilot-devenv-top-level-lsp-fanout = mkTest "copilot-devenv-top-level-lsp-fanout" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.lspServers.typescript = {
          command = "typescript-language-server";
          args = ["--stdio"];
        };
      };
      lspFile = result.config.files.".config/github-copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "typescript-language-server" (lspFile.text or "")
  );

  # HM: per-CLI ai.kiro.lspServers overrides top-level ai.lspServers on
  # name collision. Kiro-specific override wins.
  module-kiro-hm-per-cli-lsp-overrides-top-level = mkTest "kiro-hm-per-cli-lsp-overrides-top-level" (
    let
      result = evalHm {
        ai = {
          kiro.enable = true;
          lspServers.nixd = {
            command = "nixd-top-level";
          };
          kiro.lspServers.nixd = {
            command = "nixd-kiro-specific";
          };
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "nixd-kiro-specific" (lspFile.text or "")
      && !(lib.hasInfix "nixd-top-level" (lspFile.text or ""))
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

  # HM: top-level ai.environmentVariables fans out to Kiro wrapper + Copilot wrapper.
  module-kiro-hm-top-level-env-fanout = mkTest "kiro-hm-top-level-env-fanout" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.environmentVariables.KIRO_FOO = "bar";
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "kiro-cli-wrapped"
  );

  # Devenv: top-level ai.environmentVariables fans to Kiro env blob.
  module-kiro-devenv-top-level-env-fanout = mkTest "kiro-devenv-top-level-env-fanout" (
    let
      result = evalDevenv {
        ai.kiro.enable = true;
        ai.environmentVariables.KIRO_DEBUG = "1";
      };
    in
      (result.config.env.KIRO_DEBUG or null) == "1"
  );

  # HM: top-level ai.environmentVariables triggers Copilot wrapper.
  module-copilot-hm-top-level-env-fanout = mkTest "copilot-hm-top-level-env-fanout" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.environmentVariables.COPILOT_FOO = "bar";
      };
      packages = result.config.home.packages or [];
      first = builtins.head packages;
    in
      builtins.length packages
      == 1
      && (first.name or "") == "copilot-cli-wrapped"
  );

  # Devenv: top-level ai.environmentVariables fans to Copilot env blob.
  module-copilot-devenv-top-level-env-fanout = mkTest "copilot-devenv-top-level-env-fanout" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.environmentVariables.COPILOT_DEBUG = "1";
      };
    in
      (result.config.env.COPILOT_DEBUG or null) == "1"
  );

  # Devenv: per-CLI ai.kiro.environmentVariables wins over top-level on name collision.
  module-kiro-devenv-per-cli-env-wins = mkTest "kiro-devenv-per-cli-env-wins" (
    let
      result = evalDevenv {
        ai = {
          kiro.enable = true;
          environmentVariables.SHARED = "top-level";
          kiro.environmentVariables.SHARED = "kiro-specific";
        };
      };
    in
      (result.config.env.SHARED or null) == "kiro-specific"
  );

  # Copilot HM: typed LSP with `extensions` emits fileExtensions
  # mapping. Per-ecosystem Copilot translator (mkCopilotLspConfig).
  module-copilot-hm-lsp-file-extensions = mkTest "copilot-hm-lsp-file-extensions" (
    let
      result = evalHm {
        ai.copilot = {
          enable = true;
          lspServers.typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
            extensions = ["ts" "tsx"];
          };
        };
      };
      lspFile = result.config.home.file.".copilot/lsp-config.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "fileExtensions" (lspFile.text or "")
      && lib.hasInfix "\".ts\"" (lspFile.text or "")
      && lib.hasInfix "\".tsx\"" (lspFile.text or "")
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

  # Kiro HM: package-based declaration renders `${package}/bin/${binary}`.
  # Exercises the package+binary resolution branch.
  module-kiro-hm-lsp-package-command-rendering = mkTest "kiro-hm-lsp-package-command-rendering" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          lspServers.hello-lsp = {
            package = pkgs.hello;
            binary = "hello";
            args = [];
          };
        };
      };
      lspFile = result.config.home.file.".kiro/settings/lsp.json" or null;
    in
      lspFile
      != null
      && lib.hasInfix "/bin/hello" (lspFile.text or "")
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

  # HM: top-level ai.agents fans out to Copilot's agents file write.
  module-copilot-hm-top-level-agents-fanout = mkTest "copilot-hm-top-level-agents-fanout" (
    let
      result = evalHm {
        ai.copilot.enable = true;
        ai.agents.reviewer = "# Reviewer";
      };
      agentFile = result.config.home.file.".copilot/agents/reviewer.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Reviewer" (agentFile.text or "")
  );

  # Devenv: top-level ai.agents fans out to Copilot's .github/agents.
  module-copilot-devenv-top-level-agents-fanout = mkTest "copilot-devenv-top-level-agents-fanout" (
    let
      result = evalDevenv {
        ai.copilot.enable = true;
        ai.agents.reviewer = "# Reviewer";
      };
      agentFile = result.config.files.".github/agents/reviewer.agent.md" or null;
    in
      agentFile
      != null
      && lib.hasInfix "Reviewer" (agentFile.text or "")
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

  # Kiro independence: top-level ai.agents is markdown-shape, Kiro agents
  # are JSON-shape. Setting ai.agents.foo when ai.kiro.enable = true
  # must NOT produce a .kiro/agents/foo file.
  module-kiro-ignores-top-level-agents = mkTest "kiro-ignores-top-level-agents" (
    let
      result = evalHm {
        ai.kiro.enable = true;
        ai.agents.reviewer = "# Reviewer markdown";
      };
    in
      !(result.config.home.file ? ".kiro/agents/reviewer.json")
      && !(result.config.home.file ? ".kiro/agents/reviewer.md")
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

  # HM: ai.claude.hooks routes to programs.claude-code.hooks via
  # identity translation.
  module-claude-hm-hooks-route-to-upstream = mkTest "claude-hm-hooks-route-to-upstream" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          hooks.pre-edit = "#!/usr/bin/env bash\necho edit\n";
        };
      };
      upstream = result.config.programs.claude-code.hooks or {};
    in
      (upstream.pre-edit or null) == "#!/usr/bin/env bash\necho edit\n"
  );

  # Devenv: ai.claude.hooks merges into claude.code.hooks alongside
  # the legacy settings.hooks route. ai.claude.hooks wins on collision.
  module-claude-devenv-hooks-merge = mkTest "claude-devenv-hooks-merge" (
    let
      result = evalDevenv {
        ai.claude = {
          enable = true;
          settings.hooks.from-settings = "#!/usr/bin/env bash\necho from-settings\n";
          hooks.from-top = "#!/usr/bin/env bash\necho from-top\n";
        };
      };
      upstream = result.config.claude.code.hooks or {};
    in
      (upstream.from-settings or null)
      != null
      && (upstream.from-top or null) != null
  );

  # HM: rule with sourcePath emits home.file.<path>.source (out-of-store
  # symlink) instead of baking content into the store. Note: the
  # module-eval harness stubs home.file as attrsOf anything, so the
  # actual source value is a raw path string (the harness's
  # config.lib.file.mkOutOfStoreSymlink stub is a no-op identity —
  # see hmLib below if the test fails). We assert presence of
  # `source` and absence of `text`.
  module-kiro-hm-rule-sourcepath-emits-source = mkTest "kiro-hm-rule-sourcepath-emits-source" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rules.my-rule.sourcePath = "/abs/path/to/my-rule.md";
        };
      };
      entry = result.config.home.file.".kiro/steering/my-rule.md" or null;
    in
      entry != null && (entry ? source) && !(entry ? text)
  );

  # HM: rule with text (no sourcePath) keeps baking behavior.
  module-kiro-hm-rule-text-still-bakes = mkTest "kiro-hm-rule-text-still-bakes" (
    let
      result = evalHm {
        ai.kiro = {
          enable = true;
          rules.my-rule.text = "Inline content";
        };
      };
      entry = result.config.home.file.".kiro/steering/my-rule.md" or null;
    in
      entry
      != null
      && (entry ? text)
      && !(entry ? source)
      && lib.hasInfix "Inline content" entry.text
  );

  # Devenv: rule with sourcePath emits files.<path>.source verbatim.
  module-kiro-devenv-rule-sourcepath = mkTest "kiro-devenv-rule-sourcepath" (
    let
      result = evalDevenv {
        ai.kiro = {
          enable = true;
          rules.my-rule.sourcePath = "/abs/path/to/my-rule.md";
        };
      };
      entry = result.config.files.".kiro/steering/my-rule.md" or null;
    in
      entry != null && (entry.source or null) == "/abs/path/to/my-rule.md"
  );

  # HM: Claude rules sourcePath emits source, not text.
  module-claude-hm-rule-sourcepath-emits-source = mkTest "claude-hm-rule-sourcepath-emits-source" (
    let
      result = evalHm {
        ai.claude = {
          enable = true;
          rules.my-rule.sourcePath = "/abs/path/to/my-rule.md";
        };
      };
      entry = result.config.home.file.".claude/rules/my-rule.md" or null;
    in
      entry != null && (entry ? source) && !(entry ? text)
  );
}
