# Factory for a typed GitHub MCP entry.
# The default command branch ignores settings: supply credentials through env
# references, or use mkStdioEntry with a package for typed settings.credentials.
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
