---
repo: arxanas/git-branchless
repo-head: f238c0993fea69700b56869b3ee9fd03178c6e32
repo-indexed: 2026-03-21
wiki-head: 98aa4029b230f432416e9029fe6182ed8fa1d695
wiki-indexed: 2026-03-21
issues-indexed: 2026-03-21
discussions-indexed: 2026-03-21
labels-indexed: 2026-03-21
label-head: 904c06c39a895525e0e94a1888d19139c20c7eedfb489ef889635d3ea5d45e30
doc-sources:
  - path: "CHANGELOG.md"
    type: repo-file
    relevance: "version history and breaking changes"
  - path: "CONTRIBUTING.md"
    type: repo-file
    relevance: "development setup and contribution workflow"
  - path: "README.md"
    type: repo-file
    relevance: "primary overview and feature summary"
exclude-issue-patterns:
  - "renovate"
  - "dependabot"
  - "bump version"
  - "release v"
value-labels:
  - name: "bug"
    reason: "confirmed bugs reveal edge cases and error handling details"
  - name: "has-workaround"
    reason: "direct workarounds and recipes for known issues"
  - name: "no-planned-fix"
    reason: "confirmed limitations users must work around"
  - name: "question"
    reason: "resolved Q&A with usage patterns and recipes"
  - name: "documentation"
    reason: "doc gaps and usage clarifications"
  - name: "enhancement"
    reason: "feature discussions and design decisions"
  - name: "good first issue"
    reason: "sometimes reveals architectural patterns"
  - name: "help wanted"
    reason: "community-discussed issues, often contain workarounds"
issue-stats:
  total-fetched: 1551
  from-labels: 248
  from-keywords: 166
  from-reactions: 1465
  after-dedup: 1456 issues + 95 discussions
---

# git-branchless Reference

Distilled from https://github.com/arxanas/git-branchless, updated 2026-03-21.

## Worktree safety

These skills assume the primary checkout can hold a stale local `main`, while
each task uses a linked worktree whose branch was created from `origin/main`.
Another linked worktree may be a sibling, stacked on this worktree, or detached
on either line. Under that topology:

- Select only this worktree's stack with the sibling-safe revset documented in
  **Selecting your own stack**. A selection or guard that errors or resolves to
  no commits must stop the operation.
- Never use a bare `git sync` or `git sync --pull`. Fetch the configured remote,
  then move the guarded selection onto the remote-tracking ref. Do not move
  local `main`.
- Never repair with a bare `git restack`, recursive `git hide -r`, or an
  unchecked `children()` subtree. Those operations can reach commits or branches
  owned by another worktree. Stop and ask the user when the guarded operation
  cannot finish without such a repair.
- Run `git test fix` with `--strategy working-copy --jobs 1 --no-cache`. Cached
  results from a worktree-strategy run can otherwise turn the fix into a
  successful no-op.
- Resolve a restructure base with `git merge-base "$base" HEAD`; the upstream
  tip itself is not the stack's fork point after upstream advances.

## Overview

git-branchless is a suite of Git extensions that adds anonymous branching,
in-memory rebases, commit graph visualization, and a general-purpose undo
system. It enables patch-stack workflows (as used at Meta, Google, and the Linux
project) where the unit of change is an individual commit rather than a branch.
All rewrite operations (move, sync, restack) run in-memory by default, never
touching the working copy unless merge conflicts require it.

The tool is fully compatible with branches — "branchless" refers to the ability
to work _without_ them when convenient, via anonymous branching where all draft
commits stay visible in the smartlog.

**Status:** Alpha. Latest release v0.10.0 (Oct 2024). The maintainer considers
Jujutsu the long-term successor; git-branchless serves as a bridge and workflow
test-bed.

## Installation & Setup

```bash
# Nix (already in your overlay), or:
cargo install --locked git-branchless

# Initialize in each repository (idempotent)
git branchless init

# Set main branch if not auto-detected
git config branchless.core.mainBranch main
```

### Key Configuration

```bash
# Set default push remote for git submit --create
git config remote.pushDefault origin

# Interactive mode for git next when ambiguous
git config branchless.next.interactive true

# Preserve timestamps during restack
git config branchless.restack.preserveTimestamps true

# Test isolation. The default is working-copy, which needs a clean tree and
# reuses build artifacts in place; worktree isolates each commit instead.
# git test fix needs --strategy working-copy regardless (see git test fix).
git config branchless.test.strategy worktree
# Parallelism. Setting worktree above makes fan-out POSSIBLE, so pin the job
# count deliberately. 0 would mean "one job per physical CPU", which is what
# OOM-killed a workstation. See "Sizing --jobs" below.
git config branchless.test.jobs 1

# Define test command aliases
git config branchless.test.alias.check "nix fmt -- --check"

# Revset aliases
git config 'branchless.revsets.alias.d' 'draft()'
```

### All Configuration Options

| Key                                        | Default        | Description                                     |
| ------------------------------------------ | -------------- | ----------------------------------------------- |
| `branchless.core.mainBranch`               | `master`       | Main branch name                                |
| `branchless.next.interactive`              | `false`        | Interactive ambiguity resolution                |
| `branchless.navigation.autoSwitchBranches` | `true`         | Auto-switch to branch on target                 |
| `branchless.restack.preserveTimestamps`    | `false`        | Keep authored timestamp                         |
| `branchless.restack.warnAbandoned`         | `true`         | Warn about abandoned children                   |
| `branchless.smartlog.defaultRevset`        | _(complex)_    | Default smartlog query                          |
| `branchless.commitMetadata.branches`       | `true`         | Show branches in smartlog                       |
| `branchless.commitMetadata.relativeTime`   | `true`         | Show timestamps in smartlog                     |
| `branchless.undo.createSnapshots`          | `true`         | Working copy snapshots for undo                 |
| `branchless.test.strategy`                 | `working-copy` | Test isolation strategy                         |
| `branchless.test.jobs`                     | `1`            | Parallel test jobs (`0` = one per physical CPU) |
| `branchless.test.alias.<name>`             | —              | Named test commands                             |
| `branchless.revsets.alias.<key>`           | —              | Custom revset aliases                           |

