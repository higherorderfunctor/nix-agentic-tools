## Generation Architecture

> **Last verified:** 2026-10-03 — repo documents and agent files are built by
> `mkTree` with the evaluated `ai.formatter` treefmt config and the named
> guards; scoped rules rely on the normalized matcher-derived `fileMatch`
> trigger default. `generate:all` writes instruction and repo-document
> projections plus devenv.yaml; devenv.lock requires a separate network update;
> the generator produces content only; `dev/ai.nix` hands it to `ai.*`, which
> writes every agent instruction file from its generated-file tree, formatted
> there with this repository's treefmt; the drift check compares the built
> files.
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
  documents as `references`, and the matcher-derived default `fileMatch`
  trigger). `dev/ai.nix` sets them as `ai.context` and `ai.rules` in this
  repository's own devenv, and `ai.*` renders and writes each runtime's files
  exactly as it would for any consumer: AGENTS.md (Codex, Kiro, Kimchi, with a
  path-scoped index of the rules), `.claude/CLAUDE.md` and `.claude/rules/`,
  `.github/copilot-instructions.md` and `.github/instructions/`, and
  `.kiro/steering/`. The committed ones (AGENTS.md and `.github/`) are read-only
  copies.
- **Human documents** — README.md and CONTRIBUTING.md are not agent steering.
  `dev/repo-docs.nix` renders them from `dev/generate.nix` and builds each with
  the same builder as the agent files (`lib/generated.nix`'s `mkTree`, the
  evaluated treefmt config, and the same named guards `ai.guards` selects);
  `generate:repo:*` copies them out.

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
  `devenv.nix` and evaluated by the drift check. Its generated trees use the
  default `ai.formatter`, which is this flake's exported treefmt module, so a
  committed file is already in the same house style as `nix fmt` produces.
- `packages/coding-standards/fragments/` — published coding standards, part of
  the orientation.
- `packages/delegate-routing/` and `packages/stacked-workflows/router.nix` — the
  always-on routing rules, delivered as `ai.*` rules of their own (the
  delegate-routing program and a root rule) rather than inlined into the
  orientation.
- `lib/ai/transformers/` — the per-runtime renderers `ai.*` uses.

### Committed files and the drift check

`checks/instructions/instructions-drift.nix` evaluates `dev/ai.nix` through the
module harness with `isCI = false` (Semble, and so its AGENTS.md rule, is gated
on it, and committed bytes must not depend on who evaluates them) and compares
the tracked AGENTS.md, `.github/copilot-instructions.md` and
`.github/instructions/` tree with the built files the `ai.*` writers' plans
point at: each is a file in its runtime's generated-file store tree, already
formatted and checked. README.md and CONTRIBUTING.md compare against the
`repo-*` packages. `treefmt.nix` excludes none of the committed instruction
files: they come out of the tree in the house format, and `checks.formatting`
reads them like any tracked file.

### Running Generation

```bash
devenv tasks run --mode before generate:all  # instructions, repo docs, devenv.yaml
```

`generate:all` orders the projection writers: the two `ai.*` writers whose files
are committed (`ai:agents-md:materialize`,
`ai:copilot:materialize-instructions`), `devenv:files` for the gitignored ones
(Claude rules, Kiro steering and the rest), `generate:devenv-yaml`, and
`generate:repo`. It is not a second writer. The aggregate form requires
`--mode before`; without it devenv runs the named aggregate but skips its
dependency leaves.

`generate:devenv-yaml` projects the root flake inputs and their locked revisions
into devenv.yaml. After adding or changing an input, run `devenv update <input>`
to sync devenv.lock separately: resolving its transitive inputs can require
network access, so it is outside `generate:all`. The pure
`checks.devenv-inputs-drift` check compares devenv.yaml with its generator and
checks each declared input's locked rev and narHash against flake.lock,
resolving root edges rather than assuming lock node names match input names. It
reports the generation or lock-update command needed to repair drift. It
compares only each root input's own lock entry: transitive nodes can still
differ (today `go-overlay/git-hooks`, because `config/generate-devenv-yaml.nix`
emits only `nixpkgs` follows), and extra undeclared root inputs in devenv.lock
are ignored.
