#!/usr/bin/env bash
#
# Self-test for the synthetic drain queue and its claim/push/status scripts.
#
# The load-bearing test is T3/T4: N claimants racing on one queue, asserting
# zero double-claims and every item terminal exactly once -- immediately
# followed by the SAME harness run against the deliberately non-atomic
# read-then-write claim, which MUST fail. Without that control a passing test
# and a test that cannot fail are indistinguishable.
#
# Everything runs in a mktemp scratch directory. Nothing here reads or writes
# $HOME/.kiro, $HOME/.local/share/kiro-cli, or launches Kiro.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# source-path=SCRIPTDIR resolves the include relative to THIS script rather
# than to the caller's cwd, which is what lets `shellcheck -x` follow it from
# the repo root the way pre-commit invokes it. lib.sh is sourced for its
# bash-only guard and for kiro_assert_under_scratch, which every rm -rf below
# routes through.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../harness/lib.sh
. "$here/../harness/lib.sh"

claimants="${CLAIMANTS:-12}"
repetitions="${REPETITIONS:-5}"
unit_ms="${UNIT_MS:-10}"
turn_ms="${TURN_MS:-5}"

work="$(mktemp -d "${TMPDIR:-/tmp}/kiro-queue-self_test.XXXXXX")"
work_parent="$(dirname "$work")"
mkdir -p "$work/logs"

cleanup() {
  # The guard, not a comment: a bug in $work must not be able to reach real
  # state. kiro_assert_under_scratch refuses anything that is not under the
  # scratch parent, and refuses an unsafe parent outright.
  if kiro_assert_under_scratch "$work" "$work_parent" 2>/dev/null; then
    rm -rf "$work"
  else
    echo "self-test-queue: refusing to remove ${work}" >&2
  fi
}
trap cleanup EXIT

ok=0
bad=0

pass() {
  ok=$((ok + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  bad=$((bad + 1))
  printf 'FAIL  %s: %s\n' "$1" "$2" >&2
}

expect_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1 ($3)"
  else
    fail "$1" "want=$2 got=$3"
  fi
}

expect_ne() {
  if [ "$2" != "$3" ]; then
    pass "$1 ($3)"
  else
    fail "$1" "did not want $3"
  fi
}

expect_match() {
  case "$3" in
  *"$2"*) pass "$1" ;;
  *) fail "$1" "'$3' does not contain '$2'" ;;
  esac
}

# Run R repetitions of a fully parallel drain over one fresh queue each.
# Echoes the last run root so the caller can inspect it.
race() {
  local profile="$1" strategy="$2" reps="$3" tag="$4"
  local rep root i rc
  local -a pid_list
  for rep in $(seq 1 "$reps"); do
    root="$work/${tag}-${profile}-${rep}"
    "$here/queue_init.py" --root "$root" --profile "$profile" \
      --unit-ms "$unit_ms" >"$work/logs/${tag}-${profile}-${rep}-init.json"
    pid_list=()
    for i in $(seq 1 "$claimants"); do
      "$here/queue-branch.sh" --root "$root" --owner "w${i}" \
        --turn-ms "$turn_ms" --strategy "$strategy" \
        >"$work/logs/${tag}-${profile}-${rep}-w${i}.json" \
        2>"$work/logs/${tag}-${profile}-${rep}-w${i}.err" &
      pid_list+=("$!")
    done
    for pid in "${pid_list[@]}"; do
      rc=0
      wait "$pid" || rc=$?
      # One file for ALL reps: a per-rep file lets a check that reads only the
      # last one report green while an earlier rep failed.
      printf '%s\n' "$rc" >>"$work/logs/${tag}-${profile}-branch-rcs"
    done
  done
  printf '%s\n' "$root"
}

# Number of lines in a file that are not "0". `grep -c` exits 1 on no match,
# which under errexit would abort the script rather than report zero.
count_nonzero() {
  local n
  n="$(grep -cv '^0$' "$1" || :)"
  printf '%s\n' "${n:-0}"
}

