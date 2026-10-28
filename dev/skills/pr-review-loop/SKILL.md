---
name: pr-review-loop
description: >-
  Use when a PR against main is open, updated, or failing — the mechanics of
  running its review loop. Covers reading a Copilot review without missing the
  suppressed bucket, the API traps that silently report a clean round, the
  separate-agent substitute when Copilot does not review, and the pointer to
  delegate-routing for three blind checks. Load it when you are actually
  operating the loop; the trigger and the decision rules are always-on in the
  repository operating policy.
---

# PR review loop — mechanics

The operating policy owns WHEN to do these things and WHOSE job it is. This
skill owns HOW, because the how is a pile of API traps that each produce a
confident wrong answer, and none of it is needed until a PR actually exists.

## Reading a Copilot review

Copilot writes findings in TWO places and only one creates a thread.

**Bucket 1 — inline comments** become resolvable threads and gate the merge.
Read them with GraphQL, not the REST comments endpoint:

```bash
gh api graphql -f query='
query { repository(owner:"OWNER", name:"REPO") {
  pullRequest(number:N) { reviewThreads(first:100) {
    nodes { id isResolved path comments(first:1){nodes{author{login} body}} } } } } }' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)'
```

`first:100` is the maximum page size, and it is a CAP, not a guarantee. A PR
with more threads than that returns a truncated set with no error — which is
this document's own failure mode, a query that reports a clean round it never
established. Check `pageInfo.hasNextPage` and page through `endCursor` before
concluding a PR has no unresolved threads.

REST attributes the same output to two DIFFERENT logins —
`copilot-pull-request-reviewer[bot]` on `/pulls/N/reviews`, plain `Copilot` on
`/pulls/N/comments` — so filtering comments by the bot login returns zero while
gating threads are open. Measured on PR #614: four unresolved threads invisible,
and since threads block merge it presented as a PR that would not land. GraphQL
sidesteps it and returns the `isResolved` and thread id you need anyway.

**Bucket 2 — a `<details>` block in the review BODY.** No thread, nothing to
resolve, invisible to every thread query.

```bash
gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
  --jq '[.[]|select(.user.login=="copilot-pull-request-reviewer[bot]")]|last|.body'
```

**Print the whole body. Never grep it for a heading.** The block's title is not
stable — `Comments suppressed due to low confidence (N)` and plain
`Suppressed comments (N)` have both shipped. A phrase grep that returns empty is
indistinguishable from a clean bucket, which makes the failure silent and
self-confirming. On PR #568 the suppressed bucket produced 7 genuine findings
against the gating bucket's 2; the confidence signal was inverted.

`--paginate` is load-bearing: the endpoint pages at 30 and `last` on page one is
an OLD review that reads exactly like a fresh clean one.

**"generated no new comments" describes bucket 1 only.** It has appeared in the
same body as a suppressed finding.

## Watching a PR

Every wait on a PR uses one watcher, `scripts/pr-watch.sh` in this skill's
directory (in this repository, `dev/skills/pr-review-loop/scripts/pr-watch.sh`).
Run it in the background (`run_in_background`) for every PR you own or wait on,
all PRs of a stack in one call, so its exit is the one notification:

```bash
scripts/pr-watch.sh [--repo OWNER/REPO] [--interval 30] [--settle 60] [--timeout 21600] PR [PR...]
```

It snapshots each PR at start and exits 0 on the first poll that sees a change,
printing every change from that poll as `#<pr> <event>`: `merged <sha>`,
`closed`, `reopened`, `ready`, `draft`, `head-moved <old>-><new>`,
`base <old>-><new>`, `auto-merge armed <method>`, `auto-merge disarmed`,
`dirty`, `check-failed <name> <link>`, `checks-green`, `rerun-cancelled <run>`,
`review <login> <STATE> on <sha>: <first line>` and
`thread-new <path>:<line> <first line>`. Exit 2 means ten polls in a row failed
to read GitHub, 3 a timeout and 64 a usage error.

The baseline is the state at start, so re-arm after each wake once you have
acted on it, and stop the watcher when the PR is done. Act on each event:

- **`check-failed`**: read that job's log, fix, push and re-arm. It fires on the
  FIRST failure while slow Darwin legs still run; `gh pr checks --watch` and
  `--fail-fast` wait for pending checks or ignore cancellations.
- **`dirty`**: rebase. A conflicted PR gets no checks, so it reads like slow CI.
- **`review`**: read it as below. Copilot's quota and error replies arrive as
  `COMMENTED` reviews, and the first line shows which one this is.
- **`rerun-cancelled`** appears once the other checks are green, even right
  after re-arming: run `gh run rerun <run>` so the superseded run's required
  contexts clear, then re-arm. Runs older than GitHub's 30-day rerun window are
  never asked for; push or dispatch to get fresh checks instead.

The guards each close a way a hand-written watcher reported the wrong thing:

- **Checks and reviews belong to the head.** It reads checks for the PR's
  current head commit, so the previous commit's finished checks never pass for a
  new push, and a moved head is its own event. A review of an older commit is
  not an event; every new review of the head is, two from one author included.
- **No checks is not green.** `checks-green` needs at least one check and none
  pending. A stacked PR may have none at all; that is silence, not an event.
