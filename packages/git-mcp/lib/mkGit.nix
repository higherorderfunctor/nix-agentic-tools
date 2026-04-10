# Factory-of-factory for git-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGit {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "git";
  defaults = {
    package = pkgs.ai.mcpServers.git-mcp;
    type = "stdio";
    command = "mcp-server-git";
    args = [];
  };
  # No custom options — git-mcp has no unique config knobs
  # beyond the common schema.
}
