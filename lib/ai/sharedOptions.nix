# Declares cross-app options (ai.context, ai.mcpServers, ai.instructions,
# ai.rules, ai.skills).
#
# Imported by every mkAiApp module so per-app overrides
# (ai.<name>.mcpServers, etc.) can merge on top of these top-level
# pools. Per-app values win on key conflicts; lists are concatenated.
{lib, ...}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
in {
  options.ai = {
    context = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
      default = null;
      description = ''
        Cross-app global context (single always-on file) fanned out to every
        enabled AI app. Each ecosystem emits it at its native location:
        Claude → ~/.claude/CLAUDE.md, Kiro → ~/.kiro/steering/<contextFilename>
        (default AGENTS.md). Per-app overrides (ai.<name>.context) win when set.
      '';
      example = lib.literalExpression "./ai-context.md";
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [(import ./mcpServer/commonSchema.nix)];
      });
      default = {};
      description = ''
        MCP servers fanned out to every enabled AI app. Per-app overrides
        (ai.<name>.mcpServers) merge on top and win on conflict.
      '';
    };

    instructions = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = "Cross-app instructions fanned out to every enabled AI app.";
    };

    rules = lib.mkOption {
      type = lib.types.attrsOf aiCommon.ruleModule;
      default = {};
      description = ''
        Cross-app modular rule files fanned out to every enabled AI app.
        Each attribute becomes one file in the ecosystem's native rules
        directory (Claude: `.claude/rules/<name>.md`, Kiro:
        `.kiro/steering/<name>.md`, Copilot:
        `.github/instructions/<name>.instructions.md`). Per-app overrides
        (ai.<name>.rules) merge on top and win on name conflict.
      '';
      example = lib.literalExpression ''
        {
          code-style = { text = "Use consistent formatting."; };
          testing = {
            text = ./rules/testing.md;
            paths = [ "**/*.test.*" ];
            description = "Testing conventions";
          };
        }
      '';
    };

    lspServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {};
      description = ''
        LSP servers fanned out to every enabled AI app. Per-app overrides
        (ai.<name>.lspServers) merge on top and win on conflict.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Cross-app skills fanned out to every enabled AI app.";
    };
  };
}
