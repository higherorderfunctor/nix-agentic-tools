# Factory-of-factory for github-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitHub {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# TODO(milestone-N): add a `token` option for GitHub API authentication.
# The GITHUB_PERSONAL_ACCESS_TOKEN env var or --token flag will need a
# typed option surface once consumer needs materialize.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "github";
  defaults = {
    package = pkgs.ai.github-mcp;
    type = "stdio";
    command = "github-mcp-server";
    args = [];
  };
  # No custom options in this milestone — auth options deferred.
  options = {};
}
