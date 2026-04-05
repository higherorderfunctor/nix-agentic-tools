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

## Overview

git-branchless is a suite of Git extensions that adds anonymous branching,
in-memory rebases, commit graph visualization, and a general-purpose undo
system. It enables patch-stack workflows (as used at Meta, Google, and the
Linux project) where the unit of change is an individual commit rather than a
branch. All rewrite operations (move, sync, restack) run in-memory by default,
never touching the working copy unless merge conflicts require it.

The tool is fully compatible with branches — "branchless" refers to the ability
to work _without_ them when convenient, via anonymous branching where all draft
commits stay visible in the smartlog.

**Status:** Alpha. Latest release v0.10.0 (Oct 2024). The maintainer considers
Jujutsu the long-term successor; git-branchless serves as a bridge and
workflow test-bed.

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

# Test strategy and parallelism
git config branchless.test.strategy worktree
git config branchless.test.jobs 0

# Define test command aliases
git config branchless.test.alias.check "nix fmt -- --check"

# Revset aliases
git config 'branchless.revsets.alias.d' 'draft()'
```

### All Configuration Options

| Key                                        | Default        | Description                      |
| ------------------------------------------ | -------------- | -------------------------------- |
| `branchless.core.mainBranch`               | `master`       | Main branch name                 |
| `branchless.next.interactive`              | `false`        | Interactive ambiguity resolution |
| `branchless.navigation.autoSwitchBranches` | `true`         | Auto-switch to branch on target  |
| `branchless.restack.preserveTimestamps`    | `false`        | Keep authored timestamp          |
| `branchless.restack.warnAbandoned`         | `true`         | Warn about abandoned children    |
| `branchless.smartlog.defaultRevset`        | _(complex)_    | Default smartlog query           |
| `branchless.commitMetadata.branches`       | `true`         | Show branches in smartlog        |
| `branchless.commitMetadata.relativeTime`   | `true`         | Show timestamps in smartlog      |
| `branchless.undo.createSnapshots`          | `true`         | Working copy snapshots for undo  |
| `branchless.test.strategy`                 | `working-copy` | Test isolation strategy          |
| `branchless.test.jobs`                     | `1`            | Parallel test jobs (0 = auto)    |
| `branchless.test.alias.<name>`             | —              | Named test commands              |
| `branchless.revsets.alias.<key>`           | —              | Custom revset aliases            |

## Core Concepts

### Commit Stacks

A series (or subtree) of draft commits. Unlike branches, stacks can diverge
into multiple lines of work. Commands like `git move` operate on entire
subtrees, not just linear sequences.

### Public vs Draft Commits

- **Public**: on the main branch (diamond `◆`/`◇` in smartlog). Immutable.
- **Draft**: your local work, not yet on main (circle `◯`/`●`). Freely rewritable.

### Anonymous Branching

You can make commits in detached HEAD mode. They stay visible in the smartlog
without needing a branch name. Useful for speculative/experimental work.

### Speculative Merges

Operations like `git move` and `git sync` speculatively apply rebases
in-memory. If a merge conflict would occur, they abort cleanly without
starting conflict resolution (unless `--merge` is passed).

### Bitemporality

git-branchless tracks how commits change over time (like Mercurial's Changeset
Evolution). This powers `git undo` — you can undo any graph operation by
browsing previous states of the repository.

### Working Copy Snapshots

Some commands create ephemeral snapshots of the working copy (including
unstaged changes). These power `git undo` but never include untracked files.
Auto garbage-collected. Disable via `branchless.undo.createSnapshots = false`.

## Command Reference

### Visualization

**`git sl`** (smartlog) — Show your commit graph.

```bash
git sl                    # default: draft commits + branches
git sl 'stack()'          # only current stack
git sl 'branches()'       # only commits with branches
```

Icons: `◆`/`◇` = public, `◯`/`●` = draft (● = HEAD), `✕` = hidden/abandoned.

Visibility rules: shows checked-out commit, commits with branches, your
commits (not hidden), commits with visible descendants, and hidden public
commits that were rewritten. Commits made before `git branchless init`
won't appear. For color in pipes: `git branchless --color always smartlog`
(flag goes before subcommand, arxanas/git-branchless#1308).

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

Note: If changes are staged, `git record` uses only those. Otherwise it
commits all unstaged tracked changes. Untracked files still need `git add`.

**`git amend`** — Amend current commit + auto-restack descendants.

```bash
git amend                 # amend with all unstaged changes
git add file && git amend # amend with only staged changes
git amend --reparent      # amend without rebasing children (for formatters)
```

**Gotcha:** `git amend` skips pre-commit hooks (arxanas/git-branchless#1275). Use `git commit --amend` + `git restack` if hooks are needed.

### Rewriting

**`git reword`** — Edit commit messages without checkout.

```bash
git reword                         # edit HEAD message in $EDITOR
git reword <hash>                  # edit specific commit's message
git reword <hash> -m "new msg"     # replace message inline
git reword 'stack()'               # batch reword entire stack
```

**Gotcha:** `git reword` rewrites all stack commits even when only one message changed (arxanas/git-branchless#1385).

**`git move`** — Move commits/subtrees in the graph (in-memory rebase).

```bash
git move -s <src> -d <dest>   # move src + descendants onto dest
git move -b <branch> -d <dest> # move branch's entire lineage onto dest
git move -x <hash> -d <dest>  # move exact commit only (no descendants)
git move -d <dest>             # move current stack onto dest (default -b HEAD)
git move -s <src>              # move src onto HEAD (default -d HEAD)
git move -I                    # insert commit between others
git move -F -x <src> -d <dest> # fixup: combine src into dest
```

Defaults: no `-d` → `HEAD`; no `-s`/`-b` → `-b HEAD`.
Conflicts: fails cleanly unless `--merge` is passed.

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
git restack               # restack all abandoned commits
git restack <hash>        # restack only children of specific abandoned commit
```

