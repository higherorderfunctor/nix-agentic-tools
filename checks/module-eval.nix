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
  # lib.ai.app.mkAiApp and lib.ai.transformers.claude.
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
    };

  # Stub HM options so the config callback in mkClaude.nix can set
  # home.activation.* and home.file.* without importing all of
  # home-manager. The assertions only check ai.* values; these stubs
  # prevent "option does not exist" errors on the side-effect attrs.
  hmStubs = {
    options = {
      home = {
        activation = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
        file = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
      };
    };
  };

  evalHm = config:
    lib.evalModules {
      specialArgs = {
        lib = hmLib;
        pkgs = pkgs // {ai = pkgs.ai or {};};
        inherit (hmLib) hm;
      };
      modules = [
        ./../lib/ai/sharedOptions.nix
        ./../packages/claude-code/modules/homeManager
        ./../packages/copilot-cli/modules/homeManager
        ./../packages/kiro-cli/modules/homeManager
        hmStubs
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

  module-claude-buddy-submodule-default = mkTest "claude-buddy-submodule-default" (!(evalHm {}).config.ai.claude.buddy.enable);

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
          package = pkgs.ai.context7-mcp or pkgs.hello;
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
}
