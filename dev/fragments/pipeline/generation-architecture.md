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
