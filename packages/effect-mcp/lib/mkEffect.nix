# Factory-of-factory for effect-mcp.
#
# Consumers call `lib.ai.mcpServers.mkEffect {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "effect";
  defaults = {
    package = pkgs.ai.effect-mcp;
    type = "stdio";
    command = "effect-mcp";
    args = [];
  };
  # No custom options — effect-mcp has no unique config knobs
  # beyond the common schema.
}
