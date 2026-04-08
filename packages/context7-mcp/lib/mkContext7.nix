# Factory-of-factory for context7-mcp.
#
# Consumers call `lib.ai.mcpServers.mkContext7 {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "context7";
  defaults = {
    package = pkgs.ai.context7-mcp;
    type = "stdio";
    command = "context7-mcp";
    args = [];
  };
  # No custom options — context7-mcp has no unique config knobs
  # beyond the common schema.
}
