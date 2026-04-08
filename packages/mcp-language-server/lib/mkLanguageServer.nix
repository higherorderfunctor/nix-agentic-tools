# Factory-of-factory for mcp-language-server.
#
# Consumers call `lib.ai.mcpServers.mkLanguageServer {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "language-server";
  defaults = {
    package = pkgs.ai.mcp-language-server;
    type = "stdio";
    command = "mcp-language-server";
    args = [];
  };
  # No custom options — mcp-language-server has no unique config knobs
  # beyond the common schema.
}
