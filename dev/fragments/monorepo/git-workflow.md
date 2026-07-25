## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-07-24 (commit pending — the bot's `update/*` PRs now
> arm GitHub-native auto-merge and land themselves, the manual
> `pr:merge-updates` task and `merge-update-prs` skill are deleted, the update
> sweep runs 4x/day, and squash-only is re-attributed to the repository
> settings rather than the ruleset). If you change the branch-protection
> ruleset, the repository merge settings, the worktree convention, the
> bootstrap step, the local commit guard, the auto-merge arming, or the PR flow
> and this fragment isn't updated in the same commit, stop and fix it.

`main` is the trunk. Its branch-protection ruleset requires a pull request, no
force-push, no deletion, and four required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`test`, and `gitleaks`. It requires **zero approving reviews** and does not
require review threads to be resolved.

**Squash-merge only** — but that is the REPOSITORY settings, not the ruleset:
`allow_squash_merge` true, `allow_merge_commit` and `allow_rebase_merge` false.
The ruleset's own `allowed_merge_methods` still lists all three, so changing it
there changes nothing. Copilot review runs on every PR from a separate ruleset
rule that _requests_ a review: not a required approval, and no required status
check, so it annotates a PR but never gates its merge.

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

Worktrees live in `<repo>-worktrees/`, a **sibling of the primary checkout** —
a clone at `~/src/nix-agentic-tools` puts them in
`~/src/nix-agentic-tools-worktrees/<slug>`. Keeping them beside the clone means
a direnv whitelist (or any editor/tooling trust root) covering the checkout
covers new worktrees too, so `cd` alone enters the devenv shell and
materializes the gitignored `files.*` artifacts with no manual step — and it
keeps work out of `~/.cache`, which cache-cleaning tools treat as disposable.

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

3. **Push at the first commit** — not at the end — so the branch is a
   continuous off-machine backup. Open the PR **ready (non-draft) as soon as
   the work is dev-complete**: Copilot review does **not** run on draft PRs in
   this repo, so a draft that is actually ready silently skips review. Reserve
   **draft** for genuine WIP, or when you explicitly want to preview the branch
   in GitHub without review. Draft and ready PRs both get full CI here.

4. Keep pushing as work lands. Flip draft → ready the moment it is
   dev-complete so review can start.

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
