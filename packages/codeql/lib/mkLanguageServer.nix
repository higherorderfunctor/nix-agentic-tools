# Client-launched stdio, using the same MCP bridge on every runtime/backend.
{
  lib,
  pkgs,
  ...
}: {
  searchPath ? [],
  workspace,
  ...
} @ args:
lib.ai.mcpServers.mkLanguageServer {inherit lib pkgs;} ({
    args = ["-workspace" workspace "-lsp" (lib.getExe (pkgs.ai.lspServers.codeql-lsp.override {inherit searchPath;}))];
    command = lib.mkForce (lib.getExe pkgs.ai.mcpServers.mcp-language-server);
  }
  // builtins.removeAttrs args ["searchPath" "workspace"])
