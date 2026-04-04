# services.mcp-servers home-manager module.
# Manages systemd services, credentials, and mcpConfig for MCP servers.
# Implementation in Phase 3.4.
{lib, ...}: {
  options.services.mcp-servers = {
    servers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.enable = lib.mkEnableOption "this MCP server";
      });
      default = {};
      description = "MCP server configurations.";
    };
  };
}
