## Generation Architecture

Content is generated via Nix derivations wrapped in devenv tasks, organized by
scope:

- `generate:instructions:*` — AI instruction files (CLAUDE.md, AGENTS.md,
  Copilot, Kiro) from fragments + ecosystem transforms
- `generate:repo:*` — repo front-door files (README.md, CONTRIBUTING.md) from
  fragments + nix-evaluated data
- `generate:all` — runs all scopes

Each task wraps a `nix build .#<derivation>` and copies output to the working
tree. Nix store caching means unchanged inputs skip rebuild.

### Source Layout

- `config/fragment-categories.nix` — the fragment-category registry: each
  category's scope globs and fragment sources. Option declared in
  `lib/fragments-registry.nix`.
- `dev/fragments/` — dev-only instruction fragments. Composed into instruction
  files and CLAUDE.md.
- `dev/generate.nix` — shared fragment composition logic consumed by both devenv
  tasks and flake derivations.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/stacked-workflows/fragments/` — published skill-routing rule.
- `packages/fragments-ai/` — AI ecosystem transforms (passthru).

### What Stays in Module System

Skills, settings.json, MCP config, and CLI settings use `files.*` (devenv) or
`home.file` (HM). These are symlinks to immutable store paths — no generation
step.

Instruction files are the exception: they are **copies**, not symlinks,
materialized on every shell entry by `generate:instructions:materialize`
(`before = ["devenv:enterShell"]`). Kiro cannot read symlinked steering — it
discovers by scanning the directory and the scan skips symlinks — and the
git-tracked outputs cannot be symlinks either, since a store symlink commits as
an absolute `/nix/store` path. See the devenv files-internals fragment.

### Running Generation

```bash
devenv tasks run generate:instructions    # all instruction files
devenv tasks run generate:instructions:claude  # just CLAUDE.md + rules
devenv tasks run generate:repo            # README.md + CONTRIBUTING.md
devenv tasks run generate:all             # everything
```
