---
name: stack-plan
description: >-
  Use when you need to plan commits, restructure a stack, or commit uncommitted
  work as organized atomic commits. Builds a stack from a description,
  uncommitted work, or existing commits INSTEAD of manual git rebase -i,
  git reset --soft, or ad-hoc git move sequences. Prevents: wrong commit
  ordering, forward references, git move -F panics, untested intermediates.
argument-hint: "<plan | range | (none for working tree)>"
disable-model-invocation: false
compatibility: "Requires git-branchless"
---

Plan and execute a commit stack. Determines mode automatically based on input:

- **From a plan/description** — user describes what needs to be built; skill
  produces the commit ordering and executes it
- **From uncommitted work** — working tree has changes; skill classifies and
  commits them as an atomic stack
- **From existing commits** — range like `main..HEAD`; skill restructures into
  a clean atomic stack

## Pre-flight

1. **Load references** — read `references/philosophy.md` and
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

## Determine Mode

Examine `$ARGUMENTS` and repo state to select the mode:

- If `$ARGUMENTS` contains `--root` or requests a from-root restructure →
  **Restructure mode (from-root)**
- If `$ARGUMENTS` looks like a commit range (`main..HEAD`, `hash1..hash2`,
  branch name) → **Restructure mode**
- If `$ARGUMENTS` is a natural-language description of work to do →
  **Plan mode**
- If `$ARGUMENTS` is empty and the working tree has uncommitted changes →
  **Working tree mode**
- If `$ARGUMENTS` is empty and the working tree is clean → ask the user what
  they want to do

## Plan Mode

The user describes work to be done. Build the stack from scratch.

1. **Understand the task** from `$ARGUMENTS`. If the description is vague, ask
   clarifying questions.

2. **Design the commit stack** following the ordering in
   `references/philosophy.md`:
   1. Refactoring / cleanup (separate from feature work, always first)
   2. Dependencies / build config changes
   3. Scaffolding / types / interfaces / schemas
   4. Core business logic
   5. Edge cases / error handling
   6. Tests

   For each commit, note:
   - One-sentence commit message (Conventional Commits format)
   - Which files will be created or modified
   - Estimated line count (target 50-200 per commit)
   - Dependencies on prior commits (no forward references)

3. **Verify no forward references**: each commit must only reference files,
   imports, and config that exist in it or earlier commits. Documentation goes
   WITH the feature it documents. Dependencies arrive in the commit that first
   uses them.

4. **Present the plan** to the user:

   ```
   Proposed stack (N commits):

   1. type(scope): description — files X, Y (~80 lines)
   2. type(scope): description — files A, B (~120 lines)
   3. type(scope): description — files C, D, E (~150 lines)
   ...
   ```

   **Wait for user approval.** Adjust if they have feedback.

5. **Execute the plan** — implement each commit in order:

   ```bash
   # Write the code for commit 1
   git add <files>
   git commit -m "type(scope): description"

   # Write the code for commit 2
   git add <files>
   git commit -m "type(scope): description"
   ```

   After each commit, verify the codebase is in a working state.

## Working Tree Mode

Uncommitted changes exist. Classify and commit them as a stack.

1. **Survey the changes**:

   ```bash
   git status --short
   git diff --stat
   git diff
   ```

   Read the full diff. Count total lines changed.

2. **Classify every change** into logical groups following the ordering in
   `references/philosophy.md`. For each group, note:
   - Which files and hunks belong to it
   - A one-sentence commit message
   - Estimated line count (target 50-200 per commit)

   If a file has changes spanning multiple groups, it will need `git add -p`
   to split hunks across commits.

3. **Present the plan** to the user (same format as Plan mode step 4).
   **Wait for user approval.**

4. **Commit each group** in plan order:

   ```bash
   # For file-level grouping:
   git add <file1> <file2>
   git commit -m "type(scope): description"

   # For hunk-level splitting within a file:
   git add -p <file>
   git commit -m "type(scope): description"
   ```

   After each commit, verify nothing was missed or double-counted:

   ```bash
   git diff --stat   # remaining uncommitted changes
   ```

