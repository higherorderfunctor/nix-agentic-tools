# Kiro CLI devenv integration.
# Mirrors devenv's claude.nix pattern for Kiro's file layout.
#
# Generates:
#   .kiro/settings/mcp.json — MCP server config
#   .kiro/settings/cli.json — CLI settings (if configured)
#   .kiro/skills/{name} — skill directories (symlinked)
#   .kiro/steering/{name}.md — steering files
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.kiro;
  mcpCommon = import ./mcp-common.nix {inherit lib;};

  # Build MCP config
  mcpServers = lib.mapAttrs (_: mcpCommon.transformMcpServer) cfg.mcpServers;

  mcpContent =
    if cfg.mcpServers == {}
    then null
    else {inherit mcpServers;};
in {
  options.kiro = {
    enable = lib.mkEnableOption "Kiro CLI integration";

    mcpServers = lib.mkOption {
      type = mcpCommon.mcpServerType;
      default = {};
      description = "MCP servers to configure for Kiro.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Kiro CLI settings (written to .kiro/settings/cli.json).";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Skill directories to install for Kiro.";
    };

    steering = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Steering files for Kiro (.kiro/steering/).";
    };
  };

  config = lib.mkIf cfg.enable {
    files =
      # MCP servers
      lib.optionalAttrs (mcpContent != null) {
        ".kiro/settings/mcp.json".json = mcpContent;
      }
      # Settings
      // lib.optionalAttrs (cfg.settings != {}) {
        ".kiro/settings/cli.json".json = cfg.settings;
      }
      # Skills (directory symlinks)
      // lib.concatMapAttrs (name: path: {
        ".kiro/skills/${name}".source = path;
      })
      cfg.skills
      # Steering
      // lib.concatMapAttrs (name: content: {
        ".kiro/steering/${name}.md".text = content;
      })
      cfg.steering;
  };
}
