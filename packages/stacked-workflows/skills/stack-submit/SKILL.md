---
name: stack-submit
description: >-
  Use when you need to push, submit, or create pull requests for a commit stack.
  Rebases only the current stack onto upstream main, validates, and pushes
  INSTEAD of manual git sync + git submit + PR/MR creation. Handles branch
  creation, stacked PR/MR creation with correct base branches.
argument-hint: "[revset]"
disable-model-invocation: false
compatibility: "Requires git-branchless"
---

Submit this worktree's commit stack for review. If an argument is provided, use
it as a revset to select which commits to submit. Default is this worktree's own
stack (`$STACK`, pre-flight step 5).

## Pre-flight

1. **Load references** — read `references/git-branchless.md` (relative to this
   skill's directory) before proceeding.

2. **Confirm repository initialization.** A devenv project with
   `git.branchless.enable` runs `git branchless init` on every shell entry.
   Anywhere else, check and stop if it is missing:

   ```bash
   git config --get branchless.core.mainBranch >/dev/null ||
     echo "not initialized: ask the user to run git branchless init"
   ```

   Do not run `git branchless init` yourself: it rewrites the repository's
   shared configuration and hooks for every worktree.

3. **Require a clean working tree**:

   ```bash
   test -z "$(git status --porcelain --untracked-files=no)" || echo "dirty: commit first"
   ```

   The rebase below carries uncommitted edits across and could strand the
   checkout on a conflict, so if tracked files have changes, stop and ask the
   user to commit them (see **Don't use `git stash`** in
   `references/git-branchless.md`). Untracked files do not affect the move.

4. **Check for stale rebase state**:

   ```bash
   ls -d "$(git rev-parse --git-path rebase-merge)" \
     "$(git rev-parse --git-path rebase-apply)" 2>/dev/null
   ```

   If either exists, run `git rebase --abort` before proceeding. Ask Git for the
   paths: in a linked worktree `.git` is a file, and an on-disk rebase keeps its
   state in that worktree's own git dir.

5. **Derive and fetch the upstream ref, and select this worktree's stack.** If
   `git remote` prints nothing, ask the user for the remote URL and add it
   first. The upstream is the main branch's upstream, falling back to
   `<remote>/<main>`:

   ```bash
   main_branch="$(git config branchless.core.mainBranch || echo main)"
   remote="$(git config "branch.${main_branch}.remote" || echo origin)"
   if [ "$remote" = . ]; then
     # main tracks a local branch: that branch is the upstream; nothing to fetch
     upstream="$(git rev-parse --abbrev-ref "${main_branch}@{upstream}")"
   else
     upstream="$(git rev-parse --abbrev-ref "${main_branch}@{upstream}" 2>/dev/null \
       || echo "${remote}/${main_branch}")"
     git fetch "$remote"   # updates $upstream; no local branch moves
   fi
   if git rev-parse --verify -q "${upstream}^{commit}" >/dev/null; then
     base="$upstream"
   else
     upstream=""           # first push: the remote has no main branch yet
     base="$main_branch"
   fi
   STACK="descendants(roots((stack() & ::HEAD) - ::$base)) - ::$base"
   ```

   `$STACK` is this worktree's own stack: HEAD's first commit past `$base` and
   everything descended from it. Every later revset in this skill uses it
   instead of `stack()`. Local `main` is never updated here, so while it is
   behind `$upstream` the upstream commits count as draft, and `stack()` then
   holds every stack that another worktree branched from them. See **Selecting
   your own stack** in `references/git-branchless.md`.

   When `$upstream` does not resolve (a first push to a remote that has no main
   branch yet), there is nothing to rebase onto. `$base` falls back to local
   `main`, and step 3 is skipped.

   `$remote` is also where the push steps below push. If it is `.` (main tracks
   a local branch), ask the user which remote to push to and set `remote` to it.

   Run this block again in any new shell before a later step or section that
   uses `$upstream`, `$base`, `$remote`, `$STACK` or `$SELECTED`, then redo step
   2's selection and checks.

6. **Check pushDefault**:

   ```bash
   git config remote.pushDefault || git config remote.pushDefault "$remote"
   ```

   `git submit -c` requires this to know where to push new branches.

## Steps

1. **Visualize the stack** with `git sl` to understand what will be submitted.

2. **Determine and check the commit range** from `$ARGUMENTS`:

   ```bash
   # If $ARGUMENTS is empty, this worktree's stack:
   SELECTED="$STACK"

   # If $ARGUMENTS is a revset (use git sl or git branchless log, not git log).
   # current() follows a commit hash to its rewritten copy after step 3's move:
   SELECTED="current($ARGUMENTS) - ::$base"

   : "${STACK:?run pre-flight step 5 first}"
   selected_commits="$(git query -r "$SELECTED")" || exit 1
   test -n "$selected_commits" || { echo "empty selection" >&2; exit 1; }
   stack_commits="$(git query -r "$STACK")" || exit 1
   test -n "$stack_commits" || { echo "empty stack selection" >&2; exit 1; }
   outside="$(git query -r "only($SELECTED, $base) - ($STACK)")" || exit 1
   test -z "$outside" || { printf '%s\n' "$outside"; exit 1; }
   current_worktree="$(git rev-parse --show-toplevel)" || exit 1
   other_heads="$(git worktree list --porcelain | awk -v current="$current_worktree" '
     $1 == "worktree" {
       if (path != "" && path != current && head != "") print head
       path = substr($0, 10); head = ""
     }
     $1 == "HEAD" { head = $2 }
     END { if (path != "" && path != current && head != "") print head }
   ')" || exit 1
   overlap=""
   for other_head in $other_heads; do
     for stack_commit in $stack_commits; do
       if git merge-base --is-ancestor "$stack_commit" "$other_head"; then
         overlap="${overlap}${overlap:+ }${other_head}"
       fi
     done
   done
   test -z "$overlap" || { printf '%s\n' "$overlap"; exit 1; }
   merges="$(git query -r "merges() & ($STACK)")" || exit 1
   test -z "$merges" || { printf '%s\n' "$merges"; exit 1; }
   ```

   - **Empty selection:** stop and ask which commits to submit. HEAD has no
     commits of its own past `$base`: you are on `main`, in a fresh worktree, or
     everything selected is already upstream. Do **not** fall back to `draft()`
     or `stack()`: in a repository with several worktrees both select other
     worktrees' stacks. (A first push of a repository whose whole history is on
     `main` also lands here; the answer is the manual `git push` in step 8.)
   - **The second query prints commits:** stop, show those commits, and ask.
     Either the revset reaches past this worktree's stack (`draft()` does, for
     example), or local `main` has commits that are not on `$upstream` and the
     stack is built on them. The move in step 3 would carry those commits along.
   - **The worktree check prints a commit:** another worktree, including a
     detached one, has its HEAD inside this selection. Stop and ask: step 3
     would rewrite or abandon the commit under that worktree.
   - **The merge query prints a commit:** the stack contains a merge commit, for
     example from merging `origin/main` into it. Stop and tell the user this
     skill does not submit a stack with a merge in it. Step 3 would move only
     the commits below the merge and leave the merge and everything above it,
     HEAD included, on the old base, and it still exits 0.

