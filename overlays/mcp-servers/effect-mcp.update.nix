# effect-mcp's own update-target contribution, co-located with the overlay it
# bumps. Merged into the `config.update.targets` registry declared by
# lib/update.nix (the single source of truth that replaced
# config/update-matrix.nix). Kept out of config/update-targets.nix so it stays
# next to the overlay it maintains — disjoint keys, no collision.
#
# `file` is a repo-relative STRING (NOT a Nix path literal): it must equal the
# tail resolve_overlay_file prints for tim-smart/effect-mcp, asserted
# byte-identical by checks/update-targets-parity.nix.
#
# This sidecar carries its own `git` URL. resolve_overlay_file deliberately
# skips `*.update.nix` files (they hold update metadata, never pin a source),
# so the URL here does not make the resolver mistake this file for a second
# overlay pinning tim-smart/effect-mcp.
_: {
  config.update.targets.effect-mcp = {
    file = "overlays/mcp-servers/effect-mcp.nix";
    flags = ["--version" "skip"];
    git = "https://github.com/tim-smart/effect-mcp.git";
  };
}
