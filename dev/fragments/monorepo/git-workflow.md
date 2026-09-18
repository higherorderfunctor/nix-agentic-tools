## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-09-12 — source paths and ownership guidance follow
> native package assembly.
>
> **Settled — do not relitigate.** Each of these records an approach that was
> TRIED and rejected, so the reasoning is not re-derived from scratch. Full
> lineage: `git show ca236499:dev/fragments/monorepo/git-workflow.md`.
>
> - **Back up with a ref pushed to `origin`, never a local tag or branch.** The
>   tag was tried, on the sound reasoning that `--update-refs` moves branches
>   and not tags. Tags are refs in the COMMON git dir, so any worktree's fetch
>   prunes them all when the author's global `fetch.pruneTags` is set — measured
>   twice on 2026-08-15, the second time by the verifying fetch itself.
> - **Do NOT re-add a `devenv shell` bootstrap to the worktree recipe.** It was
>   required until 2026-08-18 and is now actively wrong under the sandbox-stack
>   topology. `devenv tasks run` was the obvious substitute and does NOT
>   materialize `.pre-commit-config.yaml` either — measured 2026-07-31 in two
>   fresh worktrees, where the task succeeded and the next commit was still
>   rejected.
> - **Do not restore `devenv-test` as a required context.** It was promoted
>   2026-08-03 and demoted two days later as a merge-blocking liability, risk
>   accepted; it left automatic PR/push execution entirely on 2026-08-29.
> - **Do not re-derive a Copilot auto-trigger rate from push observations.** The
>   "1 review in 5 pushes" datum was a ready-transition coinciding with a push,
>   not a flaky trigger. Sampling this way produces a confident wrong model and
>   costs a paid review re-establishing a trigger that fires on readiness only.

`main` is the trunk. Its branch-protection ruleset requires a pull request, no
force-push, no deletion, and six required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`kiro-patched (x86_64-linux, ubuntu-latest)`,
`kiro-patched (aarch64-darwin, macos-latest)`, `test`, and `gitleaks`. Both
`kiro-patched` contexts were promoted 2026-08-13 with PR #895; this file said
"four" until 2026-08-14. It requires **zero approving reviews** but it DOES
require **every review thread to be resolved**
(`required_review_thread_resolution`, enabled 2026-07-29).

The full Devenv Diagnostic is now `workflow_dispatch` only. It was promoted to a
required check on 2026-08-03, demoted on 2026-08-05 after becoming a
merge-blocking liability, and removed from automatic PR/push execution on
2026-08-29 after its deterministic contracts moved under `nix flake check`. Do
not "restore" its old context to make this fragment match historical prose —
read the ruleset:

```bash
gh api "repos/OWNER/REPO/rulesets" --jq '.[] | "\(.id)  \(.name)"'
gh api "repos/OWNER/REPO/rulesets/<id>" \
  --jq '.rules[] | select(.type=="required_status_checks")
        | [.parameters.required_status_checks[].context]'
```

**Squash-merge only** — but that is the REPOSITORY settings, not the ruleset:
`allow_squash_merge` true, `allow_merge_commit` and `allow_rebase_merge` false.
The ruleset's own `allowed_merge_methods` still lists all three, so changing it
there changes nothing. Copilot review comes from a separate ruleset rule
(`Copilot review for default branch`) that _requests_ a review **once per PR,
when it becomes ready** — not on every push (see the trigger model below): it is
neither a required approval nor a required status check.

**But it can now block a merge indirectly**, and that is deliberate. Since
threads must be resolved, an unaddressed Copilot comment holds the PR — a bot
`update/*` PR included, which is the intended trade: nothing auto-merges while a
reviewer has an open question on it. A stalled update PR is not lost; the next
4x/day sweep rebuilds and re-arms it.

### After you open or update a PR, the loop is YOURS

Not the operator's. They should not have to notice CI went red, notice a review
landed, or hand the PR back to you. You are the one still holding the context.

