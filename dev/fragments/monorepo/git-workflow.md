## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-07-30 (commit pending — records that a re-request
> issued while a review is still in flight is silently dropped, so the check
> run, not the API response, is the confirmation). Prior: 2026-07-30 (commit
> d42d805a) — records that the reviews and comments endpoints attribute
> Copilot's output to DIFFERENT logins, so the documented
> `copilot-pull-request-reviewer[bot]` filter returns zero on
> `/pulls/N/comments` and reads as a clean review while gating threads are open;
> measured on PR #614. Prior: 2026-07-29 — the ruleset now sets
> `required_review_thread_resolution: true`, so an unresolved review thread
> blocks merge including on auto-merging `update/*` PRs, and the claim that
> Copilot "never gates its merge" is retired; adds the rule that Copilot's
> SUPPRESSED findings must be read on every review, since they create no thread;
> gates re-review polling on `commit_id` rather than a timestamp, and caps the
> fix-and-re-review loop at 5 rounds). Prior: 2026-07-24 — the bot's `update/*`
> PRs now arm GitHub-native auto-merge and land themselves, the manual
> `pr:merge-updates` task and `merge-update-prs` skill are deleted, the update
> sweep runs 4x/day, and squash-only is re-attributed to the repository settings
> rather than the ruleset. If you change the branch-protection ruleset, the
> repository merge settings, the worktree convention, the bootstrap step, the
> local commit guard, the auto-merge arming, or the PR flow and this fragment
> isn't updated in the same commit, stop and fix it.

`main` is the trunk. Its branch-protection ruleset requires a pull request, no
force-push, no deletion, and four required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`test`, and `gitleaks`. It requires **zero approving reviews** but it DOES
require **every review thread to be resolved**
(`required_review_thread_resolution`, enabled 2026-07-29).

**Squash-merge only** — but that is the REPOSITORY settings, not the ruleset:
`allow_squash_merge` true, `allow_merge_commit` and `allow_rebase_merge` false.
The ruleset's own `allowed_merge_methods` still lists all three, so changing it
there changes nothing. Copilot review runs on every PR from a separate ruleset
rule (`Copilot review for default branch`) that _requests_ a review: not a
required approval and not a required status check.

**But it can now block a merge indirectly**, and that is deliberate. Since
threads must be resolved, an unaddressed Copilot comment holds the PR — a bot
`update/*` PR included, which is the intended trade: nothing auto-merges while a
reviewer has an open question on it. A stalled update PR is not lost; the next
4x/day sweep rebuilds and re-arms it.

### Copilot review: ALWAYS read the suppressed-comments block

Copilot records its findings in two places, and only one of them creates a
thread:

1. **Inline review comments** — these become resolvable threads, appear in
   `pull_request_read` with `method: get_review_comments`, and now gate merge.
2. **A `<details>Comments suppressed due to low confidence (N)</details>` block
   inside the review BODY** — no thread, nothing to resolve, invisible to any
   thread query.

**The two endpoints attribute Copilot to DIFFERENT logins, and mixing them up
reads as a clean review.** `/pulls/N/reviews` credits the review to
`copilot-pull-request-reviewer[bot]`; `/pulls/N/comments` credits the inline
comments to plain `Copilot`. Filtering the comments endpoint by the `[bot]`
login returns ZERO while gating threads are open — measured on PR #614, where
four unresolved threads were invisible and the body's "generated 4 comments"
line was the only tell. Since threads now block merge, that failure mode
presents as a PR that mysteriously will not land.

Prefer the GraphQL `reviewThreads` query over the REST comments endpoint: it
sidesteps the login discrepancy entirely and returns `isResolved` plus the
thread id you need for `resolveReviewThread` anyway.

```bash
gh api graphql -f query='
query {
  repository(owner:"OWNER", name:"REPO") {
    pullRequest(number:N) {
      reviewThreads(first:50) {
        nodes { id isResolved path comments(first:1){nodes{author{login} body}} }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved==false)'
```

**Reading only the threads is not reading the review.** Measured on PR #568
across seven review rounds: the suppressed bucket produced **7 findings, all
genuine**, including a functional bug (`api_protocol` hardcoded while the scheme
was stripped), a regex that could not match bracketed IPv6 hosts, and a doc that
would have had readers create a directory literally named `~`. The gating bucket
over the same period produced two, one of which was a diagnostics improvement
over already-correct behavior. On that sample the confidence signal was
inverted.

So whenever you check Copilot feedback — CLI, MCP, a monitor loop, anything —
fetch the review BODY too, not just the threads:

