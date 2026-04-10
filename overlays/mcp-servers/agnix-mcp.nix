# agnix with mainProgram overridden to the MCP server binary.
# The base agnix derivation (overlays/agnix.nix) builds all three
# binaries (agnix, agnix-lsp, agnix-mcp). This entry makes
# `lib.getExe pkgs.ai.mcpServers.agnix-mcp` return the MCP binary.
{agnix}:
agnix.overrideAttrs (old: {
  meta = old.meta // {mainProgram = "agnix-mcp";};
})
