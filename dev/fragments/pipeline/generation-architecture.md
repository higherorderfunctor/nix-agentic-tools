## Generation Architecture

> **Last verified:** 2026-10-26 — shared guidance is individually named
> always-on rules, selected per runtime through existing rule disables. Copilot
> writes its own GitHub files and does not contribute to shared AGENTS.md. Local
> AGENTS.md and `.agents/rules/` are generated and gitignored; drift compares
> tracked GitHub instructions and human documents. `generate:all` waits on
> `ai:files-ready`, writes repo documents and devenv.yaml, and leaves
> devenv.lock to an explicit network update.
>
> **Settled — do not relitigate.** Rendering and writing the instruction files
> in the generator, beside `ai.*`, is what this replaced. The generator owned
> AGENTS.md, so disabling its runtime delivery dropped every Codex rule
> (Semble's CLI rule among them) with no diagnostic. One writer per file, and
> that writer is `ai.*`. Full lineage:
> `git show f77d34ac:dev/fragments/pipeline/generation-architecture.md`.

Two kinds of generated content, two owners:

- **Agent instructions** — `dev/generate.nix` returns `rules`: one named
  always-on rule per published coding-standard fragment and selected `monorepo`
  source, plus one scoped rule per other registry category. Scoped rules carry
  composed text, scope globs as `matcher`, source documents as `references`, and
  the matcher-derived `fileMatch` default. `dev/ai.nix` assigns `ai.rules`;
  `ai.*` renders and writes each runtime's files through its generated tree.
  Codex, Kimchi and Kiro share local AGENTS.md, with a path-scoped index and
  readable child indexes under `.agents/rules/` when shorter. Claude receives
  `.claude/rules/`, Copilot receives `.github/instructions/`, and Kiro receives
  `.kiro/steering/`. All local instruction projections are gitignored; GitHub
  instructions are committed read-only copies. An explicitly declared unnamed
  Copilot context independently writes `.github/copilot-instructions.md`; this
  repository declares none.
- **Human documents** — README.md and CONTRIBUTING.md are not agent steering.
  `dev/repo-docs.nix` renders them from `dev/generate.nix` and builds each with
  the same builder as the agent files (`lib/generated.nix`'s `mkTree`, the
  evaluated treefmt config, and the same named guards `ai.guards` selects);
  `generate:repo:*` copies them out.

`dev/ai.nix` bounds github.com's reviewer instructions with an explicit category
allowlist and `ai.copilot.github.rules.<name>.enable = false` for every other
shared rule and the root stacked-workflows router. Newly registered categories
stay out until selected. Local runtimes keep every named shared rule. The
fragment-shadow guard accepts content-free runtime disables but rejects same-key
replacement text or sources, including disabled replacements. Peer communication
uses its existing Copilot program disable; delegate-routing and Semble already
exclude Copilot. `instructions-reviewer-policy` checks the emitted instruction
set, always-on metadata, the absence of Copilot from shared AGENTS.md, local
content retention, and the shadow guard.

`ai.*` genuinely cannot express the human documents: they are not context or
rules of any runtime. Everything instruction-shaped goes through `ai.*`.

Older checkouts may still hold instruction files the files engine never
recorded. The engine prunes only paths in its state, so those files can be
deleted by hand.

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
- `packages/coding-standards/fragments/` — published coding standards, delivered
  as named rules.
- `packages/delegate-routing/` and `packages/stacked-workflows/router.nix` — the
  always-on routing rules, delivered as `ai.*` rules of their own (the
  delegate-routing program and a root rule) through the same rule pool.
- `lib/ai/transformers/` — the per-runtime renderers `ai.*` uses.

### Committed files and the drift check

`checks/instructions/instructions-drift.nix` evaluates `dev/ai.nix` with both
`isCI` values and requires identical instruction plans. It compares the tracked
`.github/instructions/` tree and `.github/copilot-instructions.md` when
generated with the built files the Copilot writer's plan points at. README.md
and CONTRIBUTING.md compare against the `repo-*` packages. Local AGENTS.md and
child indexes have no tracked bytes to compare; generated composition, audience
rules and the configured Codex byte limit remain checked. `treefmt.nix` excludes
none of the committed instruction files: they come out of the generated tree in
the house format, and `checks.formatting` reads them like any tracked file.

### Running Generation

```bash
devenv tasks run --mode before generate:all  # instructions, repo docs, devenv.yaml
```

`generate:all` orders the instruction and repository projection writers:
`ai:files-ready`, by which the files engine has written AGENTS.md, the
`.github/` instruction files and the gitignored Claude and Kiro rules; then
`devenv:files` for the other gitignored links, `generate:devenv-yaml`, and
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
