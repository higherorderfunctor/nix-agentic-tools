# Recommended Git Configuration

Git settings that improve the stacked commit workflow with git-branchless,
git-absorb, and git-revise. Settings are grouped by priority.

## Required

These settings are needed for the tools to work correctly.

```gitconfig
[init]
  defaultBranch = main

[branchless "core"]
  mainBranch = main
```

## Strongly Recommended

These prevent common pain points in stacked workflows.

### git-absorb

```gitconfig
[absorb]
  # Route fixes by SHA, not message — stable across rewording
  # Note: breaks `git revise --autosquash` (see git-revise.md).
  # Prefer `git absorb --and-rebase` with this setting.
  fixupTargetAlwaysSHA = true
  # Default stack depth is 10; stacks regularly exceed this
  maxStack = 50
  # One fixup per commit prevents ambiguous routing
  oneFixupPerCommit = true
```

### Merge and rebase

```gitconfig
[merge]
  # zdiff3 shows the base version in conflicts, making resolution clearer
  conflictStyle = zdiff3

[pull]
  rebase = true

[rebase]
  # Auto-stash before rebase, unstash after
  autoStash = true
  # Process fixup!/squash! prefixes automatically
  autoSquash = true
  # Keep branch pointers in sync during rebase — critical for multi-branch stacks
  updateRefs = true

[rerere]
  # Cache conflict resolutions — invaluable when restacking repeatedly
  enabled = true
  autoupdate = true
```

> **Caution:** `pull.ff = only` — Since Git 2.34, `pull.ff = only` takes
> priority over `pull.rebase = true`, causing `git pull` to fail when local
> commits exist. We recommend `pull.rebase = true` alone.

## Recommended

These improve the development experience.

### git-branchless

```gitconfig
[branchless "smartlog"]
  # Show current commit, stack, and descendants
  defaultRevset = "(@ % main()) | stack() | descendants(@) | @"

[branchless "restack"]
  # Keep original author timestamps during restack
  preserveTimestamps = true

[branchless "next"]
  # Interactive prompt when multiple next commits exist
  interactive = true

[branchless "navigation"]
  # Auto-switch to associated branch when navigating to a commit
  autoSwitchBranches = true

[branchless "test"]
  # Use worktrees for test execution — enables parallelism and avoids
  # dirtying the working copy
  strategy = worktree
  # Use all available CPU cores for parallel testing
  jobs = 0
```

### git-revise

```gitconfig
[revise]
  # Auto-apply fixup!/squash! when using interactive mode
  autoSquash = true
```

### General git

```gitconfig
[commit]
  # Show diff in commit message editor for context
  verbose = true

[diff]
  # Better diff output for structured code
  algorithm = histogram
  # Detect moved code blocks and color them differently
  colorMoved = plain
  # Use meaningful prefixes: i/ (index), w/ (working), c/ (commit)
  mnemonicPrefix = true

[fetch]
  # Fetch all remotes and clean up stale refs
  all = true
  prune = true
  pruneTags = true

[push]
  # Auto-create upstream tracking branch on first push
  autoSetupRemote = true
  followTags = true

[tag]
  sort = version:refname
```

## Optional

Convenience settings that some users prefer.

```gitconfig
[absorb]
  # Auto-stage all tracked changes if nothing is staged
  autoStageIfNothingStaged = true

[column]
  ui = auto
```

## Complete Option Reference

### git-branchless (all config keys)

