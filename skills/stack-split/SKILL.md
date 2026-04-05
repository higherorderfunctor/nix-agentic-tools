---
name: stack-split
description: >-
  Use when you need to break up, split, or decompose a large commit into
  smaller atomic commits. Use INSTEAD of manual git rebase -i + edit or
  git reset HEAD^. Prevents: non-working intermediate commits, wrong split
  ordering, missed downstream restack.
argument-hint: "[commit]"
disable-model-invocation: false
compatibility: "Requires git-branchless"
---

Split a large commit into multiple smaller, atomic commits. Target commit
defaults to HEAD if not specified.

## Pre-flight

1. **Load references** — read `references/git-branchless.md` and
   `references/philosophy.md` (relative to this skill's directory) before
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

## Steps

1. **Identify the target commit**. If `$ARGUMENTS` is provided, use it.
   Otherwise default to HEAD.

2. **Analyze the commit** to understand what it contains:
   ```bash
   git show --stat <commit>
   git show <commit>
   ```
   Read the full diff. Identify logical groups following the ordering in
   `references/philosophy.md`:
   - Refactoring / cleanup (should be first)
   - Type definitions / interfaces / schemas
   - Core logic changes
   - Edge cases / error handling
   - Tests

   Documentation belongs with the feature it documents, not as a separate
   split. Dependencies and config files go in the commit that first uses them.

3. **Propose a split plan** to the user. For each proposed commit:
   - One-sentence description
   - Which files/hunks belong to it
   - Why it's a separate concern

   Wait for user approval before proceeding.

4. **Perform the split** using interactive rebase:
   ```bash
   git rebase -i <commit>^
   ```
   Mark the target commit as `edit`, then:
   ```bash
   git reset HEAD^
   ```
   This unwinds the commit but keeps all changes in the working tree.

5. **Stage and commit each group** in the agreed order:
   ```bash
   git add -p  # or git add <specific-files>
   git commit -m "descriptive message for this group"
   ```
   Repeat for each logical group. Each commit must:
   - Be describable in one sentence
   - Leave the codebase in a working state
   - Target 50-200 lines

6. **Complete the rebase**:
   ```bash
   git rebase --continue
   ```

7. **Restack** if there are downstream commits:
   ```bash
   git restack
   ```

8. **Verify** the result:
   ```bash
   git sl
   ```
   Show the user the new stack. If a test command is available, run tests
   across the new commits:
   ```bash
   git test run -x '<test-command>' 'stack()'
   ```

## Alternative: Full Stack Restructure

If the user wants to restructure multiple commits (not just split one), use
`/stack-plan` instead.

## Tips

- **`git revise -c <hash>` for two-way splits:** Splits a commit into
  exactly two pieces in-memory (no checkout). Select hunks for the first
  commit; remainder becomes the second. Faster for simple splits, but
  limited: no 3+ way splits, no binary files, no empty file additions.
  Requires `git restack` afterward.
- Format changes should ALWAYS be a separate commit (they dominate diffs and
  hide functional changes)
- If a file has both refactoring and new logic, use `git add -p` to split
  hunks within the file
- Prefer too many small commits over too few large ones — they can always be
  squashed later
- Each commit message should explain WHY, not just WHAT
