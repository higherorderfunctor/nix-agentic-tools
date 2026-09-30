---
name: stack-split
description: >-
  Use when you need to break up, split, or decompose a large commit into smaller
  atomic commits. Use INSTEAD of manual git rebase -i + edit or git reset HEAD^.
  Prevents: non-working intermediate commits, wrong split ordering, missed
  downstream restack.
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

2. **Confirm repository initialization.** A devenv project with
   `stacked-workflows.gitPreset` enabled initializes automatically before Git
   hooks are installed. Outside that setup, initialize from the primary worktree
   when the common branchless state is absent:

   ```bash
   git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
   if [ ! -d "$git_common_dir/branchless" ]; then
     git -C "$(dirname "$git_common_dir")" branchless init
   fi
   ```

3. **Check for stale rebase state**:

   ```bash
   ls -d "$(git rev-parse --git-path rebase-merge)" \
     "$(git rev-parse --git-path rebase-apply)" 2>/dev/null
   ```

   If either exists, run `git rebase --abort` before proceeding. In a linked
   worktree `.git` is a file, so ask Git for the paths.

4. **Select this worktree's own stack** as `$STACK`, and use it wherever this
   skill tests the stack:

   ```bash
   main_branch="$(git config branchless.core.mainBranch || echo main)"
   remote="$(git config "branch.${main_branch}.remote" || echo origin)"
   base="$(git rev-parse --abbrev-ref "${main_branch}@{upstream}" 2>/dev/null \
     || echo "${remote}/${main_branch}")"
   git rev-parse --verify -q "${base}^{commit}" >/dev/null || base="$main_branch"
   STACK="descendants(roots((stack() & ::HEAD) - ::$base)) - ::$base"
   ```

   `$base` is main's upstream ref (the last fetched one), or local `main` when
   there is none. Plain `stack()` is not your stack while local `main` is behind
   its upstream, the normal state when worktrees branch from `origin/main`: it
   also holds the upstream commits and every stack another worktree branched
   from them. See **Selecting your own stack** in
   `references/git-branchless.md`.

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

   Documentation belongs with the feature it documents, not as a separate split.
   Dependencies and config files go in the commit that first uses them.

3. **Propose a split plan** to the user. For each proposed commit:
   - One-sentence description
   - Which files/hunks belong to it
   - Why it's a separate concern

   Wait for user approval before proceeding.

4. **Perform the split** using interactive rebase:

   ```bash
   git rebase -i --update-refs <commit>^
   ```

   `--update-refs` makes Git move every branch inside the rebased range onto the
   rewritten commits, including the ones between the split commit and HEAD.

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

7. **No restack is needed.** `--update-refs` already moved the downstream
   branches. branchless may still warn that the rebase abandoned them: it prints
   that just before Git moves them. Step 8's `git sl` shows whether any branch
   is left on a `rewritten as` commit. If one is, stop and ask the user. Do not
   repair it with a restack or subtree move; the abandoned line may belong to a
   stacked or detached worktree.

8. **Verify** the result:
   ```bash
   git sl
   ```
   Show the user the new stack. If a test command is available, run tests over
   the new commits:
   ```bash
   git test run -x '<test-command>' --jobs <N> '<revset>'
   ```
   Pick `<revset>` per **Choosing the test revset** in
   `references/git-branchless.md`, reading `stack()` there as `$STACK`.
   Splitting is one of the cases that argues for `$STACK` even inside a single
   PR — you have just created commits that never existed before — but say so
   rather than widening silently, and size `<N>` by memory, not cores.

## Alternative: Full Stack Restructure

If the user wants to restructure multiple commits (not just split one), use
`/stack-plan` instead.

## Tips

- Do not substitute git-revise for the guarded rebase above. Its branch repair
  would require moving repository-global refs after the rewrite.
- Format changes should ALWAYS be a separate commit (they dominate diffs and
  hide functional changes)
- If a file has both refactoring and new logic, use `git add -p` to split hunks
  within the file
- Prefer too many small commits over too few large ones — they can always be
  squashed later
- Each commit message should explain WHY, not just WHAT
