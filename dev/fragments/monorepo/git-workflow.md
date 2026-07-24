## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-07-24 (commit pending — first statement of the
> trunk-based conventions after the `main` promotion). If you change the
> branch-protection ruleset, the worktree convention, or the PR flow and
> this fragment isn't updated in the same commit, stop and fix it.

`main` is the trunk. It is protected: pull-request required, **squash-merge
only**, no force-push, no deletion, and four required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`test`, and `gitleaks`. Copilot review runs on every PR.

**Never commit directly to `main`.** This is enforced at _push_ time, not
locally: a local commit on `main` succeeds and only the push is rejected, so
branch **before** you start rather than discovering it afterwards.

### Every change goes through an isolated worktree + PR

1. Branch off `main` into its own worktree:

   ```bash
   git worktree add -b <type>/<slug> ~/.cache/nat-worktrees/<slug> origin/main
   ```

   `<type>` is a Conventional Commits type (`build`, `chore`, `ci`, `docs`,
   `feat`, `fix`, `perf`, `refactor`, `style`, `test`).

2. **Push and open a DRAFT PR at the first commit** — not at the end. The
   pushed branch is continuous off-machine backup, and the draft PR is a
   progress surface reviewable without attaching to the session. Draft PRs
   do get full CI in this repo.

3. Keep pushing as work lands. Flip draft → ready only when merge-ready.

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
