# Factory for a typed Kagi MCP entry.
# The default command branch ignores settings: supply credentials through env
# references, or use mkStdioEntry with a package for typed settings.credentials.
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
