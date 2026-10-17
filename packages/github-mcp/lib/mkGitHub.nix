# Factory-of-factory for github-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitHub {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# The shared settings surface accepts redact references and resolves them
# into the server's credential environment variable at launch.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "github";
  defaults = {
    package = pkgs.ai.mcpServers.github-mcp;
    type = "stdio";
    command = "github-mcp-server";
    args = [];
  };
  options = {};
}
