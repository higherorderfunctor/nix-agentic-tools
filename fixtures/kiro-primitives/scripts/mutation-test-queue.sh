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

prepare_sandbox() {
	mkdir -p "$1"
	cp -r "$src/harness" "$src/queue" "$src/scripts" "$1/"
}

run_queue() {
	local sandbox="$1" branch_rc=0 verify_rc=0
	"$sandbox/scripts/queue_init.py" --root "$sandbox/run" --profile moderate \
		--unit-ms 5 >/dev/null
	# A correct run needs 16 iterations. Capping at 40 keeps a mutation that
	# never drains from burning the default 400 before it reports.
	"$sandbox/scripts/queue-branch.sh" --root "$sandbox/run" --owner w1 \
		--turn-ms 0 --max-iterations 40 >"$sandbox/branch.json" 2>"$sandbox/branch.err" || branch_rc=$?
	"$sandbox/scripts/queue_verify.py" --root "$sandbox/run" \
		>"$sandbox/verify.json" 2>&1 || verify_rc=$?
	printf '%s %s\n' "$branch_rc" "$verify_rc"
}

# run_case <label> <anchor> <replacement> <branch-exit> <expected-check> <detail>
run_case() {
	local label="$1" from="$2" to="$3" want_branch_rc="$4" want="$5" detail="$6"
	local sandbox="$work/case-$((caught + missed + 1))" branch_rc verify_rc
	prepare_sandbox "$sandbox"

	python3 - "$sandbox/scripts/queuelib.py" "$from" "$to" <<'PY'
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

	local exit_codes
	exit_codes="$(run_queue "$sandbox")"
	read -r branch_rc verify_rc <<<"$exit_codes"
	if [[ "$branch_rc" == "$want_branch_rc" && "$verify_rc" == 2 ]] &&
		jq -e --arg name "$want" --arg detail "$detail" \
			'any(.violations[]; .name == $name and (.detail | contains($detail)))' \
			"$sandbox/verify.json" >/dev/null; then
		caught=$((caught + 1))
		printf 'CAUGHT  %-34s by %s\n' "$label" "$want"
	else
		missed=$((missed + 1))
		printf 'MISSED  %-34s branch=%s (want %s) verify=%s (want 2)\n' \
			"$label" "$branch_rc" "$want_branch_rc" "$verify_rc" >&2
		printf '        expected %s: %s\n' "$want" "$detail" >&2
		cat "$sandbox/branch.err" "$sandbox/verify.json" >&2
	fi
}

# A control run with NO mutation must verify clean. Without it, a verifier that
# failed everything unconditionally would score 100% below.
control="$work/control"
prepare_sandbox "$control"
exit_codes="$(run_queue "$control")"
if [[ "$exit_codes" != "0 0" ]] ||
	! jq -e '.ok == true and .violations == []' "$control/verify.json" >/dev/null; then
	printf 'FAIL    baseline control: branch/verify exits [%s], expected [0 0] and no violations\n' \
		"$exit_codes" >&2
	cat "$control/branch.err" "$control/verify.json" >&2
	exit 1
fi
printf 'CLEAN   %-34s verifies with no violations\n' "baseline control"

# The wrong range can still produce the right answer for that range.
run_case "child range starts one late" \
	'start = int(parent["payload"]["b"]) + 100 * ordinal' \
	'start = int(parent["payload"]["b"]) + 101 * ordinal' \
	0 payload-and-depth-match-prediction 'm02.c1: (124, 128, 2, 1) != predicted (123, 127, 2, 1)'

# A single branch observes pending proposals here, not live claims.
# It incorrectly exits 0 while the depth-3 proposal is still pending.
run_case "drained ignores pending proposals" \
	' or counts["proposed"] or counts["ready"]' \
	' or counts["ready"]' \
	0 all-items-terminal "non-terminal=['m08.c1.c1.c1']"

# A grandchild attributed to its seed still has the predicted ID and payload.
run_case "grandchild attributed to seed" \
	'"derived_from": parent["id"],' \
	'"derived_from": parent["id"].split(".")[0],' \
	0 lineage-depth-is-parent-plus-one 'm02.c1.c1: depth=2 but parent m02 is at 0'

# The admission gate rejects the depth-4 proposal, so the branch errors out;
# the verifier must still identify the proposal that should have been dead.
run_case "over-cap push refusal" \
	'    if depth > cap:
        child["dead_letter_reason"] = (' \
	'    if depth > cap + 5:
        child["dead_letter_reason"] = (' \
	1 over-cap-items-are-dead-lettered 'm08.c1.c1.c1.c1: depth=4 cap=3 state=proposed'

# Change the worker's answer without changing the seeded expected field.
run_case "worker omits the upper bound" \
	'return expected_answer(item["payload"])' \
	'return expected_answer(item["payload"]) - int(item["payload"]["b"])' \
	0 every-answer-is-correct 'm01: result=33 item=33 truth=46'

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
