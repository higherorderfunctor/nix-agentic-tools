# Stacked Workflow Philosophy

Principles and conventions for working with stacked commits. These apply
across all skills in this package.

## Atomic Commits

Every commit should:

- Be describable in one sentence (if you need "and", split it)
- Be independently revertible without side effects
- Leave the codebase in a working state (tests pass, code compiles)
- Target 50-200 lines of changed code
- Only reference things that exist in earlier commits (no forward references)
- Include documentation for the feature it introduces (not in a separate doc
  commit)

Never accumulate a large diff then commit at the end. Commit as you go, one
concern per commit. The unit of change is an individual commit, not a branch.

## Commit Ordering

When building a feature, structure the stack as:

1. Refactoring / cleanup (separate from feature work, always first)
2. Dependencies / build config changes
3. Scaffolding / types / interfaces / schemas
4. Core business logic (the main feature or fix)
5. Edge cases / error handling
6. Tests

Each of these is one or more separate commits. Never mix refactoring with
feature work in the same commit.

When initializing a new repo, the first commit should establish project
identity (LICENSE, README intro paragraph) — no tooling, no config, no code.
Universal coding standards go in the earliest instruction file commit.
Feature-specific rules go with the commit that introduces the tooling they
depend on.

## Dependency Timing

Dependencies (imports, inputs, config files, devShell packages) arrive in the
commit that first uses them — never frontloaded "just in case."

- If `.envrc` depends on a flake, it goes in the flake commit
- If a linter flag references a tool, both the devShell package and the config
  go in the same commit
- A boilerplate scaffold commit should be minimal — don't pre-populate it with
  tools that aren't configured until a later commit

Generated or auto-managed files (lock files, code-gen output) should still
show incremental additions per commit, even if the tool regenerates them
wholesale. Each commit's diff should tell a coherent story.

## Incremental Content

Every artifact — code, docs, config, README sections — should be introduced
incrementally in the commit where it first becomes relevant. Never batch
related content into a single large commit at the end.

- **Library code / imports**: add what's needed when it's needed, not all at
  once in a setup commit
- **README / user-facing docs**: each feature commit adds or updates its own
  README section; don't accumulate a monolithic docs commit
- **Config / CI**: add rules and checks alongside the code they validate, not
  as a late "add linting" commit
- **Types / interfaces**: introduce them in the commit that first uses them,
  not in a speculative "add all types" commit

This applies to both greenfield stacks and restructuring existing ones. When
auditing a stack, look for commits that batch multiple unrelated additions —
they should be split so each addition lives with its first consumer.

## Bulk Stack Modification

When inserting or reordering multiple commits at different stack positions,
avoid navigating to each insertion point individually (`git prev` → change →
`git record -I` → restack, repeated N times). Each intermediate restack can
trigger conflict cascades from transient states.

Instead, use the **batch-at-tip** pattern:

1. Create all new commits at the tip of the stack
2. Use `fixup!` message prefixes for changes targeting existing commits
3. Reorder everything in a single pass via scripted
   `GIT_SEQUENCE_EDITOR` + `git rebase -i --root`

Add `--autosquash` to automatically process `fixup!` prefixes, or set `rebase.autoSquash = true`.

This reduces N restacks to one rebase, with one set of conflicts (often zero)
instead of compounding intermediate conflicts.

When to use this over individual operations:

- 3+ insertions at different stack positions → batch-at-tip
- Single insertion → `git record -I` or `git move`
- Single fix to existing commit → `git absorb --and-rebase` or `/stack-fix`

**Warning:** scripted `GIT_SEQUENCE_EDITOR` reorders cascade conflicts when
files are built incrementally across commits (e.g. README.md gaining one
section per commit). In that case, prefer `git move -x <hash> -d <dest>` for
individual commits — it runs in-memory and avoids context-dependent conflicts.

### Distributing Fixes Across a Stack

When applying multiple fixes to different commits (e.g., after a review run):

1. **Survey first** — run `/stack-summary` to understand the current stack
2. **Classify each fix** — absorb (in-place line edits) vs manual amend
   (new files, structural changes) vs new commit (new content)
3. **Execute earliest-first** — amend the earliest commit first, then
   restack. This minimizes cascading restacks since each amend only
   restacks its descendants.
4. **Stage all absorb-candidates at once** — `git absorb` can route
   multiple hunks to different commits in one pass. Use `--dry-run` first
   to verify routing, then `--and-rebase`.
5. **Handle absorb leftovers** — hunks absorb can't route (new files,
   multi-line format changes, commuting patches) remain staged. Check
   `git diff --cached` after absorb and handle manually.

### Stack Rebuild Gotchas

When rebuilding a stack from scratch (`git reset --soft` + recommit):

- **`git add -u` stages everything dirty** — during a multi-commit rebuild,
  `git add -u` will stage all modified tracked files, not just the ones
  intended for the current commit. Always use explicit `git add <file>` to
  avoid pulling unrelated changes into the wrong commit.
- **Stacked PRs auto-close on force-push** — force-pushing a branch that's
  the base of a stacked PR can auto-close the dependent PR on GitHub. After
  restructuring a stack, expect to create new PRs rather than reopen closed
  ones.

### Dependency Audit Before `git move -x`

`git move -x` extracts a single commit without its descendants. Before using
it, run a quick file-overlap audit to spot likely conflicts (this checks
overlapping paths, not all possible logical dependencies):

```bash
# Check which files the commit touches
git show --stat <commit-to-move>

# Check if any commits between it and the destination touch the same files
git log --stat <commit-to-move>..<destination>
```

If other commits modify the same files, you have three options (in order of
preference):

1. **Move together** — use `git move -s` instead of `-x` to bring dependents
   along
2. **Squash first** — combine the commit with its dependents before moving
3. **Resolve conflicts** — use `git move -x <commit> -d <dest> --merge` and
   fix conflicts on-disk (last resort, error-prone with multiple conflicts)

## History Hygiene

The commit history should read as a clean narrative — what _should_ happen, not
a diary of what _did_ happen during development.

- Never create "addresses feedback", "fix", "WIP", or "tweaks" commits
- Use `git absorb --and-rebase` to route fixes to the correct stack commit
  - **Limitation:** absorb sees a line reorder (swap A and B) as a deletion +
    addition. It may absorb the deletion but leave the addition orphaned,
    producing a net content loss. For reorders, amend directly instead.
- Use `git amend` to update the current commit (auto-restacks descendants)
- Use `git reword` to fix commit messages without checkout
- Clean up before pushing, not after
- After any structural change (squash, split, reorder), audit checklists,
  commit messages, and docs for accuracy

## Commit Message Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `chore`, `build`, `ci`, `style`,
`perf`, `test`

**Scopes** are optional but encouraged. Use the most specific component name.
Keep descriptions lowercase, imperative mood, no trailing period.

## Sizing Heuristic

Target 50-200 lines per commit. If a commit exceeds 200 lines, look for a
natural split point. If it's under 50 lines and could logically combine with
an adjacent commit touching the same concern, consider merging them.

Three similar lines of code is better than a premature abstraction, but three
similar _blocks_ means it's time to extract.
