#!/usr/bin/env bash
# cspell:words fromdateiso
# shellcheck disable=SC2016 # $ in the GraphQL and jq programs is theirs
# pr-watch.sh — exit on the first change to any watched pull request.
#
#   pr-watch.sh [--repo OWNER/REPO] [--interval S] [--settle S] [--timeout S] PR [PR...]
#
# Takes a baseline per PR, polls, and prints one "#<pr> <event>" line per
# change seen in the poll that found any. Exit 0 on events, 2 after ten
# consecutive failed polls, 3 on timeout, 64 on a usage error.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

usage() {
  echo "usage: pr-watch.sh [--repo OWNER/REPO] [--interval S] [--settle S] [--timeout S] PR [PR...]" >&2
  exit 64
}

repo='' interval=${PR_WATCH_INTERVAL:-30} timeout=${PR_WATCH_TIMEOUT:-21600}
settle=${PR_WATCH_SETTLE:-60} prs=()
while [ $# -gt 0 ]; do
  case $1 in
  --repo | --interval | --settle | --timeout) [ $# -ge 2 ] || usage ;;&
  --repo) repo=$2 ;;
  --interval) interval=$2 ;;
  --settle) settle=$2 ;;
  --timeout) timeout=$2 ;;
  [0-9]*) prs+=("$1") && shift && continue ;;
  *) usage ;;
  esac
  shift 2
done
for n in "${prs[@]}" "$interval" "$settle" "$timeout"; do [[ $n =~ ^[0-9]+$ ]] || usage; done
[ "${#prs[@]}" -gt 0 ] || usage

# The deadline is in milliseconds: SECONDS ticks on wall-clock seconds, so a
# short --timeout could expire milliseconds after the start.
now_ms() {
  local t=${EPOCHREALTIME//[!0-9]/}
  echo $((10#$t / 1000))
}
left_ms() { echo $((deadline - $(now_ms))); }
secs() { printf '%d.%03d' $(($1 / 1000)) $(($1 % 1000)); } # MS -> S.mmm
deadline=$(($(now_ms) + timeout * 1000))

err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

timed_out() {
  echo "pr-watch: no change on ${prs[*]} after ${timeout}s" >&2
  exit 3
}

# gh sets no HTTP timeout, so bound every call by 60 s and by the time left: a
# hung call fails its poll instead of outliving --timeout. timeout(1) without
# --foreground signals gh's whole process group; -k kills a call that ignores
# TERM, so a call ends at most 2 s past its limit.
gh_bounded() {
  local left
  left=$(left_ms) || return 1
  [ "$left" -gt 0 ] || { echo "deadline reached: gh $1 $2" >"$err_file" && return 1; }
  timeout -k 2 "$(secs $((left < 60000 ? left : 60000)))" gh "$@"
}

if [ -z "$repo" ]; then
  if ! repo=$(gh_bounded repo view --json nameWithOwner --jq .nameWithOwner 2>"$err_file"); then
    [ "$(left_ms)" -gt 0 ] || timed_out
    usage
  fi
fi
[[ $repo == */* ]] || usage
owner=${repo%%/*} name=${repo#*/}

pr_query='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){
  pullRequest(number:$pr){state isDraft headRefOid baseRefName mergeStateStatus
    autoMergeRequest{mergeMethod} reviews(last:100){nodes{id author{login} state commit{oid} body}}}}}'
threads_query='query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){repository(owner:$owner,name:$name){
  pullRequest(number:$pr){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}
    nodes{id isResolved path line comments(first:1){nodes{body}}}}}}}'
checks_query='query($owner:String!,$name:String!,$oid:GitObjectID!,$endCursor:String){repository(owner:$owner,name:$name){
  object(oid:$oid){...on Commit{statusCheckRollup{contexts(first:100,after:$endCursor){pageInfo{hasNextPage endCursor}
    nodes{__typename ...on CheckRun{name status conclusion detailsUrl checkSuite{workflowRun{databaseId}}}
      ...on StatusContext{context state targetUrl}}}}}}}}'

# An empty or failed call is "unknown", never a state: callers retry next poll.
call() {
  local out
  out=$(gh_bounded "$@" 2>"$err_file") || return 1
  [ -n "$out" ] || { echo "empty response: gh $1 $2" >"$err_file" && return 1; }
  printf '%s\n' "$out"
}

