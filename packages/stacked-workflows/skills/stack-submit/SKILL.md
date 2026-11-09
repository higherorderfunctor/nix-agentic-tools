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

   In a new shell, re-derive these variables and redo step 2's selection and
   checks. Preserve any lease snapshot captured before a rewrite; fetching again
   never authorizes refreshing that snapshot.

6. **Capture pinned leases before rewriting**, including step 3's initial move.
   Run this block in the same Bash shell as the later push calls:

   ```bash
   set -euETo pipefail
   shopt -s inherit_errexit 2>/dev/null || :

   lease_remote="$remote"
   lease_heads="$(git ls-remote --heads "$lease_remote")" || exit 1

   push_selected() {
     : "${lease_remote:?capture remote leases before rewriting}"
     : "${lease_heads?capture remote leases before rewriting}"
     local b branches expected
     local -a leases=() refs=()
     branches="$(git query --branches "$SELECTED")" || return 1
     test -n "$branches" || { echo "no selected branches" >&2; return 1; }
     for b in $branches; do
       expected="$(printf '%s\n' "$lease_heads" | awk -v ref="refs/heads/$b" '$2 == ref { print $1 }')"
       leases+=("--force-with-lease=refs/heads/$b:$expected")
       refs+=("refs/heads/$b:refs/heads/$b")
     done
     git push "$@" --set-upstream "${leases[@]}" "$lease_remote" "${refs[@]}"
   }
   ```

   This records the remote's branch tips before any rewrite. A branch absent
   from that snapshot gets an empty expected SHA: its lease requires that the
   remote branch still does not exist. This also covers branches named in step 6
   after the move. A failed remote read stops the workflow; it must never be
   treated as an empty remote.

   Keep `lease_heads`, `lease_remote` and the function in this shell until the
   push finishes. Do not recapture after a rewrite or fetch, including when
   resuming in a new shell: without the original snapshot, stop and recover it
   before pushing. For a later operation, capture a fresh snapshot **before**
   that operation's first rewrite. The push uses the captured remote and
   explicit branch refs, independent of tracking or `push.default`.

   The packaged `git submit` has no expected-SHA option. Its branch forge
   fetches before pushing with bare `--force-with-lease`; even `git submit -c`
   can update existing branches that way. See the **`git submit`** entry in
   `references/git-branchless.md` for the source evidence. Use `push_selected`
   for both new branches and updates throughout this skill.

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
     `main` also lands here; use step 8's explicit `SELECTED` and pinned
     `push_selected` path.)
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
   fetched and step 6 captured the leases, so move only the selected stack onto
   the remote-tracking ref:

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

   Present the branch list to the user for review before proceeding. Every local
   branch on a selected commit is pushed, including incidental review or
   worktree branches. Step 7's dry-run preview shows each remote ref that will
   be published; delete or move an unwanted local branch before publishing.

   The pinned push sets upstream tracking to each branch's own remote branch,
   including branches that initially track `main`.

7. **Confirm before pushing** — preview what will be pushed:

   ```bash
   set -euETo pipefail
   shopt -s inherit_errexit 2>/dev/null || :
   push_selected --dry-run
   ```

   Show the dry-run output to the user and ask for confirmation:

   ```
   Ready to push N branches and create N PRs. Proceed? (y/n)
   ```

   **Wait for explicit user approval.** Pushing creates remote branches and PRs
   — these are visible side effects that cannot be easily undone. This gate is
   especially important when the skill is auto-invoked via
   `disable-model-invocation: false`.

8. **Push branches with the captured leases**:

   ```bash
   set -euETo pipefail
   shopt -s inherit_errexit 2>/dev/null || :
   push_selected
   ```

   This creates absent branches and updates existing ones in the same push. If
   any lease is rejected, stop and inspect the remote change with the user; do
   not refresh the snapshot and retry or replace the command with `git submit`.
   A dry-run does not reserve the remote refs, so the real push must use the
   same leases.

   For a first push whose entire history is on local `main`, step 2 reports an
   empty selection. After agreeing which branches to publish, set `SELECTED` to
   a revset union of their explicit names (separated by `|`, not spaces):

   ```bash
   SELECTED='feat/a|feat/b'
   ```

   Capture their remote snapshot with pre-flight step 6 before any rewrite, skip
   step 3, and use the same preview and push in steps 7 and 8. This path
   publishes public commits without rerunning step 2's empty-stack guard; there
   is no unpinned fallback.

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

