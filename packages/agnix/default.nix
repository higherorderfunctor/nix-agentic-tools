# agnix is a multi-purpose binary package (linter + LSP + MCP
# server for AI coding assistant config files). No HM module,
# no factory — consumers that want it as an MCP server use
# lib.mcp.mkPackageEntry pkgs.ai.agnix (reads passthru.mcpBinary).
# Also accessible as pkgs.ai.mcpServers.agnix-mcp (proxy) and
# pkgs.ai.lspServers.agnix-lsp (proxy) — same derivation.
{
  docs = ./docs;
}
