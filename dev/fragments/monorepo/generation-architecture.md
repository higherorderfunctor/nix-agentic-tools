## Generation Architecture

Content is generated via Nix derivations wrapped in devenv tasks,
organized by scope:

- `generate:instructions:*` — AI instruction files (CLAUDE.md,
  AGENTS.md, Copilot, Kiro) from fragments + ecosystem transforms
- `generate:repo:*` — repo front-door files (README.md,
  CONTRIBUTING.md) from fragments + nix-evaluated data
- `generate:site:*` — doc site (mdbook) from authored prose +
  nix-evaluated reference pages and data snippets
- `generate:all` — runs all scopes

Each task wraps a `nix build .#<derivation>` and copies output to the
working tree. Nix store caching means unchanged inputs skip rebuild.

### Source Layout

- `dev/docs/` — authored prose (getting-started guides, concepts,
  troubleshooting). Copied to `docs/src/` by `generate:site:prose`.
- `dev/fragments/` — dev-only instruction fragments. Composed into
  instruction files and CLAUDE.md.
- `dev/generate.nix` — shared fragment composition logic consumed by
  both devenv tasks and flake derivations.
- `docs/src/` — gitignored generated output. mdbook serves from here.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/stacked-workflows/fragments/` — published routing table.
- `packages/fragments-ai/` — AI ecosystem transforms (passthru).
- `packages/fragments-docs/` — doc site transforms and generators
  (passthru).

### What Stays in Module System

Skills, settings.json, MCP config, and CLI settings use `files.*`
(devenv) or `home.file` (HM). These are symlinks to immutable store
paths — no generation step.

### Running Generation

```bash
devenv tasks run generate:instructions    # all instruction files
devenv tasks run generate:instructions:claude  # just CLAUDE.md + rules
devenv tasks run generate:repo            # README.md + CONTRIBUTING.md
devenv tasks run generate:site            # full doc site
devenv tasks run generate:all             # everything
```
