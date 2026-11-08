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

2. **Fix at HEAD, then name the target for each hunk:** the newest commit that
   introduces either the lines it edits or any name it uses. Absorb sees edited
   lines, not name dependencies. Line proximity never decides the target. If the
   target is unknown, stop and ask the user.

   **Every absorb uses `--base <target-commit>^` to exclude older commits.** The
   base only bounds the oldest candidate; absorb walks newest to oldest, so
   every newer commit remains a candidate. It pins the target only when that
   target is the newest commit. A broader base (`origin/main`, the stack root)
   or no base admits unintended older candidates. Fixes for several commits
   require separate targeted runs, staging only one target's hunks at a time.

   ```bash
   git absorb --dry-run --base <target-commit>^
   ```

3. **Review the dry-run output.** Show the user which hunks will be absorbed
   into which commits. Accept a newer target only when the hunk edits lines
   introduced by that commit: those lines make it the correct dependency target.
   A choice at or after every used name's introduction satisfies the name
   dependencies; an older choice is wrong. If absorb picks a commit older than
   the named target, rerun with a base that excludes it, or stage that hunk
   alone and use the explicit fixup below. Hunks that commute with every
   candidate may remain staged; use the same fixup for those.

4. **Confirm with the user** that the mapping looks correct. If `$ARGUMENTS`
   contains `--dry-run`, stop here.

5. **Absorb and rebase**:

   ```bash
   git absorb --and-rebase --base <target-commit>^ -- --update-refs
   ```

   The rebase does not run commit hooks: afterwards run the project's hook or
   lint runner on the changed files (for example `prek run --files <files>`).

6. **Verify the result** with `git sl` to show the updated stack.

7. **Check for leftover changes**:

   ```bash
   git diff --cached --stat
   git diff --stat
   ```

   If the target's hunks commute and remain staged, fold them into the named
   target explicitly (resolve its current hash after absorb's rebase). For this
   fixup or a wrong-target hunk, run the content hooks first; if the
   repository's commit-msg hook rejects `fixup!` subjects (such as this
   repository's convco hook), pass `--no-verify` to the transient
   `git commit --fixup`. Absorb's own commits skip hooks.

   ```bash
   git commit --fixup=<target-commit>
   GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --update-refs <target-commit>^
   git diff --cached --stat
   ```

   Confirm nothing remains staged. For other changes absorb cannot route, use
   **Structural fixes** below. Run the project's hook or lint runner after this
   rebase too.

8. **Post-fix verification** (see below).

## Structural fixes

For changes absorb cannot route beyond the commuting-hunk fixup above, stop and
ask the user. Manual amend, git-revise, restack, and branch-repair recipes can
rewrite or move a sibling, stacked, or detached worktree. This skill does not
attempt those repairs.

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

3. **Verify every commit still builds on its own after the rebase.** Use the
   project's build or test command across `$STACK`:

   ```bash
   git test run -x '<test-command>' --jobs <N> '<revset>'
   ```

   Use `$STACK` for `<revset>` here so every commit is checked. Size `<N>` by
   memory, not cores, and never pass `--jobs 0`. If no build or test command is
   identifiable, report this verification as unknown.

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