# Wait until an item records at least one attempt. Polling for the claim marker
# is NOT equivalent: the marker is published before the attempt counter is
# bumped, so a signal sent on the marker's appearance can land inside the claim
# and make the test's own timing the variable under measurement.
wait_for_attempt() {
  local root="$1" item="$2" _
  for _ in $(seq 1 200); do
    if [ -f "$root/items/${item}.json" ] &&
      [ "$(jq -r '.attempts' "$root/items/${item}.json")" -ge 1 ]; then
      return 0
    fi
    sleep 0.05
  done
  echo "wait_for_attempt: ${item} never recorded an attempt" >&2
  return 1
}

echo "== T1  profile duration vectors are the literals the design specifies"
expect_eq "moderate durations" \
  '[1,1,1,2,2,2,2,3,3,3]' \
  "$(jq -c '.durations' "$here/../queue/profiles/moderate.json")"
expect_eq "severe durations" \
  '[1,1,1,1,1,1,1,1,6,10]' \
  "$(jq -c '.durations' "$here/../queue/profiles/severe.json")"

echo
echo "== T2  status.json exists with drained:false from the start"
t2="$work/t2"
"$here/queue_init.py" --root "$t2" --profile moderate --unit-ms "$unit_ms" \
  >"$work/logs/t2-init.json"
expect_eq "status.json present after init" yes \
  "$([ -f "$t2/status.json" ] && echo yes || echo no)"
expect_eq "drained is false at seed time" false "$(jq -r '.drained' "$t2/status.json")"
expect_eq "seeded ready count" 10 "$(jq -r '.counts.ready' "$t2/status.json")"
rc=0
"$here/queue_init.py" --root "$t2" --profile moderate >/dev/null 2>&1 || rc=$?
expect_eq "re-init without --force is refused" 1 "$rc"

echo
echo "== T3  ${claimants} concurrent claimants x ${repetitions} reps x 2 profiles"
for profile in moderate severe; do
  last_root="$(race "$profile" exclusive "$repetitions" race)"
  expect_eq "every branch across every rep exited 0 (${profile})" 0 \
    "$(count_nonzero "$work/logs/race-${profile}-branch-rcs")"
  expect_eq "branch count (${profile})" \
    "$((claimants * repetitions))" \
    "$(wc -l <"$work/logs/race-${profile}-branch-rcs")"
  for rep in $(seq 1 "$repetitions"); do
    root="$work/race-${profile}-${rep}"
    rc=0
    "$here/queue_verify.py" --root "$root" \
      >"$work/logs/race-${profile}-${rep}-verify.json" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
      fail "verify rep ${rep} (${profile})" \
        "$(jq -c '.violations' "$work/logs/race-${profile}-${rep}-verify.json" 2>/dev/null || echo "rc=$rc")"
    else
      pass "verify rep ${rep} (${profile}): all $(jq -r '.checks|length' "$work/logs/race-${profile}-${rep}-verify.json") checks"
    fi
  done
  summary="$work/logs/race-${profile}-${repetitions}-verify.json"
  echo "     last rep: $(jq -c '.counts' "$summary")"
  echo "     acquires: $(jq -r '.event_kinds["claim.acquired"]' "$summary")" \
    "releases: $(jq -r '.event_kinds["claim.released"]' "$summary")"
  # Denominator: a race that claimed nothing would satisfy every predicate.
  expect_ne "acquire events were actually recorded (${profile})" 0 \
    "$(jq -r '.event_kinds["claim.acquired"]' "$summary")"
  expect_eq "work was spread over more than one claimant (${profile})" yes \
    "$(jq -rs '[.[]|select(.worked>0)]|length' \
      "$work"/logs/race-"${profile}"-"${repetitions}"-w*.json |
      awk '{print ($1 > 1) ? "yes" : "no"}')"
  expect_eq "every branch reported the dry_threshold it read (${profile})" \
    "$claimants" \
    "$(jq -rs '[.[]|select(.dry_threshold != null)]|length' \
      "$work"/logs/race-"${profile}"-"${repetitions}"-w*.json)"
done
echo "     (last_root=${last_root})"

