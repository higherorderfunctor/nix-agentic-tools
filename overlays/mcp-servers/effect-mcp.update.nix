# effect-mcp's own update-target contribution, co-located with the overlay it
# bumps. Merged into the `update.targets` registry declared by lib/update.nix
# (see that file for the coexistence rationale — this is the Track-A merge-up
# beachhead, and config/update-matrix.nix stays the live fallback).
#
# `file` is a repo-relative STRING (NOT a Nix path literal): it must equal the
# tail resolve_overlay_file prints for tim-smart/effect-mcp so both resolution
# paths agree during coexistence. Enforced by checks/update-targets-parity.nix.
#
# This file deliberately carries NO `owner = "…"` / `repo = "…"` attrs and no
# `github.com/<owner>/<repo>` URL, so resolve_overlay_file does not mistake it
# for a second overlay pinning tim-smart/effect-mcp.
_: {
  config.update.targets.effect-mcp = {
    file = "overlays/mcp-servers/effect-mcp.nix";
    flags = ["--version" "skip"];
  };
}
