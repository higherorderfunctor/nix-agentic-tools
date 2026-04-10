# Factory-of-factory for openmemory-mcp.
#
# Consumers call `lib.ai.mcpServers.mkOpenmemory {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "openmemory";
  defaults = {
    package = pkgs.ai.mcpServers.openmemory-mcp;
    type = "stdio";
    command = "openmemory-mcp";
    args = [];
  };
  # No custom options — openmemory-mcp has no unique config knobs
  # beyond the common schema.
}
