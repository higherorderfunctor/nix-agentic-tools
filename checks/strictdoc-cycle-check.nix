# checks/strictdoc-cycle-check.nix -- SLICE-GRAPH-CHECKS's CI gate for
# MECH-CYCLE-CHECK (docs/plans/strictdoc-tooling/mech-cycle-check.sdoc). Exports
# the whole design graph and runs dev/scripts/cycle-check.py over it, failing
# the build on any relation cycle.
#
# StrictDoc's own cycle detection only sees role-less edges, and every
# relation in this grammar carries a role, so it never fires here -- a cycle
# would otherwise surface as a recursion-depth crash during render instead of
# a build failure. See MECH-CYCLE-CHECK's RATIONALE.
#
# The clean output directory is load-bearing, not incidental -- same reason as
# checks/strictdoc-fp-check.nix: `strictdoc export` caches under its output
# dir, and a broken input can exit 1 then exit 0 on re-run against a warm one.
# `runCommand` gives every build its own fresh $TMPDIR.
#
# `pkgs.ai.devTools.strictdoc`, not `pkgs.strictdoc`: the overlay re-exports
# upstream's own flake, which tracks main, so the design system is measured
# against what upstream ships rather than against whichever version the nixpkgs
# pin carries (SLICE-STRICTDOC-OVERLAY).
{
  pkgs,
  self,
}:
pkgs.runCommand "strictdoc-cycle-check" {
  nativeBuildInputs = [pkgs.ai.devTools.strictdoc pkgs.python3];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"
  strictdoc export ${self} --formats=json --output-dir "$TMPDIR/output"
  python3 ${self}/dev/scripts/cycle-check.py "$TMPDIR/output/json/index.json" | tee "$out"
''
