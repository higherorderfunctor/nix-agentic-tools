---
name: stack-submit
description: >-
  Use when you need to push, submit, or create pull requests for a commit
  stack. Syncs, validates, and pushes INSTEAD of manual git sync + git submit
  + PR/MR creation. Handles branch creation, stacked PR/MR creation with
  correct base branches.
argument-hint: "[revset]"
disable-model-invocation: false
compatibility: "Requires git-branchless"
---

Submit the current commit stack for review. If an argument is provided, use it
as a revset to select which commits to submit. Default is the current stack.

## Pre-flight

1. **Load references** — read `references/git-branchless.md` (relative to this
   skill's directory) before proceeding.

2. **Check branchless init**:
   ```bash
   if [ ! -d ".git/branchless" ]; then git branchless init; fi
   ```

3. **Check for stale rebase state**:
   ```bash
   ls .git/rebase-merge .git/rebase-apply 2>/dev/null
   ```
   If present, run `git rebase --abort` before proceeding.

4. **Check remote and pushDefault**:
   ```bash
   git remote -v
   git config remote.pushDefault
   ```
   If no remote exists, ask the user for the remote URL.
   If `remote.pushDefault` is not set, set it:
   ```bash
   git config remote.pushDefault origin
   ```
   `git submit -c` requires this to know where to push new branches.

## Steps

1. **Visualize the stack** with `git sl` to understand what will be submitted.

2. **Determine the commit range** from `$ARGUMENTS`:
   ```bash
   # If $ARGUMENTS is a revset (use git sl or git branchless log, not git log):
   git sl

   # If $ARGUMENTS is empty, try stack():
   git sl

   # If on main with no stack, use draft():
   git query 'draft()'

   # If all commits are public (on main), the user needs to specify
   # a range explicitly or use --root
   ```

3. **Sync with main** to ensure the stack is up to date:
   ```bash
   git sync --pull
   ```
   If this is the first push (remote main doesn't exist or has fewer commits),
   sync may be a no-op — that's fine.

   If conflicts are reported (without `--merge`), stop and inform the user
   which commits conflict. Ask if they want to resolve with
   `git sync --merge` or handle individually with
   `git move -b <hash> -d main --merge`.

4. **Run tests across the stack** to validate each commit independently:
   ```bash
   git test run -x '<test-command>' 'stack()'
   ```
   Determine the test command from the project (package.json scripts, Makefile,
   Cargo.toml, etc.). If no obvious test command exists, ask the user. If the
   project has no tests, skip this step.

   If any commit fails, stop and report which commit(s) failed. Do not submit
   a stack with failing tests.

5. **Verify commit messages** — review `git sl` output. Flag any commits with
   vague messages ("fix", "WIP", "update") and suggest rewording with
   `git reword <commit>`.

6. **Ensure branches exist** on each commit. For commits without branches,
   generate branch names from commit messages:
   ```bash
   # Pattern: type/scope or type/short-description
   # feat(flake): add minimal flake skeleton → feat/flake-skeleton
   # docs(references): add git-branchless reference → docs/git-branchless-reference
   # chore: add TODO.md → chore/add-todo
   ```

   Create branches:
   ```bash
   git branch <branch-name> <commit-hash>
   ```

   Present the branch list to the user for review before proceeding.

7. **Confirm before pushing** — preview what will be pushed:
   ```bash
   git submit --dry-run    # or: git submit -c --dry-run (first push)
   ```
   Show the dry-run output to the user and ask for confirmation:
   ```
   Ready to push N branches and create N PRs. Proceed? (y/n)
   ```
   **Wait for explicit user approval.** Pushing creates remote branches
   and PRs — these are visible side effects that cannot be easily undone.
   This gate is especially important when the skill is auto-invoked via
   `disable-model-invocation: false`.

8. **Push branches** with `git submit` or `git push`:
   ```bash
   git submit -c
   ```

   **Gotcha:** `git submit -c` silently does nothing when commits are on main
   (public/non-draft). This happens when the entire history is being submitted
   for the first time on the main branch. In this case, fall back to manual
   push:
   ```bash
   git push -u origin <branch-1> <branch-2> ... <branch-N>
   ```
   The `-u` flag sets upstream tracking so tools like lazygit show branches
   as in-sync with remote.

   **Gotcha:** `git submit` skips commits with 2+ branches attached. Ensure
   one branch per commit.

   **Gotcha:** `git submit` requires `remote.pushDefault` to be set for
   `--create` mode:
   ```bash
   git config remote.pushDefault origin
   ```

9. **Create stacked PRs/MRs** — for each branch, create a
   pull/merge request targeting the previous branch in the stack (or `main`
   for the first). Use the commit message as the title. Keep the body
   minimal — the commit diff speaks for itself.

#### GitHub

```bash
# First commit after main:
gh pr create --head <branch-1> --base main \
  --title "<commit message>" --body "$(cat <<'EOF'
## Summary
<one-line description>

Stack: 1/N

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"

# Subsequent commits:
gh pr create --head <branch-N> --base <branch-N-1> \
  --title "<commit message>" --body "..."
```

10. **Report results** — show a summary table:

    ```
    | # | Branch | PR/MR | Base | Status |
    |---|--------|----|------|--------|
    | 1 | feat/flake-skeleton | #2 | main | created |
    | 2 | chore/formatting | #3 | feat/flake-skeleton | created |
    | ... | ... | ... | ... | ... |
    | 25 | todo/pre-publish | — | (tracking only) | pushed |
    ```

## Subsequent Updates

After amending or restacking commits, re-submit with:

```bash
git submit    # force-push all existing remote branches (no -c needed)
```

If `git submit` produces no output (public commits on main), force-push all
branches manually:

```bash
git push --force-with-lease origin <branch-1> <branch-2> ... <branch-N>
```

PRs/MRs auto-update when their branches are force-pushed. No need to recreate them.
Only branches downstream of the changed commit need updating, but pushing all
is safe — unchanged branches are skipped automatically.

After each squash-merged PR/MR, you MUST sync, update the next PR/MR's base,
and force-push remaining branches. Without this, downstream PRs/MRs show the full
diff of all prior commits (the squash merge creates a new commit hash that
downstream branches don't share).

This must be done after EVERY squash merge, not just the first. Each merge
changes main, and all downstream branches need rebasing onto it.

```bash
# 1. Sync: rebases stack onto the new squash-merged main
git sync --pull

# 2. Update the next PR/MR's base to main (it was pointing at the merged branch)
#    See platform-specific commands below

# 3. Force-push ALL remaining branches so PRs/MRs show clean single-commit diffs
git push --force-with-lease origin <branch-1> <branch-2> ... <branch-N>
```

#### GitHub

```bash
gh pr edit <next-PR-number> --base main
```

**Gotcha:** Squash-merged PRs are not always detected by `git sync` — manually
`git hide -r <hash>` if needed (arxanas/git-branchless#965).

### Out-of-order merge recovery

If a PR is merged out of order (e.g., PR N+1 merged before PR N), the squash
goes into the base branch — not main. Merge the base PR (N) next — it now
contains both changes. After merging:

```bash
git fetch origin && git branch -f main origin/main
git sync --pull     # may only skip one of the two commits
```

If `git sync` doesn't skip the already-merged commit, move the remaining
stack past it:

```bash
git move -s <first-unskipped-hash> -d main
```

Then hide orphaned commits and force-push all branches.

## Addressing Review Feedback

When a reviewer (human, Copilot, etc.) comments on a specific PR in the stack:

1. **Identify the target commit** — the PR tells you which branch/commit the
   feedback applies to.

2. **Apply the fix** using `/stack-fix`. It handles both absorb (line-level
   fixes) and manual amend (structural changes) paths, including dry-run
   preview, conflict resolution, and restacking.

3. **Force-push all downstream branches** (target + every branch after it):
   ```bash
   git push --force-with-lease origin <target-branch> <downstream-1> ... <downstream-N>
   ```

4. **Return to the stack tip** after pushing:
   ```bash
   git checkout <tip-branch>   # e.g. todo/pre-publish or the last PR branch
   ```

5. **Reply to and resolve** each review thread. Replying alone does NOT
   close the conversation — you must explicitly resolve each thread in the
   UI or via the platform's API/CLI.

   #### GitHub

   ```bash
   # Get unresolved thread IDs for a PR
   gh api graphql -f query='{
     repository(owner: "<owner>", name: "<repo>") {
       pullRequest(number: <N>) {
         reviewThreads(first: 100) {
           nodes { id isResolved }
         }
       }
     }
   }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not) | .id'

   # Resolve each thread
   gh api graphql -f query='mutation {
     resolveReviewThread(input: {threadId: "<thread-id>"}) {
       thread { isResolved }
     }
   }'
   ```

## Tips

- Always start with `git sl` to understand the stack before submitting.
- One branch per commit. If a commit has multiple branches, `git submit` skips it.
- For very large stacks (20+ PRs), consider batching — submit the first 5-10,
  get them merged, then submit the next batch. Reviewers struggle with 20+ open
  PRs at once.
- **For stacks > 10 commits, script branch creation and PR creation.** Write
  a standalone bash script (not inline shell — zsh doesn't support bashisms
  like `${!array[@]}`). Use `#!/usr/bin/env bash` with strict mode. Add
  `sleep 1` between `gh pr create` calls to avoid GitHub rate limiting.

  Template for scripted stacked PR creation:
  ```bash
  #!/usr/bin/env bash
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  # Define stack: branch names and commit messages in order
  BRANCHES=("feat/first" "feat/second" "feat/third")
  TITLES=("feat: first change" "feat: second change" "feat: third change")
  TOTAL=${#BRANCHES[@]}

  for i in "${!BRANCHES[@]}"; do
    branch="${BRANCHES[$i]}"
    title="${TITLES[$i]}"
    pos=$((i + 1))
    base=$([[ $i -eq 0 ]] && echo "main" || echo "${BRANCHES[$((i - 1))]}")

    echo "Creating PR ${pos}/${TOTAL}: ${branch} -> ${base}"
    gh pr create --head "${branch}" --base "${base}" \
      --title "${title}" --body "Stack: ${pos}/${TOTAL}"
    sleep 1
  done
  ```
- If `git submit -c` fails with "no remote configured", set
  `git config remote.pushDefault origin`.
- If `git submit -c` produces no output, commits are likely public (on main).
  Use `git push origin <branch> ...` instead.
