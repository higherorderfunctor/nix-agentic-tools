# checks/strictdoc-file-check.nix -- the CI gate for
# MECH-FILE-RELATION-EXISTENCE
# (docs/plans/strictdoc-tooling/mech-file-relation-existence.sdoc). Exports the
# whole design graph and runs dev/scripts/file-check.py over it, failing the
# build on any File relation that is malformed or names no existing file.
#
# A File relation to a deleted path EXPORTS CLEAN -- strictdoc's own
# file-traceability validation is off here -- so without this gate a node can
# point at a file that no longer exists and nothing notices. SLICE-SDOC-CLI's
# write-time check cannot cover it: that check sees the VALUEs it is about to
# write, and the ghost problem runs the other way, from a file removed after
# its relation was written.
#
# `${self}` is the flake source, so the repo root the script resolves paths
# against is the same tree the export was taken from. That matters: the JSON
# export carries no path for anything, which is why this script takes a second
# argument neither cycle-check.py nor fp-check.py does.
#
# The clean output directory is load-bearing, not incidental -- same reason as
# checks/strictdoc-cycle-check.nix: `strictdoc export` caches under its output
# dir, and a broken input can exit 1 then exit 0 on re-run against a warm one.
# `runCommand` gives every build its own fresh $TMPDIR.
{
  pkgs,
  self,
}:
pkgs.runCommand "strictdoc-file-check" {
  nativeBuildInputs = [pkgs.ai.devTools.strictdoc pkgs.python3];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"
  strictdoc export ${self} --formats=json --output-dir "$TMPDIR/output"
  python3 ${self}/dev/scripts/file-check.py "$TMPDIR/output/json/index.json" ${self} | tee "$out"
''
