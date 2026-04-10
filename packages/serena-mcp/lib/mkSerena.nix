# Factory-of-factory for serena-mcp.
#
# Consumers call `lib.ai.mcpServers.mkSerena {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This server is sourced from inputs.serena (not nvfetcher-tracked).
# The upstream package's main binary takes "start-mcp-server" as an arg
# to run in MCP mode (see passthru.mcpArgs in the overlay).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "serena";
  defaults = {
    package = pkgs.ai.mcpServers.serena-mcp;
    type = "stdio";
    command = "serena";
    args = ["start-mcp-server"];
  };
  # No custom options — serena-mcp has no unique config knobs
  # beyond the common schema.
}
