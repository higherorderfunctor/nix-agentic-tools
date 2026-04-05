# MCP server devshell module — generates .mcp.json from enabled servers.
#
# Uses the same server definition format as the HM module but produces
# stdio entries for devshell use (no systemd, no HTTP services).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.mcpServers;

  enabledServers = lib.filterAttrs (_: srv: srv.enable) cfg;

  # Build the mcpServers JSON for .mcp.json
  mcpConfig = lib.mapAttrs (name: srv: let
    base =
      if srv.url != null
      then {
        type = "http";
        inherit (srv) url;
      }
      else {
        type = "stdio";
        inherit (srv) command;
        inherit (srv) args;
      };
  in
    base
    // lib.optionalAttrs (srv.env != {}) {inherit (srv) env;})
  enabledServers;
in {
  options.mcpServers = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "this MCP server in the devshell";

        command = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Command to run the MCP server (stdio mode).";
        };

        args = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Arguments for the MCP server command.";
        };

        env = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = {};
          description = "Environment variables for the MCP server.";
        };

        url = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "URL for HTTP MCP servers.";
        };

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "Package providing the server binary. Added to devshell packages.";
        };
      };
    });
    default = {};
    description = "MCP server configurations for the devshell.";
  };

  config = lib.mkIf (enabledServers != {}) {
    files.".mcp.json".json = {
      mcpServers = mcpConfig;
    };

    packages =
      lib.filter (p: p != null)
      (lib.mapAttrsToList (_: srv: srv.package) enabledServers);
  };
}