| Key                                              | Type   | Default                                                  | What it does                                           |
| ------------------------------------------------ | ------ | -------------------------------------------------------- | ------------------------------------------------------ |
| `branchless.core.mainBranch`                     | string | `master`                                                 | Primary branch name                                    |
| `branchless.commitMetadata.branches`             | bool   | `true`                                                   | Show branch names in smartlog                          |
| `branchless.commitMetadata.differentialRevision` | bool   | `true`                                                   | Show Phabricator revision IDs                          |
| `branchless.commitMetadata.relativeTime`         | bool   | `true`                                                   | Show relative timestamps in smartlog                   |
| `branchless.navigation.autoSwitchBranches`       | bool   | `true`                                                   | Auto-switch branch on navigate                         |
| `branchless.next.interactive`                    | bool   | `false`                                                  | Interactive prompt on ambiguous next                   |
| `branchless.restack.preserveTimestamps`          | bool   | `false`                                                  | Keep author timestamps during restack                  |
| `branchless.restack.warnAbandoned`               | bool   | `true`                                                   | Warn when commits become abandoned                     |
| `branchless.revsets.alias.<name>`                | string | —                                                        | Custom revset aliases                                  |
| `branchless.smartlog.defaultRevset`              | revset | `((draft()\|branches()\|@) % main()) \| branches() \| @` | Default smartlog display                               |
| `branchless.test.alias.<name>`                   | string | —                                                        | Named test command aliases                             |
| `branchless.test.jobs`                           | int    | 1                                                        | Parallel test jobs (0 = auto)                          |
| `branchless.test.strategy`                       | enum   | `working-copy`                                           | Test execution strategy (`working-copy` or `worktree`) |
| `branchless.undo.createSnapshots`                | bool   | `true`                                                   | Working copy snapshots before destructive ops          |
| `remote.pushDefault`                             | string | —                                                        | Default remote for `git submit --create`               |

### git-absorb (all config keys)

| Key                               | Type | Default | What it does                                     |
| --------------------------------- | ---- | ------- | ------------------------------------------------ |
| `absorb.autoStageIfNothingStaged` | bool | `false` | Auto-stage tracked changes when index is empty   |
| `absorb.createSquashCommits`      | bool | `false` | Generate squash commits instead of fixup         |
| `absorb.fixupTargetAlwaysSHA`     | bool | `false` | Use SHA in fixup messages (stable across reword) |
| `absorb.forceAuthor`              | bool | `false` | Target commits by any author                     |
| `absorb.forceDetach`              | bool | `false` | Allow on detached HEAD                           |
| `absorb.maxStack`                 | int  | `10`    | Max commits to search for fixup targets          |
| `absorb.oneFixupPerCommit`        | bool | `false` | One fixup per target commit (not per hunk)       |

### git-revise (all config keys)

| Key                 | Type | Default | What it does                                  |
| ------------------- | ---- | ------- | --------------------------------------------- |
| `revise.autoSquash` | bool | `false` | Auto-apply fixup!/squash! in interactive mode |

## Nix Integration

This flake exports a `lib.gitConfig` attribute containing all Required and
Strongly Recommended settings as a Nix attrset. Nix users can merge it into
their home-manager git config:

```nix
{
  inputs.stacked-workflow-skills.url = "github:higherorderfunctor/stacked-workflow-skills";
}

# In home-manager configuration:
{ inputs, ... }: {
  programs.git.settings =
    inputs.stacked-workflow-skills.lib.gitConfig;
}
```

This applies the Required + Strongly Recommended settings.

Override individual values with `lib.recursiveUpdate` (the `//` operator is
a shallow merge and would drop other keys in the same attrset):

```nix
lib.recursiveUpdate
  inputs.stacked-workflow-skills.lib.gitConfig
  { absorb.maxStack = 100; };
```

For the full Recommended set, use `lib.gitConfigFull`:

```nix
programs.git.settings =
  inputs.stacked-workflow-skills.lib.gitConfigFull;
```

## Tool Interoperability Notes

### git-revise + git-branchless

git-revise does NOT call `post-rewrite` hooks, so git-branchless cannot track
revise operations. Both old and new commits appear in `git sl`. Always run
`git restack` after using git-revise.

### git-absorb internals

git-absorb uses libgit2, so pre-commit hooks do NOT run during the fixup
commit phase. `rebase.updateRefs = true` makes `--and-rebase -- --update-refs`
redundant.

### git-branchless `git move -F`

Panics on conflicts (on-disk fixup not implemented). Use manual checkout +
`git amend` + `git restack --merge` for squash operations on overlapping files.
