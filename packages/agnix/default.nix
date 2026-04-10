# agnix is a multi-purpose binary package (linter + LSP + MCP
# server for AI coding assistant config files). No HM module,
# no factory. Three binaries: agnix (CLI), agnix-lsp, agnix-mcp.
#
# pkgs.ai.agnix              — base derivation, mainProgram = "agnix"
# pkgs.ai.mcpServers.agnix-mcp — overrideAttrs mainProgram = "agnix-mcp"
# pkgs.ai.lspServers.agnix-lsp — overrideAttrs mainProgram = "agnix-lsp"
#
# Consumers use lib.getExe on the grouped entry for the right binary.
{
  docs = ./docs;
}