## Core Concepts

### Commit Stacks

A series (or subtree) of draft commits. Unlike branches, stacks can diverge into
multiple lines of work. Commands like `git move` operate on entire subtrees, not
just linear sequences.

### Public vs Draft Commits

- **Public**: on the main branch (diamond `◆`/`◇` in smartlog). Immutable.
- **Draft**: your local work, not yet on main (circle `◯`/`●`). Freely
  rewritable.

"Main" here is the **local** main branch (`branchless.core.mainBranch`), never
its remote-tracking ref. A remote ref such as `origin/main` is rejected as a
main branch.

### Stale local main

When you rebase a stack onto `origin/main` without updating local `main` (the
worktree-safe update under `git sync` below), the upstream commits between
`main` and `origin/main` count as **draft** until local `main` catches up. The
same holds for every worktree created from `origin/main` while local `main` is
behind it (`git worktree add -b <x> <path> origin/main`). `stack()` is the whole
draft component around HEAD, so it then holds those upstream commits **and every
stack another worktree branched from them**:

- `git test run 'stack()'` also tests upstream commits and other worktrees'
  stacks.
- `git test fix 'stack()'` **rewrites** them: the stack's base becomes a forged
  copy of an upstream commit, and other worktrees' branches move under them. A
  build that carries the checked-out-branch guard panics instead and leaves HEAD
  detached.
- Any other `stack()`-scoped rewrite (reword, split, move) can reach them too.
- `git submit` (default revset `stack()`) force-pushes other worktrees' branches
  once they are on the remote.

`only(stack(), origin/main)` does not fix this. It drops the upstream commits
but keeps the other worktrees' stacks. Select your own stack instead.

### Selecting your own stack

```bash
base=origin/main   # your upstream ref; local main while the remote has no main yet
own="descendants(roots((stack() & ::HEAD) - ::$base)) - ::$base"
```

Read it from the inside out:

1. `stack() & ::HEAD` is the draft commits HEAD is built on: your own line, not
   the stacks beside it.
2. `- ::$base` drops the ones already upstream.
3. `roots(...)` is your first commit past `$base`.
4. `descendants(...) - ::$base` is that commit and everything built on it. That
   includes forks inside your stack, and the commits above HEAD after
   `git prev`.

`$own` is empty when HEAD has no commits of its own: on `main`, in a fresh
worktree, or once everything has merged. Stop there instead of widening to
`stack()` or `draft()`. It is the same whether local `main` is stale or current,
and it never contains public commits.

Three things it does not guard against:

- **Local `main` commits that are not on the remote.** If your stack sits on
  them, `git move -b` onto `origin/main` carries them along.
  `git query "only($own, $base) - ($own)"` lists them.
- **A worktree stacked on yours.** Its commits descend from yours, so they are
  in `$own`, and moving them moves its checked-out branch. Compare
  `git query --branches "$own"` with the branches in `git worktree list`.
- **A merge commit in the stack**, for example from merging `origin/main` into
  it. `git move -b "$own" -d origin/main` then moves only the commits below the
  merge. It leaves the merge and everything above it, HEAD included, on the old
  base, and still exits 0. `git query "merges() & ($own)"` lists them.

To narrow an explicit revset, subtract: `(<revset>) - ::$base` keeps a single
commit single, while `only(<revset>, $base)` widens it to all its ancestors.
Before any rewrite, check that `(<revset>) - ($own)` is empty. The skills define
this selection as `$STACK`.

### Anonymous Branching

You can make commits in detached HEAD mode. They stay visible in the smartlog
without needing a branch name. Useful for speculative/experimental work.

### Speculative Merges

Operations like `git move` and `git sync` speculatively apply rebases in-memory.
If a merge conflict would occur, they abort cleanly without starting conflict
resolution (unless `--merge` is passed).

That parenthetical is the whole contract, and it is easy to read past: `--merge`
is precisely the opt-in to an **on-disk** rebase. Without it a conflict simply
aborts and nothing is touched. **With `--merge`**, a failed in-memory attempt
falls back to re-running the rebase against the real working copy, where it
stops at the conflict — leaving a detached HEAD and an in-progress rebase to
finish or `git rebase --abort`. `--in-memory` forbids that fallback outright, so
it is the flag to reach for when you need a guaranteed **no on-disk rebase**.

### Bitemporality

git-branchless tracks how commits change over time (like Mercurial's Changeset
Evolution). This powers `git undo` — you can undo any graph operation by
browsing previous states of the repository.

### Working Copy Snapshots

Some commands create ephemeral snapshots of the working copy (including unstaged
changes). These power `git undo` but never include untracked files. Auto
garbage-collected. Disable via `branchless.undo.createSnapshots = false`.

## Command Reference

### Visualization

**`git sl`** (smartlog) — Show your commit graph.

```bash
git sl                    # default: draft commits + branches
git sl 'stack()'          # only current stack
git sl 'branches()'       # only commits with branches
```

Icons: `◆`/`◇` = public, `◯`/`●` = draft (● = HEAD), `✕` = hidden/abandoned.

