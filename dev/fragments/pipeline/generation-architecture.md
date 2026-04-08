## Generation Architecture

Content is generated via Nix derivations wrapped in devenv tasks,
organized by scope. On the current branch only the
`generate:instructions:*` group is wired; `generate:repo:*` and
`generate:site:*` task groups (and the `generate:all` umbrella) land
in later chunks alongside their derivations.

- `generate:instructions:*` — AI instruction files (CLAUDE.md,
  AGENTS.md, Copilot, Kiro) from fragments + ecosystem transforms

Each task wraps a `nix build .#<derivation>` and copies output to the
working tree. Nix store caching means unchanged inputs skip rebuild.

### Source Layout

- `dev/fragments/` — dev-only instruction fragments. Composed into
  instruction files and CLAUDE.md.
- `dev/generate.nix` — shared fragment composition logic consumed by
  both devenv tasks and flake derivations.
- `dev/tasks/generate.nix` — devenv task wrappers around the
  `instructions-*` derivations.
- `lib/ai/transformers/` — pure ecosystem transformer functions
  (claude, copilot, kiro, agentsmd). Consumed via
  `lib.ai.transformers.<eco>.render`.
- `packages/coding-standards/fragments/` — published coding standards.
- `packages/stacked-workflows/fragments/` — published routing table.
- `devshell/docs-site/` — mdbook doc site generators (internal,
  never published to consumers).

### What Stays in Module System

Skills, `settings.json`, MCP config, and CLI settings use `files.*`
(devenv) or `home.file` (HM). These are symlinks to immutable store
paths — no generation step.

### Running Generation

```bash
devenv tasks run generate:instructions          # all instruction files
devenv tasks run generate:instructions:claude   # CLAUDE.md + rules only
```
