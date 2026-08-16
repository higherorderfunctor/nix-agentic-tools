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
  - Match: `checks/copilot-wrapper-argv.nix`, `overlays/chatgpt-codex.nix`,
    `overlays/claude-code.nix`, `overlays/copilot-cli.nix`,
    `overlays/kimchi.nix`, `overlays/kiro-cli.nix`, `overlays/kiro-gateway.nix`,
    `packages/chatgpt-codex/**`, `packages/copilot-cli/**`,
    `packages/kiro-cli/**`
  - Read:
    [`dev/fragments/ai-clis/copilot-config-delivery.md`](dev/fragments/ai-clis/copilot-config-delivery.md),
    [`dev/fragments/ai-clis/packaging-guide.md`](dev/fragments/ai-clis/packaging-guide.md)

- **`ai-module`**
  - Match: `checks/module-eval.nix`, `lib/ai/agent.nix`, `lib/ai/ai-common.nix`,
    `lib/ai/app/**`, `lib/ai/default.nix`, `lib/ai/hooks.nix`,
    `lib/ai/mkSkillPackageModule.nix`, `lib/ai/runtimes.nix`,
    `lib/ai/sharedOptions.nix`, `packages/*/lib/mk*.nix`,
    `packages/chatgpt-codex/modules/**`, `packages/claude-code/modules/**`,
    `packages/copilot-cli/modules/**`, `packages/kiro-cli/modules/**`
  - Read:
    [`dev/fragments/ai-module/ai-module-fanout.md`](dev/fragments/ai-module/ai-module-fanout.md),
    [`dev/fragments/ai-module/collision-semantics.md`](dev/fragments/ai-module/collision-semantics.md),
    [`dev/fragments/ai-module/dir-helpers.md`](dev/fragments/ai-module/dir-helpers.md),
    [`dev/fragments/ai-module/layered-fanout.md`](dev/fragments/ai-module/layered-fanout.md),
    [`dev/fragments/ai-module/shell-option.md`](dev/fragments/ai-module/shell-option.md)

- **`ai-skills`**
  - Match: `lib/ai/hm-helpers.nix`, `packages/chatgpt-codex/modules/**`,
    `packages/claude-code/modules/**`, `packages/copilot-cli/modules/**`,
    `packages/kiro-cli/modules/**`
  - Read:
    [`dev/fragments/ai-skills/skills-fanout-pattern.md`](dev/fragments/ai-skills/skills-fanout-pattern.md)

- **`claude-code`**
  - Match: `overlays/claude-code.nix`, `packages/claude-code/**`
  - Read:
    [`packages/claude-code/docs/claude-code-wrapper.md`](packages/claude-code/docs/claude-code-wrapper.md),
    [`packages/claude-code/docs/heron-brook-clamp.md`](packages/claude-code/docs/heron-brook-clamp.md)

- **`devenv`**
  - Match: `.github/workflows/devenv-test.yml`, `devenv.nix`,
    `lib/ai/hm-helpers.nix`, `packages/*/modules/devenv/**`
  - Read:
    [`dev/fragments/devenv/ci-lean-closure.md`](dev/fragments/devenv/ci-lean-closure.md),
    [`dev/fragments/devenv/files-internals.md`](dev/fragments/devenv/files-internals.md)

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
    `overlays/*.nix`, `overlays/**/*.nix`
  - Read:
    [`dev/fragments/overlays/ifd-patterns.md`](dev/fragments/overlays/ifd-patterns.md)

- **`kimchi`**
  - Match: `packages/kimchi/**`
  - Read:
    [`packages/kimchi/docs/kimchi-factory.md`](packages/kimchi/docs/kimchi-factory.md)

- **`kiro-cli`**
  - Match: `overlays/kiro-memory-distiller.nix`,
    `overlays/kiro-memory-distiller/**`,
    `overlays/mcp-servers/openmemory-mem/**`, `packages/kiro-cli/**`
  - Read:
    [`packages/kiro-cli/docs/kiro-auto-memory.md`](packages/kiro-cli/docs/kiro-auto-memory.md)

- **`kiro-wrapper`**
  - Match: `checks/kiro-wrapper-argv.nix`, `lib/idempotentFlags.nix`,
    `overlays/kiro-cli.nix`, `packages/kiro-cli/lib/**`
  - Read:
    [`packages/kiro-cli/docs/fhs-sandbox.md`](packages/kiro-cli/docs/fhs-sandbox.md),
    [`packages/kiro-cli/docs/launcher-argv.md`](packages/kiro-cli/docs/launcher-argv.md)

- **`markdown-formatting`**
  - Match: `**/*.md`, `checks/doubled-words-fixtures.nix`,
    `checks/doubled-words-fixtures.py`, `checks/doubled-words.nix`,
    `checks/doubled-words.py`, `checks/fixtures/doubled-words/**`,
    `checks/markdown-scan.nix`, `checks/markdown-scanners.nix`,
    `checks/split-code-spans.nix`, `checks/split-code-spans.py`, `treefmt.nix`
  - Read:
    [`dev/fragments/markdown-formatting/markdown-formatting.md`](dev/fragments/markdown-formatting/markdown-formatting.md)

