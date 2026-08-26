# checks/strictdoc-fp-check.nix -- SLICE-FP-DETECTOR's CI gate
# (docs/plans/strictdoc-tooling/01-tooling.sdoc). Exports the whole design
# graph and runs dev/scripts/fp-check.py over it, failing the build on any
# drifted, unbacked, or deleted-parent PARENT_FP entry.
#
# The clean output directory is load-bearing, not incidental: `strictdoc
# export` caches under its output dir, and a broken input can exit 1 then
# exit 0 on re-run against a warm one -- see the sdoc skill's gotcha list.
# `runCommand` gives every build its own fresh $TMPDIR, so there is no warm
# cache to produce that false green with.
#
# `pkgs.ai.devTools.strictdoc`, not `pkgs.strictdoc`: the overlay tracks the
# latest upstream release, and the design system is measured against that
# rather than against whichever version the nixpkgs pin carries
# (SLICE-STRICTDOC-OVERLAY).
{
  pkgs,
  self,
}:
pkgs.runCommand "strictdoc-fp-check" {
  nativeBuildInputs = [pkgs.ai.devTools.strictdoc pkgs.python3];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"
  strictdoc export ${self} --formats=json --output-dir "$TMPDIR/output"
  python3 ${self}/dev/scripts/fp-check.py "$TMPDIR/output/json/index.json" | tee "$out"
''
