---
repo: tummychow/git-absorb
repo-head: debdcd28d9db2ac6b36205bda307b6693a6a91e7
repo-indexed: 2026-03-22
wiki-head: null
wiki-indexed: null
issues-indexed: 2026-03-22
discussions-indexed: null
labels-indexed: 2026-03-22
label-head: 61da6cc314d0c00da78c5a875e51a4c71241dad289c628c295baee450d1c42ff
doc-sources:
  - path: "Documentation/git-absorb.adoc"
    type: repo-file
    relevance: "man page with authoritative flag/option/config reference"
  - path: "Documentation/README.md"
    type: repo-file
    relevance: "documentation build instructions"
  - path: "README.md"
    type: repo-file
    relevance: "primary overview, usage examples, and motivation"
exclude-issue-patterns:
  - "renovate"
  - "dependabot"
  - "bump version"
  - "release v"
value-labels:
  - name: "bug"
    reason: "resolved bugs reveal workarounds and confirmed patterns"
  - name: "enhancement"
    reason: "feature discussions and design decisions"
  - name: "packaging"
    reason: "installation and packaging context"
  - name: "question"
    reason: "direct Q&A, recipes, usage clarification"
  - name: "upstream"
    reason: "known limitations blocked on libgit2/git2-rs with workarounds"
issue-stats:
  total-fetched: 231
  from-labels: 19
  from-keywords: 0
  from-reactions: 212
  after-dedup: 212
---

# git-absorb Reference

Distilled from https://github.com/tummychow/git-absorb, updated 2026-03-22.

## Overview

git-absorb is a port of Facebook's `hg absorb` for Mercurial. It automatically
folds staged changes into the correct ancestor commits by analyzing whether
patches "commute" (apply identically regardless of order). It examines a range
of recent commits (default: 10), identifies which ones modified the staged
lines, and creates `fixup!` commits accordingly.

The key insight: if a staged hunk modifies lines that were last touched by
exactly one ancestor commit, that hunk can be unambiguously attributed to that
commit. git-absorb creates fixup commits for each such match.

## Installation & Setup

Available in nixpkgs, Homebrew, Arch, Debian, Fedora, and others. From crates.io:
`cargo install git-absorb`.

### Recommended Configuration

```bash
# Increase stack depth for branchless workflows (default: 10)
git config absorb.maxStack 50

# One fixup per commit (cleaner history)
git config absorb.oneFixupPerCommit true

# Auto-stage tracked changes if nothing staged
git config absorb.autoStageIfNothingStaged true

# Always reference targets by SHA (stable across rewording)
git config absorb.fixupTargetAlwaysSHA true
```

## Core Concepts

### Patch Commutation

git-absorb checks whether a staged hunk can be unambiguously attributed to a
single ancestor commit. If the lines modified in the hunk were last touched by
exactly one commit in the stack, the hunk "commutes" to that commit. If
multiple commits touched those lines, git-absorb skips the hunk (it's
ambiguous).

### Fixup Commits

git-absorb creates `fixup!` commits (or `squash!` with `--squash`). These are
consumed by `git rebase --autosquash` to fold into their targets. The
`--and-rebase` flag runs the rebase automatically.

### Stack Depth

By default, only the last 10 commits are candidates. Set `absorb.maxStack=50`
for deeper stacks. Use `--no-limit` to consider all commits until root, a
merge, or a different author. Use `--base <commit>` for explicit targeting.

### Stack Boundaries

The revwalk stops at: the root commit, merge commits, commits by a different
author (unless `--force-author`), or the configured depth limit.

## Command Reference

```
git absorb [FLAGS] [OPTIONS]
```

### Flags

| Flag                         | Description                                            |
| ---------------------------- | ------------------------------------------------------ |
| `-f, --force`                | Skip all safety checks (author + detach)               |
| `-F, --one-fixup-per-commit` | Consolidate to one fixup per target commit             |
| `--force-author`             | Create fixups for other authors' commits               |
| `--force-detach`             | Allow on detached HEAD                                 |
| `-n, --dry-run`              | Show what would happen without making changes          |
| `--no-limit`                 | Remove stack depth limit                               |
| `-r, --and-rebase`           | Run autosquash rebase after creating fixups            |
| `-s, --squash`               | Create squash commits (edit message) instead of fixup  |
| `-v, --verbose`              | Display more output                                    |
| `-w, --whole-file`           | Match first commit touching same file (not line-level) |

