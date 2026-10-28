#!/usr/bin/env bash
# Offline test for dev/skills/pr-review-loop/scripts/pr-watch.sh against a stub
# gh. Run directly, or through checks.pr-watch:
#   bash checks/workflow/pr-watch.test.sh [path/to/pr-watch.sh]
#
# The stub serves fixtures from $FIX/<pr>/<poll>/<kind>.json, where <kind> is
# meta, threads, checks or runs and <poll> counts that PR's meta calls. A poll
# without a fixture reuses the latest earlier one; no fixture at all, or a
# "<kind>.fail" file, makes the call fail. A "<kind>.hang" file makes it hang,
# and "<kind>.hang-term" makes it hang while ignoring TERM.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

here=$(cd "$(dirname "$0")" && pwd)
script=${1:-$here/../../dev/skills/pr-review-loop/scripts/pr-watch.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
{
  command -v bash | sed 's|^|#!|'
  cat <<'STUB'
set -euETo pipefail
kind=meta pr=
for arg; do
  case $arg in
    pr=*) pr=${arg#pr=} ;;
    *reviewThreads*) kind=threads ;;
    *statusCheckRollup*) kind=checks ;;
    repos/*/actions/runs*) kind=runs ;;
  esac
done
if [ "$kind" = meta ]; then
  poll=$(($(cat "$FIX/.poll.$pr" 2>/dev/null || echo 0) + 1))
  echo "$poll" >"$FIX/.poll.$pr"
  echo "$pr" >"$FIX/.current"
fi
pr=$(cat "$FIX/.current")
poll=$(cat "$FIX/.poll.$pr")
[ ! -e "$FIX/$pr/$poll/$kind.fail" ] || exit 1
[ ! -e "$FIX/$pr/$poll/$kind.hang" ] || exec sleep 300
if [ -e "$FIX/$pr/$poll/$kind.hang-term" ]; then trap '' TERM && exec sleep 300; fi
for ((p = poll; p >= 1; p--)); do
  if [ -e "$FIX/$pr/$p/$kind.json" ]; then cat "$FIX/$pr/$p/$kind.json" && exit 0; fi
done
exit 1
STUB
} >"$work/bin/gh"
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH"

H1=5788f8d5ae2514f9d354e0101d7eb75740aef6e5 H2=def67890aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RUNS=https://github.com/o/r/actions/runs

# Fixture builders; each takes an optional jq update applied to the default.
meta() {
  jq -nc --arg h "$H1" "{state: \"OPEN\", isDraft: false, headRefOid: \$h, baseRefName: \"main\",
    mergeStateStatus: \"BLOCKED\", autoMergeRequest: null, reviews: {nodes: []}} | ${1:-.} |
    {data: {repository: {pullRequest: .}}}"
}
threads() { jq -nc "[${1:-}] | {data: {repository: {pullRequest: {reviewThreads:
  {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}}"; }
checks() { jq -nc "[${1:-}] | {data: {repository: {object: {statusCheckRollup:
  {contexts: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: .}}}}}}"; }
check() { # check NAME STATUS CONCLUSION RUN JOB
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"detailsUrl":"%s/%s/job/%s","checkSuite":{"workflowRun":{"databaseId":%s}}}' \
    "$1" "$2" "$3" "$RUNS" "$4" "$5" "$4"
}
runs() { jq -nc --arg h "$H1" "[${1:-}] | map(. + {head_sha: \$h}) | {workflow_runs: .}"; }

# put PR POLL KIND JSON
put() { mkdir -p "$FIX/$1/$2" && printf '%s' "$4" >"$FIX/$1/$2/$3.json"; }
fresh() {
  FIX=$(mktemp -d "$work/fix.XXXX")
  export FIX
  put 1 1 meta "$(meta)"
  put 1 1 threads "$(threads)"
  put 1 1 checks "$(checks)"
}

pass=0 fail=0
# expect NAME EXIT EXPECTED-STDOUT [PRS...]
expect() {
  local name=$1 want_rc=$2 want=$3 got rc=0
  shift 3
  got=$(timeout 60 bash "$script" --repo o/r --interval 0 --settle 0 --timeout 10 "${@:-1}" 2>"$work/err") || rc=$?
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
    echo "ok   - $name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s: exit %s (want %s)\n  got:  %s\n  want: %s\n  err:  %s\n' \
      "$name" "$rc" "$want_rc" "$got" "$want" "$(cat "$work/err")" >&2
    fail=$((fail + 1))
  fi
}
polls() { grep -qx "$1" "$FIX/.poll.${2:-1}" || { echo "FAIL - expected $1 polls" >&2 && fail=$((fail + 1)); }; }

fresh
put 1 3 meta "$(meta '.state = "MERGED"')"
expect "no change, then merged" 0 "#1 merged 5788f8d5"
polls 3

fresh
put 1 1 meta "$(meta '.isDraft = true')"
put 1 2 meta "$(meta)"
expect "draft to ready" 0 "#1 ready"

fresh
put 1 2 meta "$(meta ".headRefOid = \"$H2\"")"
expect "head moved" 0 "#1 head-moved 5788f8d5->def67890"

# Green on a new head is that head's business: report only the move.
fresh
put 1 1 checks "$(checks "$(check build IN_PROGRESS null 1 1)")"
put 1 2 meta "$(meta ".headRefOid = \"$H2\"")"
put 1 2 checks "$(checks "$(check build COMPLETED '"SUCCESS"' 1 1)")"
expect "green with a moved head reports only the move" 0 "#1 head-moved 5788f8d5->def67890"

# A rerun the new head still needs is reported after re-arming on it.
fresh
put 1 2 meta "$(meta ".headRefOid = \"$H2\"")"
put 1 2 checks "$(checks "$(check lint COMPLETED '"CANCELLED"' 100 1),$(check lint COMPLETED '"SUCCESS"' 101 2)")"
put 1 2 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled"},
  {id: 101, workflow_id: 7, status: "completed", conclusion: "success"}' | jq -c --arg h "$H2" '.workflow_runs |= map(.head_sha = $h)')"
expect "head move with a pending rerun" 0 "#1 head-moved 5788f8d5->def67890"
expect "re-armed watcher still asks for the rerun" 0 "#1 rerun-cancelled 100"

# A cancelled run past GitHub's 30-day rerun window is never asked for again.
fresh
put 1 1 checks "$(checks "$(check lint COMPLETED '"CANCELLED"' 100 1),$(check lint COMPLETED '"SUCCESS"' 101 2)")"
put 1 1 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled", created_at: "2020-01-01T00:00:00Z"},
  {id: 101, workflow_id: 7, status: "completed", conclusion: "success", created_at: "2020-01-02T00:00:00Z"}')"
expect "no rerun request for an expired run" 3 "" --timeout 1 1

fresh
put 1 1 meta "$(meta '.baseRefName = "feat/x"')"
put 1 2 meta "$(meta)"
expect "base changed" 0 "#1 base feat/x->main"

fresh
put 1 2 meta "$(meta '.autoMergeRequest = {mergeMethod: "SQUASH"}')"
expect "auto-merge armed" 0 "#1 auto-merge armed squash"

fresh
put 1 2 meta "$(meta '.mergeStateStatus = "DIRTY"')"
expect "conflict" 0 "#1 dirty"

darwin="build (aarch64-darwin, macos-latest)"
fresh
put 1 1 checks "$(checks "$(check "$darwin" IN_PROGRESS null 100 1),$(check lint IN_PROGRESS null 100 2)")"
put 1 2 checks "$(checks "$(check "$darwin" COMPLETED '"FAILURE"' 100 1),$(check lint IN_PROGRESS null 100 2)")"
put 1 2 runs "$(runs '{id: 100, workflow_id: 7, status: "in_progress", conclusion: null}')"
expect "first failure while others pend" 0 "#1 check-failed $darwin $RUNS/100/job/1"

fresh
put 1 2 checks "$(checks "$(check lint COMPLETED '"CANCELLED"' 100 1),$(check lint IN_PROGRESS null 101 2)")"
put 1 2 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled"},
  {id: 101, workflow_id: 7, status: "in_progress", conclusion: null}')"
put 1 3 checks "$(checks "$(check lint COMPLETED '"CANCELLED"' 100 1),$(check lint COMPLETED '"FAILURE"' 101 2)")"
put 1 3 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled"},
  {id: 101, workflow_id: 7, status: "completed", conclusion: "failure"}')"
# Silent at poll 2; once the replacement fails, the cancel is no longer superseded.
expect "cancelled duplicate waits for its replacement" 0 "#1 check-failed lint $RUNS/100/job/1
#1 check-failed lint $RUNS/101/job/2"
polls 3

fresh
put 1 1 checks "$(checks "$(check lint IN_PROGRESS null 100 1)")"
put 1 2 checks "$(checks "$(check lint COMPLETED '"SUCCESS"' 100 1),$(check copilot COMPLETED '"SUCCESS"' 9 3)")"
expect "all green" 0 "#1 checks-green"

# A later batch of checks resets the settle wait: no checks-green at poll 2.
fresh
put 1 2 checks "$(checks "$(check lint COMPLETED '"SUCCESS"' 100 1)")"
put 1 3 checks "$(checks "$(check lint COMPLETED '"SUCCESS"' 100 1),$(check late IN_PROGRESS null 100 2)")"
put 1 4 checks "$(checks "$(check lint COMPLETED '"SUCCESS"' 100 1),$(check late COMPLETED '"FAILURE"' 100 2)")"
put 1 4 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "failure"}')"
expect "green waits to settle" 0 "#1 check-failed late $RUNS/100/job/2" --settle 30 1
polls 4

fresh
put 1 1 checks "$(checks "$(check lint COMPLETED '"CANCELLED"' 100 1),$(check lint IN_PROGRESS null 101 2)")"
put 1 1 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled"},
  {id: 101, workflow_id: 7, status: "in_progress", conclusion: null}')"
put 1 2 checks "$(checks "$(check lint COMPLETED '"CANCELLED"' 100 1),$(check lint COMPLETED '"SUCCESS"' 101 2)")"
put 1 2 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled"},
  {id: 101, workflow_id: 7, status: "completed", conclusion: "success"}')"
expect "green past a superseded cancel" 0 "#1 checks-green
#1 rerun-cancelled 100"

# Only a cancelled job is superseded: a failed job in a run that was later
# cancelled and replaced is still a failure.
fresh
put 1 2 checks "$(checks "$(check lint COMPLETED '"FAILURE"' 100 1),$(check lint COMPLETED '"SUCCESS"' 101 2)")"
put 1 2 runs "$(runs '{id: 100, workflow_id: 7, status: "completed", conclusion: "cancelled"},
  {id: 101, workflow_id: 7, status: "completed", conclusion: "success"}')"
expect "failed job in a replaced cancelled run" 0 "#1 check-failed lint $RUNS/100/job/1"

fresh
put 1 1 checks "$(checks "$(check lint COMPLETED '"SUCCESS"' 100 1)")"
put 1 2 checks "$(checks "$(check lint IN_PROGRESS null 100 1)")"
put 1 3 checks "$(checks "$(check lint COMPLETED '"SUCCESS"' 100 1)")"
expect "green, pending, green again" 0 "#1 checks-green"
polls 3

fresh
put 1 1 meta "$(meta '.baseRefName = "feat/x" | .isDraft = true')"
put 1 3 meta "$(meta '.baseRefName = "feat/x"')"
expect "no checks on a stacked PR is not green" 0 "#1 ready"
polls 3

quota="Copilot was unable to review this pull request because the user who requested the review has insufficient quota."
fresh
put 1 2 meta "$(meta ".reviews.nodes = [{id: \"R1\", author: {login: \"copilot-pull-request-reviewer\"},
  state: \"COMMENTED\", commit: {oid: \"$H1\"}, body: \"\n$quota\nMore.\"}]")"
expect "review with a quota refusal" 0 "#1 review copilot-pull-request-reviewer COMMENTED on 5788f8d5: $quota"

review() { # review ID LOGIN OID BODY
  printf '{id: "%s", author: {login: "%s"}, state: "COMMENTED", commit: {oid: "%s"}, body: "%s"}' "$@"
}
fresh
put 1 2 meta "$(meta ".reviews.nodes = [$(review OLD bot "$H2" "old commit")]")"
put 1 3 meta "$(meta ".reviews.nodes = [$(review OLD bot "$H2" "old commit")] | .state = \"CLOSED\"")"
expect "review of an older commit is not an event" 0 "#1 closed"

fresh
put 1 2 meta "$(meta ".reviews.nodes = [$(review R1 bot "$H1" first),$(review R2 bot "$H1" second)]")"
expect "two new reviews by one author" 0 "#1 review bot COMMENTED on 5788f8d5: first
#1 review bot COMMENTED on 5788f8d5: second"

fresh
put 1 1 threads "$(threads '{id: "T1", isResolved: false, path: "a.sh", line: 1, comments: {nodes: [{body: "old"}]}}')"
put 1 2 threads "$(threads '{id: "T1", isResolved: false, path: "a.sh", line: 1, comments: {nodes: [{body: "old"}]}},
  {id: "T2", isResolved: true, path: "b.sh", line: 2, comments: {nodes: [{body: "done"}]}},
  {id: "T3", isResolved: false, path: "dev/x.sh", line: 12, comments: {nodes: [{body: "Quote this.\nWhy."}]}}')"
expect "new unresolved thread" 0 "#1 thread-new dev/x.sh:12 Quote this."

fresh
put 1 2 meta ''
put 1 3 meta "$(meta)"
put 1 3 checks '{"data":{"repository":{"object":null}}}'
mkdir -p "$FIX/1/4" && touch "$FIX/1/4/threads.fail"
put 1 5 meta "$(meta '.state = "MERGED"')"
put 1 5 checks "$(checks)"
expect "empty and failed calls are not events" 0 "#1 merged 5788f8d5"
polls 5

fresh
put 1 2 meta "$(meta '.isDraft = true')"
put 2 1 meta "$(meta '.autoMergeRequest = {mergeMethod: "SQUASH"}')"
put 2 1 threads "$(threads)"
put 2 1 checks "$(checks)"
put 2 2 meta "$(meta '.state = "MERGED" | .autoMergeRequest = null')"
expect "every event of the poll, across PRs" 0 "#1 draft
#2 merged 5788f8d5
#2 auto-merge disarmed" 1 2

fresh
rm -r "$FIX/1"
expect "ten failed polls exit 2" 2 ""
polls 10

fresh
expect "timeout exits 3" 3 "" --timeout 0 1

fresh
mkdir -p "$FIX/1/2" && touch "$FIX/1/2/meta.hang"
start=$SECONDS
expect "hung gh call ends at the timeout" 3 "" --timeout 1 1
[ $((SECONDS - start)) -le 5 ] || { echo "FAIL - hung gh took $((SECONDS - start))s" >&2 && fail=$((fail + 1)); }
fresh
mkdir -p "$FIX/1/2" && touch "$FIX/1/2/meta.hang-term"
start=$SECONDS
expect "gh ignoring TERM is killed at the timeout" 3 "" --timeout 1 1
[ $((SECONDS - start)) -le 6 ] || { echo "FAIL - TERM-proof gh took $((SECONDS - start))s" >&2 && fail=$((fail + 1)); }

expect "usage error exits 64" 64 "" --bogus

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