**Never end a turn on a promise.** "I'll check when it lands" with no mechanism
is worse than saying nothing: it looks like ownership and behaves like a block.
Arm something that re-invokes you — a backgrounded watcher whose exit wakes the
session — and only then report. Kill it once the signal arrives.

On every push, including the first:

1. **Watch CI to completion.** Read the exit status of the tool, not a
   notification's summary — a pipeline's status is the last command's, so
   `nix flake check | tail` reports the tail's success. Capture the real code.
2. **A conflicted PR gets ZERO check runs and reads exactly like slow CI.**
   `mergeStateStatus: DIRTY` with an empty check list means rebase, not wait.
   The same shape appears when the base moves under a long-running branch.
3. **React to a red check by reading the failing job's log**, not by guessing
   from the check name. Fix, push, re-arm the watcher.
4. **Then read the review** (next section).

Only report back when the PR is green and reviewed, or when something needs a
decision that is genuinely the operator's.

### Copilot reviews once, automatically. Do not trigger the first one

The ruleset requests it when the PR **becomes ready for review** — which covers
a PR opened non-draft as well as a draft flipped later. It is automatic. Do not
request it by hand, and do not treat an absent run on a fresh push as a missed
trigger: pushes never trigger a review, so absent is the resting state.

**Re-request only after a significant change since the last run.** New scope, a
mechanism the previous review never saw, an approach rewritten rather than
corrected. Applying the review's own findings is NOT a significant change, and
neither is rewording, reformatting or renaming. There is no round count to spend
down — there is one question, asked each time: is there materially new code to
review? Every review after the first is a paid manual request.

Read BOTH buckets. The inline threads gate the merge; the review body carries a
suppressed block that creates no thread and that a heading grep will silently
miss. Reply and resolve each gating thread **in the same turn as the fix**, not
after the checks pass. Mechanics, and the API traps that each report a clean
round that did not happen, are in the `pr-review-loop` skill.

### When Copilot does not review, a SEPARATE agent does

Triggers, any of them: the review errored, the account is out of quota, the PR
never left draft, or `git diff --stat <last-reviewed-sha>...HEAD` shows a change
that would earn a re-request under the test above — a new file or mechanism, or
an approach rewritten rather than corrected.

**You cannot review your own diff.** Reading it back produces agreement, because
the reasoning that wrote the code is the reasoning evaluating it. Dispatch a
reviewer that did not write it, told plainly that the PR body is an argument
rather than evidence and that its author cannot be deferred to. One independent
reviewer is the default. Report what was dismissed as well as what was fixed.

This is not a fallback for one outage. It is the standing substitute whenever
the automatic review did not happen, and github.com Copilot fails on this repo
often enough that it is the common case, not the rare one.

### Escalating past one reviewer: prosecute, defend, judge

Escalate from one independent reviewer to the three-role protocol when EITHER
holds. Do not grade the change's "complexity" — that word routed this decision
before and two agents reading it reached opposite answers.

**(a) You intend to DISMISS a reviewer finding rather than fix it.** Dismissing
your own reviewer's finding is the second discard filter this whole structure
exists to remove, so the intent to dismiss is itself the trigger. One round,
scoped to the disputed findings only.

**(b) The diff touches a shared abstraction.**
`git diff --name-only origin/main...HEAD` matches `lib/**`, `packages/*/lib/**`
or `packages/*/packages/**/*.nix`; or a hunk under `packages/*/modules/**` or
`lib/ai/**` adds, removes or retypes a `mkOption`.

Everything else uses the single-reviewer default. Run the three-role protocol:
an agent that prosecutes, a separate agent that defends, and a third that judges
on evidence. If the judge cannot converge, loop — at most three rounds, each
narrowed to what stayed unresolved. Surface a genuine split to the operator
rather than adjudicating it yourself.

**Scope, deliberately narrow:**

- Only for changes going to `main`. A draft PR, or a long-lived experiment
  branch where the design is not settled yet, forgoes it — if it is a draft, it
  is not ready for this.
