# Factory-of-factory for mcp-proxy.
#
# Consumers call `lib.ai.mcpServers.mkProxy {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "proxy";
  defaults = {
    package = pkgs.ai.mcp-proxy;
    type = "stdio";
    command = "mcp-proxy";
    args = [];
  };
  # No custom options — mcp-proxy has no unique config knobs
  # beyond the common schema.
}
