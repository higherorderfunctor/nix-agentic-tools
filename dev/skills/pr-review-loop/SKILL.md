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

## Watching CI without racing it

`gh pr checks <n> --watch` returns IMMEDIATELY with `no checks reported` if it
beats GitHub to creating them, which is the normal case right after a push. The
watcher then exits successfully having watched nothing, and the turn ends on a
green-looking result — the same silent-clean shape as everything else here.

Use this watcher after every push, run in the background from the worktree you
pushed, so its exit is the one notification. It exits non-zero on the first real
failure, a conflict, a timeout or a moved head, and zero only when every check
on the pushed commit has finished and the required ones passed:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
pr=<n> repo=OWNER/REPO
head=$(git rev-parse HEAD) # the commit you just pushed
ready=
for _ in $(seq 1 40); do
  state=$(gh pr view "$pr" --repo "$repo" --json headRefOid,mergeStateStatus)
  if [ "$(jq -r .mergeStateStatus <<<"$state")" = DIRTY ]; then
    echo "DIRTY: rebase"
    exit 1
  fi
  n=$(gh pr checks "$pr" --repo "$repo" --json name --jq length 2>/dev/null || echo 0)
  if [ "$(jq -r .headRefOid <<<"$state")" = "$head" ] && [ "$n" -gt 0 ]; then
    ready=1
    break
  fi
  sleep 15
done
if [ -z "$ready" ]; then
  echo "no checks on $head after 10 minutes"
  exit 1
fi
rerun='{}'
while :; do
  state=$(gh pr view "$pr" --repo "$repo" --json headRefOid,mergeStateStatus)
  if [ "$(jq -r .headRefOid <<<"$state")" != "$head" ] ||
     [ "$(jq -r .mergeStateStatus <<<"$state")" = DIRTY ]; then
    echo "head moved or DIRTY: re-arm on the new head or rebase"
    exit 1
  fi
  checks=$(gh pr checks "$pr" --repo "$repo" --json bucket,link)
  if jq -e 'any(.bucket == "fail" or .bucket == "cancel")' <<<"$checks" >/dev/null; then
    runs=$(gh api --paginate --slurp "repos/$repo/actions/runs?head_sha=$head&per_page=100")
    cancelled=$(jq -n --argjson checks "$checks" --argjson pages "$runs" --argjson rerun "$rerun" --argjson now "$SECONDS" --arg head "$head" '
      [$pages[].workflow_runs[] | select(.head_sha == $head)] as $runs |
      [$checks[] | select(.bucket == "fail" or .bucket == "cancel") |
        . as $check |
        ((.link | capture("/actions/runs/(?<id>[0-9]+)").id)? // "") as $id |
        ($runs | map(select((.id | tostring) == $id)) | first) as $run |
        [$runs[] | select(.id != $run.id and .workflow_id == $run.workflow_id) |
          select(.status != "completed" or .conclusion == "success")] as $replacement |
        ($rerun[$id].links // []) as $old |
        {id: $id, expired: (($old | index($check.link)) != null and $now >= $rerun[$id].deadline),
         defer: (($old | index($check.link)) != null or
           (($old | length) == 0 and $run.conclusion == "cancelled" and ($replacement | length) > 0)),
         ready: (($old | length) == 0 and any($replacement[]; .conclusion == "success"))}]')
    if jq -e 'any(.expired)' <<<"$cancelled" >/dev/null; then
      echo "cancelled rerun checks still stale after 10 minutes"
      exit 1
    fi
    if jq -e 'any(.defer | not)' <<<"$cancelled" >/dev/null; then
      echo "real failure on $head: read the failing job log"
      exit 1
    fi
    while read -r id ready; do
      if [ "$ready" = true ]; then
        echo "replacement succeeded: rerunning cancelled run $id"
        gh run rerun "$id" --repo "$repo"
        rerun=$(jq --arg id "$id" --argjson checks "$checks" --argjson now "$SECONDS" '
          .[$id] = {deadline: ($now + 600), links:
            [$checks[] | select(.link | contains("/actions/runs/" + $id + "/")) | .link]}' <<<"$rerun")
      else
        echo "deferring cancelled run $id while its replacement or rerun updates checks"
      fi
    done < <(jq -r 'unique_by(.id)[] | "\(.id) \(.ready)"' <<<"$cancelled")
    sleep 30
    continue
  fi
  if jq -e 'any(.bucket == "pending")' <<<"$checks" >/dev/null; then
    sleep 30
    continue
  fi
  sleep 60
  again=$(gh pr checks "$pr" --repo "$repo" --json bucket --jq 'any(.bucket == "pending" or .bucket == "fail" or .bucket == "cancel")')
  [ "$again" = true ] || break
done
if [ "$(gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid)" != "$head" ]; then
  echo "head moved past $head: re-arm on the new commit"
  exit 1
fi
gh pr checks "$pr" --repo "$repo" --required
```

Each part closes a way a watcher has reported the wrong thing:

- **The head gate.** Right after a push the count can still be the PREVIOUS
  commit's checks, so a count alone can watch a run that is already over.
- **The count gate and its timeout.** Gating on "is anything PENDING" falls
  through on an empty list; running out of attempts must fail, not carry on.
- **Fail fast on each poll.** Classify every failure before waiting, so while
  checks are active a real failure stops within the thirty-second polling
  interval. A blocking `--watch --fail-fast` does not stop on cancellations
  while any check is pending, which would delay replacement reruns and bypass
  their stale-check deadline.
- **Cancelled duplicates.** A failed check is deferred only when its Actions run
  is cancelled and another run of the same workflow on the same head is
  unfinished or successful. A successful replacement triggers a rerun of the
  cancelled run to clear its required contexts; a real failure still exits
  immediately, even alongside a deferred cancellation. Each cancelled run is
  rerun once; its old check links are deferred while GitHub replaces them, and
  any new failing link is classified normally. Old links persisting for ten
  minutes fail the watcher; head movement or a conflict also stops the deferred
  wait.
- **The re-watch loop.** Jobs that wait on other jobs create their checks later,
  so a settled snapshot can cover only the first batch. Wait sixty seconds and
  recheck for a new batch before finishing.
- **The final head check and `--required`.** `gh pr checks` reads whatever the
  PR's head is now; a later push would otherwise report the newer commit.
- **`DIRTY`.** A conflicted PR gets no checks, so the count gate would wait out
  its whole budget.

`gh pr checks --json` reports failures in `bucket` without a failing exit
status. The watcher classifies every failure and cancelled duplicate explicitly;
read a real failing job's log next.

`UNSTABLE` on the PR is not a failure — it means "not all green yet" and covers
pending. `DIRTY` is the one that means stop waiting and rebase.

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
