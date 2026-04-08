# Factory-of-factory for fetch-mcp.
#
# Consumers call `lib.ai.mcpServers.mkFetch {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "fetch";
  defaults = {
    package = pkgs.ai.fetch-mcp;
    type = "stdio";
    command = "mcp-server-fetch";
    args = [];
  };
  # No custom options — fetch-mcp has no unique config knobs
  # beyond the common schema.
}