### Pinned force-push

Before any amend, fix, restack or move, run pre-flight step 6 to capture the
remote tips and define `push_selected`. This applies to the initial step 3 move
as well as later updates. After the rewrite, re-derive `$SELECTED` using
pre-flight step 5 and step 2's selection and checks, keeping the original lease
snapshot. Preview with `push_selected --dry-run`, then push with `push_selected`
after the required approval.

Never push a base branch tip containing a still-open stacked PR's head. GitHub
then marks that PR merged, and deletes its head branch when the repository
deletes branches on merge.

Never refresh the expected tips after the rewrite. Bare `--force-with-lease`
compares against remote-tracking refs, which any fetch (including another
worktree's fetch) can update. The explicit SHA captured before rewriting still
rejects a competing push after such a fetch. An empty expected SHA requires an
absent branch, so a competing branch creation is rejected too.

PRs/MRs auto-update when their branches are force-pushed. No need to recreate
them. Only branches downstream of the changed commit need updating, but pushing
all is safe — unchanged branches are skipped automatically.

### Before merging

Before the user or agent merges any PR/MR, find every open PR whose base is the
merging PR's head branch:

```bash
gh pr list --base <branch> --state open --limit 1000 --json number
```

Here `<branch>` is the merging PR's head branch. Retarget each dependent PR to
the merging PR's current base BEFORE merging:

```bash
gh pr edit <dependent-PR-number> --base <current-base-branch>
```

For the bottom PR, the current base is `main`: use
`gh pr edit <dependent-PR-number> --base main`. For an out-of-order merge of PR
N+1 into branch N, use branch N instead. Confirm every affected PR is still open
and targets that current base:

```bash
gh pr view <dependent-PR-number> --json state,baseRefName
```

If any retarget or confirmation fails, stop before merging. Repeat this before
every PR/MR merge. On GitLab or another forge, use its target-branch controls to
move every open dependent MR/PR to the merging MR/PR's current base and confirm
each remains open and targets that base before merging.

On GitHub, an observed merge that deleted the base branch recorded a
`BaseRefDeletedEvent`, followed by an `AutomaticBaseChangeSucceededEvent` (base
moved to `main`) and a `ClosedEvent` on the dependent PR. The retarget and close
happened in the same second, right after the deletion. That PR ended CLOSED with
state reason COMPLETED even though its base had moved to `main`. Do not rely on
automatic retargeting to keep dependent PRs open.

### After each squash merge

After each squash-merged PR/MR, you MUST move the remaining stack onto the new
upstream, confirm the next PR/MR's base, and force-push the remaining branches.
Without this, downstream PRs/MRs show the full diff of all prior commits (the
squash merge creates a new commit hash that downstream branches don't share). Do
it after EVERY squash merge, not just the first: each merge changes main.

Move only the remaining commits with `git move -s`, not `-b`. `-b` moves the
whole lineage of the selection from where it leaves `$upstream`, so it drags the
merged (now squashed) commits along; `-s <first remaining>` moves exactly that
commit and its descendants. Never run a bare `git restack` here: it selects
other worktrees' stacks and stale branches repo-wide (see **Rewriting** in
`references/git-branchless.md`).

1. **Fetch and detach review checkouts.** Re-run pre-flight step 5 (it fetches).
   A worktree you own that has a stack commit checked out (for example a review
   checkout) would be rewritten under you, and step 2's worktree check refuses
   it: `git -C <path> switch --detach "$upstream"`. For a worktree you do not
   own, stop and ask.
2. **Select the remaining commits.** `$STACK` still holds the merged commits,
   because the squash created a new commit upstream. Name the first commit whose
   PR/MR is still open, select it and its descendants, then re-run step 2's
   checks on that selection:

   ```bash
   first="<first remaining commit>"
   SELECTED="descendants($first) - ::$base"
   git query -r "$SELECTED"            # must list only the unmerged commits
   tip="$(git query -r "heads($SELECTED)")"
   [ "$tip" = "$(git rev-parse HEAD)" ] || { echo "check out the tip: $tip"; exit 1; }
   old_base="$(git rev-parse "${first}^")"
   old_tip="$(git rev-parse HEAD)"
   ```

   Before the move, capture the lease for every remaining branch (Pinned
   force-push).

   If every PR/MR in the stack merged, nothing remains to move: skip the rest of
   this recipe and tear the worktree down instead of submitting again.

3. **Push a backup** of the tip to the remote before rewriting, under a name of
   its own so an earlier rewrite's backup is never overwritten, for example
   `git push "$remote" "HEAD:refs/heads/archive/pre-move-$(git rev-parse --short HEAD)"`.
   A local tag or branch is not a safe backup.
4. **Move.** `git move --dry-run` only tests the in-memory attempt, so use it as
   the preview and then run the real move:

   ```bash
   git move --dry-run -s "$first" -d "$upstream" || exit 1
   git move -s "$first" -d "$upstream" || exit 1
   ```

   If it reports a conflict it exits 1 and changes nothing. Stop and ask the
   user.

5. **Verify nothing else changed.** `git range-diff` must show every remaining
   patch unchanged (a `=` row for each commit):

   ```bash
   git range-diff "$old_base..$old_tip" "$upstream..HEAD"
   git sl
   ```

6. **Force-push with pinned leases.** Push every remaining branch with the lease
   step 2 captured (Pinned force-push). Do not fetch to refresh the lease: a
   fetch is what makes the bare form pass.

7. **Confirm the next PR/MR is open and targets main.** Retargeting had to
   happen before the merge (see **Before merging**); a base of `main` alone does
   not prove the PR/MR stayed open. If a dependent PR/MR closed unexpectedly,
   stop and report it before continuing.

Because `-s` starts at the first remaining commit, the move never has to skip an
already-merged patch, so a multi-commit squash needs no special handling. If a
remaining commit's edits overlap the new upstream, the move conflicts (exit 1,
nothing changed): stop and ask rather than hiding the still-live descendants
(arxanas/git-branchless#965).

Step 3's `-b` move, by contrast, skips a commit whose patch is already upstream
and deletes its branch. It detects a squash of several commits only when their
edits do not overlap, each applying as an empty commit; when they overlap, it
conflicts.

### Out-of-order merge recovery

Before merging PR N+1 into branch N, apply **Before merging**: retarget every
open dependent PR/MR (including N+2) from branch N+1 to branch N and confirm
each remains open and targets branch N.

If a PR is merged out of order (e.g., PR N+1 merged before PR N), the squash
goes into the base branch — not main. Merge the base PR (N) next — it now
contains both changes. After merging, the commits for both PRs are upstream:
re-run pre-flight step 5 (it fetches), then run the squash-merge recipe above
with `$SELECTED` limited to what remains, and `-s` on the first commit that is
still unmerged.

Do not try to update local `main` with `git branch -f main origin/main`: Git
refuses it whenever another worktree has `main` checked out, and the move does
not need it.

If a merged commit is still in the selection, stop and ask. Do not start the
move at a merged commit or hide orphaned commits; either can reach another
worktree's line.

## Addressing Review Feedback

When a reviewer (human, Copilot, etc.) comments on a specific PR in the stack:

1. **Identify the target commit** — the PR tells you which branch/commit the
   feedback applies to. Before step 2, capture the lease for the target and
   every downstream branch (Pinned force-push).

2. **Apply the fix** using `/stack-fix`. It handles both absorb (line-level
   fixes) and manual amend (structural changes) paths, including dry-run
   preview, conflict resolution, and restacking.

3. **Force-push all downstream branches** (target + every branch after it):

   Push with the pinned lease (Pinned force-push) for the target and downstream
   branches.

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
- Use one branch per commit so each stacked PR has a clear base.
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