3. **Rebase the stack onto the latest upstream.** Pre-flight step 5 already
   fetched, so move only the selected stack onto the remote-tracking ref:

   ```bash
   git move -b "$SELECTED" -d "$upstream" || exit 1
   selected_commits="$(git query -r "$SELECTED")" || exit 1
   test -n "$selected_commits" || { echo "selection became empty" >&2; exit 1; }
   ```

   `-b` accepts a revset and moves each selected commit's whole lineage from
   where it leaves `$upstream`, so commits already upstream are never re-moved.
   That holds for a stack without merge commits, which step 2 checked. If
   `$upstream` has not moved, this is a no-op — that's fine. On a first push
   (`$upstream` empty), skip this step. If the selection is empty after the
   move, everything selected was already upstream: stop and say so instead of
   testing and submitting nothing.

   This skill does not use branchless sync because it targets local `main` and
   can span other draft stacks. If the guarded move reports a conflict, it exits
   1 and changes nothing. Stop and ask the user; do not start an on-disk repair.

4. **Run tests across the stack** to validate each commit independently. This is
   the one case where testing every commit is unambiguously right: every commit
   here is about to become its own PR, so every commit has to stand alone.

   ```bash
   git test run -x '<test-command>' --jobs <N> "$SELECTED"
   ```

   Size `<N>` by **memory**, not cores — see **Sizing `--jobs`** in
   `references/git-branchless.md`. Each job is a separate worktree with no
   shared cache, so peak usage is `jobs x per-job footprint`. Never pass
   `--jobs 0` — it means one job per physical CPU and overrides any bound the
   machine's config set, which for a multi-GB command such as `nix flake check`
   exhausts RAM.

   Determine the test command from the project (package.json scripts, Makefile,
   Cargo.toml, etc.). If no obvious test command exists, ask the user. If the
   project has no tests, skip this step.

   If any commit fails, stop and report which commit(s) failed. Do not submit a
   stack with failing tests.

