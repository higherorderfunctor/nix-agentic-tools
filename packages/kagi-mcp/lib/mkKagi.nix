# Factory-of-factory for kagi-mcp.
#
# Consumers call `lib.ai.mcpServers.mkKagi {...}` from their config
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
  name = "kagi";
  defaults = {
    package = pkgs.ai.mcpServers.kagi-mcp;
    type = "stdio";
    command = "kagimcp";
    args = [];
  };
  options = {};
}
