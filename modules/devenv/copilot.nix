# GitHub Copilot devenv integration.
# Mirrors devenv's claude.nix pattern for Copilot's file layout.
#
# Generates:
#   .github/copilot-instructions.md — repo-wide instructions (via files.*)
#   .github/instructions/*.instructions.md — per-package scoped instructions
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.copilot;
in {
  options.copilot = {
    enable = lib.mkEnableOption "GitHub Copilot integration";

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
      description = "MCP servers to configure for Copilot.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Copilot settings (written to .copilot/config.json).";
    };
  };

  config = lib.mkIf cfg.enable {
    files = let
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
    in
      lib.optionalAttrs (cfg.mcpServers != {}) {
        ".copilot/mcp.json".json = {inherit mcpServers;};
      }
      // lib.optionalAttrs (cfg.settings != {}) {
        ".copilot/config.json".json = cfg.settings;
      };
  };
}
