---
applyTo: "**"
---

## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

This applies everywhere: standalone scripts, generated wrappers,
`writeShellApplication`, heredocs in Nix.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to
lists, attribute sets, JSON objects, markdown tables, TOML sections, and
similar collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing
appears twice, extract it. Three similar lines is better than a premature
abstraction, but three similar blocks means it is time to extract.

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `style`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`, `devshell`), or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

## Config Parity

Three configuration methods exist with the same rough interface:

- **lib/** — manual functions for consumers wiring config directly
- **HM modules** (`modules/`) — declarative home-manager (system-level)
- **devenv modules** (`modules/devenv/`) — project-local dev shell

If a feature can be configured in HM, it must also be configurable in
devenv and vice versa. Gaps between methods are bugs.

Surfaces to keep aligned across all three methods: skills,
instructions/steering, MCP servers, LSP servers, settings, hooks,
agents, environment variables, permissions.

The `ai.*` module (both HM and devenv) provides a unified interface
that fans out to all enabled ecosystems (Claude, Copilot, Kiro) with
ecosystem-specific translation.

## External Tooling

When accessing external services, prefer the highest-fidelity integration
available:

1. **MCP server** — richest context, structured responses, stays in-conversation
2. **CLI tool** (e.g., `gh`, `curl`) — scriptable, good for batch operations
3. **Direct web access** — last resort, use only when MCP and CLI are unavailable

## Validation

### Formatting

After editing any file — regardless of how it was modified (Edit, Write,
Bash, sed, etc.) — run `treefmt <file>` on the changed file. treefmt
handles Nix (via alejandra) and markdown (via prettier).

## Architecture Fragments

> **Last verified:** 2026-04-08 (commit pending — follows the
> monorepo fragment re-scope in a9f991b).

This repo ships path-scoped architecture fragments as dev-only
context for agents working on it. They are SEPARATE from the
published consumer-facing content. Locations:

- `dev/fragments/monorepo/` — always-loaded orientation (this
  category, composed into `common.md` and the equivalent for
  each ecosystem)
- `packages/<pkg>/fragments/dev/` — scoped to files under
  `packages/<pkg>/**`, co-located with the code they document
- `modules/<subdir>/fragments/dev/` — scoped to files under
  `modules/<subdir>/**`, co-located with the code they document

Each scoped fragment emits per-ecosystem frontmatter via the
`fragments-ai.passthru.transforms` pipeline:

- Claude: `.claude/rules/<name>.md` with `paths:` YAML list
- Copilot: `.github/instructions/<name>.instructions.md` with
  `applyTo:` comma-joined globs
- Kiro: `.kiro/steering/<name>.md` with `inclusion: fileMatch`
  and an array `fileMatchPattern:`
- Codex / AGENTS.md: orientation only (no scoped fragments).
  Deep-dive architecture content lives in the per-ecosystem
  scoped files above and in the mdbook contributing section.
  AGENTS.md used to concatenate every scoped fragment flat, but
  that bloated it to ~2k lines; Phase 2.4 trimmed it to just the
  monorepo orientation content (commit c4f4aff).

### Maintenance is mandatory

**When you make changes that alter the shape of any abstraction a
scoped fragment describes, update the fragment in the same commit.**
Out-of-date architecture fragments actively mislead future sessions
and are worse than no fragment at all.

Each scoped fragment opens with a `Last verified: <date> (commit
<hash>)` marker. If that marker predates your change to the area
the fragment scopes, the fragment is stale. Stop and update it
before landing the commit — in the same commit, not a follow-up.

This is not an etiquette rule. Research on LLM context shows
out-of-date instructions degrade task success more than missing
instructions. A lie is worse than silence.

### When to add a new fragment

Add a fragment when you encounter a piece of non-inferable
knowledge during debugging or implementation — something the
next session would burn a lot of tokens rediscovering. Examples
of the kind of content worth writing down:

- **Why** a non-obvious design decision was made (trade-offs,
  abandoned alternatives)
- **Cross-cutting invariants** that span multiple files
- **Shapes of abstractions** (fanout patterns, wrapper chains,
  activation lifecycles)
- **Known pitfalls** (subtle bugs, gotchas, migrations in flight)
- **Debugging entry points** (what to grep, what to eval)

Do NOT add fragments for content that is:

- Discoverable by reading the code itself in under 10 seconds
- Already covered by existing code comments (DRY)
- A restatement of function signatures, file paths, or line numbers
- Ephemeral (in-progress state goes in plan.md or memory, not
  fragments)

Target under 150 lines per fragment. If a topic outgrows that,
split by sub-concern with tighter scopes.

### Generator registration

New fragments are registered in `dev/generate.nix` under
`devFragmentNames`. The attribute key is the category (which
becomes the output filename for scoped Claude rules, Copilot
instructions, and Kiro steering). Each entry is either a bare
string (legacy dev/fragments/ path) or an attrset with an
explicit location:

```nix
devFragmentNames.ai-clis = [
  "packaging-guide"  # legacy: dev/fragments/ai-clis/packaging-guide.md
  {
    location = "package";
    name = "claude-code-wrapper";
    # dir defaults to "ai-clis"
    # → packages/ai-clis/fragments/dev/claude-code-wrapper.md
  }
];
```

Scope globs for each category live in `packagePaths` as Nix lists.
`null` means always-loaded. The transforms handle per-ecosystem
emission — do not hand-format frontmatter.

After adding or editing fragments, run
`devenv tasks run --mode before generate:instructions` to
regenerate steering files for all ecosystems.

## Build & Validation Commands

```bash
nix flake show                              # List all outputs
nix flake check                             # Linters + evaluation (does NOT build packages)
nix build .#<package>                       # Build a specific package
devenv shell                                # Enter devShell with all tools
devenv tasks run generate:instructions      # Regenerate instruction files from fragments
treefmt                                     # Format all files (Nix, markdown, JSON, TOML, shell)
```

## Change Propagation

When removing or renaming a concept, update ALL surfaces that reference
it in the same commit:

- Fragments and generated instruction files
- CLAUDE.md, AGENTS.md, Kiro steering, Copilot instructions
- Routing tables in skills
- README feature matrix and server reference
- flake.nix output lists
- nvfetcher.toml keys
- CI workflow matrices
- Home-manager module registrations
- Overlay export lists
- Structural check expectations

The structural check (`nix flake check`) validates cross-references.
The pre-commit hook runs a fast subset. If something is removed, grep
for it across the repo before committing.

## Linting

All code must pass linters before committing:

- **Meta-formatter:** treefmt (orchestrates all formatters below)
- **Nix:** alejandra (format), deadnix (dead code), statix (anti-patterns)
- **Shell:** shellcheck, shellharden, shfmt
- **Markdown:** prettier (via treefmt)
- **JSON:** biome (via treefmt)
- **TOML:** taplo (via treefmt)
- **Spelling:** cspell
- **Agent configs:** agnix

## Project Overview

nix-agentic-tools is a Nix flake monorepo that will provide:

- **Stacked workflow skills** — SKILL.md files for stacked commit workflows
  using git-branchless, git-absorb, and git-revise
- **MCP server packages** — Model Context Protocol servers packaged as
  Nix derivations with typed settings and credential handling
- **Home-manager modules** — declarative configuration for Claude Code,
  Copilot CLI, Kiro CLI, stacked workflows, and MCP services
- **DevShell modules** — per-project AI tool configuration without
  home-manager (`mkAgenticShell`)
- **Git tool overlays** — git-absorb, git-branchless, git-revise

The monorepo is being assembled bottom-up across a sequence of PRs.
Skills work without Nix. Nix unlocks overlays, home-manager modules,
and devshell integration.

### Current Branch Layout

```
dev/
  fragments/    Dev-only instruction fragments (not exported)
  generate.nix  Fragment composition for instruction file generation
  tasks/        DevEnv task wrappers
devshell/       Standalone devshell modules (mkAgenticShell)
lib/            Shared library: fragments, MCP helpers, devshell helpers
packages/
  fragments-ai/ AI ecosystem transforms (fragment frontmatter)
```

Future top-level directories (introduced in later chunks):

- `modules/` — Home-manager modules
- `packages/coding-standards/` — content package: reusable standards
- `packages/stacked-workflows/` — content package: skills + routing
- `packages/ai-clis/` — AI CLI overlays
- `packages/git-tools/` — git tool overlays
- `packages/mcp-servers/` — MCP server overlays
- `packages/fragments-docs/` — docsite transforms and generators

## Skill Routing — MANDATORY

When the user is working with stacked commits, use the appropriate skill
instead of running commands manually via Bash.

<!-- prettier-ignore -->
| Operation                                               | Skill            | Use INSTEAD of                                                 |
| ------------------------------------------------------- | ---------------- | -------------------------------------------------------------- |
| Audit stack quality before restructure                  | `/stack-summary` | Manual `git log` inspection                                    |
| Commit uncommitted work as an atomic stack              | `/stack-plan`    | `git add -A && git commit` (single monolithic commit)          |
| Edit earlier commit (content moves, structural changes) | `/stack-fix`     | Manual `git prev` + edit + `git amend` + `git restack --merge` |
| Fix lines in earlier commit                             | `/stack-fix`     | `git absorb`, `git commit --fixup`, manual checkout + amend    |
| Plan and build a commit stack from a description        | `/stack-plan`    | Ad-hoc `git record` / `git commit` without a plan              |
| Push stack for review                                   | `/stack-submit`  | Manual `git sync` + `git submit` + `gh pr create`              |
| Restructure/reorder existing commits                    | `/stack-plan`    | `git rebase -i`, `git reset --soft`, `git move` sequences      |
| Split a large commit                                    | `/stack-split`   | `git rebase -i` + edit, `git reset HEAD^`                      |
| Test across stack                                       | `/stack-test`    | Manual `git test run` or looping `git checkout` + test         |

**RULE: Before running any git-branchless, git-absorb, or git-revise command
via Bash, check if a skill covers the operation.** Skills include pre-flight
checks, dry-run previews, conflict guidance, and post-operation verification
that manual commands miss.
