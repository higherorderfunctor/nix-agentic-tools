# checks/strictdoc-commentary-check.nix -- the CI gate for the COMMENTARY
# element (packages/strictdoc-grammar/values.nix). Exports the whole design
# graph and runs dev/scripts/commentary-check.py over it.
#
# INV-GUARDS-MUST-EXECUTE is why this exists in the same commit as the element.
# A grammar type whose only guarantee is a check that does not run is exactly
# the pattern that requirement forbids, and the operator's stated reason for
# wanting COMMENTARY at all was "a new class of core cannon grammar for
# effectively commentary nodes I can run semantic validators against."
#
# THE SELF-TEST IS THE POINT. The corpus carries ZERO commentary nodes today,
# so the real run reports "0 checked: 0 findings" and exits 0 -- which is
# indistinguishable from a checker that returns 0 unconditionally. So this
# build also feeds the script a hand-written export fixture holding one bad
# COMMENTARY and asserts it exits NON-zero. Same technique as
# checks/strictdoc-grammar-negative-fixtures.nix: a green over an empty set
# only means something once the red has been demonstrated.
#
# The fixture is a literal JSON index rather than a second strictdoc project
# because the script reads only DOCUMENTS[].NODES[] -- there is nothing to
# gain from parsing .sdoc twice, and a fixture that cannot drift with the
# grammar is the more durable one.
#
# The clean output directory is load-bearing, not incidental -- same reason as
# checks/strictdoc-file-check.nix: `strictdoc export` caches under its output
# dir, and a broken input can exit 1 then exit 0 on re-run against a warm one.
# `runCommand` gives every build its own fresh $TMPDIR.
{
  pkgs,
  self,
}:
pkgs.runCommand "strictdoc-commentary-check" {
  nativeBuildInputs = [pkgs.ai.devTools.strictdoc pkgs.python3];
} ''
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  export HOME="$TMPDIR"

  # 1. the real corpus must be clean
  strictdoc export ${self} --formats=json --output-dir "$TMPDIR/output"
  python3 ${self}/dev/scripts/commentary-check.py "$TMPDIR/output/json/index.json" | tee "$out"

  # 2. the checker must be able to FAIL: one COMMENTARY whose EDGE names a
  #    relation nobody wrote, and which does not carry either endpoint as a
  #    Remarks_On target
  cat > "$TMPDIR/bad.json" <<'FIXTURE'
  {"DOCUMENTS": [{"TITLE": "negative fixture", "NODES": [
    {"_NODE_TYPE": "DECISION", "UID": "DEC-FIXTURE-ONE", "RELATIONS": []},
    {"_NODE_TYPE": "DECISION", "UID": "DEC-FIXTURE-TWO", "RELATIONS": []},
    {"_NODE_TYPE": "COMMENTARY", "UID": "CMT-FIXTURE-BAD",
     "EDGE": "DEC-FIXTURE-ONE Governed_By DEC-FIXTURE-TWO", "RELATIONS": []}
  ]}]}
  FIXTURE

  if python3 ${self}/dev/scripts/commentary-check.py "$TMPDIR/bad.json" 2>"$TMPDIR/err"; then
    echo "self-test FAILED: the checker passed a commentary whose EDGE names no relation" >&2
    cat "$TMPDIR/err" >&2
    exit 1
  fi
  echo "self-test: the checker rejects a bad commentary" | tee -a "$out"
''