echo
echo "== T4  POSITIVE CONTROL: the same harness on a read-then-write claim MUST fail"
detectors='one-acquire-per-item-generation no-overlapping-claim-intervals'
detectors="$detectors no-double-completion-events no-claim-owner-mismatch-events"
control_reps="${CONTROL_REPS:-3}"
for rep in $(seq 1 "$control_reps"); do
  root="$work/control-moderate-${rep}"
  "$here/queue_init.py" --root "$root" --profile moderate --unit-ms "$unit_ms" \
    >"$work/logs/control-${rep}-init.json"
  pid_list=()
  for i in $(seq 1 "$claimants"); do
    "$here/queue-branch.sh" --root "$root" --owner "w${i}" --turn-ms 0 \
      --strategy read-then-write --max-iterations 40 \
      >"$work/logs/control-${rep}-w${i}.json" \
      2>"$work/logs/control-${rep}-w${i}.err" &
    pid_list+=("$!")
  done
  for pid in "${pid_list[@]}"; do
    wait "$pid" || :
  done
  rc=0
  "$here/queue_verify.py" --root "$root" --no-expect-set --allow-not-drained \
    >"$work/logs/control-${rep}-verify.json" 2>&1 || rc=$?
  fired="$(jq -r '[.checks[]|select(.ok==false)|.name]|join(" ")' \
    "$work/logs/control-${rep}-verify.json" 2>/dev/null || echo "")"
  hit=no
  for detector in $detectors; do
    case " $fired " in
    *" $detector "*) hit=yes ;;
    *) ;;
    esac
  done
  if [ "$hit" = yes ]; then
    pass "control rep ${rep} detected a double claim (${fired})"
  else
    fail "control rep ${rep}" \
      "the detector did NOT fire -- a clean result here means the concurrency test above cannot fail. verify rc=${rc}, failing checks: [${fired}]"
  fi
done

echo
echo "== T5  the depth cap is read from config and enforced structurally"
capped="$work/race-moderate-1"
expect_eq "one push refused at the cap" 1 \
  "$(jq -r '.event_kinds["push.refused_over_cap"] // 0' \
    "$work/logs/race-moderate-1-verify.json")"
expect_eq "the refused item is the depth-4 link" dead \
  "$(jq -r '.state' "$capped/items/m08.c1.c1.c1.c1.json")"
expect_match "refusal names the cap" "exceeds max_lineage_depth 3" \
  "$(jq -r '.dead_letter_reason' "$capped/items/m08.c1.c1.c1.c1.json")"
expect_eq "a dead-lettered item is never worked" no \
  "$([ -f "$capped/results/m08.c1.c1.c1.c1.json" ] && echo yes || echo no)"
# Control for T5: lower the cap and the truncation must move. A hardcoded cap
# would keep refusing at depth 4 and this would not change.
t5="$work/t5-cap1"
"$here/queue_init.py" --root "$t5" --profile moderate --unit-ms "$unit_ms" \
  --max-lineage-depth 1 >"$work/logs/t5-init.json"
"$here/queue-branch.sh" --root "$t5" --owner w1 --turn-ms 0 \
  >"$work/logs/t5-branch.json"
rc=0
"$here/queue_verify.py" --root "$t5" >"$work/logs/t5-verify.json" 2>&1 || rc=$?
expect_eq "cap=1 run still verifies" 0 "$rc"
expect_eq "cap=1 refuses two pushes, not one" 2 \
  "$(jq -r '.event_kinds["push.refused_over_cap"] // 0' "$work/logs/t5-verify.json")"
expect_eq "cap=1 dead count" 2 "$(jq -r '.counts.dead' "$work/logs/t5-verify.json")"

echo
echo "== T6  drained is false while work is in flight, even with ready == 0"
t6="$work/t6"
"$here/queue_init.py" --root "$t6" --profile moderate --unit-ms "$unit_ms" \
  >"$work/logs/t6-init.json"
tokens=()
for n in 01 02 03 04 05 06 07 08 09 10; do
  tokens+=("$("$here/queue_claim.py" --root "$t6" --owner "holder${n}" \
    --item "m${n}" | jq -r '.token')")
