# Contributing to nix-agentic-tools

<!-- TODO: refine with maintainer input -->

## Development Setup

All tools are provided by the devenv shell. No global installs required.

```bash
devenv shell          # enter dev shell with all tools
```

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

## Tests

```bash
devenv test           # run all devenv checks
nix flake check       # linters + evaluation (does NOT build packages)
```

## Generation Architecture

> **Last verified:** 2026-09-25 — the generator produces content only;
> `dev/ai.nix` hands it to `ai.*`, which writes every agent instruction file.
>
> **Settled — do not relitigate.** Rendering and writing the instruction files
> in the generator, beside `ai.*`, is what this replaced. The generator owned
> AGENTS.md, so `ai.codex.files."AGENTS.md".content.enable = false` switched
> `ai.*` off for it, and every `ai.*` rule for Codex (Semble's CLI rule among
> them) was dropped with no diagnostic. One writer per file, and that writer is
> `ai.*`. Full lineage:
> `git show f77d34ac:dev/fragments/pipeline/generation-architecture.md`.

Two kinds of generated content, two owners:

- **Agent instructions** — `dev/generate.nix` returns `context` (the
  always-loaded orientation) and `rules` (one path-scoped rule per registry
  category: its composed text, its scope globs as `matcher`, its source
  documents as `references`). `dev/ai.nix` sets them as `ai.context` and
  `ai.rules` in this repository's own devenv, and `ai.*` renders and writes each
  runtime's files exactly as it would for any consumer: AGENTS.md (Codex, Kiro,
  Kimchi, with a path-scoped index of the rules), `.claude/CLAUDE.md` and
  `.claude/rules/`, `.github/copilot-instructions.md` and
  `.github/instructions/`, and `.kiro/steering/`. The committed ones (AGENTS.md
  and `.github/`) are read-only copies.
- **Human documents** — README.md and CONTRIBUTING.md are not agent steering.
  `dev/repo-docs.nix` renders them from `dev/generate.nix` and formats them in
  the sandbox; `generate:repo:*` copies them out.

`ai.*` genuinely cannot express the human documents: they are not context or
rules of any runtime. Everything instruction-shaped goes through `ai.*`.

### Source Layout

- `lib/facets/registry.nix` — native metadata assembly shared by flake and
  document generation. Workspace categories come from
  `config/fragment-categories.nix`; package categories and descriptions come
  from owner `registry.nix` files. Options live in `lib/fragments-registry.nix`
  and `lib/documentation.nix`.
- `dev/fragments/` — dev-only instruction fragments.
- `dev/generate.nix` — fragment composition into content, plus the two human
  documents.
- `dev/ai.nix` — this repository's `ai.*` configuration, imported by
  `devenv.nix` and evaluated by the drift check.
- `packages/coding-standards/fragments/` — published coding standards, part of
  the orientation.
- `packages/delegate-sizing/` and `packages/stacked-workflows/router.nix` — the
  always-on routing rules, delivered as `ai.*` rules of their own (the
  delegate-sizing program and a root rule) rather than inlined into the
  orientation.
- `lib/ai/transformers/` — the per-runtime renderers `ai.*` uses.

### Committed files and the drift check

`checks/instructions/instructions-drift.nix` evaluates `dev/ai.nix` through the
module harness with `isCI = false` (Semble, and so its AGENTS.md rule, is gated
on it, and committed bytes must not depend on who evaluates them) and compares
the tracked AGENTS.md, `.github/copilot-instructions.md` and
`.github/instructions/` tree with the units the `ai.*` writers' plans carry.
README.md and CONTRIBUTING.md compare against the `repo-*` packages. The
committed instruction files are excluded from treefmt: they have one writer, and
the drift check is their byte gate.

### Running Generation

```bash
devenv tasks run --mode before generate:all  # instructions + repo documents
```

`generate:instructions` orders the two `ai.*` writers whose files are committed
(`ai:agents-md:materialize`, `ai:copilot:materialize-instructions`); it is not a
second writer. The aggregate form requires `--mode before`; without it devenv
runs the named aggregate but skips its dependency leaves.

## Updating Dependencies

```bash
devenv tasks run update:all   # update all inputs and packages via ninja DAG
```

