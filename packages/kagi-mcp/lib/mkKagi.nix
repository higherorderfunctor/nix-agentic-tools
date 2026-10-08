# Factory for a typed Kagi MCP entry. Credentials use redact references.
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
