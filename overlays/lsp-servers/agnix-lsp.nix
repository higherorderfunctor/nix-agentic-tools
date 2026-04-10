# agnix with mainProgram overridden to the LSP server binary.
# The base agnix derivation (overlays/agnix.nix) builds all three
# binaries (agnix, agnix-lsp, agnix-mcp). This entry makes
# `lib.getExe pkgs.ai.lspServers.agnix-lsp` return the LSP binary.
{agnix}:
agnix.overrideAttrs (old: {
  meta = old.meta // {mainProgram = "agnix-lsp";};
})