After updating, rebuild affected packages to verify hashes:

```bash
nix build .#<package>
```

If a hash mismatch occurs, copy the expected hash from the error and update
`packages/mcp-servers/hashes.json` (or the relevant sidecar).

## Code Standards

Coding standards, ordering rules, DRY principle, and Bash strict mode are
documented in [AGENTS.md](AGENTS.md), the always-loaded instructions every agent
runtime shares. Do not duplicate — read that file first.

## Linting

Run the meta-formatter before committing:

```bash
treefmt              # format everything (formats only — lints nothing)
treefmt <file>       # format a single file after editing
```

Linting is separate from formatting: the linters (deadnix, statix, shellcheck,
cspell) run as prek pre-commit hooks, which are disabled in CI and can be
skipped with `--no-verify`.

`nix flake check` is the CI gate (formatting, structural checks, and module
evaluation). Spelling is NOT part of it — cspell runs only as a prek hook, so CI
never checks it.

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

## Adding a Package

### AI CLI or MCP Server

See [Packaging](docs/packaging.md) and the scoped architecture routing in
[AGENTS.md](AGENTS.md) for recipe patterns and package-specific guidance.

### General pattern

1. Create `packages/<owner>/packages/<namespace>/<name>/package.nix` with inline
   `rev` + `hash`
2. Add update, cache, and documentation entries to the owner's `registry.nix`
3. Put consumer modules, helpers, and checks in the same owner directory
4. Add HM and devenv modules in `packages/<owner>/modules/` when applicable
5. Run `nix flake check` to verify

See [Repository ownership and layout](docs/repository-layout.md) for a worked
tree. Register checks through the owner's native `checks.nix` module.

Owner discovery exports native package namespaces, flat flake packages, and
backend modules automatically. New owners need no root export entry.

See [Change Propagation](AGENTS.md#change-propagation) — when removing or
renaming a concept, all surfaces must be updated in the same commit.

## Adding a Fragment

Fragments are composable instruction blocks. `dev/generate.nix` composes them
into the context and rules that `ai.*` writes for every runtime (AGENTS.md,
Claude, Copilot, Kiro), and into CONTRIBUTING.md.

<!-- TODO: refine with maintainer input -->

| Fragment type                    | Location                                         | Exported? |
| -------------------------------- | ------------------------------------------------ | --------- |
| Dev-only (monorepo/tooling)      | `dev/fragments/<pkg>/<name>.md`                  | No        |
| Published coding standards       | `packages/coding-standards/fragments/<name>.md`  | Yes       |
| Published delegate-sizing rule   | `packages/delegate-sizing/fragments/<name>.md`   | Yes       |
| Published SWS skill-routing rule | `packages/stacked-workflows/fragments/<name>.md` | Yes       |

To add a dev-only fragment:

1. Create `dev/fragments/<pkg>/<name>.md`
2. Add the name to `config.fragments.categories.<pkg>.sources` in
   `config/fragment-categories.nix` (scope globs for the category live alongside
   it as `.scopes`)
3. Run `devenv tasks run --mode before generate:all` to regenerate

To add a published fragment (consumed by external users):

1. Create `packages/<owner>/fragments/<name>.md`
2. Use the owner's `lib/fragments.nix` directory discovery to expose the
   fragment through its native content recipe and public library. Existing
   content owners discover markdown files automatically.
3. If the fragment also belongs in this repository's generated instructions, add
   it to the relevant owner `registry.nix` category or workspace category in
   `config/fragment-categories.nix`
4. Run `devenv tasks run --mode before generate:all` to regenerate everything

## Pull Requests

<!-- TODO: refine with maintainer input -->

- One logical change per PR
- CI must pass (formatting, linting, spelling, module evaluation)
- Committed generated files (AGENTS.md, README.md, CONTRIBUTING.md,
  `.github/copilot-instructions.md`, `.github/instructions/`) must be
  regenerated if their source fragments changed: run
  `devenv tasks run --mode before generate:all`. `nix flake check` fails on
  drift.
- Keep commits atomic using the stacked workflow skills (`/stack-plan`,
  `/stack-fix`, `/stack-submit`)