- **`mcp-secrets`**
  - Match: `checks/factory-eval.nix`, `checks/module-eval.nix`,
    `lib/ai/app/mkBackendTransform.nix`, `lib/ai/mcpProxy.nix`,
    `lib/ai/mcpServer/**`, `lib/ai/sharedOptions.nix`, `lib/mcp.nix`,
    `packages/kiro-cli/lib/mcpSecrets.nix`, `packages/kiro-cli/lib/mkKiro.nix`,
    `packages/kiro-cli/lib/wrapPackage.nix`
  - Read:
    [`dev/fragments/mcp-secrets/mcp-secrets.md`](dev/fragments/mcp-secrets/mcp-secrets.md)

- **`mcp-servers`**
  - Match: `overlays/mcp-servers/**`
  - Read:
    [`dev/fragments/mcp-servers/js-server-packaging.md`](dev/fragments/mcp-servers/js-server-packaging.md),
    [`dev/fragments/mcp-servers/overlay-guide.md`](dev/fragments/mcp-servers/overlay-guide.md)

- **`mcp-services`**
  - Match: `checks/factory-eval.nix`, `checks/module-eval.nix`,
    `lib/ai/mcpServer/mkServiceModule.nix`,
    `lib/ai/mcpServer/serviceSchema.nix`, `packages/*/modules/mcp-server.nix`,
    `packages/mcp-services/modules/homeManager/default.nix`
  - Read:
    [`dev/fragments/mcp-services/service-host-contract.md`](dev/fragments/mcp-services/service-host-contract.md)

- **`nix-standards`**
  - Match: `**/*.nix`
  - Read:
    [`dev/fragments/nix-standards/nix-standards.md`](dev/fragments/nix-standards/nix-standards.md)

- **`overlays`**
  - Match: `overlays/*.nix`, `overlays/**/*.nix`
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
  - Match: `.github/workflows/update.yml`, `config/fragment-categories.nix`,
    `config/generate-update-ninja.nix`, `config/update-targets.nix`,
    `dev/generate.nix`, `dev/scripts/update-*.sh`, `dev/tasks/generate.nix`,
    `lib/ai/transformers/**`, `lib/fragments-registry.nix`, `lib/fragments.nix`,
    `lib/update.nix`, `overlays/**/*.update.nix`
  - Read:
    [`dev/fragments/pipeline/ci-update-workflow.md`](dev/fragments/pipeline/ci-update-workflow.md),
    [`dev/fragments/pipeline/fragment-pipeline.md`](dev/fragments/pipeline/fragment-pipeline.md),
    [`dev/fragments/pipeline/generation-architecture.md`](dev/fragments/pipeline/generation-architecture.md),
    [`dev/fragments/pipeline/update-pipeline.md`](dev/fragments/pipeline/update-pipeline.md)

- **`stacked-workflows`**
  - Match: `packages/stacked-workflows/**`
  - Read:
    [`dev/fragments/stacked-workflows/development.md`](dev/fragments/stacked-workflows/development.md)

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
out shared surfaces to enabled ecosystems (Claude, Codex, Copilot, Kiro) with
ecosystem-specific translation. A surface without a lossless native mapping is
an explicit exclusion, not a silent no-op.

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

<!-- Fragment: dev/fragments/monorepo/architecture-fragments.md -->

## Architecture Fragments

> **Last verified:** 2026-08-02 (commit pending — AGENTS.md now carries a
> compact registry-generated routing index so Codex and other flat consumers can
> find applicable source fragments without flattening every fragment body).
> Prior: 2026-07-27 (the worked registration example is now explicitly
> fictional, so it can no longer drift out of sync with a real category's
> `scopes`; it previously named `ai-clis` and `claude-code` and had gone stale
> against both. Prior 2026-07-27, that example stopped teaching
> `packages/ai-clis/**`, a directory that does not exist; prior 2026-07-24, the
> `packagePaths` + `devFragmentNames` registries dissolved into
> `config.fragments.categories`).

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
`config.fragments.categories.<category>.scopes` (declared in
`config/fragment-categories.nix`) and are independent of where the markdown
source lives on disk.

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

New fragments are registered in `config/fragment-categories.nix` under
`config.fragments.categories`. The attribute key is the category (which becomes
the output filename for scoped Claude rules, Copilot instructions, and Kiro
steering). Each category is one record with two fields: `scopes` (the path globs
it loads for) and `sources` (the markdown fragments composed into it). A
`sources` entry is either a bare string (legacy dev/fragments/ path) or an
attrset with an explicit location:

