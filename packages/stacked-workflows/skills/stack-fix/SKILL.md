---
name: stack-fix
description: >-
  Use when you need to fix, correct, or update content in an earlier commit —
  line-level edits, content moves, or structural changes. Absorbs staged changes
  into correct stack commits INSTEAD of running git absorb or git commit --fixup
  via Bash, or hand-running git prev + edit + git amend + git restack --merge.
  Prevents: missed dry-run preview, leftover staged changes going unnoticed,
  forgetting to restack. Falls back to guided manual amend when absorb cannot
  route hunks.
argument-hint: "[--dry-run]"
disable-model-invocation: false
compatibility: "Requires git-branchless and git-absorb"
---

Fix earlier commits in the stack. Tries git-absorb first (automatic hunk
routing), falls back to guided manual amend with conflict resolution when absorb
cannot help.

## Pre-flight

1. **Load references** — read `references/git-absorb.md` and
   `references/git-branchless.md` (relative to this skill's directory) before
   proceeding.

2. **Confirm repository initialization.** A devenv project with
   `git.branchless.enable` runs `git branchless init` on every shell entry.
   Anywhere else, check and stop if it is missing:

   ```bash
   git config --get branchless.core.mainBranch >/dev/null ||
     echo "not initialized: ask the user to run git branchless init"
   ```

   Do not run `git branchless init` yourself: it rewrites the repository's
   shared configuration and hooks for every worktree.

3. **Check for stale rebase state**:

   ```bash
   ls -d "$(git rev-parse --git-path rebase-merge)" \
     "$(git rev-parse --git-path rebase-apply)" 2>/dev/null
   ```

   If either exists, run `git rebase --abort` before proceeding. In a linked
   worktree `.git` is a file, so ask Git for the paths.

4. **Snapshot current state** for post-fix verification:
   ```bash
   git sl
   BEFORE_SHA=$(git rev-parse HEAD)
   ```

## Path A: Absorb (automatic routing)

Use this path when you have staged changes that fix lines an earlier commit
introduced (typos, bug fixes, adjustments to existing code).

1. **Check for staged changes**:

   ```bash
   git diff --cached --stat
   ```

   If nothing is staged, check for unstaged changes and ask the user what to
   stage. Suggest `git add -p` for selective staging.

2. **Require a known target commit.** If the fix is from review feedback or the
   user specified a commit, use `--base` to constrain absorb:

   ```bash
   # Target known (review feedback, specific commit):
   git absorb --dry-run --base <target-commit>^

   ```

   If the target is unknown, stop and ask the user. Auto-discovery can search a
   wider draft component than this worktree owns.

   **Always use `--base` when the target is known.** Without it, absorb searches
   the full stack by diff context matching and may route to a later commit that
   has more matching context — especially for files built incrementally across
   commits (README.md, CLAUDE.md, etc.).

   **Note:** `--base <X>` means "search commits AFTER X" — the base commit
   itself is excluded from candidates. To include commit X, use `--base <X>^`
   (its parent). If absorb reports "no available commit to fix up" with your
   target as the base, this is why.

3. **Review the dry-run output.** Show the user which hunks will be absorbed
   into which commits. If any hunks can't be absorbed (they commute with all
   commits), warn that those will remain staged.

4. **Confirm with the user** that the mapping looks correct. If `$ARGUMENTS`
   contains `--dry-run`, stop here.

5. **Absorb and rebase**:

   ```bash
   git absorb --and-rebase --base <target-commit>^ -- --update-refs
   ```

6. **Verify the result** with `git sl` to show the updated stack.

7. **Check for leftover changes**:

   ```bash
   git diff --cached --stat
   git diff --stat
   ```

   If hunks remain, stop and ask the user whether to create a new commit or
   handle the structural change in an isolated follow-up.

8. **Post-fix verification** (see below).

## Structural fixes

If absorb cannot route the change, stop and ask the user. Manual amend,
git-revise, restack, and branch-repair recipes can rewrite or move a sibling,
stacked, or detached worktree. This skill does not attempt those repairs.

## Post-fix Verification

Run after either path to confirm the stack is healthy.

1. **Show the updated stack**:

   ```bash
   git sl
   ```

2. **Verify no unintended changes** (the diff should show ONLY the intended fix
   — unexpected files or regions indicate content lost/duplicated during
   conflict resolution):

   ```bash
   git diff $BEFORE_SHA..HEAD --stat
   ```

   For commit-message-only fixes, stop and ask the user; this skill handles
   content changes only.

3. **Run tests** if a test command is readily identifiable:

   ```bash
   git test run -x '<test-command>' --jobs <N> '<revset>'
   ```

   Pick `<revset>` per **Choosing the test revset** in
   `references/git-branchless.md`: `heads($STACK)` for one PR with several
   commits, `$STACK` only for a stack of independent PRs. Size `<N>` by memory,
   not cores, and never pass `--jobs 0`.

   `$STACK` is this worktree's own stack. Plain `stack()` also holds other
   worktrees' stacks while local `main` is behind its upstream (see **Selecting
   your own stack** in the reference):

   ```bash
   main_branch="$(git config branchless.core.mainBranch || echo main)"
   remote="$(git config "branch.${main_branch}.remote" || echo origin)"
   base="$(git rev-parse --abbrev-ref "${main_branch}@{upstream}" 2>/dev/null \
     || echo "${remote}/${main_branch}")"
   git rev-parse --verify -q "${base}^{commit}" >/dev/null || base="$main_branch"
   STACK="descendants(roots((stack() & ::HEAD) - ::$base)) - ::$base"
   ```

   Report any regressions introduced by the fix.
