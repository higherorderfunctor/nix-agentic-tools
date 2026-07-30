#!/usr/bin/env bash
#
# Mutation test for queue_verify.py: break one thing at a time and require the
# named check to catch it.
#
# self-test-queue.sh proves the queue behaves. This proves the VERIFIER bites. The
# two are not the same claim, and the gap between them is where a green suite
# that cannot fail lives: every predicate in queue_verify.py is a conjunction of
# things that are all true of a correct run, so a predicate that silently stopped
# evaluating anything would keep reporting PASS forever.
#
# Each case mutates a COPY of the tree, never the working tree. The mutation
# anchor is asserted to appear exactly once, so a refactor that moves the code
# makes this fail loudly rather than quietly stop mutating anything.
#
# SCOPE LIMIT, stated so a PASS here is not read as broader than it is: every
# case runs ONE branch, so this cannot reach the invariants that only exist under
# concurrency -- the atomic claim itself, and the exclusive result create that
# backstops it. Breaking either is invisible to a single claimant. Those are
# proven instead by self-test-queue.sh's T4, which runs the real harness against a
# deliberately non-atomic claim and requires the detectors to fire.
#
# Nothing here reads or writes $HOME/.kiro and nothing launches Kiro.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "$here/.." && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness/lib.sh
. "$here/../harness/lib.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/kiro-queue-mutation.XXXXXX")"
work_parent="$(dirname "$work")"

cleanup() {
  if kiro_assert_under_scratch "$work" "$work_parent" 2>/dev/null; then
    rm -rf "$work"
  else
    echo "mutation-test-queue: refusing to remove ${work}" >&2
  fi
}
trap cleanup EXIT

caught=0
missed=0

# run_case <label> <file-under-fixture> <anchor> <replacement> <expected-check>
run_case() {
  local label="$1" file="$2" from="$3" to="$4" want="$5"
  local sandbox="$work/case-$((caught + missed + 1))"
  mkdir -p "$sandbox"
  cp -r "$src/harness" "$src/queue" "$src/scripts" "$sandbox/"

  python3 - "$sandbox/$file" "$from" "$to" <<'PY'
import pathlib
import sys

path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
target = pathlib.Path(path)
text = target.read_text()
hits = text.count(old)
if hits != 1:
    sys.exit(
        f"mutation anchor matched {hits} times, expected exactly 1 -- the code "
        f"moved and this case is no longer mutating what it claims: {old!r}"
    )
target.write_text(text.replace(old, new))
PY

  "$sandbox/scripts/queue_init.py" --root "$sandbox/run" --profile moderate \
    --unit-ms 5 >/dev/null
  # A correct run needs 16 iterations. Capping at 40 keeps a mutation that
  # never drains from burning the default 400 before it reports.
  "$sandbox/scripts/queue-branch.sh" --root "$sandbox/run" --owner w1 \
    --turn-ms 0 --max-iterations 40 >/dev/null 2>&1 || :
  local rc=0
  "$sandbox/scripts/queue_verify.py" --root "$sandbox/run" \
    >"$sandbox/verify.json" 2>&1 || rc=$?
  local fired
  fired="$(jq -r '[.checks[]|select(.ok==false)|.name]|join(",")' \
    "$sandbox/verify.json" 2>/dev/null || echo "VERIFY-DID-NOT-PRODUCE-JSON")"

  if [ "$rc" -ne 0 ] && [[ ",$fired," == *",$want,"* ]]; then
    caught=$((caught + 1))
    printf 'CAUGHT  %-34s by %s\n' "$label" "$want"
  else
    missed=$((missed + 1))
    printf 'MISSED  %-34s rc=%s fired=[%s]\n' "$label" "$rc" "$fired" >&2
  fi
}

# A control run with NO mutation must verify clean. Without it, a verifier that
# failed everything unconditionally would score 100% below.
control="$work/control"
mkdir -p "$control"
cp -r "$src/harness" "$src/queue" "$src/scripts" "$control/"
"$control/scripts/queue_init.py" --root "$control/run" --profile moderate \
  --unit-ms 5 >/dev/null
"$control/scripts/queue-branch.sh" --root "$control/run" --owner w1 \
  --turn-ms 0 >/dev/null
control_rc=0
"$control/scripts/queue_verify.py" --root "$control/run" \
  >"$control/verify.json" 2>&1 || control_rc=$?
if [ "$control_rc" -eq 0 ]; then
  printf 'CLEAN   %-34s verifies with no violations\n' "baseline control"
else
  printf 'FAIL    %-34s rc=%s -- the verifier fails a CORRECT run, so every\n' \
    "baseline control" "$control_rc" >&2
  printf '        CAUGHT below is meaningless\n' >&2
  exit 1
fi

run_case "child payload derivation" \
  scripts/queuelib.py \
  'start = int(parent["payload"]["b"]) + 100 * ordinal' \
  'start = int(parent["payload"]["b"]) + 101 * ordinal' \
  payload-and-depth-match-prediction

run_case "lineage depth increment" \
  scripts/queuelib.py \
  'depth = int(parent.get("lineage_depth", 0)) + 1' \
  'depth = int(parent.get("lineage_depth", 0)) + 2' \
  lineage-depth-is-parent-plus-one

run_case "the work the worker performs" \
  scripts/queuelib.py \
  'for n in range(int(payload["a"]), int(payload["b"]) + 1):' \
  'for n in range(int(payload["a"]), int(payload["b"])):' \
  every-answer-is-correct

run_case "over-cap push refusal" \
  scripts/queuelib.py \
  '    if depth > cap:
        child["dead_letter_reason"] = (' \
  '    if depth > cap + 5:
        child["dead_letter_reason"] = (' \
  over-cap-items-are-dead-lettered

# The one that matters most: `drained` must count in-flight work, or the branch
# stops while a late-proposer is still holding the item that mints its child.
run_case "drained ignoring in-flight work" \
  scripts/queuelib.py \
  'counts["claimed"] or counts["orphaned"] or counts["proposed"] or counts["ready"]' \
  'counts["ready"]' \
  all-items-terminal

# The admission gate: if nothing is ever promoted, proposed work is never
# claimable and the run cannot legally finish.
run_case "the admission gate" \
  scripts/queuelib.py \
  'if create_exclusive_json(admit_path(root, item["id"]), marker):' \
  'if False and create_exclusive_json(admit_path(root, item["id"]), marker):' \
  all-items-terminal

echo
printf 'mutations caught: %d\n' "$caught"
printf 'mutations missed: %d\n' "$missed"

if [ "$caught" -eq 0 ]; then
  echo 'FAIL: no mutation was applied at all' >&2
  exit 1
fi
if [ "$missed" -ne 0 ]; then
  printf 'FAIL: %d mutation(s) went undetected\n' "$missed" >&2
  exit 1
fi
echo 'PASS'
