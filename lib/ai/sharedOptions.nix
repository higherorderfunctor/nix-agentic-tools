# Declares cross-app options (ai.context, ai.mcpServers, ai.instructions,
# ai.skills).
#
# Imported by every mkAiApp module so per-app overrides
# (ai.<name>.mcpServers, etc.) can merge on top of these top-level
# pools. Per-app values win on key conflicts; lists are concatenated.
{lib, ...}: {
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

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Cross-app skills fanned out to every enabled AI app.";
    };
  };
}
