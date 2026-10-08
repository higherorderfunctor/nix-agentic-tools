# Factory for a typed GitHub MCP entry. Credentials use redact references.
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
