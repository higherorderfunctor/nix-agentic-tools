# Factory-of-factory for sympy-mcp.
#
# Consumers call `lib.ai.mcpServers.mkSympy {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "sympy";
  defaults = {
    package = pkgs.ai.mcpServers.sympy-mcp;
    type = "stdio";
    command = "sympy-mcp";
    args = [];
  };
  # No custom options — sympy-mcp has no unique config knobs
  # beyond the common schema.
}