```bash
gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
  --jq '[.[] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
        | last | .body' | sed -n '/low confidence/,$p'
```

`--paginate` is load-bearing, not tidiness. The endpoint pages at 30, and a PR
that has been through a review loop reaches that easily — #568 took twenty.
Without it `last` returns the last review on the FIRST page, which is an OLD
one, and the answer looks exactly like a fresh clean review.

**Gate on `commit_id`, not on the timestamp.** The only condition that means
"this review saw my code" is the review's `commit_id` equalling the PR head:

```bash
gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
  --jq '[.[] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
        | last | .commit_id'
```

This was arrived at by getting it wrong three times in a row, each fix looking
sufficient until it wasn't:

1. reading `.[-1]` → returns a stale review, reported as new;
2. taking `submitted_at` as a baseline → better, but a review of an OLDER commit
   still advances the timestamp, so it reads as fresh;
3. requiring `commit_id == head` → correct.

A related tell, useful because it needs no baseline at all: **check whether a
check run named `copilot-pull-request-reviewer` exists on the head commit.** A
push does not always trigger a review, and this distinguishes "not run yet" from
"ran and found nothing" — which otherwise look identical.

```bash
gh api --paginate "repos/OWNER/REPO/commits/<head-sha>/check-runs" \
  --jq '.check_runs[] | select(.name=="copilot-pull-request-reviewer") | .status'
```

Absent means it never started, so re-request it; `in_progress` means wait;
`completed` means the review is there to read. Ask for the run BY NAME rather
than counting the checks: a total count is only correct until the CI matrix
changes.

**A re-request issued while a review is still in flight is silently dropped.**
The API returns success, no new check run appears, and the call is
indistinguishable from one that worked. Measured on #614: a push followed
immediately by a re-request left the head commit with NO reviewer check run at
all, while the previous commit's review completed normally and then read as the
"latest" one.

So the request is not the confirmation — the check run is. After requesting,
verify the run exists on the head SHA before trusting it, and if a review is
already running for an older commit, let it land first. This composes with the
`commit_id` gate above: that gate tells you a review is stale, this tells you
why no fresh one is coming.

### Cap the fix-and-re-review loop at 5 rounds

Run at most **five** fix → push → re-trigger → verify rounds, then STOP and get
explicit approval before continuing. Exit earlier if a round returns clean in
BOTH buckets — that is the real terminus.

The failure mode this prevents is not a bad round, it is a good one repeating.
On PR #568 every round produced a genuine finding, so each was individually
defensible while the aggregate churned the PR through eight force-pushes. An
uncapped loop has no guaranteed terminus; the cap makes continuing an operator
decision rather than an emergent property.

At the cap, summarize what was found, what was fixed, and what is outstanding.

Suppressed findings have no thread to resolve, so reply on the PR itself saying
what you did with each. Resolve each gating thread as you fix it — they gate the
merge now, and a PAT-authenticated MCP client cannot resolve them, so use the
GraphQL `resolveReviewThread` mutation through `gh api`.

**Never commit directly to `main`.** Two backstops enforce this. A local
`reject-default-branch-commit` pre-commit hook (installed through devenv's
git-hooks framework) rejects any commit made while the default branch (`main`)
is the checked-out HEAD — caught at _commit_ time, in whichever worktree has
`main` checked out (normally the primary checkout, since git allows a branch in
only one worktree at a time); worktrees on other branches are unaffected, and
`--no-verify` bypasses it by design. Independently, the branch-protection
ruleset rejects the _push_. Still branch **before** you start — the guard is a
safety net, not the workflow.

### Every change goes through an isolated worktree + PR

Worktrees live in `<repo>-worktrees/`, a **sibling of the primary checkout** — a
clone at `~/src/nix-agentic-tools` puts them in
`~/src/nix-agentic-tools-worktrees/<slug>`. Keeping them beside the clone means
a direnv whitelist (or any editor/tooling trust root) covering the checkout
covers new worktrees too, so `cd` alone enters the devenv shell and materializes
the gitignored `files.*` artifacts with no manual step — and it keeps work out
of `~/.cache`, which cache-cleaning tools treat as disposable.

Derive that directory once per shell. This form is correct from **any**
worktree, not just the primary checkout:

```bash
worktrees="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")-worktrees"
```

`--git-common-dir` resolves to the ORIGINAL clone's `.git` even when run from a
linked worktree, so `dirname` of it is always the primary checkout. Do **not**
substitute a bare `../<repo>-worktrees/<slug>`: from a linked worktree that
silently resolves one level too deep, into
`<repo>-worktrees/<repo>-worktrees/<slug>`.

