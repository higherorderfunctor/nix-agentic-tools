# Composes all package group overlays into a single overlay.
# Each group manages its own namespace:
#   git-tools:   top-level (pkgs.git-absorb, etc.)
#   mcp-servers: namespaced (pkgs.nix-mcp-servers.*)
#   ai-clis:     top-level (pkgs.copilot-cli, etc.)
#
# Content migrates in Phase 3.
{lib}: _final: _prev: {
  # lib.composeManyExtensions [
  #   (import ./git-tools)
  #   (import ./mcp-servers)
  #   (import ./ai-clis)
  # ]
}
