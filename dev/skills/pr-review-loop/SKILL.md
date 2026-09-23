---
name: pr-review-loop
description: >-
  Use when a PR against main is open, updated, or failing — the mechanics of
  running its review loop. Covers reading a Copilot review without missing the
  suppressed bucket, the API traps that silently report a clean round, the
  separate-agent substitute when Copilot does not review, and the
  prosecute/defend/judge protocol for complex changes. Load it when you are
  actually operating the loop; the trigger and the decision rules are always-on
  in the git-workflow orientation.
---

# PR review loop — mechanics

The orientation fragment owns WHEN to do these things and WHOSE job it is. This
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

Wait for the checks to EXIST before watching, and gate on the count rather than
on their state:

```bash
for _ in $(seq 1 40); do
  n=$(gh pr checks <n> --repo OWNER/REPO --json name | jq 'length')
  [ "$n" -gt 0 ] && break
  sleep 15
done
gh pr checks <n> --repo OWNER/REPO --watch --interval 30
```

Gating on "is anything PENDING" instead has the same bug with an extra step: an
empty list has nothing pending, so it falls through just as fast.

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

## Requesting a review

The FIRST request is the agent's election, once the work is dev-complete; after
that, only following a significant change since the last run. The orientation
fragment owns both rules. Request through REST with the real reviewer login:

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

Dispatch a reviewer that did not write the code. Give it the diff, an explicit
lens, and the standing instruction that the PR body is an ARGUMENT, not
evidence, and that the author is orchestrating the review and cannot be deferred
to. Read-only: forbid every mutating git command, because sibling worktrees hold
live edits.

Default is ONE independent reviewer. Report dismissed findings by title and
count — a review that reports only confirmed findings is indistinguishable from
one that found nothing — and record the dispositions in the PR body.

## Prosecute / defend / judge

The recipe. WHEN to run it, and the scope limits on it, are stated once in the
git-workflow orientation — do not restate them here.

1. **Prosecute.** An agent whose job is to find why the change is wrong. It may
   not conclude the change is fine.
2. **Defend.** A separate agent arguing the change is correct. It may not
   concede merely because a fix would be awkward.
3. **Judge.** A third agent, given both cases and the diff, that rules per
   finding on the EVIDENCE rather than the rhetoric.

If the judge cannot converge — it can neither confirm nor dismiss on the
evidence presented — loop, at most three times total, each round narrowed to the
unresolved findings and told what evidence was missing. Still unresolved after
three: surface the split to the operator with both cases. Never self-adjudicate;
that reintroduces the bias the structure exists to remove.

Size the stages separately. Prosecute and defend are judgement work; the
evidence-gathering underneath them is mechanical and belongs on a cheaper model.
Findings are unbounded, so bound the contest phase before adding lenses — a
94-line docs PR once produced 28 findings and a 59-agent run.
