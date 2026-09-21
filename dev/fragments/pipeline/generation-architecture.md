## Generation Architecture

> **Last verified:** 2026-09-21 — model package descriptions join the
> owner-provided README tables.

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
  and `lib/documentation.nix`. Model package rows use
  `documentation.modelDescriptions`; this documentation metadata does not create
  an `ai.models` configuration surface.
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
while project config remains statically owned by devenv. (Codex's separate
whole-file `--profile` layer and its devenv `CODEX_HOME` materializer were
removed 2026-09-19 as unreachable dead code; see the Settled bullet in
`dev/fragments/ai-module/ai-module-fanout.md`.) These app-level materialization
tasks are separate from the repository instruction generator described here.

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
