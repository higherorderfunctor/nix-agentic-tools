# agnix with mainProgram overridden to the MCP server binary.
# The base agnix derivation (packages/agnix/packages/ai/agnix/package.nix) builds all three
# binaries (agnix, agnix-lsp, agnix-mcp). This entry makes
# `lib.getExe pkgs.ai.mcpServers.agnix-mcp` return the MCP binary.
#
# Use a plain `//` overlay, NOT `overrideAttrs`: nixpkgs injects
# NIX_MAIN_PROGRAM=meta.mainProgram into the build environment, so
# changing mainProgram via `overrideAttrs` (which re-runs mkDerivation)
# forks the derivation hash and triggers a full, redundant Rust
# recompile. `//` overrides only the eval-time meta that `lib.getExe`
# reads, leaving the build untouched, so agnix/agnix-lsp/agnix-mcp all
# share ONE derivation and ONE compile.
# packages/agnix/checks/role-identity.nix guards this identity.
{agnix}:
agnix
// {
  meta = agnix.meta // {mainProgram = "agnix-mcp";};
}
