# AGENTS.md

Project instructions for AI coding assistants working in this repository. Read
by Claude Code, Kiro, GitHub Copilot, Codex, and other tools that support the
[AGENTS.md standard](https://agents.md).

Deep-dive architecture documentation (fanout semantics, wrapper chains, fragment
pipeline, overlay cache-hit parity, HM module conventions, etc.) comes from the
source fragments routed below. Claude, Copilot, and Kiro receive generated
path-scoped projections of those sources. Codex and other AGENTS-only consumers
do not load those projections, so they must use the routing index before editing
a matching path. Fragment bodies are not duplicated here, keeping always-loaded
context focused.

## Scoped architecture routing

Before editing a path that matches one or more entries, read every listed source
document for those entries. When multiple entries match, their guidance
composes. The registry-generated index is authoritative for routing; source
documents are authoritative for content. Do not edit generated `.claude/rules/`,
`.github/instructions/`, or `.kiro/steering/` projections directly.

- **`ai-clis`**
  - Match: `packages/copilot-cli/checks/copilot-wrapper-argv.nix`,
    `packages/chatgpt-codex/packages/ai/chatgpt-codex/package.nix`,
    `packages/claude-code/packages/ai/claude-code/package.nix`,
    `packages/copilot-cli/packages/ai/copilot-cli/package.nix`,
    `packages/kimchi/packages/ai/kimchi/package.nix`,
    `packages/kiro-cli/packages/ai/kiro-cli/package.nix`,
    `packages/kiro-gateway/packages/ai/kiro-gateway/package.nix`,
    `packages/chatgpt-codex/**`, `packages/copilot-cli/**`,
    `packages/kiro-cli/**`
  - Read:
    [`dev/fragments/ai-clis/copilot-config-delivery.md`](dev/fragments/ai-clis/copilot-config-delivery.md),
    [`dev/fragments/ai-clis/packaging-guide.md`](dev/fragments/ai-clis/packaging-guide.md)

- **`ai-config-scope`**
  - Match: `devenv.nix`, `packages/chatgpt-codex/lib/mkCodex.nix`,
    `packages/claude-code/lib/mkClaude.nix`,
    `packages/copilot-cli/lib/mkCopilot.nix`,
    `packages/kimchi/lib/mkKimchi.nix`, `packages/kiro-cli/lib/mkKiro.nix`,
    `packages/*/lib/wrapPackage.nix`, `packages/*/modules/devenv/**`
  - Read:
    [`dev/fragments/ai-config-scope/host-config-merge.md`](dev/fragments/ai-config-scope/host-config-merge.md)

- **`ai-module`**
  - Match: `checks/*/module-eval.nix`, `checks/ai-delivery/**`,
    `checks/module-provenance/**`, `config/ai-delivery*.nix`,
    `lib/ai/adapters/**`, `lib/ai/agent.nix`, `lib/ai/ai-common.nix`,
    `lib/ai/app/**`, `lib/ai/default.nix`, `lib/ai/deliver.nix`,
    `lib/ai/delivery-options.nix`, `lib/ai/deliveryMethod.nix`,
    `lib/ai/formats.nix`, `lib/ai/hooks.nix`, `lib/ai/launcher.nix`,
    `lib/ai/mkSkillPackageModule.nix`, `lib/ai/module-environment.nix`,
    `lib/ai/own.nix`, `lib/ai/own.py`, `lib/ai/program.nix`,
    `lib/ai/programs/**`, `lib/ai/runtime-files.nix`, `lib/ai/runtimes.nix`,
    `lib/ai/sharedOptions.nix`, `lib/testing/module-harness.nix`,
    `packages/*/checks/module-eval.nix`,
    `packages/chatgpt-codex/lib/mkCodex.nix`,
    `packages/chatgpt-codex/modules/**`,
    `packages/claude-code/lib/mkClaude.nix`, `packages/claude-code/modules/**`,
    `packages/copilot-cli/lib/mkCopilot.nix`, `packages/copilot-cli/modules/**`,
    `packages/delegate-sizing/modules/**`, `packages/kimchi/lib/mkKimchi.nix`,
    `packages/kiro-cli/lib/mkKiro.nix`, `packages/kiro-cli/modules/**`,
    `packages/semble/modules/common.nix`
  - Read:
    [`dev/fragments/ai-module/ai-module-fanout.md`](dev/fragments/ai-module/ai-module-fanout.md),
    [`dev/fragments/ai-module/collision-semantics.md`](dev/fragments/ai-module/collision-semantics.md),
    [`dev/fragments/ai-module/dir-helpers.md`](dev/fragments/ai-module/dir-helpers.md),
    [`dev/fragments/ai-module/layered-fanout.md`](dev/fragments/ai-module/layered-fanout.md),
    [`dev/fragments/ai-module/shell-option.md`](dev/fragments/ai-module/shell-option.md)

- **`ai-skills`**
  - Match: `lib/ai/hm-helpers.nix`, `lib/ai/mkSkillPackageModule.nix`,
    `packages/chatgpt-codex/lib/mkCodex.nix`,
    `packages/chatgpt-codex/modules/**`,
    `packages/claude-code/lib/mkClaude.nix`, `packages/claude-code/modules/**`,
    `packages/copilot-cli/lib/mkCopilot.nix`, `packages/copilot-cli/modules/**`,
    `packages/delegate-sizing/modules/**`, `packages/kimchi/lib/mkKimchi.nix`,
    `packages/kimchi/modules/**`, `packages/kiro-cli/lib/mkKiro.nix`,
    `packages/kiro-cli/modules/**`, `packages/stacked-workflows/modules/**`
  - Read:
    [`dev/fragments/ai-skills/skills-fanout-pattern.md`](dev/fragments/ai-skills/skills-fanout-pattern.md)

- **`beads`**
  - Match: `packages/beads/**`
  - Read:
    [`packages/beads/docs/beads-lifecycle.md`](packages/beads/docs/beads-lifecycle.md)

- **`claude-code`**
  - Match: `packages/claude-code/packages/ai/claude-code/package.nix`,
    `packages/claude-code/**`
  - Read:
    [`packages/claude-code/docs/claude-code-wrapper.md`](packages/claude-code/docs/claude-code-wrapper.md),
    [`packages/claude-code/docs/heron-brook-clamp.md`](packages/claude-code/docs/heron-brook-clamp.md)

- **`delegate-sizing`**
  - Match: `packages/delegate-sizing/**`
  - Read:
    [`packages/delegate-sizing/docs/development.md`](packages/delegate-sizing/docs/development.md)

- **`devenv`**
  - Match: `.github/workflows/devenv-test.yml`, `devenv.nix`,
    `lib/ai/hm-helpers.nix`, `packages/*/modules/devenv/**`
  - Read:
    [`dev/fragments/devenv/ci-lean-closure.md`](dev/fragments/devenv/ci-lean-closure.md),
    [`dev/fragments/devenv/files-internals.md`](dev/fragments/devenv/files-internals.md)

- **`facets`**
  - Match: `checks/*/default.nix`, `checks/facets/**`, `flake.nix`,
    `lib/facets.nix`, `lib/facets/**`, `lib/testing/**`,
    `packages/*/checks.nix`, `packages/*/packages/**`, `packages/*/registry.nix`
  - Read:
    [`dev/fragments/facets/package-ownership.md`](dev/fragments/facets/package-ownership.md)

- **`flake`**
  - Match: `flake.nix`, `devenv.nix`
  - Read:
    [`dev/fragments/flake/binary-cache.md`](dev/fragments/flake/binary-cache.md)

- **`hm-modules`**
  - Match: `packages/*/modules/homeManager/**`
  - Read:
    [`dev/fragments/hm-modules/module-conventions.md`](dev/fragments/hm-modules/module-conventions.md)

- **`ifd`**
  - Match: `.github/actions/warm-ifd/**`, `.github/workflows/ci.yml`,
    `.github/workflows/devenv-test.yml`, `.github/workflows/update.yml`,
    `lib/facets/**`, `lib/testing/**`, `lib/packaging.nix`,
    `packages/*/lib/packaging.nix`, `packages/*/packages/**/*.nix`,
    `packages/*/packages/**`
  - Read:
    [`dev/fragments/overlays/ifd-patterns.md`](dev/fragments/overlays/ifd-patterns.md)

- **`kimchi`**
  - Match: `packages/kimchi/**`
  - Read:
    [`packages/kimchi/docs/kimchi-factory.md`](packages/kimchi/docs/kimchi-factory.md)

- **`kiro-settings`**
  - Match: `lib/ai/ai-common.nix`, `packages/kiro-cli/lib/packaging.nix`,
    `packages/kiro-cli/lib/mkKiro.nix`
  - Read:
    [`packages/kiro-cli/docs/settings-shape.md`](packages/kiro-cli/docs/settings-shape.md)

- **`kiro-steering`**
  - Match: `lib/ai/ai-common.nix`, `lib/ai/transformers/kiro.nix`,
    `packages/kiro-cli/**`
  - Read:
    [`packages/kiro-cli/docs/steering-inclusion.md`](packages/kiro-cli/docs/steering-inclusion.md)

- **`kiro-workflows`**
  - Match: `packages/kiro-cli/packages/ai/kiro-cli/package.nix`,
    `packages/kiro-cli/lib/packaging.nix`, `packages/kiro-cli/lib/mkKiro.nix`
  - Read:
    [`packages/kiro-cli/docs/workflow-gating.md`](packages/kiro-cli/docs/workflow-gating.md)

- **`kiro-wrapper`**
  - Match: `packages/kiro-cli/checks/kiro-fhs-contract.nix`,
    `packages/kiro-cli/checks/kiro-wrapper-argv.nix`, `lib/idempotentFlags.nix`,
    `packages/kiro-cli/packages/ai/kiro-cli/package.nix`,
    `packages/kiro-cli/lib/**`
  - Read:
    [`packages/kiro-cli/docs/fhs-sandbox.md`](packages/kiro-cli/docs/fhs-sandbox.md),
    [`packages/kiro-cli/docs/launcher-argv.md`](packages/kiro-cli/docs/launcher-argv.md)

- **`markdown-formatting`**
  - Match: `**/*.md`, `checks/markdown/doubled-words-fixtures.nix`,
    `checks/markdown/doubled-words-fixtures.py`,
    `checks/markdown/doubled-words.nix`, `checks/markdown/doubled-words.py`,
    `checks/markdown/fixtures/doubled-words/**`,
    `checks/markdown/markdown-scan.nix`,
    `checks/markdown/markdown-scanners.nix`,
    `checks/markdown/split-code-spans.nix`,
    `checks/markdown/split-code-spans.py`, `treefmt.nix`
  - Read:
    [`dev/fragments/markdown-formatting/markdown-formatting.md`](dev/fragments/markdown-formatting/markdown-formatting.md)

- **`mcp-secrets`**
  - Match: `checks/*/factory-eval.nix`, `checks/*/module-eval.nix`,
    `lib/ai/app/mkBackendTransform.nix`, `lib/ai/mcpProxy.nix`,
    `lib/ai/mcpServer/**`, `lib/ai/sharedOptions.nix`, `lib/mcp.nix`,
    `lib/testing/factory-harness.nix`, `lib/testing/module-harness.nix`,
    `packages/*/checks/factory-eval.nix`, `packages/*/checks/module-eval.nix`,
    `packages/kiro-cli/lib/mcpSecrets.nix`, `packages/kiro-cli/lib/mkKiro.nix`,
    `packages/kiro-cli/lib/wrapPackage.nix`
  - Read:
    [`dev/fragments/mcp-secrets/mcp-secrets.md`](dev/fragments/mcp-secrets/mcp-secrets.md)

- **`mcp-servers`**
  - Match: `packages/*/packages/ai/mcpServers/**`
  - Read:
    [`dev/fragments/mcp-servers/js-server-packaging.md`](dev/fragments/mcp-servers/js-server-packaging.md),
    [`dev/fragments/mcp-servers/overlay-guide.md`](dev/fragments/mcp-servers/overlay-guide.md)

- **`mcp-services`**
  - Match: `checks/*/factory-eval.nix`, `checks/*/module-eval.nix`,
    `lib/ai/mcpServer/mkServiceModule.nix`,
    `lib/ai/mcpServer/serviceSchema.nix`, `lib/testing/factory-harness.nix`,
    `lib/testing/module-harness.nix`, `packages/*/checks/factory-eval.nix`,
    `packages/*/checks/module-eval.nix`, `packages/*/modules/mcp-server.nix`,
    `packages/mcp-services/modules/homeManager/default.nix`
  - Read:
    [`dev/fragments/mcp-services/service-host-contract.md`](dev/fragments/mcp-services/service-host-contract.md)

- **`nix-standards`**
  - Match: `**/*.nix`
  - Read:
    [`dev/fragments/nix-standards/nix-standards.md`](dev/fragments/nix-standards/nix-standards.md)

- **`overlays`**
  - Match: `lib/facets/**`, `lib/testing/**`, `lib/packaging.nix`,
    `packages/*/lib/packaging.nix`, `packages/*/packages/**/*.nix`,
    `packages/*/packages/**`
  - Read:
    [`dev/fragments/overlays/cache-hit-parity.md`](dev/fragments/overlays/cache-hit-parity.md),
    [`dev/fragments/overlays/overlay-pattern.md`](dev/fragments/overlays/overlay-pattern.md),
    [`dev/fragments/overlays/unfree-guard.md`](dev/fragments/overlays/unfree-guard.md)

- **`packaging`**
  - Match: `config/update-targets.nix`, `packages/**/*.nix`
  - Read:
    [`dev/fragments/packaging/naming-conventions.md`](dev/fragments/packaging/naming-conventions.md),
    [`dev/fragments/packaging/platforms.md`](dev/fragments/packaging/platforms.md)

- **`pipeline`**
  - Match: `.github/actions/warm-ifd/**`, `.github/workflows/ci.yml`,
    `.github/workflows/update.yml`, `config/fragment-categories.nix`,
    `config/generate-update-ninja.nix`, `config/update-targets.nix`,
    `dev/generate.nix`, `dev/scripts/ci-*.py`, `dev/scripts/test-ci-*.py`,
    `dev/scripts/test-update-*.py`, `dev/scripts/update-*.py`,
    `dev/scripts/update-*.sh`, `dev/tasks/generate.nix`,
    `lib/ai/transformers/**`, `lib/fragments-registry.nix`, `lib/fragments.nix`,
    `lib/update.nix`, `packages/*/registry.nix`
  - Read:
    [`dev/fragments/pipeline/ci-update-workflow.md`](dev/fragments/pipeline/ci-update-workflow.md),
    [`dev/fragments/pipeline/fragment-pipeline.md`](dev/fragments/pipeline/fragment-pipeline.md),
    [`dev/fragments/pipeline/generation-architecture.md`](dev/fragments/pipeline/generation-architecture.md),
    [`dev/fragments/pipeline/update-pipeline.md`](dev/fragments/pipeline/update-pipeline.md)

- **`semble`**
  - Match: `packages/semble/**`
  - Read: [`packages/semble/docs/semble.md`](packages/semble/docs/semble.md)

- **`shell-activation`**
  - Match: `.envrc`, `devenv.yaml`, `lib/traceSource.nix`
  - Read:
    [`dev/fragments/shell-activation/activation-mechanism.md`](dev/fragments/shell-activation/activation-mechanism.md)

- **`stacked-workflows`**
  - Match: `packages/stacked-workflows/**`
  - Read:
    [`packages/stacked-workflows/docs/development.md`](packages/stacked-workflows/docs/development.md)

<!-- Generated by dev/generate.nix -->
<!-- Fragment: packages/coding-standards/fragments/coding-standards.md -->

## Coding Standards

### Bash

All shell scripts must use full strict mode:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
```

`-E` (errtrace), `-T` (functrace) and `inherit_errexit` are the point: they
propagate failures out of the subshells, functions and command substitutions
that the abbreviated `set -euo pipefail` silently swallows. Never use the
abbreviated form.

**No linter checks this for you.** shellcheck has no strict-mode diagnostic — a
script carrying `set -euo pipefail`, or no `set` line at all, passes it clean.
The header is a review obligation, not a gate.

Where it applies depends on whether the shell owns its own process or is spliced
into someone else's:

| Site                                       | Rule                                                                                                                |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `home.activation` bodies                   | SCOPE IT — wrap the body in a subshell; entries concatenate, so a bare header persists into home-manager's own code |
| `shellHook` / devenv `enterShell`          | DO NOT ADD — `eval`'d into the calling shell; `set -e` arms the user's interactive session                          |
| stdenv phases, `runCommand` bodies         | DO NOT ADD — `setup.sh` already sets all four, and phases share one shell                                           |
| devenv `tasks.<name>.exec`                 | REQUIRED — rendered as a standalone script                                                                          |
| shell EMITTED by a heredoc                 | REQUIRED inside the emitted script                                                                                  |
| standalone `*.sh`, CI `run:` blocks        | REQUIRED                                                                                                            |
| `writeShellApplication`                    | SPLIT — see below; `bashOptions` alone never suffices                                                               |
| `writeShellScript` / `writeShellScriptBin` | REQUIRED — nixpkgs never lints these                                                                                |
| heredocs carrying JSON, config or prose    | does not apply — not shell                                                                                          |
| pre-commit / git-hook `entry` strings      | cannot be expressed — an argv, not a script; move the logic into a `writeShellApplication`                          |

`writeShellApplication` needs the header **split across two places**, because
`bashOptions` renders `set -o <name>` lines only and `inherit_errexit` is a
`shopt`:

```nix
pkgs.writeShellApplication {
  bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
  text = ''
    shopt -s inherit_errexit 2>/dev/null || :
    …
  '';
}
```

Put the `set -o` flags in `bashOptions` rather than all five in `text`:
writeShellApplication emits them ABOVE its own generated
`export PATH="…:$PATH"`, so `nounset` covers that line. Without it, a PATH-less
invocation yields a trailing-colon PATH — which bash reads as the current
directory — instead of failing loudly.

`home.activation` needs the header **scoped**, because home-manager concatenates
every DAG entry into one script it opens with `set -eu` + `set -o pipefail`.
Flags an entry sets stay set for every later entry, home-manager's own included:

```nix
home.activation.thing = lib.hm.dag.entryAfter ["linkGeneration"] ''
  (
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :
  …
  )
'';
```

Only wrap bodies with no parent-shell effects (no `export`, no `cd`, no `trap`).
Failure still propagates — the subshell exits non-zero and the caller's `set -e`
sees it. End a failing body with `false`, never `exit`, which would truncate the
whole concatenated script.

Two blind spots to catch by eye in review: shellcheck does not lint heredoc
BODIES under either `<<EOF` or `<<'EOF'`, and nixpkgs runs shellcheck on
`writeShellApplication` only — `writeShellScript` gets a syntax parse and no
lint at all.

### Ordering

Keep entries sorted alphabetically within categorical groups. Use section
headers for readability, sort entries within each group. This applies to lists,
attribute sets, JSON objects, markdown tables, TOML sections, and similar
collections.

### DRY Principle

Never duplicate logic, configuration, or patterns. When the same thing appears
twice, extract it. Three similar lines is better than a premature abstraction,
but three similar blocks means it is time to extract.

<!-- Fragment: packages/coding-standards/fragments/commit-convention.md -->

## Commit Convention

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

**Types:** `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`,
`style`, `test`

**Scopes** (optional but encouraged): package or module name (e.g.,
`context7-mcp`, `copilot-cli`, `fragments`), directory name (`overlay`,
`module`, `lib`, `devshell`), or `flake` for root changes.

Keep descriptions lowercase, imperative mood, no trailing period.

<!-- Fragment: packages/coding-standards/fragments/config-parity.md -->

## Config Parity

Three configuration methods exist with the same rough interface:

- **lib/** — manual functions for consumers wiring config directly
- **HM modules** (`modules/`) — declarative home-manager (system-level)
- **devenv modules** (`modules/devenv/`) — project-local dev shell

If a feature can be configured in HM, it must also be configurable in devenv and
vice versa. Gaps between methods are bugs.

Surfaces to keep aligned across all three methods: skills,
instructions/steering, MCP servers, LSP servers, settings, hooks, agents,
environment variables, permissions.

The `ai.*` module (both HM and devenv) provides a unified interface that fans
out shared surfaces to enabled ecosystems (Claude, Codex, Copilot, Kimchi, Kiro)
with ecosystem-specific translation. A surface without a lossless native mapping
is an explicit exclusion, not a silent no-op.

<!-- Fragment: packages/coding-standards/fragments/tooling-preference.md -->

## External Tooling

When accessing external services, prefer the highest-fidelity integration
available:

1. **MCP server** — richest context, structured responses, stays in-conversation
2. **CLI tool** (e.g., `gh`, `curl`) — scriptable, good for batch operations
3. **Direct web access** — last resort, use only when MCP and CLI are
   unavailable

<!-- Fragment: packages/coding-standards/fragments/validation.md -->

## Validation

### Formatting

After editing any file — regardless of how it was modified (Edit, Write, Bash,
sed, etc.) — run `treefmt <file>` on the changed file. treefmt handles Nix (via
alejandra) and markdown (via prettier).

<!-- Fragment: packages/stacked-workflows/fragments/skill-routing.md -->

## Skill Routing — MANDATORY

**RULE: Before running any git-branchless, git-absorb, or git-revise command via
Bash, check whether a `stack-*` skill covers the operation.** Skills carry
pre-flight checks, dry-run previews, conflict guidance, and post-operation
verification that the equivalent hand-run commands miss.

Each skill's own description states which operations it covers.

<!-- Fragment: devenv.nix -->

## Delegate Sizing

Before calling a subagent, spawning a delegate, or building a workflow, load the
`delegate-sizing` skill when your harness provides it and size the model and
effort explicitly; a delegate never inherits the session's model and effort.

### Launch independent work together

Before launching a delegate, ask what else is ready to run now. Briefs that
share no state go out in one message, not in consecutive turns.

A dependency graph deeper than two steps belongs in a workflow script, so stages
overlap instead of queueing.

Concurrency is still bounded: at most two external CLI delegates on one machine,
and never two against the same working tree before the first has committed.

### Orchestrator session

Keep the main session conversational. It reasons with the operator, decides, and
delegates the doing.

Delegate bulk reading, searching and measurement, every edit-verify loop, and
any run longer than a few minutes. Keep the decision, the brief, and the
verification of what came back.

Read a file into the session only to reason about it with the operator. Bulk
output goes to disk and the delegate reports the conclusion.

### Prefer the flat-rate pool

When one pool bills per token and another is flat-rate, send long, iterative or
context-heavy work to the flat-rate pool. Offloading there is not a budget
trade-off.

An unused allowance does not carry over. Spending it is free; hoarding it is a
loss.

### Verify by the artifact

A delegate's exit code reports whether its process ended, not whether it did the
work. Verify by the tree, the diff or the artifact it was asked to produce.

Ask what else in the repository is derived from or gated on the files it
touched, and check those too. Reviewing the diff proves the diff is good; it
does not prove the tree is consistent.

<!-- Fragment: dev/fragments/monorepo/architecture-fragments.md -->

## Architecture Fragments

> **Last verified:** 2026-09-12 — package categories live in owner registries
> and generation shares native metadata assembly.

This repo ships path-scoped architecture fragments as dev-only context for
agents working on it. They are SEPARATE from the published consumer-facing
content. Three location flavors are supported by `dev/generate.nix`:

- `dev/fragments/<category>/<name>.md` (default `location = "dev"`) —
  orientation and topic-scoped categories not tied to a single package.
  `dev/fragments/monorepo/` specifically holds the always-loaded orientation,
  composed into `common.md` and the equivalent for each ecosystem.
- `packages/<pkg>/docs/<name>.md` (`location = "package"`) — co-located with the
  package whose abstractions it documents.
- `devshell/<group>/docs/<name>.md` (`location = "devshell"`) — co-located with
  a devshell module.

Scope globs (which files the fragment loads for) live separately in
`config.fragments.categories.<category>.scopes` (composed from owner
`registry.nix` files and `config/fragment-categories.nix`) and are independent
of where the markdown source lives on disk.

Each scoped fragment emits per-ecosystem frontmatter via the
`lib/ai/transformers/` pipeline:

- Claude: `.claude/rules/<name>.md` with `paths:` YAML list
- Copilot: `.github/instructions/<name>.instructions.md` with `applyTo:`
  comma-joined globs
- Kiro: `.kiro/steering/<name>.md` with `inclusion: fileMatch` and an array
  `fileMatchPattern:`
- Codex / AGENTS.md: always-loaded orientation plus a compact routing index.
  Codex has no glob-scoped instruction primitive, so matching remains a manual
  progressive-disclosure step: the index maps the same registry scopes to the
  authoritative source documents. AGENTS.md used to concatenate every scoped
  fragment body, but that bloated it to ~2k lines; Phase 2.4 removed the bodies
  (commit c4f4aff), and the generated index restores discoverability without
  restoring that context cost.

The source fragments are authoritative. The Claude, Copilot, and Kiro files are
generated projections; some are gitignored and only materialized by devenv shell
entry. Never edit a runtime projection directly. A `devenv shell` or direnv
reload regenerates the analysis files after source or registry changes.

### Maintenance is mandatory

**When you make changes that alter the shape of any abstraction a scoped
fragment describes, update the fragment in the same commit.** Out-of-date
architecture fragments actively mislead future sessions and are worse than no
fragment at all.

Each scoped fragment opens with a `Last verified: <date> (commit <hash>)`
marker. If that marker predates your change to the area the fragment scopes, the
fragment is stale. Stop and update it before landing the commit — in the same
commit, not a follow-up.

This is not an etiquette rule. Research on LLM context shows out-of-date
instructions degrade task success more than missing instructions. A lie is worse
than silence.

### The marker is ONE entry, not a changelog

Update the `Last verified` marker in place. **Do not append the old entry as a
`Prior:`.** These fragments are LLM context: one source fans out to Claude,
Codex, Copilot and Kiro, so every byte is paid four times, on every turn that
matches the scope.

The habit of chaining `Prior:` entries grew to **82 KB across 31 fragments — 15%
of all fragment text** — and it broke a consumer outright: github.com's Copilot
PR reviewer began failing with `Prompt too big after adding system message`
before it read a line of any diff.

**The body is the record.** A correction that was applied to the body needs no
changelog entry — the body already says the true thing, and the entry only
restates it at four times the cost. That is what nearly all of those 82 KB were.

Keep exactly two things beyond the current entry, and only when they earn it:

- A **`Settled — do not relitigate`** bullet, for an approach that was TRIED and
  REJECTED, or a measurement that would otherwise be re-derived wrongly. Name
  the rejected thing and why it failed, keep the evidence (dates, PR numbers,
  counts), and stop. This is the one thing git does not give you cheaply,
  because reading a diff tells you WHAT changed and not what was ruled out.
- A **git ref** to the last fuller version, when the reasoning is worth being
  able to re-read: `` `git show <hash>:<path>` ``. One ref, not a chain.

Everything else — re-verification with no change, restatements of what a commit
did, dates with no claim attached — is dropped. Deleting it loses nothing: it is
in the file's history, which is what history is for.

### When to add a new fragment

Add a fragment when you encounter a piece of non-inferable knowledge during
debugging or implementation — something the next session would burn a lot of
tokens rediscovering. Examples of the kind of content worth writing down:

- **Why** a non-obvious design decision was made (trade-offs, abandoned
  alternatives)
- **Cross-cutting invariants** that span multiple files
- **Shapes of abstractions** (fanout patterns, wrapper chains, activation
  lifecycles)
- **Known pitfalls** (subtle bugs, gotchas, migrations in flight)
- **Debugging entry points** (what to grep, what to eval)

Do NOT add fragments for content that is:

- Discoverable by reading the code itself in under 10 seconds
- Already covered by existing code comments (DRY)
- A restatement of function signatures, file paths, or line numbers
- Ephemeral (in-progress state goes in plan.md or memory, not fragments)

Target under 150 lines per fragment. If a topic outgrows that, split by
sub-concern with tighter scopes.

### Generator registration

New fragments are registered under `config.fragments.categories`: use the
owner's `registry.nix` for package-specific categories and
`config/fragment-categories.nix` for workspace/shared categories. The attribute
key is the category (which becomes the output filename for scoped Claude rules,
Copilot instructions, and Kiro steering). Each category is one record with two
fields: `scopes` (the path globs it loads for) and `sources` (the markdown
fragments composed into it). A `sources` entry is either a bare string (legacy
dev/fragments/ path) or an attrset with an explicit location:

```nix
# ILLUSTRATIVE ONLY — neither category below exists. Real rows
# live in config/fragment-categories.nix; read that file for them.
config.fragments.categories = {
  example-dev-sourced = {
    scopes = ["packages/example/**"];
    sources = [
      # bare string: location="dev", dir defaults to the category key
      "packaging-guide"
      # → dev/fragments/example-dev-sourced/packaging-guide.md
    ];
  };
  example-co-located = {
    scopes = ["packages/example/**"];
    sources = [
      {
        location = "package";
        name = "example-wrapper";
        # dir overrides the category key; null (the default) would
        # look under packages/example-co-located/docs/ instead
        dir = "example";
        # → packages/example/docs/example-wrapper.md
      }
    ];
  };
};
```

Both categories above are **fictional on purpose.** A worked example that names
a real category is a standing drift liability: it goes stale every time that
category's `scopes` change, and the maintenance rule above will not catch it,
because re-pointing a glob does not alter the _shape_ this snippet teaches. That
is exactly how this snippet rotted once — it taught `packages/ai-clis/**`, a
directory that no longer exists. Keep the example about the record's shape and
let `config/fragment-categories.nix` be the source of real rows.

`scopes` is a Nix list of globs, and `null` means always-loaded (what the
`monorepo` orientation category uses). The option itself is declared in
`lib/fragments-registry.nix`; `lib/facets/registry.nix` composes the
contributions with `lib.evalModules`, and `dev/generate.nix` reads its result.
The transforms handle per-ecosystem emission — do not hand-format frontmatter.

After adding or editing fragments, run
`devenv tasks run --mode before generate:all` to regenerate instruction and
repo-document projections. `--mode before` is load-bearing: without it devenv
runs an aggregate without its dependency leaves.

<!-- Fragment: dev/fragments/monorepo/build-commands.md -->

## Build & Validation Commands

```bash
nix flake show                # List all outputs
nix flake check               # The CI gate: formatting, structural/module eval,
                              # runtime contracts, and validator corpus scans
                              # (does NOT build the package output set)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter devShell with all tools
treefmt                       # Format all files (formats only — lints nothing)
devenv tasks run devenv:git-hooks:run # Manual-stage local all-files diagnostic

# Regenerate instruction files from fragments. `--mode before` is load-bearing:
# without it devenv runs the aggregate and skips the leaves. Use generate:all,
# not generate:instructions — the latter does not cover CONTRIBUTING.md.
devenv tasks run --mode before generate:all
```

<!-- Fragment: dev/fragments/monorepo/change-propagation.md -->

## Change Propagation

When removing or renaming a concept, update ALL surfaces that reference it in
the same commit:

- Fragments and generated instruction files
- CLAUDE.md, AGENTS.md, Kiro steering, Copilot instructions
- Routing tables in skills
- README feature matrix and server reference
- flake.nix output lists
- config.update.targets entries (owner registry.nix)
- CI workflow matrices
- Home-manager module registrations
- Overlay export lists
- Structural check expectations

The structural check (`nix flake check`) validates cross-references. The
pre-commit hook runs a fast subset. If something is removed, grep for it across
the repo before committing.

<!-- Fragment: dev/fragments/monorepo/git-workflow.md -->

## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-09-20 — follow-ups amend the PR whose scope they
> belong to.
>
> **Settled — do not relitigate.** Each of these records an approach that was
> TRIED and rejected, so the reasoning is not re-derived from scratch. Full
> lineage: `git show ca236499:dev/fragments/monorepo/git-workflow.md`.
>
> - **Back up with a ref pushed to `origin`, never a local tag or branch.** The
>   tag was tried, on the sound reasoning that `--update-refs` moves branches
>   and not tags. Tags are refs in the COMMON git dir, so any worktree's fetch
>   prunes them all when the author's global `fetch.pruneTags` is set — measured
>   twice on 2026-08-15, the second time by the verifying fetch itself.
> - **Do NOT re-add a `devenv shell` bootstrap to the worktree recipe.** It was
>   required until 2026-08-18 and is now actively wrong under the sandbox-stack
>   topology. `devenv tasks run` was the obvious substitute and does NOT
>   materialize `.pre-commit-config.yaml` either — measured 2026-07-31 in two
>   fresh worktrees, where the task succeeded and the next commit was still
>   rejected.
> - **Do not restore `devenv-test` as a required context.** It was promoted
>   2026-08-03 and demoted two days later as a merge-blocking liability, risk
>   accepted; it left automatic PR/push execution entirely on 2026-08-29.
> - **Do not re-derive a Copilot auto-trigger rate from push observations.** The
>   "1 review in 5 pushes" datum was a ready-transition coinciding with a push,
>   not a flaky trigger. Sampling this way produces a confident wrong model and
>   costs a paid review re-establishing a trigger that fires on readiness only.

`main` is the trunk. Its branch-protection ruleset requires a pull request, no
force-push, no deletion, and six required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`kiro-patched (x86_64-linux, ubuntu-latest)`,
`kiro-patched (aarch64-darwin, macos-latest)`, `test`, and `gitleaks`. Both
`kiro-patched` contexts were promoted 2026-08-13 with PR #895; this file said
"four" until 2026-08-14. It requires **zero approving reviews** but it DOES
require **every review thread to be resolved**
(`required_review_thread_resolution`, enabled 2026-07-29).

The full Devenv Diagnostic is now `workflow_dispatch` only. It was promoted to a
required check on 2026-08-03, demoted on 2026-08-05 after becoming a
merge-blocking liability, and removed from automatic PR/push execution on
2026-08-29 after its deterministic contracts moved under `nix flake check`. Do
not "restore" its old context to make this fragment match historical prose —
read the ruleset:

```bash
gh api "repos/OWNER/REPO/rulesets" --jq '.[] | "\(.id)  \(.name)"'
gh api "repos/OWNER/REPO/rulesets/<id>" \
  --jq '.rules[] | select(.type=="required_status_checks")
        | [.parameters.required_status_checks[].context]'
```

**Squash-merge only** — but that is the REPOSITORY settings, not the ruleset:
`allow_squash_merge` true, `allow_merge_commit` and `allow_rebase_merge` false.
The ruleset's own `allowed_merge_methods` still lists all three, so changing it
there changes nothing. Copilot review comes from a separate ruleset rule
(`Copilot review for default branch`) that _requests_ a review **once per PR,
when it becomes ready** — not on every push (see the trigger model below): it is
neither a required approval nor a required status check.

**But it can now block a merge indirectly**, and that is deliberate. Since
threads must be resolved, an unaddressed Copilot comment holds the PR — a bot
`update/*` PR included, which is the intended trade: nothing auto-merges while a
reviewer has an open question on it. A stalled update PR is not lost; the next
4x/day sweep rebuilds and re-arms it.

### After you open or update a PR, the loop is YOURS

Not the operator's. They should not have to notice CI went red, notice a review
landed, or hand the PR back to you. You are the one still holding the context.

**Never end a turn on a promise.** "I'll check when it lands" with no mechanism
is worse than saying nothing: it looks like ownership and behaves like a block.
Arm something that re-invokes you — a backgrounded watcher whose exit wakes the
session — and only then report. Kill it once the signal arrives.

On every push, including the first:

1. **Watch CI to completion.** Read the exit status of the tool, not a
   notification's summary — a pipeline's status is the last command's, so
   `nix flake check | tail` reports the tail's success. Capture the real code.
2. **A conflicted PR gets ZERO check runs and reads exactly like slow CI.**
   `mergeStateStatus: DIRTY` with an empty check list means rebase, not wait.
   The same shape appears when the base moves under a long-running branch.
3. **React to a red check by reading the failing job's log**, not by guessing
   from the check name. Fix, push, re-arm the watcher.
4. **Then read the review** (next section).

Only report back when the PR is green and reviewed, or when something needs a
decision that is genuinely the operator's.

### Copilot reviews once, automatically. Do not trigger the first one

The ruleset requests it when the PR **becomes ready for review** — which covers
a PR opened non-draft as well as a draft flipped later. It is automatic. Do not
request it by hand, and do not treat an absent run on a fresh push as a missed
trigger: pushes never trigger a review, so absent is the resting state.

**Re-request only after a significant change since the last run.** New scope, a
mechanism the previous review never saw, an approach rewritten rather than
corrected. Applying the review's own findings is NOT a significant change, and
neither is rewording, reformatting or renaming. There is no round count to spend
down — there is one question, asked each time: is there materially new code to
review? Every review after the first is a paid manual request.

Read BOTH buckets. The inline threads gate the merge; the review body carries a
suppressed block that creates no thread and that a heading grep will silently
miss. Reply and resolve each gating thread **in the same turn as the fix**, not
after the checks pass. Mechanics, and the API traps that each report a clean
round that did not happen, are in the `pr-review-loop` skill.

### When Copilot does not review, a SEPARATE agent does

Triggers, any of them: the review errored, the account is out of quota, the PR
never left draft, or `git diff --stat <last-reviewed-sha>...HEAD` shows a change
that would earn a re-request under the test above — a new file or mechanism, or
an approach rewritten rather than corrected.

**You cannot review your own diff.** Reading it back produces agreement, because
the reasoning that wrote the code is the reasoning evaluating it. Dispatch a
reviewer that did not write it, told plainly that the PR body is an argument
rather than evidence and that its author cannot be deferred to. One independent
reviewer is the default. Report what was dismissed as well as what was fixed.

This is not a fallback for one outage. It is the standing substitute whenever
the automatic review did not happen, and github.com Copilot fails on this repo
often enough that it is the common case, not the rare one.

### Escalating past one reviewer: prosecute, defend, judge

Escalate from one independent reviewer to the three-role protocol when EITHER
holds. Do not grade the change's "complexity" — that word routed this decision
before and two agents reading it reached opposite answers.

**(a) You intend to DISMISS a reviewer finding rather than fix it.** Dismissing
your own reviewer's finding is the second discard filter this whole structure
exists to remove, so the intent to dismiss is itself the trigger. One round,
scoped to the disputed findings only.

**(b) The diff touches a shared abstraction.**
`git diff --name-only origin/main...HEAD` matches `lib/**`, `packages/*/lib/**`
or `packages/*/packages/**/*.nix`; or a hunk under `packages/*/modules/**` or
`lib/ai/**` adds, removes or retypes a `mkOption`.

Everything else uses the single-reviewer default. Run the three-role protocol:
an agent that prosecutes, a separate agent that defends, and a third that judges
on evidence. If the judge cannot converge, loop — at most three rounds, each
narrowed to what stayed unresolved. Surface a genuine split to the operator
rather than adjudicating it yourself.

**Scope, deliberately narrow:**

- Only for changes going to `main`. A draft PR, or a long-lived experiment
  branch where the design is not settled yet, forgoes it — if it is a draft, it
  is not ready for this.
- **Local runtimes only, always.** Never hand this to github.com Copilot: it
  cannot be given a model or an effort level, and the cost belongs where those
  controls exist.
- Size the roles separately, and never let a delegate inherit an interactive
  session's model and effort by default — see the delegate-sizing orientation.

The recipe is in the `pr-review-loop` skill. It lives there rather than here
because a skill is the only manual-load carrier that works across runtimes —
Kiro's `inclusion: manual` steering is inert in the CLI.

### Every change goes through an isolated worktree + PR

**"Change" includes untracked drafts.** The rule is not "worktree before you
commit" — it is worktree before you author the FIRST repo-destined file, and a
working doc you have not decided to commit yet still counts. Added 2026-08-05
after a reference doc was drafted directly in the primary checkout: the operator
runs multiple parallel sessions that share that cwd, so every one of them
started failing the shared lint hooks on a file none of them had written, while
the drafting session was the only one that could not see the damage. The primary
checkout belongs to the operator, not to any agent session.

Pre-flight before the first Write/Edit of any repo file in a session:

```bash
git rev-parse --path-format=absolute --git-dir
# ends in .git/worktrees/<slug> → linked worktree, proceed
# ends in a bare <clone>/.git   → primary checkout: STOP, make a worktree first
```

`--path-format=absolute` is load-bearing, not decoration, and the bare form is
actively misleading here. `git rev-parse --git-dir` prints a path **relative to
cwd when it can**, so at the top of the primary checkout it answers `.git` —
while in a linked worktree it answers an absolute
`<clone>/.git/worktrees/<slug>`. Measured both ways on 2026-08-05. So the one
case the check exists to catch is the case whose output does not look like the
`<clone>/.git` you are comparing against, and a reader matching on that string
concludes "not the primary checkout" precisely when they are standing in it.
Forcing absolute makes both arms comparable. This is the same flag the worktree
derivation below already uses for `--git-common-dir`, and the same one
`devenv.nix` uses for its related checks.

Only the session scratchpad is exempt, because it never touches the repo tree at
all. There is no "just a draft" exemption, no "I'll move it before committing"
exemption, and no "it's gitignored-adjacent" exemption.

Worktrees live in `<repo>-worktrees/`, a **sibling of the primary checkout** — a
clone at `~/src/nix-agentic-tools` puts them in
`~/src/nix-agentic-tools-worktrees/<slug>`. Keeping them beside the clone means
a direnv whitelist (or any editor/tooling trust root) covering the checkout
covers new worktrees too, so editors and tooling treat them as the same trusted
project — and it keeps work out of `~/.cache`, which cache-cleaning tools treat
as disposable.

This used to be justified by `cd` alone entering the devenv shell and
materializing the gitignored `files.*` artifacts, which was how a worktree got
bootstrapped. That is no longer a reason to want it: nothing needs a worktree
shell entry now (step 2 below), and under the sandbox-stack topology devenv is
deliberately entered in the primary checkout only. Do not read the sibling
layout as an endorsement of direnv-driven devenv entry in worktrees.

Derive that directory once per shell. This form is correct from **any**
worktree, not just the primary checkout:

```bash
worktrees="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")-worktrees"
```

`--git-common-dir` resolves to the ORIGINAL clone's `.git` even when run from a
linked worktree, so `dirname` of it is always the primary checkout. Do **not**
substitute a bare `../<repo>-worktrees/<slug>`: from a linked worktree that
silently resolves one level too deep, into
`<repo>-worktrees/<repo>-worktrees/<slug>`.

1. Branch off `main` into its own worktree:

   ```bash
   git worktree add -b <type>/<slug> "$worktrees/<slug>" origin/main
   ```

   `<type>` is a Conventional Commits type (`build`, `chore`, `ci`, `docs`,
   `feat`, `fix`, `perf`, `refactor`, `style`, `test`).

2. **There is no worktree bootstrap step.** `git worktree add` and commit — the
   shared prek hooks resolve their config from the primary checkout, and
   `PREK_HOME` from the committing worktree, so a worktree that has never
   entered `devenv shell` validates exactly like one that has.

   This changed on 2026-08-18 and the old shape is worth knowing, because every
   doc and habit predating it says otherwise. The hooks used to resolve
   `.pre-commit-config.yaml` from the COMMITTING worktree's toplevel — a devenv
   `files.*` artifact materialized on SHELL ENTRY only, which `git worktree add`
   never runs — so a fresh worktree's first commit was rejected until you ran
   `devenv shell true` in it. Worse, `devenv tasks run` did not materialize it
   either — measured 2026-07-31 in two fresh worktrees (`generate:all` succeeded
   in each and the next commit was still rejected) and re-confirmed 2026-08-18 —
   so bootstrapping via the task you needed anyway looked like it worked and
   failed later, attributed to the commit. That asymmetry is still live for
   anything else that wants a `files.*` artifact in a worktree; it just no
   longer gates commits.

   The primary checkout is the one that is entered — sessions launch there and
   the agent process runs with cwd in a linked worktree — so its config always
   exists and always tracks regeneration. **Only the primary checkout needs
   `devenv shell true`, and only after a fresh clone or a `devenv.nix` change.**
   If a commit is ever rejected for a missing config, the hook names that path
   and that fix; do not silence it with `PREK_ALLOW_NO_CONFIG=1`,
   `--allow-missing-config`, or `prek uninstall` — all three skip every check
   rather than fixing the bootstrap.

   Enter `devenv shell` in a **worktree** only when you specifically need its
   generated artifacts there (regenerating instruction projections, say). It is
   no longer a prerequisite for anything, and under the sandbox-stack topology
   it is not the intended shape.

3. **Push at the first commit** — not at the end — so the branch is a continuous
   off-machine backup. Open the PR **ready (non-draft) as soon as the work is
   dev-complete**: becoming ready for review is the _only_ thing that
   automatically requests a Copilot review, so a draft that is actually ready
   silently skips review and a later flip is what fires it. Reserve **draft**
   for genuine WIP, or when you explicitly want to preview the branch in GitHub
   without review. Draft and ready PRs both get full CI here.

   Corollary worth internalizing: that one automatic review is the only free
   one, so **flip to ready when the branch is worth reviewing** — not
   mid-refactor, where it is spent on code you are about to replace.

4. Keep pushing as work lands. Flip draft → ready the moment it is dev-complete
   so review can start.

5. **The moment the PR is open and non-draft, run the Copilot review loop on
   your own initiative.** Nobody has to ask. Poll for the review on the head
   commit, read BOTH buckets, fix what is real, reply, resolve each gating
   thread, re-request, verify — the sections above say how. Handing back a
   freshly-opened PR with an unread review is an incomplete task, not a
   checkpoint: it makes the operator notice the review, chase it, and hand it
   back to you, when you are the one still holding the context to act on it.
   STARTING the loop needs no permission. It is ONE round; going beyond that
   needs a significant change in reviewed scope, or the operator's say-so.

6. Merges are squash merges. The operator performs them for **human** PRs; the
   bot's `update/*` PRs land themselves (next section).

7. **Always tear the worktree and local branch down once the PR is merged.**
   This cleanup belongs to the agent that implemented the change; do not hand it
   back to the operator or declare the task complete while either remains:

   ```bash
   git worktree remove "$worktrees/<slug>"   # re-derive $worktrees if needed
   git branch -D <type>/<slug>   # squash-merged: -d refuses, -D is correct
   ```

   The remote branch auto-deletes on merge.

### Put a follow-up in the PR it belongs to

A fix for a PR's own review, a follow-up its author already intended, a defect
found while reviewing it — all of these amend that PR. Do not open a second PR
to avoid disturbing a green one.

A stacked follow-up costs the same CI and the same review round as an amendment.
It just spreads them across more PRs and hands the reviewer a worse shape. "It
is already green and reviewed" is not a reason: CI is free on this repository,
and the review being protected examined a shape that has since been superseded.

The instinct this replaces is a sound one in a project with several reviewers,
where unasked additions tax people who did not ask for them. Here there is one
reviewer, and they would rather review the right shape once.

Open a separate PR when the change is genuinely unrelated to any open one.

### Bot `update/*` PRs land themselves

`.github/workflows/update.yml` sweeps dependencies 4x/day (00:00, 06:00, 12:00,
18:00 UTC) and opens one PR per dependency that actually moved. Each is armed
with GitHub-native **auto-merge (squash)** as it is created, and re-armed on
every later sweep, so it merges itself once the six required checks go green.
Safe precisely because the ruleset requires no approving review, all six status
checks must pass, and an unresolved Copilot thread still holds the merge through
the separate review-thread rule.

A merge conflict **disables** auto-merge, so a conflicted update PR drops out of
the queue until the next sweep rebuilds its branch on the current base and
re-arms it. Arming is non-fatal too: a failure logs an `Auto-merge not armed`
warning naming the branch and PR, and that PR is the one needing a hand.

There is **no manual merge path** — the `pr:merge-updates` task and
`merge-update-prs` skill that used to batch-merge these are deleted. Do not
reintroduce hand-merging of `update/*` PRs; land the individual stragglers the
pipeline could not, and fix the reason.

### What is shared across worktrees — and what is not

Linked worktrees of one clone share the common `.git` directory, so these are
**shared, not per-worktree**:

- **The hooks directory.** One `core.hooksPath` serves every worktree, and it
  holds git-branchless's hooks (`post-commit`, `post-rewrite`,
  `reference-transaction`, `post-checkout`) alongside the prek hooks. Do NOT
  redirect `core.hooksPath` per worktree: it **replaces** `.git/hooks` with no
  fallback, so branchless's hooks would stop firing in linked worktrees and its
  event log would silently miss every commit made there.
- **The git-branchless event database** (`.git/branchless/db.sqlite3`).
  Serialize stack-skill operations across concurrent worktrees; they are not
  session-isolated.
- **Local tags.** Tags are refs in the common git dir, so a tag created in one
  worktree is visible — and deletable — from every other. A fetch run from ANY
  worktree can wipe them all at once if the author's global git config sets
  `fetch.pruneTags`, which prunes local tags with no remote-tracking
  counterpart. See "Rebasing: back up with a pushed ref" below — this is the
  root cause the tag-backup advice used to miss.

The prek **config and runtime state** resolve from different places, and the
split is deliberate. The `hooks:isolate-config` devenv task rewrites the
installed hooks so that at hook-run time they resolve:

- **`.pre-commit-config.yaml` from the PRIMARY CHECKOUT**, via
  `$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")` — the
  same derivation the worktree recipe above uses. The primary checkout is the
  one that is entered, so its config always exists and always tracks
  regeneration, and the answer no longer depends on which checkout entered a
  shell last. That is what stops a shell entry in one worktree from changing
  what another validates against.
- **`PREK_HOME` beneath the COMMITTING worktree's `.devenv/state`.** A devenv
  shell's `PREK_HOME` is not inherited by commits launched from an editor or
  agent, so deriving it beats falling back to the user-global XDG cache; and
  under the agent sandbox the primary checkout is a read-only bind while the
  worktree is the writable one, so primary-anchored state would fail there. No
  `mkdir` is needed — prek creates `PREK_HOME` itself.

`lib/validate-at-stop.sh` mirrors both, for the same reasons: its session cwd is
normally a linked worktree, and a bare `prek run` there walks up from cwd, finds
no config, and exits 2 — output the judgment loop would report as a lint finding
and block the hand-back on.

The rewrite task takes a lock in the shared hooks directory and publishes each
complete hook with a same-filesystem rename after preserving its mode. Two shell
entries therefore serialize their rewrites, and a concurrent commit sees an old
or new complete hook rather than a partially truncated script. The upstream
installer still runs immediately before the rewrite task in each shell's devenv
DAG; do not split or reorder that dependency edge.

One more shared thing, and it lives outside the repository entirely: **the
agent's own memory directory is shared across concurrent sessions, and no
session sees another's writes.** There is no locking and no notification — a
session reads the memory index once and then writes into a directory that may
have moved underneath it. Two sessions on 2026-08-05 recorded the same concept
under different filenames minutes apart, and they agreed only by luck; had the
wording diverged, the repo would now carry two half-truths with no link between
them. A duplicate under a different name is invisible to the `[[wikilink]]`
graph, so it does not surface as a conflict — it just quietly fails to be found.

Before writing a memory, **list the directory by mtime and grep it for the
concept**, not for the filename you intend to use. Anything written in the last
few minutes is a live concurrent session, and the right move is to extend that
file rather than open a second one:

```bash
ls -lt "$MEMORY_DIR" | head -20
grep -rl "<the concept, not the slug>" "$MEMORY_DIR"
```

This is a general cross-harness rule, not a Claude Code one: any two agent
sessions sharing a memory store have it, and the failure is silent in all of
them.

### Rebasing: back up with a PUSHED ref, not a tag or a local branch

`git rebase --update-refs` (and git-branchless) moves any **branch** that points
into the rebased range — including a backup branch created moments earlier,
silently defeating it. A local **tag** dodges that, but is not safe either: tags
are refs in the COMMON git dir, shared across every worktree of the clone, and
`fetch.pruneTags` — a common global git config setting — prunes any local tag
with no matching remote-tracking ref on the next fetch, from ANY worktree.
Measured twice on 2026-08-15, the second time when the same session ran its own
fetch moments later to check whether an unrelated push had landed, and it
deleted the backup tag along with it. Neither primitive alone survives both
hazards, and there is no way to tell from the tag alone whether the local config
has `pruneTags` set, so write backup guidance that holds regardless:

```bash
git push origin HEAD:refs/heads/archive/<slug>   # create + push in one step
```

Push the backup **in the same command sequence as the rebase**, before running
it — not after, and not as a "verify it's there" step, because the fetch that
verifies it is exactly the kind of operation that can delete a local-only tag.
Only a ref that has actually reached `origin` survives both a rebase with
`--update-refs` and a prune-on-fetch.

Lockfile conflicts (`flake.lock`, `devenv.lock`) during a rebase are
**regenerated, never hand-merged**: take the base's copy, then re-run
`nix flake lock` (and let devenv reconcile `devenv.lock`) so the result matches
the merged `flake.nix` / `devenv.yaml`.

<!-- Fragment: dev/fragments/monorepo/linting.md -->

## Linting

> **Last verified:** 2026-08-31 — full-corpus treefmt and hook diagnostics run
> only as explicit devenv tasks, detached from shell activation. Full lineage:
> `git show f7189d05:dev/fragments/monorepo/linting.md`.

`nix flake check` is the authoritative CI gate. Local hooks provide earlier
feedback, but neither a successful changeset scan nor a `--no-verify` commit is
evidence that the tracked corpus is clean.

The source of truth is `config/repo-validation.nix`. Every hook declaration must
name its role, Stop participation, and CI backend (including an explicit `null`
for local-only commit-lifecycle hooks). Evaluation rejects a validator,
formatter, or security hook without CI coverage, and rejects a validator that
does not participate in Stop feedback. From that table the repo derives:

| Surface                    | Selection                                           | Scope                                                       | Authority                        |
| -------------------------- | --------------------------------------------------- | ----------------------------------------------------------- | -------------------------------- |
| Git hooks                  | each declaration's real Git stages                  | staged files / commit message                               | fast local feedback; bypassable  |
| Claude Stop                | `stop = "formatter"` or `"judgment"` → manual stage | unstaged ∪ staged ∪ untracked changes                       | agent feedback; not a merge gate |
| `checks.repo-lints`        | validators with `ci.backend = "git-hooks"`          | every matching tracked file                                 | required `test` context          |
| `checks.shellcheck-corpus` | validator with the specialized corpus backend       | every tracked extension- or shebang-identified shell script | required `test` context          |

The manual stage is a lifecycle boundary, not a synonym for pre-commit. It
contains treefmt plus the four code validators and therefore excludes convco,
gitleaks, treefmt-restage, and `reject-default-branch-commit`. Devenv
diagnostics and the Stop hook always request that stage explicitly; an unscoped
`prek run` must not be used for either. Stop may rewrite working-tree files but
never stages them. Index mutation belongs only to the pre-commit restager.

Full-corpus work is not a shell-entry concern. `devenv:treefmt:run` and
`devenv:git-hooks:run` remain explicit named diagnostics with no activation DAG
edges. `devenv test` invokes the same packaged hook runner only after
shell-entry tasks finish, before its runtime smoke assertions. This placement is
deliberate: devenv's `RunMode::All` can traverse from a shared prerequisite into
a sibling lane, so leaving the hook task behind `devenv:git-hooks:install` made
ordinary shell activation run the full repository even though the hook task
targeted `devenv:enterTest`.

The treefmt hook enables treefmt's SQLite evaluation cache and sets
`require_serial = true`. prek otherwise partitions the files across concurrent
treefmt processes; those processes contend on one cache database, time out, and
lose the intended warm-cache benefit. The Stop hook is the exception: it sets
`TREEFMT_NO_CACHE=true` for both formatter passes so the second pass proves the
first rewrite converged instead of accepting a cache hit as that proof.

Formatters and linters remain separate — treefmt formats and lints nothing.

**Formatters — treefmt, all write in place:**

- **JS/TS/JSX/JSON/CSS:** biome
- **Markdown/YAML and friends:** prettier (`proseWrap = "always"`)
- **Nix:** alejandra
- **Shell:** shfmt (`*.sh`, `*.bash` — extension globs only, so it never sees an
  extensionless script, shell embedded in a `.nix` string, or a heredoc body)
- **TOML:** taplo

**Code validators — local changeset feedback plus CI corpus gates:**

- **Nix:** deadnix (dead code), statix (anti-patterns)
- **Shell:** `shellcheck -x` with the shared opt-in flags from
  `config/shell-strict.nix`. The specialized CI scanner deliberately covers a
  superset of prek's file tagging and hard-fails an empty corpus.
- **Spelling:** cspell

**Commit-only hooks:**

- convco (commit message shape)
- gitleaks (staged secrets; mirrored by its standalone CI job)
- reject-default-branch-commit
- treefmt-restage (re-adds formatter changes only during pre-commit)

**Available in the devShell, wired to no gate:** agnix (agent config linting) —
run it by hand or via the agnix MCP server.

There is no shellharden in this repo, and no linter reads shell embedded in
`.nix` strings beyond `writeShellApplication`'s own checkPhase. See the Bash
coding standard for which sites that leaves unchecked.

<!-- Fragment: dev/fragments/monorepo/peer-communication.md -->

# Peer Communication

> **Last verified:** 2026-09-23 — replaced with the operator-provided peer
> communication guide.

Optimize communication for **low reader effort, fast understanding, and fast
decision-making**.

Do not optimize for sounding sophisticated, academic, authoritative, or
maximally compressed.

## Audience and experience

Assume shared technical knowledge from the conversation.

Signals of experience, seniority, expertise, role, or technical depth may appear
anywhere in the context: user messages, memories, instructions, project files,
documentation, prior conversations, or retrieved material.

Use those signals only to adjust:

- what background knowledge you can assume;
- which concepts need explanation;
- how much introductory material can be omitted.

They must **not** cause you to:

- increase formality;
- use more scholarly vocabulary;
- increase sentence complexity;
- increase abstraction;
- compress more information into each sentence;
- adopt an academic or peer-reviewed-paper register.

Expertise changes **what needs explaining**, not how difficult the prose should
be to read.

Use normal language for the domain.

## Primary optimization target

Optimize in this order:

1. Correctness.
2. Time to understand.
3. Time to find the relevant information.
4. Time to decide or act.
5. Brevity.

Brevity matters only when it improves the goals above.

**Do not trade reader decoding effort for fewer words or tokens.**

A slightly longer answer that can be understood immediately is better than a
shorter answer that must be mentally unpacked.

## Concision

Interpret concise as **removing communication that does no useful work**.

Remove:

- praise or validation as conversational filler;
- restatement of the user's question;
- introductions that merely announce the answer;
- unnecessary scene-setting;
- rhetorical transitions;
- repeated conclusions;
- generic caveats;
- ornamental prose;
- unsolicited appendices;
- habitual "one more thing" additions;
- offers to do more work when there is no concrete reason to make the offer.

Do **not** interpret concise as:

- maximizing information per sentence;
- omitting useful connective reasoning;
- merging independent claims together;
- replacing direct statements with dense abstractions;
- shortening an explanation until the reader must reconstruct the reasoning.

## Language

Use ordinary professional language.

Prefer direct verbs and familiar words.

Prefer:

- use;
- build;
- change;
- because;
- but;
- needs;
- causes;
- prevents;
- probably;
- I don't know.

Avoid prestige vocabulary when an ordinary word communicates the same thing.

For example, avoid unnecessary use of:

- utilize;
- leverage when "use" means the same thing;
- facilitate;
- elucidate;
- operationalize;
- underscore;
- multifaceted;
- nuanced when no specific nuance is identified;
- paradigm when a more concrete word exists;
- "it is important to note";
- "it is worth noting";
- "it bears mentioning."

Domain terminology is fine when it is the normal precise vocabulary of the
domain.

Do not dumb down technical content. Make the **language** easy to process while
preserving the **technical content**.

## Information density

Do not confuse concise writing with compressed writing.

Avoid:

- many independent ideas in one sentence;
- several qualifications nested into one statement;
- omitted connective reasoning;
- noun-heavy abstractions where direct verbs are clearer;
- excessive parentheticals;
- bullets that are miniature academic paragraphs;
- conclusions that must be inferred rather than stated.

Prefer:

> X owns the connection. That means Y cannot restart it independently. So this
> still creates lifecycle coupling.

Over:

> X's connection ownership implies persistent lifecycle coupling precluding
> independent Y restart semantics.

The first is longer. It is better.

## Structure for scanning

Assume the response will often be scanned before it is read linearly.

Make the scan useful.

A reader should be able to quickly identify:

- the answer;
- important findings;
- disagreement;
- risks;
- alternatives;
- decisions;
- required actions;
- unresolved questions.

Use structure when it reduces search effort.

- Lead with the answer, conclusion, recommendation, or current state.
- Use bullets for sibling facts, constraints, findings, risks, or alternatives.
- Use numbered lists when order matters.
- Use tables when several things are genuinely being compared across common
  dimensions.
- Use short paragraphs for causal reasoning and connected explanation.
- Keep paragraphs focused on one idea.
- Use descriptive headings when they help navigation.

Do not turn every response into an essay.

Do not add structure merely to make the answer appear polished.

## Actions and decisions

When the user needs to do something, make that unmistakable.

When useful, explicitly identify:

- **Decision:** what needs to be chosen.
- **Need from you:** information required to continue.
- **Action:** something the user must do.
- **Blocker:** something preventing progress.
- **Risk:** something that materially changes the decision.

Use labels only when they improve scanning.

If nothing is required from the user, do not invent an action item.

Do not bury required action inside explanatory prose.

## Peer behavior

Treat the interaction as working communication between technical peers.

- Be direct.
- Disagree when warranted.
- Challenge assumptions that materially affect the result.
- Point out contradictions.
- Identify missing constraints when they matter.
- Distinguish fact, inference, recommendation, and uncertainty when the
  distinction affects the decision.
- Do not manufacture balance when one option is clearly stronger.
- Do not defer to claimed or inferred experience when evidence points elsewhere.
- Do not praise the user's question, background, architecture, or reasoning as
  conversational filler.
- Do not soften technical disagreement until its meaning becomes unclear.
- Do not argue merely to appear critical.

Prefer:

> I don't think that boundary works. X still owns the state Y needs, so the
> coupling is still there.

Over:

> That's a thoughtful direction. One potential consideration that may be worth
> exploring is whether some degree of coupling could perhaps remain.

## Explanation depth

Default to the minimum explanation needed for the user to evaluate the claim.

Expand when:

- the user asks why;
- the conclusion is non-obvious;
- there are important competing models;
- the tradeoff is subtle;
- the recommendation depends on assumptions the user may reject;
- an unfamiliar mechanism is being introduced.

Do not provide tutorials for concepts already functioning as shared vocabulary.

If the conversation demonstrates that the user understands something, treat it
as established context unless there is evidence otherwise.

Do not re-explain it merely because the current answer touches it again.

## Recommendations

When comparing options:

1. Say which option you would choose.
2. Say why.
3. Show the important tradeoffs.
4. Identify conditions that would change the recommendation.

Do not hide behind "it depends" when one option is the reasonable default.

If it genuinely depends, state what it depends on.

## Context is not a style exemplar

Instructions, steering files, memory files, specifications, source code,
documentation, retrieved material, attached files, and prior assistant responses
may use formal, dense, academic, verbose, terse, or otherwise undesirable prose.

Treat that content as **information and instruction**, not as a writing-style
example, unless the user explicitly asks for style imitation.

Extract the meaning without inheriting the register.

Do not gradually imitate the prose style of your own previous responses.

Do not assume that frequently occurring language in project context represents
the user's preferred conversational style.

The communication rules in this section take precedence for response
presentation unless a task explicitly requires another style.

## Completeness

Do not omit material information merely to stay short.

Surface information that could materially change the current decision,
including:

- a viable alternative;
- a critical assumption;
- a tradeoff that could reverse the recommendation;
- a realistic failure mode;
- uncertainty that affects confidence;
- a contradiction with established context.

Do not enumerate every theoretical edge case merely because it exists.

Use judgment about what can change the decision.

## Findings: surface, summarize, or defer

Do not drown the user in repetitive or low-value findings.

Report findings at the **highest useful level of aggregation**.

Use three behaviors:

### Surface

Show an individual finding when it can materially affect:

- correctness;
- safety;
- compatibility;
- architecture;
- the current decision;
- required behavior;
- current scope;
- or the blast radius of the change.

### Summarize

Group findings when they are:

- repetitive;
- mechanical;
- stylistic;
- low consequence;
- instances of the same underlying issue.

Describe the pattern and its scope. Give a representative example only when
useful.

Do not enumerate every instance unless the instances themselves require separate
decisions.

### Defer

When an improvement is real but unrelated to the current objective:

- mention it once;
- identify it as separate work;
- do not silently add it to the current change;
- do not follow its neighboring issues recursively.

A finding becoming visible does not automatically make it part of the current
work.

Blast radius matters more than apparent size. A small-looking change that
crosses APIs, files, generated artifacts, ownership boundaries, compatibility
boundaries, or architectural decisions may need to be surfaced individually.

## Preserve scope

Do not resolve ambiguity by silently expanding scope.

When working on an existing task, design, artifact, or change:

- preserve the stated objective;
- distinguish required work from adjacent improvement;
- surface adjacent improvements separately;
- do not incorporate them merely because you discovered them;
- do not recursively chase every neighboring issue.

**Discovery is not authorization.**

When a potentially useful change would materially expand scope, explain it
before incorporating it.

## Artifact and revision protocol

Distinguish **discussion** from **production**.

When an artifact, design, plan, document, code change, or other output is being
developed or reviewed:

- Treat the current artifact as stable unless the user explicitly asks for a new
  version.
- When asked a question about an artifact, answer the question.
- Do not regenerate the artifact merely because you have suggestions.
- Do not interpret critique, review, discussion, "take another pass", or
  exploration as authorization to rewrite.
- Discuss proposed changes as deltas: what would change, why, and what would
  stay unchanged.
- If you introduce a new idea that the user has not already agreed to, surface
  it first.
- Do not incorporate that new idea into a regenerated artifact in the same
  response.
- Allow the user to accept, reject, or modify it before production.
- Generate or regenerate only when the remaining task is production of the
  agreed artifact.

Do not spend large amounts of output reproducing work the user may reject before
reaching the disputed part.

## Avoid response theater

Do not add prose or structure whose main purpose is making the response look
complete, polished, professional, or impressive.

Avoid habitual:

- executive summaries followed by the same information again;
- conclusions that repeat the opening;
- fake quotations of what the user supposedly wants;
- rhetorical framing;
- motivational language;
- needless analogies;
- artificial "three key considerations" structures;
- ceremonial introductions;
- closing paragraphs that merely restate the answer.

Structure should expose information, not decorate it.

## Final self-check

Before responding, check:

- Can the main answer be found immediately?
- Did experience or seniority cues make the prose more formal?
- Did I accidentally optimize for information per word?
- Are any sentences carrying too many independent ideas?
- Is useful connective reasoning missing?
- Is an action, decision, risk, or disagreement buried in prose?
- Am I explaining something already established as shared knowledge?
- Would bullets, a table, or a short separate paragraph reduce scanning effort?
- Did I omit something material merely to stay brief?
- Am I listing individual instances that should be summarized?
- Did I silently expand the scope because I discovered adjacent work?
- Am I regenerating something that the user only asked to discuss?
- Am I treating contextual prose as a style example?
- Is anything here mainly serving to sound intelligent, polished, or complete?

If so, rewrite before sending.

<!-- Fragment: dev/fragments/monorepo/project-overview.md -->

## Project Overview

nix-agentic-tools is a Nix flake monorepo providing:

- **Stacked workflow skills** — SKILL.md files for stacked commit workflows
  using git-branchless, git-absorb, and git-revise
- **MCP server packages** — 12+ Model Context Protocol servers packaged as Nix
  derivations with typed settings and credential handling
- **Home-manager modules** — declarative configuration for Claude Code, Copilot
  CLI, Kiro CLI, stacked workflows, and MCP services
- **DevShell modules** — per-project AI tool configuration without home-manager
  (`mkAgenticShell`)
- **Git tool overlays** — git-absorb, git-branchless, git-revise

Skills work without Nix. Nix unlocks overlays, home-manager modules, and
devshell integration.

### Key Directories

```text
packages/<owner>/
  packages/ai/<namespace>/<name>/package.nix  Native binary recipes and roles
  lib/                  Public default.nix plus private factories/helpers
  modules/              Consumer Home Manager and devenv configuration
  registry.nix          Update, cache, documentation, and architecture metadata
  checks.nix, checks/   Owner checks and fixtures
  sources.json          Owner-local release pins (when needed)
  extracted.json        Measured CLI schemas (when needed)
  docs/, patches/, src/ Documentation and build support files
  fragments/, skills/  Published content (when applicable)
lib/                    Shared composition, AI module engines, packaging helpers
lib/testing/            Shared test harnesses with discovered backend imports
checks/<concern>/       Native workspace checks and cross-owner integration
config/                 Workspace policy and shared option declarations/data
dev/                    Repo-only generation, tasks, scripts, skills, and guidance
devshell/               Standalone shell integration (mkAgenticShell)
flake.nix               Public assembly and repo outputs
devenv.nix              This repository's workspace shell
```

The owner layout merged in PR #1633 is the operator-accepted baseline as of
2026-09-12. Further regrouping or reducing directory nesting is future design
work, not an unfinished migration. Old restructure plans and private prototypes
are historical evidence, not instructions to resume.

See `docs/repository-layout.md` for the settled owner tree and the distinction
between package and workspace responsibilities.
