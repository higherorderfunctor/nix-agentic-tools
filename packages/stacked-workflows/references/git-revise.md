---
repo: mystor/git-revise
repo-head: a5bdbe420521a7784dd16c8f22b374b2f1d2d167
repo-indexed: 2026-03-21
wiki-head: null
wiki-indexed: null
issues-indexed: 2026-03-21
discussions-indexed: null
labels-indexed: 2026-03-21
label-head: 6fd8065eca9d1cb1b5803fdcc443d6d9898cf7890b5fb620fa11d3e53c8a9494
doc-sources:
  - path: "docs/man.rst"
    type: repo-file
    relevance: "man page with full option reference and interactive mode docs"
  - path: "docs/performance.rst"
    type: repo-file
    relevance: "benchmarks comparing revise vs rebase performance"
  - path: "docs/install.rst"
    type: repo-file
    relevance: "installation methods"
  - path: "docs/contributing.rst"
    type: repo-file
    relevance: "development setup and contribution workflow"
  - path: "docs/index.rst"
    type: repo-file
    relevance: "documentation entry point and table of contents"
  - path: "docs/api/merge.rst"
    type: repo-file
    relevance: "merge algorithm internals (in-memory merge implementation)"
  - path: "README.md"
    type: repo-file
    relevance: "primary overview and usage examples"
exclude-issue-patterns:
  - "renovate"
  - "dependabot"
  - "bump version"
  - "release v"
value-labels:
  - name: "bug"
    reason: "confirmed bugs reveal edge cases and workarounds"
  - name: "question"
    reason: "resolved questions contain recipes and usage clarification"
  - name: "design"
    reason: "design decisions and rationale"
  - name: "enhancement"
    reason: "feature discussions and design decisions"
  - name: "help wanted"
    reason: "may surface known limitations"
issue-stats:
  total-fetched: 152
  from-labels: 152
  from-keywords: 0
  from-reactions: 0
  after-dedup: 152
---

# git-revise Reference

Distilled from https://github.com/mystor/git-revise, updated 2026-03-21.

## Overview

git-revise is a git subcommand for efficiently updating, splitting, and
rearranging commits. Unlike `git rebase`, it performs all merges **in-memory**
and never modifies the working directory or index state. This makes it
significantly faster (31x on mozilla-central) and avoids invalidating builds.

It's heavily inspired by `git rebase` but optimized for patch-stack workflows
where you frequently amend and rearrange commits.

## Installation & Setup

```bash
pip install --user git-revise
# Also available via: Homebrew, Fedora dnf, nixpkgs
```

### Configuration

```bash
# Auto-apply autosquash with -i (like rebase.autoSquash)
git config revise.autoSquash true

# GPG/SSH sign revised commits
git config revise.gpgSign true

# Enable rerere for cached conflict resolution
git config revise.rerere true        # or rerere.enabled
git config rerere.autoUpdate true    # auto-apply cached resolutions

# Opt-in commit-msg hook support (mystor/git-revise#82, not yet merged)
# git config revise.run-hooks.commit-msg true
```

## Core Concepts

### In-Memory Merges

git-revise uses a custom merge algorithm that works directly on tree objects
in memory. It only examines modified files/directories, minimizing disk I/O.
Trade-off: no rename detection (use `git rebase` when renames matter).

### Working Directory Invariant

git-revise never changes the working directory or index. After any operation,
your files are exactly as they were. This means:

- Builds are never invalidated
- Uncommitted changes are preserved
- The operation is faster (no checkout)

### Conflict Resolution

If automatic merge fails, git-revise prompts for manual conflict resolution
in the editor. No mergetool support. Unsuccessful commands leave the
repository unmodified.

