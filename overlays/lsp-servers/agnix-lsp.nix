# agnix with mainProgram overridden to the LSP server binary.
# The base agnix derivation (overlays/agnix.nix) builds all three
# binaries (agnix, agnix-lsp, agnix-mcp). This entry makes
# `lib.getExe pkgs.ai.lspServers.agnix-lsp` return the LSP binary.
#
# Use a plain `//` overlay, NOT `overrideAttrs`: nixpkgs injects
# NIX_MAIN_PROGRAM=meta.mainProgram into the build environment, so
# changing mainProgram via `overrideAttrs` (which re-runs mkDerivation)
# forks the derivation hash and triggers a full, redundant Rust
# recompile. `//` overrides only the eval-time meta that `lib.getExe`
# reads, leaving the build untouched, so agnix/agnix-lsp/agnix-mcp all
# share ONE derivation and ONE compile. Guarded by the agnix sibling
# drvPath assertion in checks/cache-hit-parity.nix.
{agnix}:
agnix
// {
  meta = agnix.meta // {mainProgram = "agnix-lsp";};
}
