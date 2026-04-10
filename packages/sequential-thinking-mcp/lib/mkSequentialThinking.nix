# Factory-of-factory for sequential-thinking-mcp.
#
# Consumers call `lib.ai.mcpServers.mkSequentialThinking {...}` from their
# config to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "sequential-thinking";
  defaults = {
    package = pkgs.ai.mcpServers.sequential-thinking-mcp;
    type = "stdio";
    command = "sequential-thinking-mcp";
    args = [];
  };
  # No custom options — sequential-thinking-mcp has no unique config knobs
  # beyond the common schema.
}