5. **Verify commit messages** — review `git sl` output. Flag any commits with
   vague messages ("fix", "WIP", "update") and ask the user before rewriting
   them.

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

   **Before the first push, drop tracking of `main`.** A branch created from the
   upstream ref (`git worktree add -b <x> <path> origin/main`, or
   `git branch <x> origin/main`) tracks `main`. `git submit` treats every branch
   that has an upstream as already pushed and fetches `refs/heads/<x>`, which
   fails with `fatal: couldn't find remote ref refs/heads/<x>`. `-c` does not
   help. Unset the upstream of each selected branch that tracks main's upstream
   branch, and leave any other tracking alone:

   ```bash
   main_merge="$(git config "branch.${main_branch}.merge" || echo "refs/heads/${main_branch}")"
   for b in $(git query --branches "$SELECTED"); do
     if [ "$b" != "$main_branch" ] \
       && [ "$(git config "branch.$b.merge" || :)" = "$main_merge" ]; then
       git branch --unset-upstream "$b"
     fi
   done
   ```

   `git submit -c` pushes with `--set-upstream`, so afterwards each branch
   tracks its own remote branch and later updates work.

7. **Confirm before pushing** — preview what will be pushed:

   ```bash
   git submit --dry-run "$SELECTED"    # or: git submit -c --dry-run "$SELECTED"
   ```

   Show the dry-run output to the user and ask for confirmation:

   ```
   Ready to push N branches and create N PRs. Proceed? (y/n)
   ```

   **Wait for explicit user approval.** Pushing creates remote branches and PRs
   — these are visible side effects that cannot be easily undone. This gate is
   especially important when the skill is auto-invoked via
   `disable-model-invocation: false`.

8. **Push branches** with `git submit` or `git push`:

   ```bash
   git submit -c "$SELECTED"
   ```

   **Gotcha:** `git submit -c` silently does nothing when commits are on main
   (public/non-draft). This happens when the entire history is being submitted
   for the first time on the main branch. In this case, fall back to manual
   push:

   ```bash
   git push -u "$remote" <branch-1> <branch-2> ... <branch-N>
   ```

   The `-u` flag sets upstream tracking so tools like lazygit show branches as
   in-sync with remote.

   **Gotcha:** `git submit` skips commits with 2+ branches attached. Ensure one
   branch per commit.

   **Gotcha:** `git submit` requires `remote.pushDefault` to be set for
   `--create` mode (pre-flight step 6):

   ```bash
   git config remote.pushDefault "$remote"
   ```

9. **Create stacked PRs/MRs** — for each branch, create a pull/merge request
   targeting the previous branch in the stack (or `main` for the first). Use the
   commit message as the title. Keep the body minimal — the commit diff speaks
   for itself.

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
git submit "$SELECTED"   # force-push existing remote branches (no -c needed)
```

Always pass `"$SELECTED"` (re-derived per pre-flight step 5 and step 2). A bare
`git submit` defaults to `stack()`, which while local `main` is stale holds
other worktrees' stacks too: it then force-pushes their branches once they are
on the remote. If it fails with `couldn't find remote ref`, a selected branch
still tracks `main`; see step 6.