## Restructure Mode

Existing commits need to be reorganized into a clean atomic stack.

1. **Parse the range** from `$ARGUMENTS`. Resolve to a `<base>` and `<tip>`:

   ```bash
   # For range syntax (base..tip):
   BASE=<resolved base>
   TIP=<resolved tip>

   # For a branch name, find the merge-base:
   BASE=$(git merge-base main <branch>)
   TIP=<branch>

   # For --root (entire history):
   BASE=<empty tree>
   TIP=HEAD
   ```

2. **Understand the current state**:

   ```bash
   git sl
   git log --oneline --reverse $BASE..$TIP   # or --root for from-root
   git log --reverse --stat --format="=== %h %s ===" $BASE..$TIP
   git diff --stat $BASE..$TIP

   # From-root (no base commit):
   git log --oneline --reverse --root
   git log --reverse --stat --format="=== %h %s ===" --root
   git diff --stat $(git hash-object -t tree /dev/null) HEAD
   ```

   Read the full diff and per-commit stats. Count total lines changed.

3. **Classify every change** into logical groups (same as Working Tree mode
   step 2).

4. **Identify files with intermediate states**: before planning the commit
   sequence, list every file that will have DIFFERENT content across multiple
   commits (e.g. README.md, CLAUDE.md, flake.nix growing incrementally).
   For each, write out EXACTLY what content it should have at each commit
   boundary. Plan ALL intermediate states BEFORE flattening — discovering
   them as you go leads to fixups and tree hash mismatches. This is the #1
   source of rework during restructure.

5. **Present the plan** (same format as Plan mode step 4).
   **Wait for user approval.**

6. **Check for uncommitted work** before flattening:

   ```bash
   git status --short
   ```

   If there are uncommitted changes, warn the user and ask whether to stash
   or commit them first.

7. **Create a backup branch**:

   ```bash
   git branch backup-before-restructure
   ```

   If a branch with this name already exists, delete it first or use a unique
   name (e.g., `backup-restructure-$(date +%s)`).

8. **Save the tree hash** for post-verification:

   ```bash
   FINAL_TREE=$(git rev-parse HEAD^{tree})
   ```

9. **Extract intermediate file states** before flattening. For every file
   identified in step 4 as having multiple states, save each version to a
   temp directory using `git show`. After flattening, the working tree only
   contains the final state — earlier versions are gone.

   ```bash
   STATES_DIR=$(mktemp -d /tmp/restructure-states.XXXXXX)
   # For each (file, commit) pair from step 4:
   git show "${HASH}":path/to/file > "${STATES_DIR}/filename.${HASH}"
   ```

   Include stub files (placeholder modules, `.gitkeep` files) that scaffold
   commits create before later commits replace them with real content.
   Restore these with `cp` or `touch` before staging each intermediate
   commit.

10. **Flatten the range** into the working tree:

```bash
# Standard range (has a base commit):
git reset --soft $BASE
git restore --staged .

# From-root (no base commit):
git checkout --orphan restructure-wip
git reset
# Note: git-branchless hook will panic on orphan branches — this is
# harmless. The checkout succeeds. Suppress noise with:
#   2>&1 | grep -v "^branchless:"
```

Verify the working tree matches the original diff:

```bash
# Standard range (files are unstaged):
git diff --stat   # should match step 2's total diff

# From-root (all files are untracked after orphan+reset):
git status --short | wc -l   # should match step 2's file count
```