- **Cancelled duplicates.** A cancelled check whose Actions run has a newer run
  of the same workflow on the same head, still running or successful, is not a
  failure. A failed job, even inside that cancelled run, still wakes you.
- **A failed read is never an event.** An empty, failed or hung `gh` call is
  retried next poll; it cannot read as "head moved" or "checks gone". Each call
  is cut off after 60 s or at `--timeout`, whichever comes first, and killed 2 s
  later if it ignores the signal.
- **Late checks.** Jobs that wait on other jobs create their checks later, so a
  settled-looking snapshot can cover only the first batch. `checks-green` waits
  until the checks have stayed green for `--settle` seconds. Checks that were
  green at the start report `checks-green` only after a non-green poll.

`UNSTABLE` on the PR is not a failure — it means "not all green yet" and covers
pending. `DIRTY` is the one that means stop waiting and rebase.

## Watching a dispatched CI run

A stacked PR (base is another PR's branch) gets no automatic checks, so an empty
check list there is expected, not a failure. After a substantive change, not a
pure rebase, dispatch CI and watch that one run with the script below, beside
`pr-watch.sh`. It is separate because it waits on one Actions run, not on the
PR: any other check on the commit, such as Copilot's, would satisfy
`checks-green` before the dispatched run exists.

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
repo=OWNER/REPO
branch=$(git branch --show-current) head=$(git rev-parse HEAD)
gh() { timeout 60 gh "$@"; } # runs the real gh; it sets no HTTP timeout
# gh prints the new run's URL: watch that run, never one picked from a list.
url=$(gh workflow run ci.yml --repo "$repo" --ref "$branch")
run=${url##*/}
[[ $run =~ ^[0-9]+$ ]] || { echo "no run URL from gh: $url"; exit 1; }
sha=$(gh run view "$run" --repo "$repo" --json headSha --jq .headSha)
[ "$sha" = "$head" ] || { echo "run $run is for $sha, not $head"; exit 1; }
deadline=$((SECONDS + 3 * 3600))
while [ "$SECONDS" -lt "$deadline" ]; do
  view=$(gh run view "$run" --repo "$repo" --json status,conclusion,jobs)
  failed=$(jq -r '[.jobs[] | select(.conclusion | IN("failure", "cancelled",
    "timed_out", "action_required", "startup_failure")) | .name] | join(", ")' <<<"$view")
  [ -z "$failed" ] || { echo "run $run failed: $failed"; exit 1; }
  if [ "$(jq -r .status <<<"$view")" = completed ]; then
    [ "$(jq -r .conclusion <<<"$view")" = success ] && exit 0
    echo "run $run ended $(jq -r .conclusion <<<"$view")"
    exit 1
  fi
  sleep 30
done
echo "run $run still running after 3 hours"
exit 1
```

It watches the run `gh workflow run` created, checked against the pushed commit,
so no other run can pass for it. It stops on the first failed job instead of
waiting for the slowest one, and every `gh` call has a time limit.

## Deciding whether a review is yours to read

Three states look alike and only one means "reviewed, nothing found".

```bash
# did a review run on THIS commit? gate on commit_id, never a timestamp
gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
  --jq '[.[]|select(.user.login=="copilot-pull-request-reviewer[bot]")]|last|.commit_id'
# did the reviewer run at all on the head SHA?
gh api --paginate "repos/OWNER/REPO/commits/<head-sha>/check-runs" \
  --jq '.check_runs[]|select(.name=="copilot-pull-request-reviewer")|.status'
```

A review of an OLDER commit still advances `submitted_at`, so a timestamp
baseline reports a stale review as fresh. Absent run = nothing ran. `completed`
plus an error body = it ran and produced nothing.

**A zero-finding round is clean ONLY if the body says the review ran.** Both
"Copilot encountered an error and was unable to review" and the quota refusal
arrive as `state: COMMENTED` with zero threads — every mechanical signal reads
"reviewed, nothing found".

## Re-requesting

Only ever after a significant change since the last run (the operating policy
defines significant). Request the review through REST with the real reviewer
login:

```bash
gh api --method POST "repos/OWNER/REPO/pulls/N/requested_reviewers" \
  -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

The request is not the confirmation. The POST returns the entire pull request
object on success, so HTTP 200 proves nothing on its own. Poll for the
`copilot-pull-request-reviewer` check run on the head SHA. A request issued
while a review is in flight is silently dropped.

GraphQL has no `requestCopilotReview` mutation. In a session that actually has
the GitHub MCP server configured, its `request_copilot_review` operation is an
alternative. The identifier shown by the client is PREFIXED and varies by MCP
client config, so match on the trailing segment rather than the full name.

## Separate-agent review

The repository operating policy owns the triggers and scope. For local review,
follow the delegate-routing skill's **Work and review** workflow, including its
Subtractive rubric, single-reviewer path and three blind checks. Keep reviewers
read-only: forbid mutating git commands because sibling worktrees hold live
edits. Record dismissed findings by title and count, and their dispositions in
the PR body.

Findings are unbounded, so bound the contest before adding lenses: a 94-line
docs PR once produced 28 findings and a 59-agent run.
