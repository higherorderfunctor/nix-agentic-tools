# Declares cross-app options (ai.mcpServers, ai.instructions, ai.skills).
#
# Imported by every mkAiApp module so per-app overrides
# (ai.<name>.mcpServers, etc.) can merge on top of these top-level
# pools. Per-app values win on key conflicts; lists are concatenated.
{lib, ...}: {
  options.ai = {
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