11. **Commit each group** in plan order (same as Working Tree mode step 4).
    For files with intermediate states (identified in step 4), restore the
    correct version from `$STATES_DIR` BEFORE staging for each commit.
    Do not rely on the final working tree content — it represents the end
    state, not intermediate states.

    After staging each commit, check for common mistakes:
    - **Orphaned deletions**: when staging renamed/moved files, the old
      paths remain as unstaged deletions. Check `git status` and stage
      them in the same commit.
    - **`git add -u` during multi-commit rebuild**: stages ALL modified
      tracked files, not just the ones for this commit. Always use
      explicit `git add <file>` paths.
    - **Verify staged content**: run `git diff --cached --stat` to
      confirm only intended files are staged.

## Post-execution

1. **Move branch pointer** (from-root only):

   ```bash
   # If on orphan branch, move main to the new history:
   git checkout -B main
   ```

2. **Verify the result**:

   ```bash
   git sl
   git log --oneline --reverse
   ```

   Show the user the new stack.

3. **REQUIRED: Confirm total diff is identical** (Restructure mode only):

   ```bash
   # Tree hash comparison (catches ALL content differences):
   test "$(git rev-parse HEAD^{tree})" = "$FINAL_TREE" && echo "trees match"

   # If MISMATCH, identify which files differ:
   git diff backup-before-restructure HEAD --stat

   # Then inspect each differing file:
   git diff backup-before-restructure HEAD -- <file>
   ```

   Do NOT proceed if trees don't match. Fix the diverging files first
   using fixup commits (`git commit --fixup <hash>` + autosquash rebase).
   Common causes: intermediate file state written incorrectly, orphaned
   deletions missed, or `git add -u` pulling unrelated changes.

4. **Clean up stale artifacts**: check for self-referencing symlinks or
   other working tree debris:

   ```bash
   git status --short   # should be clean
   ```

   Remove any untracked artifacts that weren't in the original tree.

5. **Run tests** if a test command is identifiable:
   ```bash
   git test run -x '<test-command>' 'stack()'
   ```
   Report any commits that break the build.

## Tips

- **Don't lose changes.** After flattening, double-check `git diff --stat`
  matches the original range diff. If anything is missing, stop and
  investigate.
- Prefer `git add <files>` over `git add -p` when the changeset groups by
  file without needing hunk splitting.
- Respect user-requested commit boundaries — not every restructure needs to
  flatten everything.
- **From-root restructures** flatten the entire history. Use
  `git checkout --orphan` + `git reset` (not `git reset --soft` which needs
  a parent commit). The branchless hook will panic — ignore it.
- **Intermediate file states are the #1 source of rework.** Files like
  README.md and CLAUDE.md that grow across many commits must be written with
  partial content at each step. Plan these states BEFORE flattening.
- For files with complex structure (nested sections, cross-references), a
  full rewrite at the appropriate commit is often cleaner than incremental
  Edit operations that can cause structural nesting errors.
- **Expect hook failures during restructure.** PostToolUse hooks (agnix
  linting, treefmt formatting, etc.) fire when using Write/Edit during a
  restructure. The working tree is intentionally inconsistent between
  commits — hook errors are harmless and will pass once all files are
  committed. Use `--no-verify` on intermediate commits if needed.
- **Fixup pattern for post-hoc corrections:** when you discover a missed
  change after a commit is already made, use `git commit --fixup <hash>`
  to create a fixup commit, then squash it with
  `GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <hash>~1`
  (the no-op editor `:` lets `--autosquash` do the work).
  Follow with `git restack` to update branchless tracking.
  This is faster than checking out each commit to amend.
- **Avoid scripted `GIT_SEQUENCE_EDITOR` reorders when files are built
  incrementally.** Use `git move -x <hash> -d <dest>` for individual
  commit reorders — it's in-memory and avoids context-dependent conflicts.
- **`git revise -i` for pure reorders** (no content changes, no splits,
  no drops). Operates in-memory, faster than scripted editors. But same
  logical conflicts with incrementally-built files, no `drop`/`exec`
  support, and requires `git restack` afterward for branchless tracking.
  Use `git move -x` for individual reorders, `git revise -i` for bulk.