1. Branch off `main` into its own worktree:

   ```bash
   git worktree add -b <type>/<slug> "$worktrees/<slug>" origin/main
   ```

   `<type>` is a Conventional Commits type (`build`, `chore`, `ci`, `docs`,
   `feat`, `fix`, `perf`, `refactor`, `style`, `test`).

2. Bootstrap the new worktree **once**, before its first commit:

   ```bash
   cd "$worktrees/<slug>" && devenv shell   # or any devenv task
   ```

   `.pre-commit-config.yaml` is a devenv `files.*` artifact materialized on
   shell entry, and `git worktree add` runs no devenv — until you do this the
   shared prek hooks have no config to validate against and the commit is
   rejected. With direnv allowed for the parent directory the `cd` is enough on
   its own; that is what the sibling location buys.

3. **Push at the first commit** — not at the end — so the branch is a continuous
   off-machine backup. Open the PR **ready (non-draft) as soon as the work is
   dev-complete**: Copilot review does **not** run on draft PRs in this repo, so
   a draft that is actually ready silently skips review. Reserve **draft** for
   genuine WIP, or when you explicitly want to preview the branch in GitHub
   without review. Draft and ready PRs both get full CI here.

4. Keep pushing as work lands. Flip draft → ready the moment it is dev-complete
   so review can start.

5. Merges are squash merges. The operator performs them for **human** PRs; the
   bot's `update/*` PRs land themselves (next section).

6. Tear the worktree down once merged:

   ```bash
   git worktree remove "$worktrees/<slug>"   # re-derive $worktrees if needed
   git branch -D <type>/<slug>   # squash-merged: -d refuses, -D is correct
   ```

   The remote branch auto-deletes on merge.

### Bot `update/*` PRs land themselves

`.github/workflows/update.yml` sweeps dependencies 4x/day (00:00, 06:00, 12:00,
18:00 UTC) and opens one PR per dependency that actually moved. Each is armed
with GitHub-native **auto-merge (squash)** as it is created, and re-armed on
every later sweep, so it merges itself once the four required checks go green.
Safe precisely because the ruleset requires no approving review and the Copilot
review is advisory: those checks are the only gate, and they are exactly what
auto-merge waits on.

A merge conflict **disables** auto-merge, so a conflicted update PR drops out of
the queue until the next sweep rebuilds its branch on the current base and
re-arms it. Arming is non-fatal too: a failure logs an `Auto-merge not armed`
warning naming the branch and PR, and that PR is the one needing a hand.

There is **no manual merge path** — the `pr:merge-updates` task and
`merge-update-prs` skill that used to batch-merge these are deleted. Do not
reintroduce hand-merging of `update/*` PRs; land the individual stragglers the
pipeline could not, and fix the reason.

### What is shared across worktrees — and what is not

Linked worktrees of one clone share the common `.git` directory, so these are
**shared, not per-worktree**:

- **The hooks directory.** One `core.hooksPath` serves every worktree, and it
  holds git-branchless's hooks (`post-commit`, `post-rewrite`,
  `reference-transaction`, `post-checkout`) alongside the prek hooks. Do NOT
  redirect `core.hooksPath` per worktree: it **replaces** `.git/hooks` with no
  fallback, so branchless's hooks would stop firing in linked worktrees and its
  event log would silently miss every commit made there.
- **The git-branchless event database** (`.git/branchless/db.sqlite3`).
  Serialize stack-skill operations across concurrent worktrees; they are not
  session-isolated.

The prek **config** is the one thing made per-worktree: the
`hooks:isolate-config` devenv task rewrites the installed hooks so they resolve
`.pre-commit-config.yaml` from the _committing_ worktree's toplevel at hook-run
time. That is what stops a shell entry in one worktree from changing what
another worktree validates against.

### Rebasing: back up with a TAG, not a branch

`git rebase --update-refs` (and git-branchless) moves any **branch** that points
into the rebased range — including a backup branch created moments earlier,
silently defeating it. Tags are not moved:

```bash
git tag backup-<slug>-pre-rebase <tip>   # durable across the rebase
```

Lockfile conflicts (`flake.lock`, `devenv.lock`) during a rebase are
**regenerated, never hand-merged**: take the base's copy, then re-run
`nix flake lock` (and let devenv reconcile `devenv.lock`) so the result matches
the merged `flake.nix` / `devenv.yaml`.
