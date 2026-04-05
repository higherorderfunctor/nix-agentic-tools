# Shared MCP server submodule type and transformation for devenv integrations.
# Used by both copilot.nix and kiro.nix to avoid duplicating the option
# definition and the server transformation lambda.
{lib}: {
  # MCP server submodule type for devenv options
  mcpServerType = lib.types.attrsOf (lib.types.submodule {
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

  # Transform an MCP server submodule value into the JSON structure
  # expected by the target ecosystem (VS Code mcp.json / Kiro mcp.json).
  transformMcpServer = server:
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
    else throw "Invalid MCP server type: ${server.type}";
}
