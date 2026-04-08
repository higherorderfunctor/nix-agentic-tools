## Fragment Pipeline Architecture

> **Reduced state:** this fragment documents the pipeline as it
> exists on the current branch. Components introduced in later
> chunks (content packages, docsite generators, additional dev
> fragment categories) are noted as "future" or omitted.

### The layers (current branch)

The fragment pipeline is deliberately layered so the same markdown
source can fan out to many different consumers without duplication:

1. **Primitives (`lib/fragments.nix`)** — pure, target-agnostic.
   Defines `mkFragment { text, description, paths, priority }`,
   `compose { fragments, ... }` (priority sort + SHA256 dedup +
   concat), `mkFrontmatter` (flat attrset → YAML header), and
   `render` (applies a transform to a composed fragment). No file
   I/O, no ecosystem knowledge, no hardcoded paths.

2. **Topic package (`packages/fragments-ai/`)** — derivation that
   bundles ecosystem templates with per-ecosystem transforms,
   exposed via `passthru.transforms`. Callers pull them as
   `pkgs.fragments-ai.passthru.transforms.<ecosystem>`. A future
   topic package (`packages/fragments-docs/`) lands with the
   docsite chunk; not present yet.

3. **Content packages** (e.g. `packages/coding-standards/`,
   `packages/stacked-workflows/`) — _future, not on this branch_.
   These will ship markdown files in the store AND expose them as
   typed fragments via `passthru.fragments` so consumers and the
   dev generator both read from the same passthru surface.

4. **Orchestration (`dev/generate.nix`)** — composes dev-only
   fragments and applies transforms to produce the final output
   strings for each ecosystem + AGENTS.md. The full pipeline
   merges content-package fragments on top of dev fragments; the
   reduced form on this branch only handles dev fragments until
   Layer 3 lands.

### Data flow for a scoped rule file

Concrete example: generating `.claude/rules/pipeline.md` from the
`pipeline` category:

1. `mkDevComposed "pipeline"` in `dev/generate.nix` reads the
   fragment names from `devFragmentNames.pipeline` and calls
   `mkDevFragment` on each. The location discriminator
   (`"dev" | "package" | "module"`) controls where on disk the
   markdown is read from.
2. `compose { fragments = devFrags; }` sorts by priority, dedupes
   by SHA256, and concatenates.
3. `mkEcosystemFile "pipeline"` looks up the path scope in
   `packagePaths.pipeline` and returns a set of per-ecosystem
   renderers. The claude renderer wraps `aiTransforms.claude
{ package = "pipeline"; }` which emits `paths:` frontmatter
   as a YAML list.
4. The flake derivation `packages.<system>.instructions-claude`
   stores the result at a nix store path containing
   `rules/pipeline.md`.
5. The devenv task `generate:instructions:claude` runs
   `nix build .#instructions-claude`, then copies
   `$out/rules/pipeline.md` to the working tree.

The same composed fragment runs through `copilot`, `kiro`, and
`agentsmd` transforms for the other outputs. Single source,
four ecosystem shapes.

### The transforms in detail

`packages/fragments-ai/default.nix` defines exactly four
transforms, all curried as `(transform-args)` then `(fragment)`:

- `claude { package }` — emits a YAML header with `description:`
  and `paths:`. Handles three `paths` shapes: null (no paths
  key), list (YAML list with quoted entries), string (verbatim).
  Description has a smart default: "Instructions for the
  ${package} package" when paths are set and description is null,
  otherwise omitted or passed through.
- `copilot` — emits `applyTo:` as a quoted string. List input
  is joined with commas (Copilot's native multi-glob syntax).
  Null input defaults to `applyTo: "**"` (global fallback).
- `kiro { name }` — emits `inclusion: always | fileMatch`,
  `name: ${name}`, and optionally `description:` +
  `fileMatchPattern:`. The pattern uses a quoted string for
  single-element lists and inline YAML array syntax for
  multi-element lists. Kiro docs explicitly require array form
  for multi-pattern.
- `agentsmd` — identity function. Returns `fragment.text` raw,
  no frontmatter. AGENTS.md is a flat, always-loaded file; there's
  nothing to scope.

### Orchestration details worth knowing

- **Reduced `mkDevComposed`.** On this branch `mkDevComposed`
  composes only dev fragments. The full version (lands with
  content packages) merges `commonFragments` from
  `coding-standards.passthru.fragments` and
  `extraPublishedFragments` per category on top.
- **Dev fragment location discriminator.** Each entry in
  `devFragmentNames.<category>` may be either a bare string
  (legacy, reads `dev/fragments/<category>/<name>.md`) or an
  attrset `{ location, name, dir }`:
  - `location = "dev"` (default) → `dev/fragments/<dir>/<name>.md`
  - `location = "package"` → `packages/<dir>/fragments/dev/<name>.md`
  - `location = "module"` → `modules/<dir>/fragments/dev/<name>.md`
    The `dir` field defaults to the category key but is explicit
    when they differ.
- **Path scoping is a list, not a string.** `packagePaths` must
  hold Nix lists; pre-quoted comma-joined strings produce broken
  YAML for Claude and Kiro.
- **Priority is for intra-composition ordering only.** Never
  emitted to frontmatter. Dev fragments default to priority 5,
  published fragments typically 10.
- **SHA256 dedup runs before priority sort.** Two fragments with
  identical text are collapsed; the survivor's priority wins.

### Extension points (how to add things)

- **New dev fragment**: create markdown file at the right
  location, add to `devFragmentNames.<category>` in
  `dev/generate.nix`, run
  `devenv tasks run --mode before generate:instructions`.
- **New ecosystem transform** (e.g., Codex): add function to
  `packages/fragments-ai/default.nix` `passthru.transforms.<name>`,
  wire into `mkEcosystemFile` in `dev/generate.nix`, add a new
  `instructions-<ecosystem>` derivation in `flake.nix`, add
  the corresponding `generate:instructions:<ecosystem>` task in
  `dev/tasks/generate.nix`.

### Gotchas

- **DevEnv task DAG requires `--mode before` for DAG
  resolution.** Running `devenv tasks run generate:instructions`
  alone only runs the top-level task, not its dependencies.
  Use `devenv tasks run --mode before generate:instructions`
  or run the sub-tasks directly.
- **New untracked files must be `git add`-ed before
  `nix build`** can see them in the flake context. This trips
  new fragment creation every time — add the file, THEN run
  the generate task, or the nix build won't find it.
- **devenv caches nix eval** in `.devenv/nix-eval-cache.db`.
  If task definitions change and the tasks look stale, delete
  that file.