```nix
# ILLUSTRATIVE ONLY — neither category below exists. Real rows
# live in config/fragment-categories.nix; read that file for them.
config.fragments.categories = {
  example-dev-sourced = {
    scopes = ["overlays/example.nix" "packages/example/**"];
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
`lib/fragments-registry.nix`; `dev/generate.nix` merges the two with
`lib.evalModules` and reads the result. The transforms handle per-ecosystem
emission — do not hand-format frontmatter.

After adding or editing fragments, run
`devenv tasks run --mode before generate:all` to regenerate instruction and
repo-document projections. `--mode before` is load-bearing: without it devenv
runs an aggregate without its dependency leaves.

<!-- Fragment: dev/fragments/monorepo/build-commands.md -->

## Build & Validation Commands

```bash
nix flake show                # List all outputs
nix flake check               # The CI gate: formatting, structural checks, module eval
                              # (does NOT build packages, and does NOT run the
                              # prek linters — those are local-only)
nix build .#<package>         # Build a specific package
devenv shell                  # Enter devShell with all tools
treefmt                       # Format all files (formats only — lints nothing)

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
- config.update.targets entries (config/update-targets.nix)
- CI workflow matrices
- Home-manager module registrations
- Overlay export lists
- Structural check expectations

The structural check (`nix flake check`) validates cross-references. The
pre-commit hook runs a fast subset. If something is removed, grep for it across
the repo before committing.

<!-- Fragment: dev/fragments/monorepo/git-workflow.md -->

## Git Workflow — trunk-based, worktree-per-branch

> **Last verified:** 2026-08-15 (commit pending — adds the adversarial
> subagent-review protocol that SUBSTITUTES for the Copilot loop while its quota
> is exhausted, roughly two weeks from 2026-08-15. Written because an agent
> cannot review its own output, and because the operator had been having to ask
> for an independent reviewer by hand each time. Includes the refuter+defender
> pairing and the never-self-adjudicate rule, both of which exist because
> refute-by-default on your own work is a second discard filter rather than a
> check). Prior: 2026-08-14 (commit pending — TWO corrections. (1) The
> required-status-check list said FOUR; there are SIX, both `kiro-patched`
> contexts having been promoted 2026-08-13 with PR #895. This file was wrong in
> two places, `ci-update-workflow.md` was wrong in two more, and
> `.github/workflows/update.yml` was wrong a third way — "five", including the
> demoted `devenv-test` — so read the ruleset back rather than trusting any
> prose count, this one included. (2) Copilot review can now fail in a way that
> READS AS CLEAN: when the requesting account is out of quota it still submits a
> review object on the head SHA with `state: COMMENTED`, an empty
> `requested_reviewers`, and ZERO threads. Every mechanical signal the loop
> gates on says "reviewed, nothing found". The only tell is the BODY — "Copilot
> was unable to review this pull request because the user who requested the
> review has reached their quota limit." A zero-finding round is clean ONLY if
> the body says the review ran; re-requesting cannot help, since the quota
> belongs to the requesting user). Prior: 2026-08-05 (commit pending — the
> Copilot TRIGGER MODEL was wrong and is corrected: the automatic review fires
> once, on the PR becoming ready for review, and a push NEVER triggers one.
> "Becomes ready" covers a PR opened non-draft as well as a draft flipped later
> — measured on PR #801, which was opened non-draft and got a queued reviewer
> run within seconds, so the narrower "draft → ready transition" spelling is
> deliberately avoided as it reads as excluding never-drafted PRs. The old "only
> ONCE in 5 pushes" datum was not a flaky trigger — it was #644's ready
> transition landing on the same push, with #640's four misses being correct
> behavior — so the advice to treat re-requesting as the expected next step is
> dropped, along with any reason to wait on a run that is never coming. Every
> review after the first is a paid manual request, which is now stated where the
> round cap is. Also adds agent memory to the shared-across-worktrees list:
> concurrent sessions share the memory directory, neither sees the other's
> write, and a duplicate under a different name is invisible to the wikilink
> graph). Prior: 2026-08-05 (commit pending — "change" now EXPLICITLY includes
> untracked drafts and working docs: authoring any repo-destined file in the
> primary checkout is a violation, with a pre-flight `git rev-parse` check added
> to the worktree section. Driven by a reference doc drafted in the primary
> checkout whose lint findings failed the shared stop/commit hooks in every
> parallel session sharing that cwd). Prior: 2026-08-05 (commit pending —
> `devenv-test` is NO LONGER a required check; the ruleset now lists FOUR,
> verified by reading it back rather than by trusting this file. It was made
> required on 2026-08-03 and demoted two days later as a merge-blocking
> liability, risk accepted. The entry below that announced the promotion is kept
> so the reversal is legible rather than looking like drift). Prior: 2026-08-05
> (commit pending — two corrections, both from operating the loop on PR #766 and
> both making it silently unreliable when unknown. The suppressed-block heading
> is NOT stable, so the documented `sed -n '/low confidence/,$p'` matched
> nothing against a `Suppressed comments (1)` block and nearly reported a real
> finding as a clean round; the command now prints the whole body. And
> `gh api …/requested_reviewers` silently no-ops for Copilot — 200 with an empty
> list, no check run, with nothing in flight — so re-requests go through the
> github-mcp tool). Prior: 2026-08-04 (commit pending — records that
> `requested_reviewers` is the INTERMEDIATE state and the request is CONSUMED by
> the review it triggers, so an empty list plus no reviewer check run on the
> head SHA means a re-request is genuinely needed rather than one being pending;
> observed 2026-08-01 on the retired probe-fixtures branch and re-validated on
> PR #749's round-2 re-request). Prior: 2026-08-03 (commit pending — adds the
> always-reporting `devenv-test` context to the required checks). Prior:
> 2026-08-03 (commit pending — makes post-merge removal of the feature worktree
> and local branch an explicit agent-owned completion condition). Prior:
> 2026-07-31 (commit pending — the bootstrap step's "or any devenv task" was
> WRONG and is removed: `devenv tasks run` does not materialize
> `.pre-commit-config.yaml`, measured in two fresh worktrees where the task
> succeeded and the next commit was still rejected. Also records that a push
> auto-triggered a Copilot review only ONCE in 5 pushes — 0/4 on PR #640, 1/1 on
> the first push of #644 — so checking the run is mandatory and re-requesting is
> the expected next step rather than a rare fallback). Prior: 2026-07-31 (commit
> e06e7601 — the Copilot review loop is the agent's to START, unprompted, the
> moment the PR is open and non-draft; only continuing past the 5-round cap
> needs the operator's say-so). Prior: 2026-07-30 (commit pending — records that
> a re-request issued while a review is still in flight is silently dropped, so
> the check run, not the API response, is the confirmation). Prior: 2026-07-30
> (commit d42d805a) — records that the reviews and comments endpoints attribute
> Copilot's output to DIFFERENT logins, so the documented
> `copilot-pull-request-reviewer[bot]` filter returns zero on
> `/pulls/N/comments` and reads as a clean review while gating threads are open;
> measured on PR #614. Prior: 2026-07-29 — the ruleset now sets
> `required_review_thread_resolution: true`, so an unresolved review thread
> blocks merge including on auto-merging `update/*` PRs, and the claim that
> Copilot "never gates its merge" is retired; adds the rule that Copilot's
> SUPPRESSED findings must be read on every review, since they create no thread;
> gates re-review polling on `commit_id` rather than a timestamp, and caps the
> fix-and-re-review loop at 5 rounds). Prior: 2026-07-24 — the bot's `update/*`
> PRs now arm GitHub-native auto-merge and land themselves, the manual
> `pr:merge-updates` task and `merge-update-prs` skill are deleted, the update
> sweep runs 4x/day, and squash-only is re-attributed to the repository settings
> rather than the ruleset. If you change the branch-protection ruleset, the
> repository merge settings, the worktree convention, the bootstrap step, the
> local commit guard, the auto-merge arming, or the PR flow and this fragment
> isn't updated in the same commit, stop and fix it.