- **Local runtimes only, always.** Never hand this to github.com Copilot: it
  cannot be given a model or an effort level, and the cost belongs where those
  controls exist.
- Size the roles separately, and never let a delegate inherit an interactive
  session's model and effort by default — see the delegate-sizing orientation.

The recipe is in the `pr-review-loop` skill. It lives there rather than here
because a skill is the only manual-load carrier that works across runtimes —
Kiro's `inclusion: manual` steering is inert in the CLI.

### Every change goes through an isolated worktree + PR

**"Change" includes untracked drafts.** The rule is not "worktree before you
commit" — it is worktree before you author the FIRST repo-destined file, and a
working doc you have not decided to commit yet still counts. Added 2026-08-05
after a reference doc was drafted directly in the primary checkout: the operator
runs multiple parallel sessions that share that cwd, so every one of them
started failing the shared lint hooks on a file none of them had written, while
the drafting session was the only one that could not see the damage. The primary
checkout belongs to the operator, not to any agent session.

Pre-flight before the first Write/Edit of any repo file in a session:

```bash
git rev-parse --path-format=absolute --git-dir
# ends in .git/worktrees/<slug> → linked worktree, proceed
# ends in a bare <clone>/.git   → primary checkout: STOP, make a worktree first
```

`--path-format=absolute` is load-bearing, not decoration, and the bare form is
actively misleading here. `git rev-parse --git-dir` prints a path **relative to
cwd when it can**, so at the top of the primary checkout it answers `.git` —
while in a linked worktree it answers an absolute
`<clone>/.git/worktrees/<slug>`. Measured both ways on 2026-08-05. So the one
case the check exists to catch is the case whose output does not look like the
`<clone>/.git` you are comparing against, and a reader matching on that string
concludes "not the primary checkout" precisely when they are standing in it.
Forcing absolute makes both arms comparable. This is the same flag the worktree
derivation below already uses for `--git-common-dir`, and the same one
`devenv.nix` uses for its related checks.

Only the session scratchpad is exempt, because it never touches the repo tree at
all. There is no "just a draft" exemption, no "I'll move it before committing"
exemption, and no "it's gitignored-adjacent" exemption.

Worktrees live in `<repo>-worktrees/`, a **sibling of the primary checkout** — a
clone at `~/src/nix-agentic-tools` puts them in
`~/src/nix-agentic-tools-worktrees/<slug>`. Keeping them beside the clone means
a direnv whitelist (or any editor/tooling trust root) covering the checkout
covers new worktrees too, so editors and tooling treat them as the same trusted
project — and it keeps work out of `~/.cache`, which cache-cleaning tools treat
as disposable.

This used to be justified by `cd` alone entering the devenv shell and
materializing the gitignored `files.*` artifacts, which was how a worktree got
bootstrapped. That is no longer a reason to want it: nothing needs a worktree
shell entry now (step 2 below), and under the sandbox-stack topology devenv is
deliberately entered in the primary checkout only. Do not read the sibling
layout as an endorsement of direnv-driven devenv entry in worktrees.

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

