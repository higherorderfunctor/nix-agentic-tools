# Stacked Workflows

Stacked workflows organize work as sequences of small, atomic commits
rather than one large change. agentic-tools provides git configuration
presets, 6 skills for AI coding CLIs, and integrations that wire
everything together.

## Prerequisites

Three git tools power the stacked workflow:

| Tool                                                        | Purpose                                          |
| ----------------------------------------------------------- | ------------------------------------------------ |
| [git-branchless](https://github.com/arxanas/git-branchless) | Anonymous branching, in-memory rebases, smartlog |
| [git-absorb](https://github.com/tummychow/git-absorb)       | Automatic fixup commit routing                   |
| [git-revise](https://github.com/mystor/git-revise)          | In-memory commit rewriting                       |

Install via the overlay:

```nix
nixpkgs.overlays = [inputs.agentic-tools.overlays.git-tools];
# Adds: pkgs.git-absorb, pkgs.git-branchless, pkgs.git-revise
```

## Git Configuration Presets

Two preset levels configure git for stacked workflows:

### Minimal (`gitPreset = "minimal"`)

Required and strongly recommended settings:

| Section           | Setting                                 | Value      |
| ----------------- | --------------------------------------- | ---------- |
| `absorb`          | `fixupTargetAlwaysSHA`                  | `true`     |
| `absorb`          | `maxStack`                              | `50`       |
| `absorb`          | `oneFixupPerCommit`                     | `true`     |
| `branchless.core` | `mainBranch`                            | `"main"`   |
| `init`            | `defaultBranch`                         | `"main"`   |
| `merge`           | `conflictStyle`                         | `"zdiff3"` |
| `pull`            | `rebase`                                | `true`     |
| `rebase`          | `autoSquash`, `autoStash`, `updateRefs` | `true`     |
| `rerere`          | `autoupdate`, `enabled`                 | `true`     |

### Full (`gitPreset = "full"`)

Everything in minimal, plus recommended settings:

| Section                 | Setting                                     | Value                              |
| ----------------------- | ------------------------------------------- | ---------------------------------- |
| `branchless.navigation` | `autoSwitchBranches`                        | `true`                             |
| `branchless.next`       | `interactive`                               | `true`                             |
| `branchless.restack`    | `preserveTimestamps`                        | `true`                             |
| `branchless.smartlog`   | `defaultRevset`                             | `"(@ % main()) \| stack() \| ..."` |
| `branchless.test`       | `jobs`, `strategy`                          | `0`, `"worktree"`                  |
| `commit`                | `verbose`                                   | `true`                             |
| `diff`                  | `algorithm`, `colorMoved`, `mnemonicPrefix` | `"histogram"`, `"plain"`, `true`   |
| `fetch`                 | `all`, `prune`, `pruneTags`                 | `true`                             |
| `push`                  | `autoSetupRemote`, `followTags`             | `true`                             |
| `revise`                | `autoSquash`                                | `true`                             |
| `tag`                   | `sort`                                      | `"version:refname"`                |

All values are set at `mkDefault` priority, so you can override
individual keys at normal priority in `programs.git.settings`.

### Usage

```nix
stacked-workflows = {
  enable = true;
  gitPreset = "full";  # or "minimal" or "none"
};
```

## The 6 Skills

Skills are SKILL.md files that teach AI coding CLIs how to perform
stacked workflow operations. Each skill includes pre-flight checks,
dry-run previews, conflict guidance, and post-operation verification.

| Skill           | Operation                                                          |
| --------------- | ------------------------------------------------------------------ |
| `stack-fix`     | Fix lines in or edit earlier commits (absorb, fixup)               |
| `stack-plan`    | Plan and build a commit stack from description or uncommitted work |
| `stack-split`   | Split a large commit into smaller atomic commits                   |
| `stack-submit`  | Push stack for review (sync, submit, PR creation)                  |
| `stack-summary` | Audit stack quality before restructure                             |
| `stack-test`    | Run tests/formatters across every commit in the stack              |

### Routing Table

The routing table maps operations to skills:

| Operation                                  | Skill           |
| ------------------------------------------ | --------------- |
| Commit uncommitted work as an atomic stack | `stack-plan`    |
| Restructure/reorder existing commits       | `stack-plan`    |
| Fix lines in earlier commit                | `stack-fix`     |
| Edit earlier commit (content moves)        | `stack-fix`     |
| Split a large commit                       | `stack-split`   |
| Push stack for review                      | `stack-submit`  |
| Audit stack quality                        | `stack-summary` |
| Test across stack                          | `stack-test`    |

## CLI Integrations

The stacked-workflows module wires skills and the routing table
instruction to each enabled CLI:

```nix
stacked-workflows = {
  enable = true;
  integrations = {
    claude.enable = true;   # writes to ~/.claude/skills/ and ~/.claude/references/
    copilot.enable = true;  # writes to ~/.copilot/skills/ and ~/.copilot/instructions/
    kiro.enable = true;     # writes to ~/.kiro/skills/ and ~/.kiro/steering/
  };
};
```

### What Gets Installed

| Ecosystem | Skills                      | Routing table                                 | Reference docs              |
| --------- | --------------------------- | --------------------------------------------- | --------------------------- |
| Claude    | `~/.claude/skills/stack-*`  | `~/.claude/references/stacked-workflow.md`    | `~/.claude/references/*.md` |
| Copilot   | `~/.copilot/skills/stack-*` | `~/.copilot/instructions/stacked-workflow.md` | --                          |
| Kiro      | `~/.kiro/skills/stack-*`    | `~/.kiro/steering/stacked-workflow.md`        | --                          |

Claude also gets the full reference docs (git-absorb.md,
git-branchless.md, git-revise.md, philosophy.md,
recommended-config.md) as `~/.claude/references/` files.

## Without Nix

Skills work without Nix. Copy them into your project:

```bash
# Claude Code
cp -r packages/stacked-workflows/skills/stack-* .claude/skills/

# Kiro
cp -r packages/stacked-workflows/skills/stack-* .kiro/skills/

# GitHub Copilot
cp -r packages/stacked-workflows/skills/stack-* .github/skills/
```

You'll need to install git-branchless, git-absorb, and git-revise
separately and configure git manually (see the minimal preset settings
above).