Visibility rules: shows checked-out commit, commits with branches, your commits
(not hidden), commits with visible descendants, and hidden public commits that
were rewritten. Commits made before `git branchless init` won't appear. For
color in pipes: `git branchless --color always smartlog` (flag goes before
subcommand, arxanas/git-branchless#1308).

### Navigation

**`git next`** / **`git prev`** — Move through the stack.

```bash
git next                  # move to child commit
git next 3                # move 3 commits forward
git next -a               # jump to end of stack (leaf)
git prev -a               # jump to start of stack (root)
git next -b               # jump to next branch
git prev -ab              # jump to first branch in stack
git next -n               # pick newest when ambiguous
git next -i               # interactive selection when ambiguous
```

**`git sw -i`** — Fuzzy interactive switch (powered by Skim).

```bash
git sw -i                 # open selector for all visible commits
git sw -i foo             # pre-filter with search term "foo"
```

### Committing

**`git record`** — Commit without staging.

```bash
git record -m "msg"       # commit all unstaged changes
git record -i             # interactive hunk selection (TUI)
git record -I             # insert commit into middle of stack
git record -c branch-name # create new branch and commit
git record -d             # detach from current branch first
```

Note: If changes are staged, `git record` uses only those. Otherwise it commits
all unstaged tracked changes. Untracked files still need `git add`.

**`git amend`** — Amend current commit + auto-restack descendants.

```bash
git amend                 # amend with all unstaged changes
git add file && git amend # amend with only staged changes
git amend --reparent      # amend without rebasing children (for formatters)
```

**Gotcha:** `git amend` skips pre-commit hooks (arxanas/git-branchless#1275).
Use `git commit --amend` + `git restack <pre-amend-hash>` if hooks are needed
(see `git restack` below for when to use `git move` instead).

### Rewriting

**`git reword`** — Edit commit messages without checkout.

```bash
git reword                         # edit HEAD message in $EDITOR
git reword <hash>                  # edit specific commit's message
git reword <hash> -m "new msg"     # replace message inline
git reword 'stack()'               # batch reword entire stack
```

**Gotcha:** `git reword` rewrites all stack commits even when only one message
changed (arxanas/git-branchless#1385).

**`git move`** — Move commits/subtrees in the graph (in-memory rebase).

```bash
git move -s <src> -d <dest>   # move src + descendants onto dest
git move -b <branch> -d <dest> # move branch's entire lineage onto dest
git move -x <hash> -d <dest>  # move exact commit only (no descendants)
git move -d <dest>             # move current stack onto dest (default -b HEAD)
git move -s <src>              # move src onto HEAD (default -d HEAD)
git move -I                    # insert commit between others
git move -F -x <src> -d <dest> # fixup: combine src into dest
git move --dry-run -d <dest>   # test the in-memory rebase only (see below)
git move --in-memory -d <dest> # never fall back to an on-disk rebase
```

Defaults: no `-d` → `HEAD`; no `-s`/`-b` → `-b HEAD`. Conflicts: fails cleanly
unless `--merge` is passed.

`--dry-run` is `Test whether an in-memory rebase would succeed` — **scoped to
the in-memory attempt, not to the command**. It does not suppress the on-disk
fallback, so it is not a general preview flag the way `git submit --dry-run` is.
See the pitfall below before pairing it with `--merge`.

**`git split`** — Extract changes from a commit.

```bash
git split                 # interactive: extract hunks into new child commit
git split --before        # extracted changes become parent of target
git split --detach        # extracted changes become sibling
git split --discard       # remove extracted changes entirely
```

> **Version note:** `git split` requires unreleased git-branchless (post
> v0.10.0, introduced in PR #1464, Sept 2025). The command does not exist in
> v0.10.0. Use `git rebase -i` + edit or `git revise -c` on released versions.

**`git restack`** — Fix abandoned commits after rewrites.

```bash
git restack               # every abandoned commit in draft(): every worktree's stacks
git restack <hash>        # rebase only the abandoned descendants of <hash>
```

Pass the abandoned (pre-rewrite) hash. `git restack 'stack()'` is not a safe
scope: after amending a stack's first commit, its abandoned descendants are no
longer in `stack()`, so the restack silently does nothing.

The hash limits the commits restack rebases, not the branches it moves. After
rebasing, it moves **every** branch in the repository that still points at a
rewritten commit, including one that another worktree has checked out. A build
with the checked-out-branch guard panics at that point; upstream moves the
branch under that worktree. When `git sl` shows another worktree's branch or
detached HEAD on a `rewritten as` commit, stop and ask the user to repair that
line from its own worktree.

After a `git rebase` (a split, an autosquash), pass `--update-refs` to the
rebase instead. Git then moves every branch inside the rebased range itself, and
nothing is left to restack.

### Stack Management

**`git sync`** — Rebase selected stacks onto updated main.

```bash
git sync 'stack()'                # rebase only current stack onto LOCAL main
git sync --pull 'stack()'         # update LOCAL main first, then rebase (see below)
git sync --merge 'stack()'        # resolve conflicts for current stack
```

`git sync` rebases onto **local** main. That has three consequences when several
worktrees share one repository:

- **A bare `git sync` spans every worktree's stacks.** It rebases every local
  draft stack, including branches checked out in other worktrees. Upstream
  git-branchless bypasses Git's checked-out-branch guard, so those worktrees
  keep a stale index and can show phantom staged changes that a broad `git add`
  turns into unrelated reverts. A build that carries the guard refuses instead,
  possibly after it has already moved some stacks. Always pass an explicit
  revset.
- **`--pull` always updates local main first**, whatever revset you pass. If
  another worktree (usually the primary checkout) has `main` checked out, this
  either fails with `cannot force update the branch 'main' used by worktree`
  (guard present), or moves `main` under that checkout (guard absent), which
  then shows the upstream changes as staged reverts.
- **Without `--pull`, a fetch alone changes nothing.** `git fetch` followed by
  `git sync 'stack()'` reports the stack as up to date, because local main did
  not move.

The worktree-safe way to put the current stack on the latest upstream is to skip
`sync` and move onto the remote-tracking ref directly:

```bash
git fetch origin                     # updates origin/main; no local branch moves
git move -b HEAD -d origin/main      # rebase ONLY the current stack
# on conflict: exit 1 and nothing changed. When ready to resolve:
git move -b HEAD -d origin/main --merge
```

This never writes local `main`. It moves another worktree's branch only when
that worktree is stacked on yours (see **Selecting your own stack**). Local
`main` stays behind until whoever holds it updates it; see **Stale local main**
above for what that does to `stack()`.

In nix-agentic-tools, the `git.branchless.scopedSync` option (bool, default
`false`; the stacked-workflows `"full"` `gitPreset` turns it on) installs
`alias.sync = "branchless sync 'stack()'"`. That fixes the scoping problem for a
bare `git sync`; extra revset arguments are added to `stack()` rather than
replacing it. The alias still rebases onto local main, so `git sync --pull`
keeps the `--pull` failure above.

Conflict handling: skips conflicting stacks by default, prints summary. Fix
individually: `git move -b <hash> -d origin/main --merge`.

**Gotcha:** `git sync --pull` with a dirty working tree can strand you on an old
commit (arxanas/git-branchless#1137). Commit or stash first; the same holds for
`git move`, which carries uncommitted edits across and could strand a
conflicting one. **Gotcha:** `git sync` in worktrees may corrupt the index in
other worktrees (arxanas/git-branchless#1524). Check `git status` afterward.
**Gotcha:** `git sync` and `git move` detect a squash merge of several commits
only when their edits do not overlap: each one then applies as an empty commit
and is skipped. When the edits overlap, the rebase conflicts. Stop and ask the
user rather than recursively hiding descendants (arxanas/git-branchless#965).

**`git submit`** — Push branches to remote.

```bash
git submit                # force-push existing remote branches in stack() (see Stale local main)
git submit -c             # create + push new remote branches
git submit --dry-run      # preview what would be pushed (no side effects)
git submit @              # push only branches at HEAD
git submit 'draft()'      # push all draft branches (every worktree's stacks)
```

Note: force-pushes by design (updating review branches). Set
`git config remote.pushDefault origin` for `--create`.

**Gotcha:** a branch created from the upstream ref
(`git worktree add -b <x> <path> origin/main`, or `git branch <x> origin/main`)
tracks `main`. `git submit` treats every branch that has an upstream as already
pushed and fetches `refs/heads/<x>`, which fails with
`fatal: couldn't find remote ref refs/heads/<x>`, with or without `-c`. Run
`git branch --unset-upstream <x>` before the first submit, or create the branch
with `--no-track`. `git submit -c` pushes with `--set-upstream`, so later
updates work.

**Gotcha:** `git submit` skips commits with 2+ branches attached
(arxanas/git-branchless#1131). One branch per commit.

**Known issue:** GitHub forge (`--forge github`) requires two executions — first
creates PR with wrong base, second fixes it (arxanas/git-branchless#1550).
Multiple bugs with stack reorder (arxanas/git-branchless#1259). Prefer manual
`gh pr create` workflow.

### Undo & Recovery

**`git undo`** — Undo any graph operation.

```bash
git undo                  # undo last operation
git undo -i               # interactive: browse repo states, pick one
```

Can undo: commits, amends, rebases, merges, checkouts, branch operations. Cannot
undo: working copy changes (unless captured in a snapshot), untracked files.
Requires Git v2.29+. Can undo a `git undo`.

**`git hide`** / **`git unhide`** — Remove commits from smartlog.

```bash
git hide <hash>           # hide single commit
git hide -r <hash>        # hide commit + all descendants
git unhide <hash>         # bring back a hidden commit
```

**Gotcha:** `git hide` (without `-r`) still deletes branches on the hidden
commit AND cascades branch deletion to children. If a branch like
`todo/pre-publish` is on a child commit, it gets deleted even though the child
commit itself isn't hidden. Use `git undo` to recover. Always check `git sl` for
child branches before hiding a commit.

**Gotcha:** Directory symlinks in the working tree (e.g., `.claude/skills/foo` →
`../../dev/foo`) cause branchless to panic during `git amend`, `git prev`,
`git next`, and other commands that create working copy snapshots. The error is
`could not create blob from <path>: Is a directory (os error 21)`. Workaround:
remove the symlink before the operation, amend, and recreate the symlink. If
that leaves abandoned descendants, stop and ask rather than running a broad
restack. File symlinks (pointing to a file, not a directory) work fine.

### Testing

**`git test run`** — Run a command across commits.

```bash
git test run -x 'cmd' 'heads(stack())'         # the tip -- usual choice
git test run -x 'cmd' 'stack()'                # every commit in the stack
git test run -x 'make test' 'draft()'          # all drafts, every worktree's
git test run -x 'cmd' --jobs 4                 # bounded parallelism
git test run -x 'cmd' --strategy worktree      # isolated worktrees
git test run -x 'cmd' --search binary          # bisect for first failure
git test run -x 'cmd' -b                       # shorthand for --bisect
git test run -c check                          # use command alias "check"
```

Results are cached by command + tree ID. Use `--no-cache` to bypass.
Environment: `BRANCHLESS_TEST_COMMIT`, `BRANCHLESS_TEST_COMMAND` available.

**`git test fix`** — Apply formatter/linter fixes to each commit.

```bash
git test fix --strategy working-copy --jobs 1 --no-cache -x 'cargo fmt --all'   # format each commit
```

`git test fix` never produces merge conflicts — it replaces each commit's tree
directly, leaving descendants unchanged.

**Gotcha: always pass `--strategy working-copy --jobs 1 --no-cache`.** With the
`worktree` strategy, `git test fix` silently fixes nothing. It runs the command
in a test worktree, but it reads the result with `git status` in the checkout
you ran it from. A clean checkout therefore reports `No commits to fix` and
exits 0. A dirty one gets a partial fix: only the files that are dirty there are
taken from the test worktree. A cached result from an earlier worktree-strategy
run has the same successful-no-op result because the cache is shared in the
common Git directory; `--no-cache` prevents that. `--jobs` above 1 selects
`worktree` whatever the config says, and `working-copy` refuses any other job
count. `working-copy` checks each commit out in the current worktree, so it
needs a clean tree; with uncommitted changes it exits 1 and changes nothing.
Measured on this repo's build (0.11.1), and the cause is upstream code:
`GitRunInfo::working_directory` in `git-branchless-lib/src/git/run.rs` prefers
the invoking directory over the test worktree, and `git test fix` builds the
fixed tree from that status.

**`git test show`** — Show previous test results.

```bash
git test show -x 'cmd'                         # pass/fail summary
git test show -x 'cmd' -v                      # with output
git test clean 'stack()'                       # clear cached results for the stack
git test clean 'all()'                         # clear every cached result
```

`git test clean` **defaults to `@`** when given no revset, and cached results
are keyed by tree OID under `.git/branchless/test/<tree-oid>/`, so they outlive
the commits that produced them. A bare `git test clean` on `main` therefore
reports `Cleaned 0 cached test results.` while the cache is still full. Reach
the orphaned entries with `all()`.

### Choosing the test revset

**Default to the tip, not `stack()`.** Two different situations hide behind "run
the tests on my stack", and only one of them wants per-commit testing:

| Situation                      | Revset           | Why                                                                                                                                     |
| ------------------------------ | ---------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| One PR/MR, several WIP commits | `heads(stack())` | Only the merged result ships. The tip is what reviewers read and what CI gates. Intermediate commits are checkpoints, not deliverables. |
| A stack of independent PRs/MRs | `stack()`        | Each commit lands separately and must stand alone, so each one genuinely has to pass.                                                   |

Use `heads(stack())` for the tip, **not `@`**. They differ exactly when the user
has navigated back with `git prev`: `@` is then a middle commit and testing it
proves nothing about what will merge. `@` is right only as the fallback when
`stack()` is empty — on `main` there is no stack and `heads(stack())` resolves
to zero commits, which would test nothing at all.

Which situation you are in is readable from repository structure rather than
guesswork, because every PR/MR needs its own branch:

```bash
git branchless query 'stack()' | wc -l          # commits in the stack
git branchless query 'stack() & branches()'     # and their branches
```

Two or more branches inside the stack means a stack of PRs. One or zero means a
single PR. The count cannot tell a real two-PR stack from one PR plus a stale
leftover branch, so name the branches you counted when you report — over-testing
is the safe direction, but a stale branch should be visible.

Small, frequent commits inside a single PR are a deliberate, good habit. Do
**not** discourage them, and do not read them as N things to validate: testing
all seven commits of a seven-commit PR runs six evaluations that buy nothing.

Both widening and narrowing are coverage decisions. Never switch silently — say
which revset you used and why.

Read `stack()` in this section as your own stack (`$own`, see **Selecting your
own stack**). While local `main` is behind its upstream, plain `stack()` also
holds upstream commits and other worktrees' stacks. That matters most for
`git test fix`, which would rewrite them.

### Sizing `--jobs` — by memory, not by cores

`--jobs` is a **memory** budget, not a CPU budget. Each job gets its own
worktree with no shared build or evaluation cache, so peak usage is
`jobs x per-job footprint` — sizing it to the core count assumes jobs are cheap.

Measured on this repo's own git-branchless build (`packages/git-branchless`,
which tracks the upstream flake input rather than a release, and whose binary
self-reported `0.11.1`), 8 physical / 16 logical cores, with `HOME` and
`XDG_CONFIG_HOME` pointed at a scratch dir so no real user config leaks in.

Do not treat that version string as a firm anchor: the recipe sets `name`
without `version` and strips `versionCheckHook` precisely because the two can
disagree, and the flake input advances on the normal update sweep. What the
numbers below pin down is behavior, not a release. Only the explicit `jobs = 1`
in the preset is independent of it — an explicit job count is a bound whatever
upstream's default happens to be. Peak concurrency observed by recording a start
timestamp inside each job:

| Global config | `--jobs` flag | Commits | Peak concurrency |
| ------------- | ------------- | ------- | ---------------- |
| none at all   | absent        | 4       | 1                |
| `jobs = 0`    | absent        | 4       | 4                |
| `jobs = 1`    | absent        | 4       | 1                |
| `jobs = 0`    | `1`           | 4       | 1                |
| `jobs = 1`    | `0`           | 4       | 4                |
| `jobs = 0`    | absent        | 12      | 8                |
| `jobs = 0`    | absent        | 7       | 7                |
| `jobs = 1`    | absent        | 7       | 1                |

Three consequences:

1. **`0` does not mean "default", it means "one job per physical CPU".** The
   upstream default is `1`. A config that sets `jobs = 0` is therefore not
   documenting the status quo — it is opting the machine into unbounded fan-out,
   and it is what turned a 7-commit branch into 7 concurrent Nix evaluators.
2. **The CLI flag overrides the config in both directions.** It lowers a
   configured `0` and raises a configured `1`, so a caller that passes an
   explicit `--jobs N` is bounded no matter what the machine's config says — and
   a caller that passes `--jobs 0` is unbounded no matter how careful the config
   was.
3. **`strategy = worktree` is what makes fan-out possible at all.** The default
   `working-copy` runs in one directory and cannot run jobs in parallel.
   Worktree isolation is worth having — it tolerates a dirty tree and leaves
   build artifacts alone — but it is the setting that turns `jobs` into a memory
   question, so the two belong together.

Beware when measuring this yourself: `GIT_CONFIG_GLOBAL=/dev/null` is **not**
enough to isolate git-branchless. Plain `git config --get` honours it, but
git-branchless still reads `$XDG_CONFIG_HOME/git/config`, so a real user preset
silently contaminates the run and every "default" you measure is actually that
preset. Override `HOME` and `XDG_CONFIG_HOME` instead.

Rough per-job footprints:

| Command                        | Per-job footprint | Sane concurrency on a 30 GB box |
| ------------------------------ | ----------------- | ------------------------------- |
| `nix flake check`, `nix build` | 3-4 GB            | 1                               |
| `cargo test`, `go test`        | 0.5-2 GB          | 4-8                             |
| `npm test`, `pytest`           | 0.2-0.5 GB        | all CPUs                        |
| `prettier`, `treefmt`, `fmt`   | < 0.1 GB          | all CPUs                        |

To derive a bound instead of guessing. **`footprint_mb` is the one value you
must set per command** — the default below is Nix's, and leaving it there for a
cheap command needlessly serializes the run:

```bash
# 0. The revset you are about to test, from "Choosing the test revset" above.
revset='heads(stack())'

# 1. What ONE job of YOUR command costs, from the table above.
#    nix ~3500 | cargo, go ~1500 | npm, pytest ~400 | formatters ~100
footprint_mb=3500

# 2. What this machine can spare.
if [ -r /proc/meminfo ]; then
  avail_mb=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
else
  avail_mb=$(( $(sysctl -n hw.memsize) / 1048576 / 2 ))  # macOS: half of RAM
fi

# 3. Bound by memory, then by CPUs, then by how many commits there even are.
jobs=$(( avail_mb * 70 / 100 / footprint_mb ))          # keep 30% headroom
cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
commits=$(git branchless query "$revset" | wc -l)
for cap in "$cpus" "$commits"; do
  if [ "$jobs" -gt "$cap" ]; then jobs="$cap"; fi
done
if [ "$jobs" -lt 1 ]; then jobs=1; fi
echo "$jobs"
```

**Nix does not fit per-commit testing at any `--jobs` value.** At `--jobs 0` a
seven-commit branch peaked at ~24 GB across seven evaluators and got the whole
desktop session OOM-killed on a 30 GB laptop; at `--jobs 1` it is seven
sequential full evaluations sharing no eval cache. Neither is a sane default for
a flake project — test `@` instead, and reach for `stack()` only when the
commits really are independent PRs.

### Querying

**`git query`** — Execute revset queries.

```bash
git query 'stack() & paths.changed(*.nix)'    # nix files in current stack
git query --branches 'draft() & branches()'    # branch names on drafts
git query -r 'stack()'                         # raw hashes for scripting
```

### Diff Tools

**`git branchless difftool`** — Interactive diff viewing (v0.8.0+).

```gitconfig
[difftool "branchless"]
  cmd = git-branchless difftool --read-only --dir-diff $LOCAL $REMOTE
[mergetool "branchless"]
  cmd = git-branchless difftool $LOCAL $REMOTE --base $BASE --output $MERGED
```

## Revset Quick Reference

### Functions

| Function                                      | Description                                         |
| --------------------------------------------- | --------------------------------------------------- |
| `stack([x])`                                  | Draft commits in stack containing x (default: HEAD) |
| `draft()`                                     | All draft (non-public) commits                      |
| `main()`                                      | Tip of main branch                                  |
| `public()`                                    | All public commits (= `ancestors(main())`)          |
| `branches([pat])`                             | Commits with branches (optionally matching pattern) |
| `all()`                                       | All visible commits                                 |
| `none()`                                      | Empty set                                           |
| `children(x)` / `parents(x)`                  | Immediate children/parents                          |
| `descendants(x)` / `ancestors(x)`             | All descendants/ancestors (inclusive)               |
| `ancestors.nth(x, n)` / `parents.nth(x, n)`   | Nth ancestor/parent                                 |
| `heads(x)` / `roots(x)`                       | Leaf/root commits within set                        |
| `merges()`                                    | Merge commits                                       |
| `message(pat)`                                | Commits matching message pattern                    |
| `paths.changed(pat)`                          | Commits touching matching file paths                |
| `author.name(pat)` / `author.email(pat)`      | Filter by author                                    |
| `author.date(pat)` / `committer.date(pat)`    | Filter by date                                      |
| `current(x)`                                  | Resolve rewritten commits to current version        |
| `exactly(x, n)`                               | x only if it contains exactly n commits             |
| `tests.passed([cmd])` / `tests.failed([cmd])` | Test result filters                                 |
| `tests.fixable([cmd])`                        | Commits fixable by `git test fix`                   |

### Operators

| Operator                    | Meaning                                    |
| --------------------------- | ------------------------------------------ |
| `x + y`, `x \| y`, `x or y` | Union                                      |
| `x & y`, `x and y`          | Intersection                               |
| `x - y`                     | Difference (space required: `foo - bar`)   |
| `x % y`, `x..y`             | Only: ancestors of x NOT ancestors of y    |
| `x:y`, `x::y`               | Range: descendants of x AND ancestors of y |
| `:x`, `::x`                 | Ancestors of x                             |
| `x:`, `x::`                 | Descendants of x                           |

### Patterns (for text-matching functions)

- `foo`, `substr:foo` — substring match
- `exact:foo` — exact match
- `glob:foo/*` — glob match
- `regex:foo.*` — regex match
- `before:2024-01-01`, `after:1 month ago` — date patterns

### Aliases

```bash
# Define in git config
git config 'branchless.revsets.alias.d' 'draft()'
git config 'branchless.revsets.alias.onlyChild' 'exactly(children($1), 1)'

# Use anywhere
git query 'd()'
git sl 'onlyChild(HEAD)'
```

## Recipes

### 1. Start a new commit stack from main

```bash
git checkout --detach origin/main   # detached: latest fetched upstream
# make changes...
git record -m "feat(scope): first change"
# make more changes...
git record -m "feat(scope): second change"
git sl                         # verify stack looks right
```

### 2. Edit an old commit's contents

```bash
# Option A: checkout + amend (simplest)
git prev 2                     # navigate to target commit
# make changes...
git amend                      # amend + auto-restack descendants
git next -a                    # return to stack tip

# Option B: amend from anywhere with git-absorb
# make changes in working tree that fix a specific earlier commit
git add -p                     # stage the fix
git absorb --and-rebase        # auto-routes to correct commit

# Option C: make fix commit, then combine
git record -m "fixup! original message"
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash --update-refs <target>~1
# --update-refs moves the branches in the range; no restack needed
```

### 3. Edit an old commit's message

```bash
git reword <hash> -m "feat(scope): better description"
# or open in editor:
git reword <hash>
# batch reword entire stack:
git reword 'stack()'
```

### 4. Reorder commits in a stack

```bash
# Move commit <hash> on top of HEAD (reorder it to after current position)
git move -x <hash> -d HEAD

# Move commit to a specific position
git move -x <hash> -d <target>
```

### 5. Move a commit stack to a new base

```bash
git move -d main               # move current stack onto main
git move -b feature -d main    # move feature's lineage onto main
```

### 6. Split a large commit

```bash
git checkout <hash>
git split                      # interactive (requires unreleased > v0.10.0)
# or with git rebase (works on all versions):
git rebase -i <hash>^          # mark commit as "edit"
git reset HEAD^                # unwind, keep changes in working tree
git add -p && git commit       # first logical group
git add -p && git commit       # second logical group
git rebase --continue
```

### 7. Squash commits together

```bash
# Combine src into dest
git move -F -x <src> -d <dest>

# Or use interactive rebase
git rebase -i main             # mark commits as fixup/squash
```

### 8. Sync the current stack with remote main

```bash
git fetch origin                   # updates origin/main only
git move -b HEAD -d origin/main    # rebase only the current stack
# If the stack conflicts (exit 1, nothing changed), resolve when ready:
git move -b HEAD -d origin/main --merge
```

Worktree-safe: it never writes local `main`. Until local `main` catches up, use
`$own` for later test and rewrite operations (see **Selecting your own stack**).

### 9. Push a stack for review

```bash
# First time: create branches for each commit
git branch feat-part-1 <hash1>
git branch feat-part-2 <hash2>
git submit -c "$own"           # push all new branches

# Subsequent updates after amending/restacking:
git submit "$own"              # force-push existing remote branches
```

Pass `$own` (see **Selecting your own stack**) rather than relying on the
`stack()` default. On a first push, before the remote has `main`, set `base` to
local `main`. If the first `git submit -c` fails with
`couldn't find remote ref`, the branch still tracks `main`; see the `git submit`
gotcha.

### 10. Undo a bad rebase

```bash
git undo                       # undo last operation
# or browse history:
git undo -i                    # interactive state browser
```

### 11. Run tests across the entire stack

```bash
git test run -x 'make test' '@'                # just the tip -- start here
git test run -x 'make test' --jobs 4 'stack()' # every commit, bounded
git test run -x 'make test' --search binary    # find first failing commit
```

### 12. Format all commits in a stack

```bash
git test fix --strategy working-copy --jobs 1 --no-cache -x 'nix fmt' "$own"
# No merge conflicts — each commit's tree is replaced directly.
# worktree strategy or --jobs > 1 silently fixes nothing (see git test fix).
```

### 13. Speculative / divergent development

```bash
git checkout --detach
# try approach A...
git record -m "temp: approach A"
git prev                       # go back to before approach A
# try approach B...
git record -m "temp: approach B"
git sl                         # see both approaches as siblings
# decide on B, hide A:
git hide -r <approach-A-hash>
# clean up temp commits with interactive rebase
```

### 14. Find commits that touched specific files

```bash
git query 'stack() & paths.changed(*.nix)'
git query 'draft() & paths.changed(src/)'
```

### 15. Insert a commit in the middle of a stack

```bash
git prev 2                     # navigate to insertion point
# make changes...
git record -I -m "new middle commit"   # insert + restack children
```

### 16. Resolve "trying to rewrite N public commits"

If main was force-pushed and commits are incorrectly marked as public:

```bash
git restack -f                 # force past the public commit safety check
```

To restack only one abandoned commit's descendants and skip everything else:

```bash
git restack <abandoned-hash>   # only that commit's descendants; the default draft() spans every worktree
```

See arxanas/git-branchless#988 for background on unexpected public status.

### 17. Clean up stale commits after squash-merge

```bash
git fetch origin
git move -b HEAD -d origin/main    # drops commits already applied upstream
git hide "($own) & message('substr:WIP')"  # bulk hide by pattern
```

The move skips a commit whose patch is already upstream
(`Skipped commit (was already applied upstream)`) and deletes the branch on it.
That covers linear merges and single-commit squash merges. A squash merge of
**several** commits produces one patch that matches none of them. When their
edits do not overlap, each commit still applies as an empty one and is skipped
(`Skipped now-empty commit`). When they overlap, the move conflicts (exit 1,
nothing changed). Stop and ask rather than hiding the still-live descendants
(arxanas/git-branchless#965, arxanas/git-branchless#977,
arxanas/git-branchless#1218).

If the whole stack merged, the worktree ends detached at the upstream tip with
its branch deleted. That is the cue to tear the worktree down.

## Anti-Patterns

### Don't use `git stash`

Commit instead. Anonymous commits are first-class in branchless — they appear in
the smartlog and can't be forgotten. Use `git hide` to clean up later.

### Don't run `git rebase` for moves

Use `git move` instead — it's in-memory, handles subtrees, moves branches, and
won't start conflict resolution unexpectedly.

### Don't use `-s` with branch names

`-s` (source) moves the commit and descendants. A branch points to the _last_
commit, so `-s branch` only moves the tip. Use `-b` (base) to move the entire
lineage.

### Don't forget `git restack` after stock git amend

If you use `git commit --amend` instead of `git amend`, descendants are
abandoned. Run `git restack <pre-amend-hash>` to fix, or the scoped `git move`
under `git restack` when another worktree has a stale branch. Better: always use
`git amend` which auto-restacks.

### Don't ignore abandoned commit warnings

When branchless says "This operation abandoned N commits!", run
`git restack <abandoned-hash>` (or `git undo` if it was a mistake). Don't leave
the graph in a broken state.

### Don't resolve conflicts unless needed

`git move` and `git sync` skip conflicts by default. Only pass `--merge` when
you're ready to resolve. This lets you safely try operations without risk.

### Don't read `--dry-run` as a preview of the whole command

`git move --dry-run` tests **whether an in-memory rebase would succeed** — that
is its documented scope, and it is narrower than the name suggests. Paired with
`--merge` it does not preview anything: the in-memory attempt fails on the
conflict, `--merge` sends it to an on-disk rebase, and you are left with a
detached HEAD and a real conflicted working copy from a command you thought was
read-only.

The trap is inherited from a sibling command. `git submit --dry-run` genuinely
has no side effects, so `--dry-run` reads as a universal safety flag across the
suite. It is not one here.

```bash
git move --dry-run --merge -d main   # NOT a preview — can start a real rebase
git move --dry-run -d main           # safe: no --merge, so a conflict aborts
git move --dry-run --in-memory -d main  # safe and explicit
```

The safe preview of a _conflicting_ move is to **omit a flag, not add one**:
without `--merge` the clean abort is the dry run. If you did start one by
accident, `git rebase --abort` returns you to the pre-move tip — and this is
exactly why the rebase backup should be a **tag**, since `--update-refs` moves a
backup branch along with everything else.

### Don't use `feature.manyFiles = true` without workaround

Git v2.40.0+ with `index.skipHash` (set by `feature.manyFiles`) causes libgit2
crashes. Same crash with `--index-version 4` (arxanas/git-branchless#1363).
Workaround: `git config --local index.skipHash false`.

### Don't commit on `main`

Commits on `main` are treated as public — they vanish from draft smartlog and
can't be rewritten. Always detach first (`git checkout --detach`)
(arxanas/git-branchless#860).

### Don't init in a worktree

`git branchless init` only works from the main worktree, not from
`git worktree add` worktrees (arxanas/git-branchless#540).

### GPG/SSH signing not supported

git-branchless cannot sign commits. All rewrite operations produce unsigned
commits. This is a known limitation (arxanas/git-branchless#465, labeled "help
wanted"). Community arxanas/git-branchless#1538 pending.

## Known Bugs

- **"Could not parse reference-transaction-line"** — harmless ERROR log on newer
  Git versions. Operations complete normally (arxanas/git-branchless#1388,
  arxanas/git-branchless#1321).
- **Git v2.46+ test failures** — reference-transaction hook changes break some
  tests; user impact unclear (arxanas/git-branchless#1416).
- **`git sync` slow on `main`** — redundant checkout per stack. Detach first to
  avoid (arxanas/git-branchless#1155).
- **Anti-GC ref accumulation** — 100k+ refs under `refs/branchless/*` over
  months. `git branchless gc` partially helps (arxanas/git-branchless#1125).
- **Rust 1.89+ build failure** — fails to compile with newer Rust
  (arxanas/git-branchless#1585).

## Integration

### With git-absorb

Routes staged fixup changes to the correct commit in the stack automatically.

```bash
git add -p                     # stage the fix
git absorb --and-rebase        # finds target commit, creates fixup, rebases
```

Set `git config absorb.maxStack 50` for deeper stacks.

### With git-revise

In-memory commit rewriting (alternative to rebase for some operations).

```bash
git revise -i                  # interactive rebase alternative
git revise -c <hash>           # split a commit interactively
git revise --autosquash        # process fixup! commits
```

**Caveat:** git-revise does not call `post-rewrite` hooks and updates only the
checked-out branch, so branchless records no rewrite. `git restack` afterwards
finds nothing to do, and any other branch on a rewritten commit stays on the old
one. Use git-revise only when no other branch sits in the rewritten range, or
move those branches yourself. For operations where branchless has equivalents
(`reword`, `split`, `move`), prefer those.

### With GitHub (git submit workflow)

1. Create branches: `git branch feat-1 <hash>` for each commit
2. Push: `git submit -c "$own"` (creates remote branches; see **Selecting your
   own stack**)
3. Create PRs via `gh pr create --base <prev-branch> --head <branch>`
4. After amend/restack: `git submit "$own"` to force-push updates
5. After merge: `git fetch origin && git move -b HEAD -d origin/main` drops
   merged commits (recipe 17), then submit again as in step 4

Set PR base to the previous branch in the stack; GitHub auto-updates dependent
PRs on merge (arxanas/git-branchless#716).

### Hooks Requirement

Hooks installed by `git branchless init` are required for commit tracking, undo,
and auto-restack. Without them, `git move` still works for basic rebasing but
loses commit tracking (arxanas/git-branchless#1286).

### Git Version Compatibility

- **v2.29+**: Full support including `git undo`
- **v2.24-2.27**: Supported, no `git undo`
- **v2.28**: Not supported (reference-transaction bug)
- **v2.46+**: Some test failures (arxanas/git-branchless#1416)
- **<= v2.23**: Not supported