2. **There is no worktree bootstrap step.** `git worktree add` and commit — the
   shared prek hooks resolve their config from the primary checkout, and
   `PREK_HOME` from the committing worktree, so a worktree that has never
   entered `devenv shell` validates exactly like one that has.

   This changed on 2026-08-18 and the old shape is worth knowing, because every
   doc and habit predating it says otherwise. The hooks used to resolve
   `.pre-commit-config.yaml` from the COMMITTING worktree's toplevel — a devenv
   `files.*` artifact materialized on SHELL ENTRY only, which `git worktree add`
   never runs — so a fresh worktree's first commit was rejected until you ran
   `devenv shell true` in it. Worse, `devenv tasks run` did not materialize it
   either — measured 2026-07-31 in two fresh worktrees (`generate:all` succeeded
   in each and the next commit was still rejected) and re-confirmed 2026-08-18 —
   so bootstrapping via the task you needed anyway looked like it worked and
   failed later, attributed to the commit. That asymmetry is still live for
   anything else that wants a `files.*` artifact in a worktree; it just no
   longer gates commits.

   The primary checkout is the one that is entered — sessions launch there and
   the agent process runs with cwd in a linked worktree — so its config always
   exists and always tracks regeneration. **Only the primary checkout needs
   `devenv shell true`, and only after a fresh clone or a `devenv.nix` change.**
   If a commit is ever rejected for a missing config, the hook names that path
   and that fix; do not silence it with `PREK_ALLOW_NO_CONFIG=1`,
   `--allow-missing-config`, or `prek uninstall` — all three skip every check
   rather than fixing the bootstrap.

   Enter `devenv shell` in a **worktree** only when you specifically need its
   generated artifacts there (regenerating instruction projections, say). It is
   no longer a prerequisite for anything, and under the sandbox-stack topology
   it is not the intended shape.

3. **Push at the first commit** — not at the end — so the branch is a continuous
   off-machine backup. Open the PR **ready (non-draft) as soon as the work is
   dev-complete**: becoming ready for review is the _only_ thing that
   automatically requests a Copilot review, so a draft that is actually ready
   silently skips review and a later flip is what fires it. Reserve **draft**
   for genuine WIP, or when you explicitly want to preview the branch in GitHub
   without review. Draft and ready PRs both get full CI here.

   Corollary worth internalizing: that one automatic review is the only free
   one, so **flip to ready when the branch is worth reviewing** — not
   mid-refactor, where it is spent on code you are about to replace.

4. Keep pushing as work lands. Flip draft → ready the moment it is dev-complete
   so review can start.

5. **The moment the PR is open and non-draft, run the Copilot review loop on
   your own initiative.** Nobody has to ask. Poll for the review on the head
   commit, read BOTH buckets, fix what is real, reply, resolve each gating
   thread, re-request, verify — the sections above say how. Handing back a
   freshly-opened PR with an unread review is an incomplete task, not a
   checkpoint: it makes the operator notice the review, chase it, and hand it
   back to you, when you are the one still holding the context to act on it.
   STARTING the loop needs no permission. It is ONE round; going beyond that
   needs a significant change in reviewed scope, or the operator's say-so.

6. Merges are squash merges. The operator performs them for **human** PRs; the
   bot's `update/*` PRs land themselves (next section).

7. **Always tear the worktree and local branch down once the PR is merged.**
   This cleanup belongs to the agent that implemented the change; do not hand it
   back to the operator or declare the task complete while either remains:

   ```bash
   git worktree remove "$worktrees/<slug>"   # re-derive $worktrees if needed
   git branch -D <type>/<slug>   # squash-merged: -d refuses, -D is correct
   ```

   The remote branch auto-deletes on merge.

### Bot `update/*` PRs land themselves

`.github/workflows/update.yml` sweeps dependencies 4x/day (00:00, 06:00, 12:00,
18:00 UTC) and opens one PR per dependency that actually moved. Each is armed
with GitHub-native **auto-merge (squash)** as it is created, and re-armed on
every later sweep, so it merges itself once the six required checks go green.
Safe precisely because the ruleset requires no approving review, all six status
checks must pass, and an unresolved Copilot thread still holds the merge through
the separate review-thread rule.

A merge conflict **disables** auto-merge, so a conflicted update PR drops out of
the queue until the next sweep rebuilds its branch on the current base and
re-arms it. Arming is non-fatal too: a failure logs an `Auto-merge not armed`
warning naming the branch and PR, and that PR is the one needing a hand.

There is **no manual merge path** — the `pr:merge-updates` task and
`merge-update-prs` skill that used to batch-merge these are deleted. Do not
reintroduce hand-merging of `update/*` PRs; land the individual stragglers the
pipeline could not, and fix the reason.

