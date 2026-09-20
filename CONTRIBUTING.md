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

> **Last verified:** 2026-09-12 — document generation reads the same owner
> metadata registry as flake assembly.

Content is generated via Nix derivations wrapped in devenv tasks, organized by
scope:

- `generate:instructions:*` — AI instruction files (CLAUDE.md, AGENTS.md,
  Copilot, Kiro) from fragments + ecosystem transforms
- `generate:repo:*` — repo front-door files (README.md, CONTRIBUTING.md) from
  fragments + nix-evaluated data
- `generate:all` — runs all scopes

The Nix derivations own the rendered bytes. Repository-document tasks build a
named flake package and copy its output. Instruction tasks receive their
already-realized derivation paths from devenv evaluation and invoke
`lib/materialize-repo-instructions.nix`; unchanged bytes, file type, and mode
are a no-op.

### Source Layout

- `lib/facets/registry.nix` — native metadata assembly shared by flake and
  document generation. Workspace categories come from
  `config/fragment-categories.nix`; package categories and descriptions come
  from owner `registry.nix` files. Options live in `lib/fragments-registry.nix`
  and `lib/documentation.nix`.
- `dev/fragments/` — dev-only instruction fragments. Composed into instruction
  files and CLAUDE.md.
- `dev/generate.nix` — shared fragment composition logic consumed by both devenv
  tasks and flake derivations.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/delegate-sizing/fragments/` — published delegate-sizing rule.
- `packages/stacked-workflows/fragments/` — published skill-routing rule.
- `lib/ai/transformers/` — AI ecosystem renderers, exported through the `lib/ai`
  barrel.

### What Stays in Module System

Skills and immutable CLI configuration generally use `files.*` (devenv) or
`home.file` (HM), producing symlinks to store paths with no repository
generation step. Runtime-writable files are an intentional exception: for
example, Codex's user `config.toml` is reconciled by Home Manager activation,
while project config remains statically owned by devenv. Codex named profile
files are immutable whole-file layers: Home Manager links them directly, while a
devenv pre-shell task safely materializes repository declarations into the user
CODEX_HOME where native `--profile` lookup requires them. That path is currently
unreachable — `ai.codex.profiles` is LOCKED OUT and fails evaluation (see the
lockout comment in `packages/chatgpt-codex/lib/mkCodex.nix`) — so no repository
here drives the materializer; it is described because the code is retained for
re-enablement. These app-level materialization tasks are separate from the
repository instruction generator described here.

Repository-generated instruction projections are the exception: they are
**copies**, not symlinks, materialized on every shell entry by
`generate:instructions:materialize` (`before = ["devenv:enterShell"]`).
Git-tracked outputs cannot be symlinks, since a store symlink commits as an
absolute `/nix/store` path. This is separate from consumer module delivery:
normalized runtime context/rules enter `ai.<runtime>.files` and lower to
ordinary backend symlinks. A 2.18.1 live spike confirmed Kiro steering now loads
through that path. See the devenv files-internals fragment.

`checks/instructions/instruction-materialization.nix` runs the exact packaged
copier in a temporary repository. It covers portability and lifecycle behavior
without building the full interactive devenv shell, so the on-demand Devenv
Diagnostic is no longer an automatic CI dependency.

### Running Generation

```bash
devenv tasks run --mode before generate:all  # instructions + repo documents

# A leaf can be run directly when only one projection is intentionally wanted:
devenv tasks run generate:instructions:claude # just CLAUDE.md + rules
```

The aggregate form requires `--mode before`; without it devenv runs the named
aggregate but skips its dependency leaves.

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
documented in [CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md). Do not
duplicate — read those files first.

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

Fragments are composable instruction blocks used to build AI instruction files
(CLAUDE.md, AGENTS.md, Copilot, Kiro) and CONTRIBUTING.md.

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
- Generated files (CLAUDE.md, AGENTS.md, README.md, CONTRIBUTING.md, Copilot and
  Kiro instruction files) must be regenerated if their source fragments changed:
  run `devenv tasks run --mode before generate:all`
- Keep commits atomic using the stacked workflow skills (`/stack-plan`,
  `/stack-fix`, `/stack-submit`)