# snapshot PR -> one normalized JSON state. Runs under `if`, where errexit is
# off, so every step returns explicitly.
snapshot() {
  local pr=$1 meta head threads checks runs='{}'
  meta=$(call api graphql -f query="$pr_query" -f owner="$owner" -f name="$name" -F pr="$pr") || return 1
  head=$(jq -er '.data.repository.pullRequest.headRefOid | strings' <<<"$meta") || return 1
  threads=$(call api graphql --paginate -f query="$threads_query" -f owner="$owner" -f name="$name" -F pr="$pr") || return 1
  jq -se 'all(.[]; .data.repository.pullRequest.reviewThreads.nodes | type == "array")' <<<"$threads" >/dev/null || return 1
  checks=$(call api graphql --paginate -f query="$checks_query" -f owner="$owner" -f name="$name" -f oid="$head") || return 1
  jq -se 'all(.[]; .data.repository.object | type == "object")' <<<"$checks" >/dev/null || return 1
  # Actions runs are only needed to classify a failed or cancelled check.
  if jq -se 'any(.[].data.repository.object.statusCheckRollup.contexts.nodes[]?;
      .conclusion != null and (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED") | not))' \
    <<<"$checks" >/dev/null; then
    runs=$(call api --paginate "repos/$repo/actions/runs?head_sha=$head&per_page=100") || return 1
  fi
  jq -n --argjson meta "$meta" --slurpfile threads <(printf '%s' "$threads") \
    --slurpfile checks <(printf '%s' "$checks") --slurpfile runs <(printf '%s' "$runs") '
    def bucket: if .__typename == "StatusContext" then
        ({SUCCESS: "pass", PENDING: "pending", EXPECTED: "pending"}[.state] // "fail")
      elif .status != "COMPLETED" then "pending"
      else ({SUCCESS: "pass", NEUTRAL: "pass", SKIPPED: "pass", CANCELLED: "cancel"}[.conclusion] // "fail") end;
    $meta.data.repository.pullRequest as $p |
    [$runs[].workflow_runs[]? | select(.head_sha == $p.headRefOid)] as $r |
    # A cancelled run with a newer run of the same workflow on this head that is
    # still going or succeeded is a superseded duplicate, not a failure.
    def replacements: (.run as $id | $r | map(select(.id == $id)) | first) as $run |
      if $run.conclusion == "cancelled" then [$r[] | select(.workflow_id == $run.workflow_id
        and .id > $run.id and (.status != "completed" or .conclusion == "success"))] else [] end;
    [$checks[].data.repository.object.statusCheckRollup.contexts.nodes[]? |
      {name: (.name // .context), link: (.detailsUrl // .targetUrl // ""),
       run: .checkSuite.workflowRun.databaseId, bucket: bucket}] as $c |
    # Only a cancelled check can be superseded; a failed job stays a failure even
    # when its run was later cancelled and replaced.
    [$c[] | select(.bucket == "fail" or .bucket == "cancel") |
      . + {repl: (if .bucket == "cancel" then replacements else [] end)}] as $bad |
    {head: $p.headRefOid, state: $p.state, draft: $p.isDraft, base: $p.baseRefName,
     automerge: ($p.autoMergeRequest.mergeMethod // "none"), dirty: ($p.mergeStateStatus == "DIRTY"),
     failed: [$bad[] | select(.repl == []) | {name, link}],
     # Green needs a check, and every non-pass check superseded by a success.
     green: (($c | length) > 0 and all($c[]; .bucket != "pending")
       and all($bad[]; any(.repl[]; .conclusion == "success"))),
     # GitHub refuses to rerun a run older than 30 days, so only ask for newer ones.
     rerun: [$bad[] | select(.repl != []) | .run | select(. as $id | $r[] | select(.id == $id) |
       (.created_at // "") | . == "" or fromdateiso8601 > now - 30 * 86400)] | unique,
     # Each review of the head, oldest first. A review of an older commit is not
     # news about this head. The query reads the newest 100, so only more than
     # 100 new reviews between two polls could hide one.
     reviews: [$p.reviews.nodes[] | select(.commit.oid == $p.headRefOid) |
       {id, login: (.author.login // "ghost"), state, commit: .commit.oid, body: (.body // "")}],
     threads: [$threads[].data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) |
       {id, path, line, body: (.comments.nodes[0].body // "")}]}'
}

# events PR BASELINE CURRENT SETTLED WAS_GREEN -> "#<pr> <event>" lines.
events() {
  jq -nr --arg pr "$1" --argjson a "$2" --argjson b "$3" --argjson settled "$4" --argjson was_green "$5" '
    def short: .[0:8];
    def first_line: [splits("\r?\n") | select(test("\\S"))] | (first // "(no body)") | .[0:160];
    (if $a.state != $b.state then
       {MERGED: "merged \($b.head | short)", CLOSED: "closed", OPEN: "reopened"}[$b.state] else empty end),
    (if $a.draft != $b.draft then (if $b.draft then "draft" else "ready" end) else empty end),
    (if $a.head != $b.head then "head-moved \($a.head | short)->\($b.head | short)" else empty end),
    (if $a.base != $b.base then "base \($a.base)->\($b.base)" else empty end),
    (if $a.automerge != $b.automerge then (if $b.automerge == "none" then "auto-merge disarmed"
       else "auto-merge armed \($b.automerge | ascii_downcase)" end) else empty end),
    (if $b.dirty and ($a.dirty | not) then "dirty" else empty end),
    ($b.failed[] | select(. as $f | any($a.failed[]; . == $f) | not) | "check-failed \(.name) \(.link)"),
    (if $b.green and $settled and ($was_green | not) and $a.head == $b.head then
       "checks-green" else empty end),
    # A superseded cancelled run needs a rerun whatever the baseline was, so a
    # re-armed watcher still asks for it.
    (if $b.green and $settled then ($b.rerun[] | "rerun-cancelled \(.)") else empty end),
    ($b.reviews[] | select(.id as $id | any($a.reviews[]; .id == $id) | not) |
       "review \(.login) \(.state) on \(.commit | short): \(.body | first_line)"),
    ($b.threads[] | select(.id as $id | any($a.threads[]; .id == $id) | not) |
       "thread-new \(.path):\(.line // "?") \(.body | first_line)")
    | "#\($pr) \(.)"'
}

# was_green: the checks have been green at every poll since the baseline, so a
# green now is not news. Any non-green poll clears it, so green -> pending ->
# green reports again.
declare -A baseline green_since was_green
fails=0
while :; do
  report='' failed=''
  for pr in "${prs[@]}"; do
    if ! snap=$(snapshot "$pr"); then
      failed=1
      continue
    fi
    if [ -z "${baseline[$pr]:-}" ]; then
      baseline[$pr]=$snap
      was_green[$pr]=$(jq .green <<<"$snap")
      continue
    fi
    # Jobs that wait on other jobs add their checks later, so green must hold
    # for $settle seconds before it counts.
    if jq -e .green <<<"$snap" >/dev/null; then
      green_since[$pr]=${green_since[$pr]:-$SECONDS}
    else
      unset 'green_since[$pr]'
      was_green[$pr]=false
    fi
    settled=false
    if [ -n "${green_since[$pr]:-}" ] && [ $((SECONDS - green_since[$pr])) -ge "$settle" ]; then
      settled=true
    fi
    # A moved head's checks are not settled, whatever the old head's were.
    if [ "$(jq -r .head <<<"$snap")" != "$(jq -r .head <<<"${baseline[$pr]}")" ]; then
      settled=false
    fi
    out=$(events "$pr" "${baseline[$pr]}" "$snap" "$settled" "${was_green[$pr]}")
    [ -z "$out" ] || report+=$out$'\n'
  done
  if [ -n "$report" ]; then
    printf '%s' "$report"
    exit 0
  fi
  if [ -n "$failed" ]; then
    fails=$((fails + 1))
    if [ "$fails" -ge 10 ]; then
      echo "pr-watch: $fails consecutive polls failed; last error: $(head -c 300 "$err_file")" >&2
      exit 2
    fi
  else
    fails=0
  fi
  left=$(left_ms)
  [ "$left" -gt 0 ] || timed_out
  sleep "$(secs $((interval * 1000 < left ? interval * 1000 : left)))"
done