done
t6_status="$("$here/queue_status.py" --root "$t6")"
expect_eq "ready is zero with every item held" 0 "$(jq -r '.counts.ready' <<<"$t6_status")"
expect_eq "claimed is ten" 10 "$(jq -r '.counts.claimed' <<<"$t6_status")"
# THE DISCRIMINATOR: a `ready == 0` drain check would say true right here, stop
# the loop, and drop every child the held items are about to propose.
expect_eq "drained is false anyway" false "$(jq -r '.drained' <<<"$t6_status")"
for n in 01 02 03 04 05 06 07 08 09 10; do
  answer="$(jq -r '.expected' "$t6/items/m${n}.json")"
  index=$((10#$n - 1))
  # Push first if this item declares a proposal -- queue_push refuses a released
  # claim, which is exactly the ordering constraint a worker is held to.
  if [ "$(jq -r '.proposes != null' "$t6/items/m${n}.json")" = true ]; then
    "$here/queue_push.py" --root "$t6" --claim "${tokens[$index]}" \
      --derived-from "m${n}" --owner "holder${n}" >/dev/null
  fi
  "$here/queue_release.py" --root "$t6" --claim "${tokens[$index]}" \
    --outcome "done" --answer "$answer" --owner "holder${n}" >/dev/null
done
t6_status="$("$here/queue_status.py" --root "$t6")"
expect_eq "proposals landed as proposed, not ready" 3 \
  "$(jq -r '.counts.proposed' <<<"$t6_status")"
expect_eq "un-admitted proposals keep drained false" false \
  "$(jq -r '.drained' <<<"$t6_status")"
expect_eq "admission gate promotes them" 3 \
  "$(jq -r '.admitted|length' "$("$here/queue_admit.py" --root "$t6" \
    >"$work/logs/t6-admit.json" && echo "$work/logs/t6-admit.json")")"

echo
echo "== T7  SIGKILL leaves an orphan that is surfaced, then requeued by TTL"
t7="$work/t7"
"$here/queue_init.py" --root "$t7" --profile moderate --unit-ms "$unit_ms" \
  --lease-ttl-sec 2 >"$work/logs/t7-init.json"
"$here/queue_worker.py" --root "$t7" --owner victim --hold-sec 30 \
  >"$work/logs/t7-victim.json" 2>&1 &
victim=$!
wait_for_attempt "$t7" m01
kill -KILL "$victim"
wait "$victim" 2>/dev/null || :
t7_status="$("$here/queue_status.py" --root "$t7")"
expect_eq "the killed lease is still held" 1 "$(jq -r '.counts.claimed' <<<"$t7_status")"
expect_eq "and drained stays false" false "$(jq -r '.drained' <<<"$t7_status")"
sleep 2.2
t7_status="$("$here/queue_status.py" --root "$t7")"
expect_eq "after the TTL it is reported as an orphan" 1 \
  "$(jq -r '.counts.orphaned' <<<"$t7_status")"
expect_eq "the orphan names its dead holder" victim \
  "$(jq -r '.orphans[0].owner' <<<"$t7_status")"
expect_eq "an orphan does not count as drained" false "$(jq -r '.drained' <<<"$t7_status")"
"$here/queue-branch.sh" --root "$t7" --owner recovery --turn-ms 0 \
  >"$work/logs/t7-branch.json"
rc=0
"$here/queue_verify.py" --root "$t7" >"$work/logs/t7-verify.json" 2>&1 || rc=$?
expect_eq "the requeued run verifies clean" 0 "$rc"
expect_eq "exactly one expired lease was stolen" 1 \
  "$(jq -r '.event_kinds["claim.stolen_expired_lease"] // 0' "$work/logs/t7-verify.json")"
expect_eq "the stolen item still completed exactly once" 1 \
  "$(find "$t7/results" -name 'm01.json' | wc -l)"
expect_eq "m01 records two attempts" 2 "$(jq -r '.attempts' "$t7/items/m01.json")"

echo
echo "== T8  SIGTERM releases the claim instead of orphaning it"
t8="$work/t8"
"$here/queue_init.py" --root "$t8" --profile moderate --unit-ms "$unit_ms" \
  >"$work/logs/t8-init.json"
"$here/queue_worker.py" --root "$t8" --owner quitter --hold-sec 30 \
  >"$work/logs/t8-quitter.json" 2>&1 &
quitter=$!
wait_for_attempt "$t8" m01
kill -TERM "$quitter"
wait "$quitter" 2>/dev/null || :
expect_eq "the lease was released, not left held" abandoned \
  "$(jq -r '.outcome' "$t8/claims/m01/0000.json")"
expect_eq "the abandon reason names the signal" '"signal 15"' \
  "$(jq -c '.note' "$t8/claims/m01/0000.json")"
t8_status="$("$here/queue_status.py" --root "$t8")"
expect_eq "nothing is in flight" 0 "$(jq -r '.counts.claimed' <<<"$t8_status")"
expect_eq "the item is claimable again immediately" 10 \
  "$(jq -r '.counts.ready' <<<"$t8_status")"

echo
echo "== T9  --tree renders the lineage forest, dead-letter included"
tree_out="$("$here/queue_status.py" --root "$capped" --tree)"
expect_match "tree shows a seeded root" "m08  d0  done" "$tree_out"
expect_match "tree shows the depth-1 child under it" "m08.c1  d1  done" "$tree_out"
expect_match "tree shows the refused depth-4 link as DEAD" \
  "m08.c1.c1.c1.c1  d4  dead" "$tree_out"
expect_match "tree names the cap in the refusal" \
  "DEAD: lineage_depth 4 exceeds max_lineage_depth 3" "$tree_out"
expect_eq "tree renders one line per item plus a 3-line header" 17 \
  "$(printf '%s\n' "$tree_out" | grep -c '  d[0-9]  ')"

echo
echo "== T10 REGRESSION: an in-progress write is never listed as an item"
# The glob in pathlib DOES match leading-dot names (glob.glob does not), so a
# `.tmp-*.json` scratch file was once read as a real item and handed to a
# claimant whose id had no file yet. One branch in 240.
t10="$work/t10"
"$here/queue_init.py" --root "$t10" --profile moderate --unit-ms "$unit_ms" \
  >"$work/logs/t10-init.json"
ghost='{"answer":null,"attempts":0,"derived_from":null,"duration_units":1,
  "expected":1,"id":"ghost","kind":"seed","lineage_depth":0,
  "payload":{"a":1,"b":1,"op":"sum_range"},"priority":0,"proposes":null,
  "state":"ready"}'
printf '%s\n' "$ghost" >"$t10/items/.tmp-pretend-in-progress.json"
expect_eq "a dotfile in items/ is not counted" 10 \
  "$(jq -r '.total' <<<"$("$here/queue_status.py" --root "$t10")")"
# Positive control: the SAME content under a published name must be counted.
# Without this, a glob that matched nothing at all would also pass above.
printf '%s\n' "$ghost" >"$t10/items/ghost.json"
expect_eq "the same record under a published name IS counted" 11 \
  "$(jq -r '.total' <<<"$("$here/queue_status.py" --root "$t10")")"

echo
echo "== T11 a zero denominator is not drained"
t11="$work/t11"
"$here/queue_init.py" --root "$t11" --profile moderate --unit-ms "$unit_ms" \
  >"$work/logs/t11-init.json"
mv "$t11/items" "$t11/items-hidden"
t11_status="$("$here/queue_status.py" --root "$t11")"
expect_eq "an empty items/ reports total 0" 0 "$(jq -r '.total' <<<"$t11_status")"
expect_eq "and refuses rather than claiming drained" false \
  "$(jq -r '.drained' <<<"$t11_status")"
expect_match "and says why" "zero denominator" \
  "$(jq -r '.refusal' <<<"$t11_status")"
mv "$t11/items-hidden" "$t11/items"
expect_eq "restoring items/ restores the count" 10 \
  "$(jq -r '.total' <<<"$("$here/queue_status.py" --root "$t11")")"

echo
echo "== T12 an empty claim returns; it does not poll"
t9="$work/race-moderate-1"
start="$(date +%s)"
rc=0
"$here/queue_claim.py" --root "$t9" --owner probe >/dev/null || rc=$?
elapsed=$(($(date +%s) - start))
expect_eq "empty claim exits 3" 3 "$rc"
expect_eq "and returns in under 3s" yes \
  "$([ "$elapsed" -lt 3 ] && echo yes || echo no)"

echo
printf 'checks passed: %d\n' "$ok"
printf 'checks failed: %d\n' "$bad"

# A denominator of zero is not a pass. "Everything passed" is vacuous if
# nothing ran, and that is exactly how a broken driver would present.
if [ "$ok" -eq 0 ]; then
  echo 'FAIL: no checks ran' >&2
  exit 1
fi
if [ "$bad" -ne 0 ]; then
  printf 'FAIL: %d check(s) failed\n' "$bad" >&2
  exit 1
fi
echo 'PASS'