### What is shared across worktrees — and what is not

Linked worktrees of one clone share the common `.git` directory — at ANY depth,
since git has no nested worktrees (next section) — so these are **shared, not
per-worktree**:

- **The hooks directory.** One `core.hooksPath` serves every worktree, and it
  holds git-branchless's hooks (`post-commit`, `post-rewrite`,
  `reference-transaction`, `post-checkout`) alongside the prek hooks. Do NOT
  redirect `core.hooksPath` per worktree: it **replaces** `.git/hooks` with no
  fallback, so branchless's hooks would stop firing in linked worktrees and its
  event log would silently miss every commit made there.
- **The git-branchless event database** (`.git/branchless/db.sqlite3`).
  Serialize stack-skill operations across concurrent worktrees; they are not
  session-isolated.
- **Local tags.** Tags are refs in the common git dir, so a tag created in one
  worktree is visible — and deletable — from every other. A fetch run from ANY
  worktree can wipe them all at once if the author's global git config sets
  `fetch.pruneTags`, which prunes local tags with no remote-tracking
  counterpart. See "Rebasing: back up with a pushed ref" below — this is the
  root cause the tag-backup advice used to miss.

The prek **config and runtime state** resolve from different places, and the
split is deliberate. The `hooks:isolate-config` devenv task rewrites the
installed hooks so that at hook-run time they resolve:

- **`.pre-commit-config.yaml` from the PRIMARY CHECKOUT**, via
  `$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")` — the
  same derivation the worktree recipe above uses. The primary checkout is the
  one that is entered, so its config always exists and always tracks
  regeneration, and the answer no longer depends on which checkout entered a
  shell last. That is what stops a shell entry in one worktree from changing
  what another validates against.
- **`PREK_HOME` beneath the COMMITTING worktree's `.devenv/state`.** A devenv
  shell's `PREK_HOME` is not inherited by commits launched from an editor or
  agent, so deriving it beats falling back to the user-global XDG cache; and
  under the agent sandbox the primary checkout is a read-only bind while the
  worktree is the writable one, so primary-anchored state would fail there. No
  `mkdir` is needed — prek creates `PREK_HOME` itself.

`lib/validate-at-stop.sh` mirrors both, for the same reasons: its session cwd is
normally a linked worktree, and a bare `prek run` there walks up from cwd, finds
no config, and exits 2 — output the judgment loop would report as a lint finding
and block the hand-back on.

The rewrite task takes a lock in the shared hooks directory and publishes each
complete hook with a same-filesystem rename after preserving its mode. Two shell
entries therefore serialize their rewrites, and a concurrent commit sees an old
or new complete hook rather than a partially truncated script. The upstream
installer still runs immediately before the rewrite task in each shell's devenv
DAG; do not split or reorder that dependency edge.

One more shared thing, and it lives outside the repository entirely: **the
agent's own memory directory is shared across concurrent sessions, and no
session sees another's writes.** There is no locking and no notification — a
session reads the memory index once and then writes into a directory that may
have moved underneath it. Two sessions on 2026-08-05 recorded the same concept
under different filenames minutes apart, and they agreed only by luck; had the
wording diverged, the repo would now carry two half-truths with no link between
them. A duplicate under a different name is invisible to the `[[wikilink]]`
graph, so it does not surface as a conflict — it just quietly fails to be found.

Before writing a memory, **list the directory by mtime and grep it for the
concept**, not for the filename you intend to use. Anything written in the last
few minutes is a live concurrent session, and the right move is to extend that
file rather than open a second one:

```bash
ls -lt "$MEMORY_DIR" | head -20
grep -rl "<the concept, not the slug>" "$MEMORY_DIR"
```

This is a general cross-harness rule, not a Claude Code one: any two agent
sessions sharing a memory store have it, and the failure is silent in all of
them.

### Worktrees off a worktree are FLAT — git has no second level

