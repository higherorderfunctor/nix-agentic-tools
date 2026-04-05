# Kiro CLI devenv integration.
# Mirrors devenv's claude.nix pattern for Kiro's file layout.
#
# Generates:
#   .kiro/settings/mcp.json — MCP server config
#   .kiro/settings/cli.json — CLI settings (if configured)
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.kiro;

  # Build MCP config
  mcpServers = lib.mapAttrs (name: server:
    if server.type == "stdio"
    then
      {
        type = "stdio";
        inherit (server) command;
      }
      // lib.optionalAttrs (server.args != []) {inherit (server) args;}
      // lib.optionalAttrs (server.env != {}) {inherit (server) env;}
    else if server.type == "http"
    then {
      type = "http";
      inherit (server) url;
    }
    else throw "Invalid MCP server type: ${server.type}")
  cfg.mcpServers;

  mcpContent =
    if cfg.mcpServers == {}
    then null
    else {inherit mcpServers;};
in {
  options.kiro = {
    enable = lib.mkEnableOption "Kiro CLI integration";

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.enum ["stdio" "http"];
            default = "stdio";
            description = "Type of MCP server connection.";
          };
          command = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Command for stdio servers.";
          };
          args = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Arguments for stdio servers.";
          };
          env = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Environment variables for stdio servers.";
          };
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "URL for HTTP servers.";
          };
        };
      });
      default = {};
      description = "MCP servers to configure for Kiro.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Kiro CLI settings (written to .kiro/settings/cli.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    files =
      lib.optionalAttrs (mcpContent != null) {
        ".kiro/settings/mcp.json".json = mcpContent;
      }
      // lib.optionalAttrs (cfg.settings != {}) {
        ".kiro/settings/cli.json".json = cfg.settings;
      };
  };
}
