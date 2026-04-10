# Factory-of-factory for git-intel-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitIntel {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "git-intel";
  defaults = {
    package = pkgs.ai.mcpServers.git-intel-mcp;
    type = "stdio";
    command = "git-intel-mcp";
    args = [];
  };
  # No custom options — git-intel-mcp has no unique config knobs
  # beyond the common schema.
}