If `git submit` produces no output (public commits on main), force-push all
branches manually:

```bash
git push --force-with-lease "$remote" <branch-1> <branch-2> ... <branch-N>
```

PRs/MRs auto-update when their branches are force-pushed. No need to recreate
them. Only branches downstream of the changed commit need updating, but pushing
all is safe — unchanged branches are skipped automatically.

After each squash-merged PR/MR, you MUST rebase the remaining stack, update the
next PR/MR's base, and force-push remaining branches. Without this, downstream
PRs/MRs show the full diff of all prior commits (the squash merge creates a new
commit hash that downstream branches don't share).

This must be done after EVERY squash merge, not just the first. Each merge
changes main, and all downstream branches need rebasing onto it.

```bash
# 1. Re-run pre-flight step 5 (it fetches) and step 2 (selection and checks),
#    then rebase the remaining stack onto the new upstream (same as step 3)
git move -b "$SELECTED" -d "$upstream"

# 2. Update the next PR/MR's base to main (it was pointing at the merged branch)
#    See platform-specific commands below

# 3. Force-push ALL remaining branches so PRs/MRs show clean single-commit diffs
git push --force-with-lease "$remote" <branch-1> <branch-2> ... <branch-N>
```

#### GitHub

```bash
gh pr edit <next-PR-number> --base main
```

The move skips a commit whose patch is already upstream and deletes its branch,
which handles a single-commit squash merge. A squash merge of several commits is
still detected when their edits do not overlap: each one applies as an empty
commit and is skipped. **Gotcha:** when they overlap, the move conflicts (exit
1, nothing changed). Stop and ask rather than hiding the still-live descendants
(arxanas/git-branchless#965).

If the whole stack has merged, the worktree ends up detached at the upstream tip
with its branch deleted. That is the cue to tear the worktree down, not to
submit again.

### Out-of-order merge recovery

If a PR is merged out of order (e.g., PR N+1 merged before PR N), the squash
goes into the base branch — not main. Merge the base PR (N) next — it now
contains both changes. After merging, re-run pre-flight step 5 (it fetches) and
step 2 (selection and checks), then:

```bash
git move -b "$SELECTED" -d "$upstream"   # may only skip one of the two commits
```

Do not try to update local `main` with `git branch -f main origin/main`: Git
refuses it whenever another worktree has `main` checked out, and the move above
does not need it.

If the move does not skip the already-merged commit, stop and ask. Do not move a
descendant subtree or hide orphaned commits; either can reach another worktree's
line.

## Addressing Review Feedback

When a reviewer (human, Copilot, etc.) comments on a specific PR in the stack:

1. **Identify the target commit** — the PR tells you which branch/commit the
   feedback applies to.

2. **Apply the fix** using `/stack-fix`. It handles both absorb (line-level
   fixes) and manual amend (structural changes) paths, including dry-run
   preview, conflict resolution, and restacking.

3. **Force-push all downstream branches** (target + every branch after it):

   ```bash
   git push --force-with-lease "$remote" <target-branch> <downstream-1> ... <downstream-N>
   ```

4. **Return to the stack tip** after pushing:

   ```bash
   git checkout <tip-branch>   # e.g. todo/pre-publish or the last PR branch
   ```

5. **Reply to and resolve** each review thread. Replying alone does NOT close
   the conversation — you must explicitly resolve each thread in the UI or via
   the platform's API/CLI.

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
- One branch per commit. If a commit has multiple branches, `git submit` skips
  it.
- For very large stacks (20+ PRs), consider batching — submit the first 5-10,
  get them merged, then submit the next batch. Reviewers struggle with 20+ open
  PRs at once.
- **For stacks > 10 commits, script branch creation and PR creation.** Write a
  standalone bash script (not inline shell — zsh doesn't support bashisms like
  `${!array[@]}`). Use `#!/usr/bin/env bash` with strict mode. Add `sleep 1`
  between `gh pr create` calls to avoid GitHub rate limiting.

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
  `git config remote.pushDefault "$remote"`.
- If `git submit -c` produces no output, commits are likely public (on main).
  Use `git push "$remote" <branch> ...` instead.