### Stack Management

**`git sync`** — Rebase all stacks onto updated main.

```bash
git sync                  # rebase all draft stacks (local only)
git sync --pull           # fetch remote first, then rebase
git sync 'stack()'        # rebase only current stack
git sync --merge          # resolve conflicts for all stacks
```

Conflict handling: skips conflicting stacks by default, prints summary.
Fix individually: `git move -b <hash> -d main --merge`.

**Gotcha:** `git sync --pull` with a dirty working tree can strand you on an old commit (arxanas/git-branchless#1137). Commit or stash first.
**Gotcha:** `git sync` in worktrees may corrupt the index in other worktrees (arxanas/git-branchless#1524). Check `git status` afterward.
**Gotcha:** Squash-merged PRs are not detected by `git sync` — manually `git hide -r <hash>` (arxanas/git-branchless#965).

**`git submit`** — Push branches to remote.

```bash
git submit                # force-push existing remote branches in stack
git submit -c             # create + push new remote branches
git submit --dry-run      # preview what would be pushed (no side effects)
git submit @              # push only branches at HEAD
git submit 'draft()'      # push all draft branches
```

Note: force-pushes by design (updating review branches). Set
`git config remote.pushDefault origin` for `--create`.

**Gotcha:** `git submit` skips commits with 2+ branches attached (arxanas/git-branchless#1131). One branch per commit.

**Known issue:** GitHub forge (`--forge github`) requires two executions —
first creates PR with wrong base, second fixes it (arxanas/git-branchless#1550). Multiple bugs
with stack reorder (arxanas/git-branchless#1259). Prefer manual `gh pr create` workflow.

### Undo & Recovery

**`git undo`** — Undo any graph operation.

```bash
git undo                  # undo last operation
git undo -i               # interactive: browse repo states, pick one
```

Can undo: commits, amends, rebases, merges, checkouts, branch operations.
Cannot undo: working copy changes (unless captured in a snapshot), untracked
files. Requires Git v2.29+. Can undo a `git undo`.

**`git hide`** / **`git unhide`** — Remove commits from smartlog.

```bash
git hide <hash>           # hide single commit
git hide -r <hash>        # hide commit + all descendants
git unhide <hash>         # bring back a hidden commit
```

**Gotcha:** `git hide` (without `-r`) still deletes branches on the hidden
commit AND cascades branch deletion to children. If a branch like
`todo/pre-publish` is on a child commit, it gets deleted even though the
child commit itself isn't hidden. Use `git undo` to recover. Always check
`git sl` for child branches before hiding a commit.

**Gotcha:** Directory symlinks in the working tree (e.g., `.claude/skills/foo`
→ `../../dev/foo`) cause branchless to panic during `git amend`, `git prev`,
`git next`, and other commands that create working copy snapshots. The error
is `could not create blob from <path>: Is a directory (os error 21)`. Workaround:
remove the symlink before the operation, use `git commit --amend --no-edit` +
`git restack` instead of `git amend`, then recreate the symlink afterward.
File symlinks (pointing to a file, not a directory) work fine.

### Testing

**`git test run`** — Run a command across commits.

```bash
git test run -x 'nix fmt -- --check'          # test current stack
git test run -x 'make test' 'draft()'          # test all drafts
git test run -x 'cmd' --jobs 0                 # parallel (auto CPU count)
git test run -x 'cmd' --strategy worktree      # isolated worktrees
git test run -x 'cmd' --search binary          # bisect for first failure
git test run -x 'cmd' -b                       # shorthand for --bisect
git test run -c check                          # use command alias "check"
```

Results are cached by command + tree ID. Use `--no-cache` to bypass.
Environment: `BRANCHLESS_TEST_COMMIT`, `BRANCHLESS_TEST_COMMAND` available.

**`git test fix`** — Apply formatter/linter fixes to each commit.

```bash
git test fix -x 'cargo fmt --all'              # format each commit
git test fix -x 'cmd' --jobs 0                 # parallel fixing
```

`git test fix` never produces merge conflicts — it replaces each commit's
tree directly, leaving descendants unchanged.

**`git test show`** — Show previous test results.

```bash
git test show -x 'cmd'                         # pass/fail summary
git test show -x 'cmd' -v                      # with output
git test clean 'stack()'                       # clear cached results
```

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
git checkout main
git checkout --detach          # or: git record -d -m "first commit"
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
GIT_SEQUENCE_EDITOR=: git rebase --interactive --autosquash main
git restack                    # if branches were abandoned
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

### 8. Sync all stacks with remote main

```bash
git sync --pull                # fetch + rebase all stacks
# If some stacks conflict:
git move -b <conflicting-root> -d main --merge   # resolve individually
```

### 9. Push a stack for review

```bash
# First time: create branches for each commit
git branch feat-part-1 <hash1>
git branch feat-part-2 <hash2>
git submit -c                  # push all new branches

# Subsequent updates after amending/restacking:
git submit                     # force-push all existing remote branches
```

### 10. Undo a bad rebase

```bash
git undo                       # undo last operation
# or browse history:
git undo -i                    # interactive state browser
```

### 11. Run tests across the entire stack

```bash
git test run -x 'make test'                    # serial, current stack
git test run -x 'make test' --jobs 0           # parallel
git test run -x 'make test' --search binary    # find first failing commit
```

### 12. Format all commits in a stack

```bash
git test fix -x 'nix fmt' --jobs 0
# No merge conflicts — each commit's tree is replaced directly
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

If you only want to restack draft commits and skip public ones:

```bash
git restack 'draft()'          # target only draft commits (this is the default revset)
```

See arxanas/git-branchless#988 for background on unexpected public status.

### 17. Clean up stale commits after squash-merge

```bash
git sync --pull                # auto-cleans linearly merged stacks
git hide -r <hash>             # manually hide squash-merged stacks
git hide "draft() & message('substr:WIP')"  # bulk hide by pattern
```

`git sync` only detects linear merges, not squash merges (arxanas/git-branchless#965, arxanas/git-branchless#977, arxanas/git-branchless#1218).

## Anti-Patterns

### Don't use `git stash`

Commit instead. Anonymous commits are first-class in branchless — they appear
in the smartlog and can't be forgotten. Use `git hide` to clean up later.

### Don't run `git rebase` for moves

Use `git move` instead — it's in-memory, handles subtrees, moves branches,
and won't start conflict resolution unexpectedly.

### Don't use `-s` with branch names

`-s` (source) moves the commit and descendants. A branch points to the _last_
commit, so `-s branch` only moves the tip. Use `-b` (base) to move the entire
lineage.

### Don't forget `git restack` after stock git amend

If you use `git commit --amend` instead of `git amend`, descendants are
abandoned. Run `git restack` to fix. Better: always use `git amend` which
auto-restacks.

### Don't ignore abandoned commit warnings

When branchless says "This operation abandoned N commits!", run `git restack`
(or `git undo` if it was a mistake). Don't leave the graph in a broken state.

### Don't resolve conflicts unless needed

`git move` and `git sync` skip conflicts by default. Only pass `--merge` when
you're ready to resolve. This lets you safely try operations without risk.

### Don't use `feature.manyFiles = true` without workaround

Git v2.40.0+ with `index.skipHash` (set by `feature.manyFiles`) causes
libgit2 crashes. Same crash with `--index-version 4` (arxanas/git-branchless#1363). Workaround:
`git config --local index.skipHash false`.

### Don't commit on `main`

Commits on `main` are treated as public — they vanish from draft smartlog
and can't be rewritten. Always detach first (`git checkout --detach`) (arxanas/git-branchless#860).

### Don't init in a worktree

`git branchless init` only works from the main worktree, not from
`git worktree add` worktrees (arxanas/git-branchless#540).

### GPG/SSH signing not supported

git-branchless cannot sign commits. All rewrite operations produce unsigned
commits. This is a known limitation (arxanas/git-branchless#465, labeled "help wanted").
Community arxanas/git-branchless#1538 pending.

## Known Bugs

- **"Could not parse reference-transaction-line"** — harmless ERROR log on
  newer Git versions. Operations complete normally (arxanas/git-branchless#1388, arxanas/git-branchless#1321).
- **Git v2.46+ test failures** — reference-transaction hook changes break
  some tests; user impact unclear (arxanas/git-branchless#1416).
- **`git sync` slow on `main`** — redundant checkout per stack. Detach
  first to avoid (arxanas/git-branchless#1155).
- **Anti-GC ref accumulation** — 100k+ refs under `refs/branchless/*` over
  months. `git branchless gc` partially helps (arxanas/git-branchless#1125).
- **Rust 1.89+ build failure** — fails to compile with newer Rust (arxanas/git-branchless#1585).

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

**Caveat:** git-revise does not call `post-rewrite` hooks, so branchless
can't track the rewrite. Run `git restack` afterward. For operations where
branchless has equivalents (`reword`, `split`, `move`), prefer those.

### With GitHub (git submit workflow)

1. Create branches: `git branch feat-1 <hash>` for each commit
2. Push: `git submit -c` (creates remote branches)
3. Create PRs via `gh pr create --base <prev-branch> --head <branch>`
4. After amend/restack: `git submit` to force-push updates
5. After merge: `git sync --pull` auto-cleans merged commits

Set PR base to the previous branch in the stack; GitHub auto-updates
dependent PRs on merge (arxanas/git-branchless#716).

### Hooks Requirement

Hooks installed by `git branchless init` are required for commit tracking,
undo, and auto-restack. Without them, `git move` still works for basic
rebasing but loses commit tracking (arxanas/git-branchless#1286).

### Git Version Compatibility

- **v2.29+**: Full support including `git undo`
- **v2.24-2.27**: Supported, no `git undo`
- **v2.28**: Not supported (reference-transaction bug)
- **v2.46+**: Some test failures (arxanas/git-branchless#1416)
- **<= v2.23**: Not supported