A long-lived branch sometimes wants per-unit-of-work isolation of its own: a
parallel session per unit, each with its own tree. `git worktree add` run from
inside a linked worktree does that — and it produces a plain SIBLING, not a
child. The new worktree registers under the ORIGINAL clone's `.git/worktrees/`
and its `commondir` is `../..`, the same two-level path a level-one worktree
has. Measured 2026-08-27.

So a "worktree of a worktree" does not exist, and the phrase is worth retiring:
depth is a filesystem-layout choice and nothing else. Everything above survives
unchanged because there is no second level for it to get lost in. Measured on
such a tree: prek resolves correctly in both directions — config from the
primary checkout, `PREK_HOME` under the committing worktree — a mis-formatted
staged file FAILED the real hook, a clean one passed, and the parent worktree's
prek state was untouched; `strictdoc export` yielded an identical graph (139
UIDs, same set).

Use the same `$worktrees` directory the one-level recipe derives, flat, with the
unit slug PREFIXED by its parent's:

```bash
git worktree add -b <type>/<parent>-<unit> "$worktrees/<parent>-<unit>" <branch>
```

Two reasons — one measured, one not:

- **Never place it inside the parent's tree.** The outer tree's
  `git status --porcelain` reports the inner one as untracked, so its files
  reach treefmt, prek and gitleaks; and `strictdoc export` from the outer tree
  HARD-FAILS on duplicate UIDs. Both measured. The "worktree of a worktree"
  framing invites exactly that layout, which is the other reason to drop it.
- **The registry is a FLAT namespace keyed on the path's LAST COMPONENT**, so
  generic basenames (`docs`, `wip`, `fix`) collide across a per-unit population.
  Prefixing is a caution, not a finding — the collision behavior itself was not
  measured.

**The isolation is PARTIAL, and the list above is the whole of what it misses.**
Disjoint working directories, yes; the branchless event database, the hooks
directory, local tags and the refs namespace stay shared at depth two exactly as
at depth one. Per-unit worktrees fix file collisions between parallel agents.
They do NOT make concurrent `git branchless` operations safe.

Merge a unit back **in the long-lived worktree** — git refuses a second checkout
of a branch already checked out — which makes that worktree the one
serialization point the pattern still needs.

Teardown is step 7's, once per unit, with one addition: a session that dies
leaves TWO residues and only one is collected. The registry entry goes
`prunable` and any `git worktree prune` sweeps it; the branch is an orphan that
nothing ever collects. `git worktree remove` handles the tree and never the
branch — `git branch -D` stays a separate, mandatory step.

### Rebasing: back up with a PUSHED ref, not a tag or a local branch

`git rebase --update-refs` (and git-branchless) moves any **branch** that points
into the rebased range — including a backup branch created moments earlier,
silently defeating it. A local **tag** dodges that, but is not safe either: tags
are refs in the COMMON git dir, shared across every worktree of the clone, and
`fetch.pruneTags` — a common global git config setting — prunes any local tag
with no matching remote-tracking ref on the next fetch, from ANY worktree.
Measured twice on 2026-08-15, the second time when the same session ran its own
fetch moments later to check whether an unrelated push had landed, and it
deleted the backup tag along with it. Neither primitive alone survives both
hazards, and there is no way to tell from the tag alone whether the local config
has `pruneTags` set, so write backup guidance that holds regardless:

```bash
git push origin HEAD:refs/heads/archive/<slug>   # create + push in one step
```

Push the backup **in the same command sequence as the rebase**, before running
it — not after, and not as a "verify it's there" step, because the fetch that
verifies it is exactly the kind of operation that can delete a local-only tag.
Only a ref that has actually reached `origin` survives both a rebase with
`--update-refs` and a prune-on-fetch.

Lockfile conflicts (`flake.lock`, `devenv.lock`) during a rebase are
**regenerated, never hand-merged**: take the base's copy, then re-run
`nix flake lock` (and let devenv reconcile `devenv.lock`) so the result matches
the merged `flake.nix` / `devenv.yaml`.