`main` is the trunk. Its branch-protection ruleset requires a pull request, no
force-push, no deletion, and six required status checks —
`build (x86_64-linux, ubuntu-latest)`, `build (aarch64-darwin, macos-latest)`,
`kiro-patched (x86_64-linux, ubuntu-latest)`,
`kiro-patched (aarch64-darwin, macos-latest)`, `test`, and `gitleaks`. Both
`kiro-patched` contexts were promoted 2026-08-13 with PR #895; this file said
"four" until 2026-08-14. It requires **zero approving reviews** but it DOES
require **every review thread to be resolved**
(`required_review_thread_resolution`, enabled 2026-07-29).

`devenv-test` still RUNS on every PR and is still worth reading, but it is no
longer required and does not block a merge. It was promoted to a required check
on 2026-08-03 and demoted on 2026-08-05, having aged badly enough in two days to
be a merge-blocking liability rather than a signal; the resulting risk is
accepted deliberately. Do not "restore" it to the list to make this fragment
match the older prose — read the ruleset:

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

### When Copilot is unavailable, YOU are not the reviewer — a subagent is

> **Standing as of 2026-08-15.** Copilot's quota is exhausted for roughly two
> weeks, so the automatic review below produces nothing. **This section is the
> substitute, and it is not optional while that holds.** It is also the right
> shape whenever the automatic review is absent for any other reason: a draft PR
> that never flipped, a re-request that no-ops, a repo without the rule.

**An agent cannot review its own output.** Reading back your own diff produces
agreement, because the same reasoning that wrote the code evaluates it. The
substitute is not "read it more carefully" — it is **dispatching an independent
reviewer that never saw you write it.**

So when there is no automatic review, run this before marking a PR ready:

1. **Finders, in a subagent, one per lens.** Give each an explicit lens (factual
   accuracy / reasoning and scope / document or code integrity / security) and
   the standing instruction that **the PR body is an argument, not evidence**,
   and that its confident tone is not a signal. Tell them plainly that the
   author is orchestrating the review and cannot be deferred to.
2. **Contest every finding TWICE — refute AND defend.** A refuter alone is a
   second discard filter stacked on an author who was already grading their own
   work, so the dismissal rate goes up for reasons that have nothing to do with
   the code. Pair every refuter with a DEFENDER whose job is to argue the
   finding is real, and who may not concede merely because a fix is awkward.
3. **Never self-adjudicate a split.** Where refuter and defender disagree,
   SURFACE the disagreement to the operator with both arguments. Resolving it
   yourself reintroduces exactly the bias the whole structure exists to remove.
4. **Fix what survives, and say what did not.** Report dismissed findings by
   title and count — a review that reports only confirmed findings is
   indistinguishable from one that found nothing.

#### Sizing — STANDARD by default, thorough only when asked

**The cost blows up in the CONTEST phase, not the finders.** Finders are bounded
by however many lenses you pick. Findings are NOT bounded, and a refute+defend
pair per finding is `2 × findings`. Measured on a 94-line docs PR: 3 lenses
produced ~28 findings, so the run cost **59 agents** — the finders were 3 of
them. A verbose finder triples the bill. Bound the contest phase first, and only
then think about lenses.

**STANDARD — the default, target 5-9 agents total:**

1. **2-3 finders, on a CHEAPER MODEL (Sonnet).** Finder work is mechanical: open
   the cited line, check whether it says what the PR claims. Reserve the strong
   model for contest and synthesis, where judgement actually decides something.
2. **Deduplicate before contesting.** Several lenses over one diff overlap
   heavily, and contesting the same defect three times is pure waste.
3. **Triage by severity.** Contest BLOCKER and SHOULD-FIX. NITs are REPORTED,
   not litigated.
4. **Batch the contest** — one agent takes ~5 findings, not one agent each.
5. **Two-agent refute/defend for BLOCKERs only.** Below that, a single agent
   argues both sides and returns a verdict plus the strongest counter-argument.
   That is weaker — one context means correlated errors — which is precisely why
   the genuine blockers keep the two-agent treatment.

**THOROUGH — only when the operator asks.** Per-finding refute/defend on
everything, more lenses, strong model throughout. Still deduplicate, and still
cap the total: an uncapped fan-out has no terminus.

**Scale lenses with BLAST RADIUS, not diff size.** A thirty-line change to a
shared `lib/` file earns more than a thousand-line docs PR; a fragment edit
warrants one or two.

**Do not ask which tier to use per PR.** Standard is the default and the
operator says "thorough" when they want it — asking is friction paid on every
review.

**Do not skip this because the change is "just docs".** The failure this repo
actually experienced was a design document whose PR sequence sent a later
session to build the wrong thing for a day. Prose that directs future work has a
blast radius; treat it like code.

### Copilot review: ALWAYS read the suppressed-comments block

**This loop is yours to start, unprompted, as soon as the PR is non-draft — it
is part of landing the change, not a follow-up the operator has to request.** A
PR handed back with its review unread is unfinished work. Only continuing past
the 5-round cap below needs explicit approval.

Copilot records its findings in two places, and only one of them creates a
thread:

1. **Inline review comments** — these become resolvable threads, appear in
   `pull_request_read` with `method: get_review_comments`, and now gate merge.
