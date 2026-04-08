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

2. **Ecosystem transformers (`lib/ai/transformers/`)** — pure
   functions per ecosystem (claude, copilot, kiro, agentsmd)
   that render a composed fragment into ecosystem-specific
   bytes. Exposed via `flake.lib.ai.transformers.<ecosystem>.render`.
   Each transformer has a `render` function taking a fragment
   attrset (`{ text, description, paths, ... }`) and returning
   the rendered string. No derivation, no IFD, pure Nix.

3. **Content packages (`packages/coding-standards/`,
   `packages/stacked-workflows/`)** — derivations that ship
   markdown files in the store AND expose the same files as typed
   fragments via `passthru.fragments` (and, for stacked-workflows,
   `passthru.skillsDir` + `passthru.referencesDir`). Consumers
   and the dev generator read from the same passthru surface.

4. **Orchestration (`dev/generate.nix`)** — composes dev-only
   fragments together with content-package fragments
   (`commonFragments` from coding-standards always-loaded;
   `swsFragments` from stacked-workflows-content per
   `extraPublishedFragments`), applies transforms, and produces
   the final output strings for each ecosystem + AGENTS.md.

### Data flow for a scoped rule file

Concrete example: generating `.claude/rules/pipeline.md` from the
`pipeline` category:

1. `mkDevComposed "pipeline"` in `dev/generate.nix` reads the
   fragment names from `devFragmentNames.pipeline` and calls
   `mkDevFragment` on each. The location discriminator
   (`"dev" | "package" | "module"`) controls where on disk the
   markdown is read from.
2. `compose { fragments = devFrags; }` sorts by priority
   (descending), then deduplicates the sorted list by SHA256
   (first occurrence wins), then concatenates.
3. `mkEcosystemFile "pipeline"` looks up the path scope in
   `packagePaths.pipeline` and returns a set of per-ecosystem
   renderers. The claude renderer calls
   `aiTransforms.claude.render (composed // { package = "pipeline"; })`
   which emits `paths:` frontmatter as a YAML list.
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

`lib/ai/transformers/` contains four transformer files. Each
exposes a `render` function that takes a composed fragment
(optionally merged with ecosystem-specific extras like `package`
for claude or `name` for kiro) and returns rendered bytes:

- `lib/ai/transformers/claude.nix` — emits a YAML header with
  `description:` and `paths:`. Handles three `paths` shapes:
  null (no paths key), list (YAML list with quoted entries),
  string (verbatim). Description has a smart default:
  "Instructions for the ${package} package" when paths are set
  and description is null, otherwise omitted or passed through.
  Consumer pattern: `lib.ai.transformers.claude.render (composed // { inherit package; })`.
- `lib/ai/transformers/copilot.nix` — emits `applyTo:` as a
  quoted string. List input is joined with commas (Copilot's
  native multi-glob syntax). Null input defaults to
  `applyTo: "**"` (global fallback).
- `lib/ai/transformers/kiro.nix` — emits `inclusion: always | fileMatch`,
  `name: ${name}`, and optionally `description:` +
  `fileMatchPattern:`. The pattern uses a quoted string for
  single-element lists and inline YAML array syntax for
  multi-element lists. Kiro docs explicitly require array form
  for multi-pattern. Consumer pattern:
  `lib.ai.transformers.kiro.render (composed // { name = package; })`.
- `lib/ai/transformers/agentsmd.nix` — emits `fragment.text`
  raw with no frontmatter. AGENTS.md is a flat, always-loaded
  file; there's nothing to scope.

### Orchestration details worth knowing

- **`mkDevComposed` profile semantics.** The monorepo (root)
  profile prepends `commonFragments` (always-loaded coding
  standards from `coding-standards.passthru.fragments`) plus any
  `extraPublishedFragments` (e.g., the SWS routing-table
  fragment). Scoped profiles include ONLY their dev fragments —
  repeating the always-loaded set in scoped rule files would
  amplify context rot.
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
  published fragments typically 10. Higher priority sorts
  earlier (descending order).
- **Sort runs BEFORE dedup.** `compose` sorts the input list by
  priority descending, then walks the sorted list and skips any
  fragment whose SHA256 has already been seen. So the
  highest-priority occurrence of duplicated text is the one that
  survives, not "whichever priority wins" — the sort order
  determines who's first.

### Extension points (how to add things)

- **New dev fragment**: create markdown file at the right
  location, add to `devFragmentNames.<category>` in
  `dev/generate.nix`, run
  `devenv tasks run --mode before generate:instructions`.
- **New ecosystem transform** (e.g., Codex): create
  `lib/ai/transformers/<name>.nix` exporting a `render` function
  that takes `{ text, description, paths, ...extras }` and
  returns rendered bytes. Wire it into `lib/ai/transformers/default.nix`.
  Then add the new transformer to `mkEcosystemFile` in
  `dev/generate.nix`, add a new `instructions-<ecosystem>`
  derivation in `flake.nix` (inside the `pkgs.ai // { ... }` splat),
  and add the corresponding `generate:instructions:<ecosystem>`
  task in `dev/tasks/generate.nix`.

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
