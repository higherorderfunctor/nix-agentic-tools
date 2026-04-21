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
  # Also extend lib with lib.ai so mkClaude.nix can call
  # lib.ai.app.mkAiApp and lib.ai.transformers.claude. mcpLib is
  # exported as top-level helpers (lib.mkStdioEntry, lib.renderServer)
  # to mirror the flake's `baseLib` shape.
  mcpLib = import ./../lib/mcp.nix {inherit lib;};
  hmLib =
    lib
    // {
      ai = import ./../lib/ai {inherit lib;};
      hm = {
        dag = {
          entryAfter = _: text: {inherit text;};
          entryBefore = _: text: {inherit text;};
        };
      };
      inherit (mcpLib) loadServer mkPackageEntry mkStdioEntry mkHttpEntry mkStdioConfig renderServer;
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
      programs.claude-code = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
        };
        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
        };
        settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        skills = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        context = lib.mkOption {
          type = lib.types.either lib.types.lines lib.types.path;
          default = "";
        };
        plugins = lib.mkOption {
          type = with lib.types; listOf (either package path);
          default = [];
        };
        mcpServers = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
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
      mcpFile = result.config.home.file.".config/github-copilot/mcp-config.json" or null;
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
      skillEntry = result.config.home.file.".config/github-copilot/skills/stack-fix" or null;
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
      lspFile = result.config.home.file.".config/github-copilot/lsp-config.json" or null;
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
      agentFile = result.config.home.file.".config/github-copilot/agents/reviewer.md" or null;
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
      agentFile = result.config.files.".config/github-copilot/agents/reviewer.md" or null;
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

  # When enabled, skills are contributed to the shared ai.skills pool.
  module-sws-enable-sets-ai-skills = mkTest "sws-enable-sets-ai-skills" (
    let
      result = evalHm {stacked-workflows.enable = true;};
    in
      result.config.ai.skills ? sws-stack-fix
      && result.config.ai.skills ? sws-stack-plan
      && result.config.ai.skills ? sws-stack-split
      && result.config.ai.skills ? sws-stack-submit
      && result.config.ai.skills ? sws-stack-summary
      && result.config.ai.skills ? sws-stack-test
  );

  # When enabled, instructions are contributed to the shared pool.
  module-sws-enable-sets-ai-instructions = mkTest "sws-enable-sets-ai-instructions" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      inherit (result.config.ai) instructions;
      swsEntries = builtins.filter (i: (i.name or "") == "stacked-workflows") instructions;
    in
      builtins.length swsEntries == 1
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

  # Reference files are symlinked under .claude/references/.
  module-sws-reference-files-written = mkTest "sws-reference-files-written" (
    let
      result = evalHm {stacked-workflows.enable = true;};
      files = result.config.home.file;
    in
      files ? ".claude/references/philosophy.md"
      && files ? ".claude/references/git-absorb.md"
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
}