2. **A `<details>` block inside the review BODY** — no thread, nothing to
   resolve, invisible to any thread query. **Its heading is NOT stable.** Two
   spellings have been observed on this repo:
   `Comments suppressed due to low confidence (N)`, and plain
   `Suppressed comments (N)` (PR #766 round 2, 2026-08-05). Do not anchor a read
   on either — see the command below.

**The two endpoints attribute Copilot to DIFFERENT logins, and mixing them up
reads as a clean review.** `/pulls/N/reviews` credits the review to
`copilot-pull-request-reviewer[bot]`; `/pulls/N/comments` credits the inline
comments to plain `Copilot`. Filtering the comments endpoint by the `[bot]`
login returns ZERO while gating threads are open — measured on PR #614, where
four unresolved threads were invisible and the body's "generated 4 comments"
line was the only tell. Since threads now block merge, that failure mode
presents as a PR that mysteriously will not land.

Prefer the GraphQL `reviewThreads` query over the REST comments endpoint: it
sidesteps the login discrepancy entirely and returns `isResolved` plus the
thread id you need for `resolveReviewThread` anyway.

```bash
gh api graphql -f query='
query {
  repository(owner:"OWNER", name:"REPO") {
    pullRequest(number:N) {
      reviewThreads(first:50) {
        nodes { id isResolved path comments(first:1){nodes{author{login} body}} }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved==false)'
```

**Reading only the threads is not reading the review.** Measured on PR #568
across seven review rounds: the suppressed bucket produced **7 findings, all
genuine**, including a functional bug (`api_protocol` hardcoded while the scheme
was stripped), a regex that could not match bracketed IPv6 hosts, and a doc that
would have had readers create a directory literally named `~`. The gating bucket
over the same period produced two, one of which was a diagnostics improvement
over already-correct behavior. On that sample the confidence signal was
inverted.

So whenever you check Copilot feedback — CLI, MCP, a monitor loop, anything —
fetch the review BODY too, not just the threads:

```bash
gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
  --jq '[.[] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
        | last | .body'
```

**Print the WHOLE body and read it. Do not pipe it through a heading grep.**
This command used to end in `sed -n '/low confidence/,$p'`, and that is exactly
how the bucket gets missed: on PR #766 round 2 the block was titled
`Suppressed comments (1)`, the `sed` matched nothing, and the round was about to
be reported clean in both buckets. The finding underneath was real — a security
positive control whose greps were basic regexes, so `.` matched any character. A
phrase grep that returns empty is indistinguishable from a genuinely clean
bucket, which makes this failure silent and self-confirming.

**"generated no new comments" does NOT mean there is nothing to read.** That is
the count of INLINE comments. The same review body carried a suppressed finding
alongside that line. Cross-check the two independently: the count line describes
bucket 1, the `<details>` block is bucket 2.

`--paginate` is load-bearing, not tidiness. The endpoint pages at 30, and a PR
that has been through a review loop reaches that easily — #568 took twenty.
Without it `last` returns the last review on the FIRST page, which is an OLD
one, and the answer looks exactly like a fresh clean review.

**Gate on `commit_id`, not on the timestamp.** The only condition that means
"this review saw my code" is the review's `commit_id` equalling the PR head:

```bash
gh api --paginate "repos/OWNER/REPO/pulls/N/reviews" \
  --jq '[.[] | select(.user.login=="copilot-pull-request-reviewer[bot]")]
        | last | .commit_id'
```

This was arrived at by getting it wrong three times in a row, each fix looking
sufficient until it wasn't:

1. reading `.[-1]` → returns a stale review, reported as new;
2. taking `submitted_at` as a baseline → better, but a review of an OLDER commit
   still advances the timestamp, so it reads as fresh;
3. requiring `commit_id == head` → correct.

A related tell, useful because it needs no baseline at all: **check whether a
check run named `copilot-pull-request-reviewer` exists on the head commit.** It
distinguishes "never ran on this commit" from "ran and found nothing" — which
otherwise look identical.

```bash
gh api --paginate "repos/OWNER/REPO/commits/<head-sha>/check-runs" \
  --jq '.check_runs[] | select(.name=="copilot-pull-request-reviewer") | .status'
```

Absent means no review ran on this commit; `in_progress` means wait; `completed`
means the review is there to read. Ask for the run BY NAME rather than counting
the checks: a total count is only correct until the CI matrix changes.

**The automatic review fires exactly once per PR, when the PR becomes ready for
review. Pushes never trigger it.** That is how the ruleset's
`Copilot review for default branch` rule is configured and always has been, so
after any push the head commit has no reviewer check run and never will acquire
one on its own. Absent is not a miss to wait out — it is the resting state.

**"Becomes ready" covers both paths, and the narrower phrasing is a trap.** A
draft flipped to ready fires it, and so does a PR **opened non-draft in the
first place**, which never has a draft → ready transition at all. Measured on PR
#801: `gh pr create` without `--draft` produced `requested_reviewers: [Copilot]`
and a `queued` reviewer check run within seconds. Writing this rule as "on the
draft → ready transition" reads as excluding never-drafted PRs — it is the right
mechanism stated too narrowly, and it would have you re-request a review you had
already been given.

This corrects a datum that read as flakiness. An earlier revision recorded "a
push auto-triggered a review only ONCE in 5 pushes" (0 for 4 on PR #640, 1 for 1
on the first push of PR #644) and concluded the trigger was unreliable. It is
not unreliable; it is not a push trigger at all. The single hit was PR #644's
draft → ready transition landing on the same push, and the four misses were the
rule behaving correctly. **Do not re-derive an auto-trigger rate from
observations like these** — the sampling looks like a flaky trigger and is
actually a deterministic one being read through the wrong event.

Two consequences, and the second is the expensive one:

- **Never poll or wait for a review after a push.** Nothing is coming. Read the
  run once to confirm which commit the existing review covers, then decide.
- **Every review after the first is a deliberate, paid manual request.** Spend
  it on a content change that is worth a fresh review, not on re-establishing a
  trigger. Batch fixes into one push and request once, rather than requesting
  per round.

Pair this with the `commit_id` gate below. The two compound: after a push the
previous commit's review stays readable and is indistinguishable from a fresh
clean one, so a stale review plus an absent run is the normal post-push state
and reads exactly like a PR that has been reviewed.

**A re-request issued while a review is still in flight is silently dropped.**
The API returns success, no new check run appears, and the call is
indistinguishable from one that worked. Measured on #614: a push followed
immediately by a re-request left the head commit with NO reviewer check run at
all, while the previous commit's review completed normally and then read as the
"latest" one.

So the request is not the confirmation — the check run is. After requesting,
verify the run exists on the head SHA before trusting it, and if a review is
already running for an older commit, let it land first. This composes with the
`commit_id` gate above: that gate tells you a review is stale, this tells you
why no fresh one is coming.

**Re-request through the GitHub MCP server's copilot-review request tool, NOT
`gh api …/requested_reviewers`.** The GitHub MCP server exposes a dedicated
"request a Copilot review" operation — `request_copilot_review` on the server
side, though the name your client shows is prefixed and varies by MCP client
config, so match on the trailing segment rather than the full identifier. That
REST endpoint silently no-ops for Copilot: it answers HTTP 200 with
`requested_reviewers: []` and never creates a check run. Measured on PR #766
(2026-08-05) with NO review in flight, so this is a SEPARATE failure from the
in-flight drop above — Copilot is simply not addressable as an ordinary reviewer
login there. Both spellings failed identically across ~40s of polling:

```bash
# both of these return 200 and do NOTHING
gh api --method POST "repos/OWNER/REPO/pulls/N/requested_reviewers" \
  -f "reviewers[]=Copilot"
echo '{"reviewers":["Copilot"]}' | gh api --method POST \
  "repos/OWNER/REPO/pulls/N/requested_reviewers" --input -
```

The MCP tool produced `requested_reviewers: [Copilot]` and a `queued` run on the
first try. Because BOTH failure modes present as "200 and nothing happened",
always confirm by polling for the run on the head SHA rather than trusting the
call's response.

**`requested_reviewers` is the INTERMEDIATE state, and the request is CONSUMED
by the review it triggers.** So an empty list there does not mean "no request
was made" — it is also what you see after a request has already been answered.
Read it together with the check run:

```bash
gh api "repos/OWNER/REPO/pulls/N" \
  --jq '[.requested_reviewers[].login]'
```

Empty **plus** no `copilot-pull-request-reviewer` check run on the head SHA
means a re-request is genuinely needed. Empty **plus** a completed run means the
review already happened and is there to read. A NON-empty list is the one state
where requesting again is pointless — a request is pending. Reading the list
alone inverts the first case into the third and leaves you waiting for a review
nobody asked for.

### Cap the fix-and-re-review loop at 5 rounds

Run at most **five** fix → push → re-request → verify rounds, then STOP and get
explicit approval before continuing. Exit earlier if a round returns clean in
BOTH buckets — that is the real terminus. The cap is the only place in this loop
where approval is required: you enter round one without asking, and you leave
round five without proceeding.

Five is a ceiling, not a target. Round one is free — it is the automatic review
the ready transition buys — and **every round after it spends a paid manual
request**, so the loop is not merely long when it runs hot, it is expensive.
Batch a round's fixes into one push and request once.

The failure mode this prevents is not a bad round, it is a good one repeating.
On PR #568 every round produced a genuine finding, so each was individually
defensible while the aggregate churned the PR through eight force-pushes. An
uncapped loop has no guaranteed terminus; the cap makes continuing an operator
decision rather than an emergent property.

At the cap, summarize what was found, what was fixed, and what is outstanding.

Suppressed findings have no thread to resolve, so reply on the PR itself saying
what you did with each. Resolve each gating thread as you fix it — they gate the
merge now, and a PAT-authenticated MCP client cannot resolve them, so use the
GraphQL `resolveReviewThread` mutation through `gh api`.

**Never commit directly to `main`.** Two backstops enforce this. A local
`reject-default-branch-commit` pre-commit hook (installed through devenv's
git-hooks framework) rejects any commit made while the default branch (`main`)
is the checked-out HEAD — caught at _commit_ time, in whichever worktree has
`main` checked out (normally the primary checkout, since git allows a branch in
only one worktree at a time); worktrees on other branches are unaffected, and
`--no-verify` bypasses it by design. Independently, the branch-protection
ruleset rejects the _push_. Still branch **before** you start — the guard is a
safety net, not the workflow.

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
covers new worktrees too, so `cd` alone enters the devenv shell and materializes
the gitignored `files.*` artifacts with no manual step — and it keeps work out
of `~/.cache`, which cache-cleaning tools treat as disposable.

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

2. Bootstrap the new worktree **once**, before its first commit:

   ```bash
   cd "$worktrees/<slug>" && devenv shell true
   ```

   `.pre-commit-config.yaml` is a devenv `files.*` artifact materialized on
   SHELL ENTRY, and `git worktree add` runs no devenv — until you do this the
   shared prek hooks have no config to validate against and the commit is
   rejected. With direnv allowed for the parent directory the `cd` is enough on
   its own; that is what the sibling location buys.

   **It has to be a shell entry — `devenv tasks run` does NOT materialize it.**
   Measured 2026-07-31 in two fresh worktrees: a full
   `devenv tasks run --mode before generate:all` completed successfully in each,
   and the very next commit was still rejected for a missing config. Running a
   task is not the shell-entry path, whatever else it does.

   That combination is worth naming because it is the natural way to get this
   wrong. Bootstrapping via a task is exactly what you reach for when the
   worktree needs generated output anyway, the task succeeds, and the failure
   surfaces later attributed to the commit rather than to the bootstrap. This
   step previously read `devenv shell   # or any devenv task`; the comment was
   wrong and is now removed.

   `devenv shell true` is the cheapest spelling — it enters, runs `true`, and
   exits, instead of dropping you into an interactive shell you then have to
   leave.

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
   STARTING the loop needs no permission; only CONTINUING past the 5-round cap
   does.

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

The prek **config** is the one thing made per-worktree: the
`hooks:isolate-config` devenv task rewrites the installed hooks so they resolve
`.pre-commit-config.yaml` from the _committing_ worktree's toplevel at hook-run
time. That is what stops a shell entry in one worktree from changing what
another worktree validates against.

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

### Rebasing: back up with a TAG, not a branch

`git rebase --update-refs` (and git-branchless) moves any **branch** that points
into the rebased range — including a backup branch created moments earlier,
silently defeating it. Tags are not moved:

```bash
git tag backup-<slug>-pre-rebase <tip>   # durable across the rebase
```

Lockfile conflicts (`flake.lock`, `devenv.lock`) during a rebase are
**regenerated, never hand-merged**: take the base's copy, then re-run
`nix flake lock` (and let devenv reconcile `devenv.lock`) so the result matches
the merged `flake.nix` / `devenv.yaml`.

<!-- Fragment: dev/fragments/monorepo/linting.md -->

## Linting

`nix flake check` is the CI gate. The prek pre-commit hooks are a fast local
subset: they are `lib.optionalAttrs (!isCI)` in `devenv.nix`, so they do NOT run
in CI and are not part of `nix flake check`. They can also be skipped with
`--no-verify`.

Formatters and linters are separate here — treefmt runs formatters only and
lints nothing.

**Formatters — treefmt, all write in place:**

- **JS/TS/JSX/JSON/CSS:** biome
- **Markdown/YAML and friends:** prettier (`proseWrap = "always"`)
- **Nix:** alejandra
- **Shell:** shfmt (`*.sh`, `*.bash` — extension globs only, so it never sees an
  extensionless script, shell embedded in a `.nix` string, or a heredoc body)
- **TOML:** taplo

**Linters — prek hooks, not treefmt, not `nix flake check`:**

- **Nix:** deadnix (dead code), statix (anti-patterns)
- **Shell:** `shellcheck -x`, on files prek tags `shell` — which needs a `.sh` /
  `.bash` extension OR the executable bit. Shell embedded in `.nix` strings is
  linted by nothing except `writeShellApplication`'s own build-time checkPhase.
- **Spelling:** cspell

**Commit gates — prek hooks that block the commit:**

- convco (commit message shape)
- gitleaks (staged secrets)
- reject-default-branch-commit
- treefmt `--fail-on-change`, plus treefmt-restage to re-add reformatted files

**Available in the devShell, wired to no gate:** agnix (agent config linting) —
run it by hand or via the agnix MCP server.

There is no shellharden in this repo, and no linter reads shell embedded in
`.nix` strings beyond `writeShellApplication`'s own checkPhase. See the Bash
coding standard for which sites that leaves unchecked.

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

```
packages/
  <pkg>/              Per-package facet barrel: modules/{homeManager,devenv},
                      lib, docs, and fragments for that package
  stacked-workflows/  Content package: skills, references, skill-routing fragment
  coding-standards/   Content package: reusable coding standard fragments
overlays/     Binary package overlays (all groups under pkgs.ai.*) plus per-package
              -sources.json / -extracted.json sidecars
  dev-tools/  Agent-adjacent development utilities (pkgs.ai.devTools.*)
  generic/    Temporary split-ready bucket for supporting packages that have
              not yet earned a more specific category
  git-tools/  Git workflow utilities (pkgs.ai.gitTools.*)
  lsp-servers/  LSP server packages and role projections
  mcp-servers/  MCP server packages and role projections
lib/          Shared library: the ai factory (lib/ai/*), fragments, MCP helpers,
              credentials, devshell
devshell/     Standalone devshell modules (mkAgenticShell)
config/       update-targets.nix (config.update.targets) and shared configuration data
dev/
  fragments/    Dev-only instruction fragments (not exported)
  references/   Dev-only reference docs (not exported)
  skills/       Dev-only skills (index-repo-docs, repo-review)
  generate.nix  Fragment to per-ecosystem instruction generator
checks/       Flake checks
```
