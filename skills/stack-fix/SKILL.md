---
name: stack-fix
description: >-
  Use when you need to fix, correct, or update content in an earlier commit.
  Absorbs staged changes into correct stack commits INSTEAD of running
  git absorb or git commit --fixup via Bash. Prevents: missed dry-run preview,
  leftover staged changes going unnoticed, forgetting to restack. Falls back
  to guided manual amend when absorb cannot route hunks.
argument-hint: "[--dry-run]"
disable-model-invocation: false
compatibility: "Requires git-branchless and git-absorb"
---

Fix earlier commits in the stack. Tries git-absorb first (automatic hunk
routing), falls back to guided manual amend with conflict resolution when
absorb cannot help.

## Pre-flight

1. **Load references** — read `references/git-absorb.md` and
   `references/git-branchless.md` (relative to this skill's directory) before
   proceeding.

2. **Check branchless init**:
   ```bash
   if [ ! -d ".git/branchless" ]; then git branchless init; fi
   ```

3. **Check for stale rebase state**:
   ```bash
   ls .git/rebase-merge .git/rebase-apply 2>/dev/null
   ```
   If present, run `git rebase --abort` before proceeding.

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

2. **Determine if the target commit is known** — if the fix is from review
   feedback or the user specified a commit, use `--base` to constrain absorb:
   ```bash
   # Target known (review feedback, specific commit):
   git absorb --dry-run --base <target-commit>^

   # Target unknown (let absorb auto-discover):
   git absorb --dry-run
   ```
   **Always use `--base` when the target is known.** Without it, absorb
   searches the full stack by diff context matching and may route to a later
   commit that has more matching context — especially for files built
   incrementally across commits (README.md, CLAUDE.md, etc.).

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
   # With known target:
   git absorb --and-rebase --base <target-commit>^

   # Auto-discover:
   git absorb --and-rebase
   ```

6. **Verify the result** with `git sl` to show the updated stack.

7. **Check for leftover changes**:
   ```bash
   git diff --cached --stat
   git diff --stat
   ```
   If hunks remain (couldn't be absorbed), inform the user. Options:
   - Switch to **Path B** for the leftover changes
   - Create a new commit if the changes are genuinely new work

8. **Post-fix verification** (see below).

## Path B: Manual amend (guided conflict resolution)

Use this path when absorb cannot route the changes: content moves between
commits, adding to files that descendants also touch, structural edits, or
new file additions to earlier commits.

### Identify the target

1. **Determine which commit to edit**. Ask the user, or if changes are staged,
   use the smartlog to find the most likely target:
   ```bash
   git sl
   ```

### Pre-analyze conflict risk

2. **Check file overlap** between the target commit and its descendants:
   ```bash
   # Files the target commit touches
   git show --stat <target>

   # Files each descendant touches
   git log --stat <target>..HEAD
   ```
   If descendants modify the same files, warn the user:
   - **Same file, different regions** → restack will likely succeed in-memory
   - **Same file, overlapping regions** → expect per-commit conflicts at each
     descendant that touches those regions
   - **Descendant reorganizes the file** (reorders sections, restructures) →
     expect a conflict cascade; consider editing the reorganization commit
     directly instead

### Navigate and edit

3. **Navigate to the target commit**:
   ```bash
   git prev <N>  # or git checkout <target>
   ```
   **Always verify you landed on the right commit before editing:**
   ```bash
   git log --oneline -1   # works in detached HEAD (git branch --show-current does not)
   ```
   If checkout fails (e.g. "local changes would be overwritten"), you are
   still on the PREVIOUS commit. Stash or commit changes first, then retry.
   Never proceed with `git add` + `git amend` after a failed checkout — the
   amend goes into whatever commit you are currently on.

4. **Make the edit**. The user (or you) modifies files as needed.

5. **Amend the commit**:
   ```bash
   git amend
   ```
   If `git amend` succeeds with in-memory restack, skip to step 8.

### Handle conflicts

6. If amend reports conflicts ("To resolve merge conflicts, run:
   `git restack --merge`"), run:
   ```bash
   git restack --merge
   ```
   This starts an on-disk rebase that stops at each conflicting commit.

7. **For each conflict**:
   ```bash
   # See what's conflicting
   git diff --name-only --diff-filter=U

   # Resolve the conflict (edit files, git add)
   git add <resolved-files>
   git rebase --continue
   ```
   **Watch for orphaned additions**: when removing content from an earlier
   commit, conflict resolution may drop additions that later commits made to
   the same block. After each resolution, verify the resolved file contains
   all expected content.

### Return and verify

8. **Return to the stack tip**:
   ```bash
   git next -a
   ```

9. **Post-fix verification** (see below).

## Path C: In-memory amend (git-revise)

Use this path when the fix is small (a few lines), the target is deep in
the stack (5+ commits back), and you want to avoid checking out the target
commit (preserves build cache, avoids "local changes would be overwritten"
errors).

**Limitations:** No rename detection. Requires `git restack` afterward
(branchless can't track git-revise rewrites). Not suitable for structural
changes, new file additions, or complex multi-hunk edits.

1. **Stage the fix** at the current position (stack tip):
   ```bash
   git add -p   # or git add <files>
   ```

2. **Apply in-memory** to the target commit:
   ```bash
   git revise <target-hash>
   ```
   If conflicts occur, git-revise opens an editor for resolution. If
   the conflict is too complex for editor-based resolution, abort and
   use Path B instead.

3. **Fix branchless tracking**:
   ```bash
   git restack
   ```
   If restack reports conflicts, resolve with `git restack --merge`
   (same as Path B step 6-7).

4. **Post-fix verification** (see below).

## Post-fix Verification

Run after either path to confirm the stack is healthy.

1. **Show the updated stack**:
   ```bash
   git sl
   ```

2. **Verify no unintended changes** (the diff should show ONLY the intended
   fix — unexpected files or regions indicate content lost/duplicated during
   conflict resolution):
   ```bash
   git diff $BEFORE_SHA..HEAD --stat
   ```
   For commit message fixes (not content), use `git reword <hash>` directly
   — this skill handles content changes only.

3. **Run tests** if a test command is readily identifiable:
   ```bash
   git test run -x '<test-command>' 'stack()'
   ```
   Report any regressions introduced by the fix.