The conflict prompt format is: `Resolution or (A)bort?` — type the resolution
number (1 or 2) or `a` to abort. The prompt shows which commit each side
comes from (mystor/git-revise#45, mystor/git-revise#53). Note: when reordering two commits that touch the same
line, you may be asked to resolve the same conflict twice (mystor/git-revise#132).

### Rerere Support

git-revise supports `git rerere`-style conflict caching (mystor/git-revise#75). When enabled,
resolved conflicts are recorded and replayed automatically on future
encounters. Resolutions are stored in `.git/rr-cache/` and shared with git's
own rerere. Enable via `revise.rerere` (or `rerere.enabled`) plus
`rerere.autoUpdate`. Variant support (multiple resolutions per conflict)
is not yet implemented.

## Command Reference

```
git revise [<options>] [<target>]
```

### Modes

| Mode                        | Description                                       |
| --------------------------- | ------------------------------------------------- |
| _(default)_                 | Apply staged changes to `<target>` commit         |
| `-i, --interactive`         | Edit todo list for commits after `<target>`       |
| `--autosquash`              | Auto-fold `fixup!`/`squash!` commits              |
| `-c, --cut`                 | Split `<target>` by interactively selecting hunks |
| `-e, --edit`                | Edit `<target>`'s commit message                  |
| `-m <msg>, --message <msg>` | Set commit message directly                       |

### Options

| Option           | Description                                       |
| ---------------- | ------------------------------------------------- |
| `-a, --all`      | Stage tracked file changes before revising        |
| `-p, --patch`    | Interactively stage hunks before revising         |
| `--no-index`     | Ignore staged changes                             |
| `--reauthor`     | Reset author to current user                      |
| `--ref <gitref>` | Branch to update (default: HEAD)                  |
| `-S, --gpg-sign` | GPG/SSH sign commits                              |
| `--no-gpg-sign`  | Don't sign commits                                |
| `--root`         | Include root commit (with `-i` or `--autosquash`) |

### Interactive Commands

| Command  | Description                                |
| -------- | ------------------------------------------ |
| `pick`   | Use commit as-is                           |
| `squash` | Merge into previous, edit combined message |
| `fixup`  | Merge into previous, discard this message  |
| `reword` | Edit commit message                        |
| `cut`    | Interactively split into two commits       |
| `index`  | Leave changes staged (must be last)        |

**Not available:** `drop` (see Anti-Patterns), `exec` (mystor/git-revise#28, won't fix).
Editing summary lines directly in `-i` view is ignored; use `-ie` or
`reword` instead (mystor/git-revise#34).

## Recipes

### 1. Amend a specific commit with staged changes

```bash
git add -p                         # stage the fix
git revise <target-hash>           # apply staged changes to target
```

### 2. Amend a commit and edit its message

```bash
git add -p
git revise -e <target-hash>       # apply changes + open message editor
```

### 3. Interactive rebase (in-memory)

```bash
git revise -i main                 # reorder/squash/fixup commits after main
git revise -i --root               # rewrite entire history including root
```

### 4. Interactive rebase with message editing

```bash
git revise -ie main                # -e shows full messages with ++ prefix
                                   # edit messages inline in the todo list
```

### 5. Process fixup/squash commits

```bash
# After creating fixup! commits (manually or via git-absorb)
git revise --autosquash            # fold all fixup!/squash! commits
```

### 6. Split a commit

```bash
git revise -c <hash>               # select hunks for first commit
                                   # remainder becomes second commit
                                   # edit both messages
```

Note: `--cut` only splits into exactly two commits. For more pieces, run
`-c` repeatedly on the remainder (mystor/git-revise#80). Pathspec support (`git revise -c
<hash> -- path/to/file`) is proposed but not yet merged (mystor/git-revise#134).

### 7. Reword a commit message

```bash
git revise -e <hash>               # opens editor for that commit's message
git revise -m "new message" <hash> # set message directly
```

### 8. Amend all tracked changes into a commit

```bash
git revise -a <hash>               # stages all tracked changes, applies to target
```

### 9. Undo a revise operation

```bash
git reset @{1}                     # reflog-based undo (single entry per revise)
```

### 10. Revise without touching staged changes

```bash
git revise --no-index -e <hash>    # only edit message, ignore index
```

### 11. Revise the last commit that touched staged files

Useful alias — automatically finds the most recent commit for the staged
files and revises it (mystor/git-revise#66):

```bash
# Add to .gitconfig [alias] section:
revise-auto = "!f() { \
  REV=$(git status --porcelain --untracked-files=no | sed '/^ /d;s/^.. //' \
    | xargs -n1 git rev-list -1 HEAD --); \
  NUM=$(echo \"$REV\" | sort -u | wc -l); \
  [ $NUM -ne 1 ] && echo 'Staged files span multiple commits' >&2 && exit 1; \
  REV=$(echo \"$REV\" | sort -u); \
  git revise \"$REV\" \"$@\"; \
}; f"
```

### 12. Sign all commits in a range

```bash
git revise --gpg-sign <oldest-hash>  # signs all commits from target to HEAD
```

Passing `--gpg-sign` with no index changes triggers signing for the
entire range without modifying content (mystor/git-revise#73).

## Performance

Benchmarked on mozilla-central (large repo):

| Operation  | git rebase | git revise |
| ---------- | ---------- | ---------- |
| autosquash | 16.9s      | 0.5s       |

Speed comes from: in-memory tree cache, custom merge algorithm operating on
tree objects directly, no working directory or index operations.

## Anti-Patterns

### Don't rebase through merge commits

git-revise cannot rewrite through merge commits. Error: "has 2 parents" (mystor/git-revise#32,
mystor/git-revise#137). Workaround: use `git merge-base HEAD origin/HEAD` as target to stop
before the merge.

### Don't expect rename detection

The custom merge algorithm skips rename detection for speed. If your changes
involve renames, use `git rebase` instead for correct results.

### Don't drop commits via interactive mode

There is no `drop` command (mystor/git-revise#16). git-revise's invariant is that the working
tree state doesn't change, and dropping a commit would alter file state.
Workaround: move commit to end and change `pick` to `index` (leaves changes
staged), then handle manually. Note: deleting a line in `-i` mode also does
not work — it errors with "Unexpected commits missing from TODO list" (mystor/git-revise#52).

### Don't rely on post-rewrite hooks

git-revise does **not** call `post-rewrite` or `reference-transaction` hooks
(mystor/git-revise#106). This is the primary interop issue with git-branchless — both old and
new commits appear in `git sl` after using git-revise.

### Don't split commits with only binary changes

`git revise -c` fails with "cut part [1] is empty" when only binary changes
remain in one side (mystor/git-revise#33). Similarly, empty file creations are invisible to
`-c` and always land in the second commit (mystor/git-revise#55). Workaround: split in reverse
order and reorder via `git revise -i`.

### Don't expect --update-refs support

git-revise does not support `--update-refs` (mystor/git-revise#131, 12 reactions — most
requested feature). When rewriting commits that are shared across multiple
branches, only the current branch (or `--ref` target) is updated. Other
local branches diverge silently (mystor/git-revise#25). Workaround: manually update affected
branches, or use `git rebase --update-refs` for multi-branch rewrites.

### Don't expect git notes to be copied

Unlike `git rebase` and `git commit --amend`, git-revise does not copy git
notes to rewritten commits (mystor/git-revise#83). If you rely on notes (e.g., Gerrit
Change-Ids stored as notes), verify them after revising.

### Autosquash only matches full subject lines

Unlike `git rebase --autosquash`, git-revise's `--autosquash` requires the
full commit subject to match — partial subject matches and hash-based
`fixup!` targeting may not work reliably (mystor/git-revise#79). Ensure fixup commit messages
use the exact full subject of the target commit.

## Integration

### With git-branchless

**Known issue:** git-revise does not call `post-rewrite` hooks, so
git-branchless cannot track the rewrite. After using git-revise, both old
and new commits appear in `git sl`. Run `git restack` to clean up.

For operations where git-branchless has native equivalents, prefer those:

- `git revise -e` → `git reword` (branchless tracks the rewrite)
- `git revise -c` → `git split` (branchless tracks the rewrite)
- `git revise -i` → `git move` (branchless tracks the rewrite)

git-revise is most valuable for `--autosquash` (faster than rebase) and
bulk operations where speed matters and you can `git restack` afterward.

### With git-absorb

Complementary workflow:

```bash
git add -p                         # stage fixes
git absorb                         # create fixup! commits (no rebase)
git revise --autosquash            # in-memory autosquash (fast)
git restack                        # fix branchless tracking
```

> **Caveat:** This workflow requires `absorb.fixupTargetAlwaysSHA = false`.
> With the recommended config (`= true`), absorb creates `fixup! <SHA>`
> messages that git-revise `--autosquash` cannot match
> (mystor/git-revise#79). Prefer `git absorb --and-rebase` instead, which
> uses git's native autosquash and handles SHA-based fixup targets correctly.

### Signing Support

git-revise supports GPG, SSH, and X.509 signing (`-S` flag or
`revise.gpgSign` config). SSH signing was added in mystor/git-revise#136 (fixing mystor/git-revise#123).
Unlike git-absorb, signing works correctly since git-revise implements
its own `sign_buffer()`. Reads `gpg.format`, `user.signingKey`, and
related git config.

### Git 2.48 Compatibility

A reflog corruption bug in git 2.48 affected `git update-ref` when
symbolic refs (like HEAD) referenced the updated branch (mystor/git-revise#138). This was
fixed in git-revise via mystor/git-revise#139. If you encounter corrupted reflog entries,
ensure you're on git-revise >= 0.7.0+ with this fix.

### Editor Configuration

git-revise respects `GIT_SEQUENCE_EDITOR` and `sequence.editor` for the
todo list editor, falling back to `GIT_EDITOR` / `core.editor` for commit
messages (mystor/git-revise#60, #70). This matches `git rebase -i` behavior. The tool also
respects `core.commentChar` (mystor/git-revise#38) and `commit.cleanup` / `commit.verbose`
(mystor/git-revise#126).