### Options

| Option                | Description                                          |
| --------------------- | ---------------------------------------------------- |
| `-b, --base <commit>` | Explicit base commit for absorb range                |
| `-m, --message <msg>` | Body text for all generated fixup commits            |
| `-- <REBASE_OPTIONS>` | Pass-through options for `git rebase` (must be last) |

### Configuration (`[absorb]` in .gitconfig)

| Key                        | Default | Description                                  |
| -------------------------- | ------- | -------------------------------------------- |
| `autoStageIfNothingStaged` | false   | Auto-stage tracked changes if nothing staged |
| `createSquashCommits`      | false   | Create squash commits instead of fixup       |
| `fixupTargetAlwaysSHA`     | false   | Reference targets by SHA, not message        |
| `forceAuthor`              | false   | Allow fixups to other authors' commits       |
| `forceDetach`              | false   | Allow on detached HEAD                       |
| `maxStack`                 | 10      | Number of ancestor commits to consider       |
| `oneFixupPerCommit`        | false   | One fixup per target commit                  |

## Recipes

### 1. Fix a bug in an earlier stack commit

```bash
# Edit the file with the fix
vim src/broken.rs
# Stage only the fix
git add -p
# Create fixup and rebase in one step
git absorb --and-rebase
```

### 2. Bulk fixes across multiple stack commits

```bash
# Make all your fixes across multiple files
# Stage everything
git add -A
# Absorb routes each hunk to the correct commit
git absorb --and-rebase
```

### 3. Preview what absorb would do

```bash
git add -p
git absorb --dry-run
# If satisfied:
git absorb --and-rebase
```

### 4. Handle leftover staged changes

After absorb, any staged hunks it couldn't attribute remain staged. Check
`git status` to see what's left; these need manual fixups:

```bash
git add -A
git absorb --and-rebase
# Check if anything remains staged (absorb couldn't find a target)
git status
# Manually create a fixup for leftovers
git commit --fixup=<target-hash>
GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash main
```

### 5. Absorb into a deep stack

```bash
# Temporarily increase depth
git absorb --and-rebase --base main

# Or configure permanently
git config absorb.maxStack 50
git absorb --and-rebase
```

### 6. Recover from a bad absorb

```bash
# Undo everything absorb did (ref set before any fixups are created)
git reset --soft PRE_ABSORB_HEAD
```

### 7. Absorb with auto-staging

```bash
# With config: absorb.autoStageIfNothingStaged = true
# Don't stage anything -- absorb stages tracked changes, creates fixups,
# then unstages whatever it couldn't absorb
git absorb --and-rebase
```

### 8. Pair programming: fixup a colleague's commits

```bash
# Per-repo (or use absorb.forceAuthor = true in config)
git absorb --force-author --and-rebase
```

### 9. Pass extra options to rebase

```bash
# Run pre-commit hooks on each rebased commit
git absorb --and-rebase -- -x "pre-commit run --all-files"

# Update stacked branch refs during rebase
git absorb --and-rebase -- --update-refs
```

### 10. Use --whole-file for new-line additions

When absorb can't match new lines (e.g., an `import` statement added to
support code in an earlier commit), `--whole-file` matches to the last
commit that touched the same file:

```bash
git add -p
git absorb --whole-file --and-rebase
```

## What Absorb Cannot Do

Absorb only handles **in-place line modifications** — hunks where lines in a
staged file replace lines introduced by an earlier commit. These operations
require manual `git commit --amend` or `git checkout` + amend instead:

- **New files** — absorb reports "not in-place file modifications"
- **Deleted files** — same; can't route a deletion to a commit
- **Renamed/moved files** — same
- **Multi-line format changes** (e.g., YAML list → string) where the hunk
  spans both added and removed lines that don't match a single commit's
  context — absorb can't find a unique target
- **Content that commutes with all candidates** — if the staged hunk could
  apply cleanly to any commit in the stack, absorb can't choose and skips it

When absorb can't route a hunk, it remains staged. Check `git diff --cached`
after absorb to see what's left, then handle manually.

## Anti-Patterns

### Don't use `--force` as a default

`--force` skips all safety checks (author, detach). Use `--force-author` or
`--force-detach` for specific overrides.

### Don't expect hook support

