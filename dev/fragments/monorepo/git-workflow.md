## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-07-24 (commit pending — documents the local
> `reject-default-branch-commit` pre-commit guard and aligns the PR-draft
> guidance with the review policy). If you change the branch-protection
> ruleset, the worktree convention, the local commit guard, or the PR flow
> and this fragment isn't updated in the same commit, stop and fix it.

`main` is the trunk. It is protected: pull-request required, **squash-merge
only**, no force-push, no deletion, and four required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`test`, and `gitleaks`. Copilot review runs on every PR.

**Never commit directly to `main`.** Two backstops enforce this. A local
`reject-default-branch-commit` pre-commit hook (installed through devenv's
git-hooks framework) rejects any commit made while the default branch is the
checked-out HEAD — a mis-branched commit is caught at _commit_ time, in the
primary checkout only; linked worktrees on feature branches are unaffected,
and `--no-verify` bypasses it by design. Independently, the branch-protection
ruleset rejects the _push_. Still branch **before** you start — the guard is a
safety net, not the workflow.

### Every change goes through an isolated worktree + PR

1. Branch off `main` into its own worktree:

   ```bash
   git worktree add -b <type>/<slug> ~/.cache/nat-worktrees/<slug> origin/main
   ```

   `<type>` is a Conventional Commits type (`build`, `chore`, `ci`, `docs`,
   `feat`, `fix`, `perf`, `refactor`, `style`, `test`).

2. **Push at the first commit** — not at the end — so the branch is a
   continuous off-machine backup. Open the PR **ready (non-draft) as soon as
   the work is dev-complete**: Copilot review does **not** run on draft PRs in
   this repo, so a draft that is actually ready silently skips review. Reserve
   **draft** for genuine WIP, or when you explicitly want to preview the branch
   in GitHub without review. Draft and ready PRs both get full CI here.

3. Keep pushing as work lands. Flip draft → ready the moment it is
   dev-complete so review can start.

4. Merges are squash merges, performed by the operator.

5. Tear the worktree down once merged:

   ```bash
   git worktree remove ~/.cache/nat-worktrees/<slug>
   git branch -D <type>/<slug>   # squash-merged: -d refuses, -D is correct
   ```

   The remote branch auto-deletes on merge.

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