git-absorb uses libgit2 for commits, which does **not** run pre-commit hooks.
If your workflow requires hooks, run them manually after absorb:

```bash
git absorb --and-rebase
pre-commit run --from-ref HEAD~5 --to-ref HEAD  # if using pre-commit framework
# Or pass -x to rebase:
git absorb --and-rebase -- -x "pre-commit run --all-files"
```

### Don't rely on `includeIf` gitconfig

libgit2 doesn't fully support `includeIf` directives. If you use conditional
includes (e.g., for work email), put overrides in the repo's `.git/config`
instead. This also affects `GIT_AUTHOR_EMAIL` / `GIT_COMMITTER_EMAIL` env
vars -- libgit2 may not respect them for the author check. Use
`--force-author` or `absorb.forceAuthor` as a workaround.

### Don't expect signed commits

`commit.gpgsign` is not honored. Fixup commits will be unsigned. This is a
libgit2 limitation with no current workaround.

### Don't absorb through merge commits

git-absorb only works with linear history. Merge commits in the stack will
stop the revwalk. Use `--base` to explicitly target past a merge if you know
what you're doing.

### Don't expect git CLI `-c` overrides to work

`git -c absorb.fixupTargetAlwaysSHA=true absorb` does **not** work because
libgit2 reads config independently from the git CLI. Use `.git/config`,
`~/.gitconfig`, or `GIT_CONFIG_GLOBAL` env var instead.

### Don't expect new file additions to be absorbed

Staging a brand-new file or re-adding a deleted file shows "No additions
staged" because absorb only considers line-level diffs against ancestor
commits. New files have no ancestor attribution. Create manual fixup commits
for these.

### Don't expect submodule changes to be absorbed

Submodule pointer updates are not handled. Absorb reports "No additions
staged" for submodule diffs. Create manual fixup commits for submodule
updates.

## Known Limitations (libgit2 / upstream)

These are blocked on libgit2 or git2-rs and have no fix in git-absorb:

| Issue                           | Limitation                                                     | Workaround                                                            |
| ------------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------- |
| `@` alias not supported         | `--base @~5` fails, must use `HEAD`                            | Use `--base HEAD~5`                                                   |
| `extensions.partialclone`       | Repos with partial-clone fail to open                          | Clone without partial-clone                                           |
| `extensions.worktreeConfig`     | Fails in repos with this extension                             | `git config --unset extensions.worktreeConfig`, run absorb, re-enable |
| `feature.manyFiles`             | Older libgit2 versions fail                                    | Update to git-absorb >= 0.7 (git2 0.19+)                              |
| `index.skipHash`                | Checksum mismatch error                                        | `git config --local index.skipHash false`, re-stage                   |
| `includeIf` not fully supported | Conditional includes ignored                                   | Put overrides in `.git/config`                                        |
| Reftable format                 | Repos using reftable backend fail                              | Awaiting libgit2 reftable support (tummychow/git-absorb#211)          |
| `skip-worktree` bits cleared    | Auto-stage resets index entry flags (tummychow/git-absorb#202) | Avoid auto-stage with skip-worktree files                             |

## Integration

### With git-branchless

The primary workflow for stacked commits:

```bash
# Make fixes to code in the stack
git add -p
git absorb --and-rebase
# If branchless shows abandoned commits:
git restack
```

Configure `absorb.maxStack=50` to match typical branchless stack depths.

Use `--and-rebase -- --update-refs` to keep stacked branch pointers in sync
during the autosquash rebase. Redundant if `rebase.updateRefs = true` is
configured (see recommended-config.md).

### With git-revise

Alternative to `--and-rebase`:

```bash
git absorb                    # create fixup commits only
git revise --autosquash       # in-memory autosquash (faster than rebase)
```

> **Caveat:** Requires `absorb.fixupTargetAlwaysSHA = false`. With the
> recommended config (`= true`), absorb creates `fixup! <SHA>` messages
> that git-revise cannot match (mystor/git-revise#79). Prefer
> `git absorb --and-rebase` with the recommended config.

A native `--and-revise` flag has been requested (tummychow/git-absorb#188) but is not yet
implemented.

### Recovery

After any absorb operation, `PRE_ABSORB_HEAD` points to the pre-absorb state:

```bash
git reset --soft PRE_ABSORB_HEAD   # undo absorb completely
git diff PRE_ABSORB_HEAD           # inspect what changed
```
