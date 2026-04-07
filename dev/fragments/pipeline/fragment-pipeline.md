## Fragment Pipeline Architecture

> **Last verified:** 2026-04-07 (commit a3c05f3). If you touch
> `lib/fragments.nix`, `dev/generate.nix`, `packages/fragments-ai/`,
> `packages/fragments-docs/`, or any content-package `passthru.fragments`
> surface and this fragment isn't updated in the same commit, stop
> and fix it. This is a cross-cutting pipeline — changes that look
> small in one file frequently ripple into generator outputs for
> four ecosystems plus the docsite.

### The four layers

The fragment pipeline is deliberately layered so the same markdown
source can fan out to many different consumers without duplication:

1. **Primitives (`lib/fragments.nix`)** — pure, target-agnostic.
   Defines `mkFragment { text, description, paths, priority }`,
   `compose { fragments, ... }` (priority sort + SHA256 dedup +
   concat), `mkFrontmatter` (flat attrset → YAML header), and
   `render` (applies a transform to a composed fragment). No file
   I/O, no ecosystem knowledge, no hardcoded paths.

2. **Topic packages (`packages/fragments-ai/`,
   `packages/fragments-docs/`)** — derivations that bundle content
   templates together with per-ecosystem transforms. Transforms are
   exposed via `passthru.transforms` (fragments-ai) or
   `passthru.generators` (fragments-docs). These are the eval-time
   API — callers pull them via `pkgs.fragments-ai.passthru.transforms.claude`
   etc.

3. **Content packages (`packages/coding-standards/`,
   `packages/stacked-workflows/`, etc.)** — derivations that ship
   markdown files in the store AND expose the same files as
   typed fragments via `passthru.fragments` and `passthru.presets`.
   Consumers and the dev generator both read from the same
   passthru surface.

4. **Orchestration (`dev/generate.nix`)** — composes dev-only
   fragments with published fragments, applies transforms, and
   produces the final output strings for each ecosystem +
   AGENTS.md + README + CONTRIBUTING.

### Data flow for a scoped rule file

Concrete example: generating `.claude/rules/claude-code.md` from
the `claude-code` category:

1. `mkDevComposed "claude-code"` in `dev/generate.nix` reads the
   fragment names from `devFragmentNames.claude-code` and calls
   `mkDevFragment` on each. The location discriminator
   (`"dev" | "package" | "module"`) controls where on disk the
   markdown is read from.
2. `compose { fragments = devFrags; }` sorts by priority, dedupes
   by SHA256, and concatenates. Scoped categories do NOT include
   commonFragments — only the root `monorepo` profile does, to
   avoid duplicating shared content across always-loaded common.md
   and every scoped rule file.
3. `mkEcosystemFile "claude-code"` looks up the path scope in
   `packagePaths.claude-code` and returns a set of per-ecosystem
   renderers. The claude renderer wraps `aiTransforms.claude
{ package = "claude-code"; }` which emits `paths:` frontmatter
   as a YAML list.
4. The flake derivation `packages.<system>.instructions-claude`
   stores the result at a nix store path.
5. The devenv task `generate:instructions:claude` runs
   `nix build .#instructions-claude`, then copies
   `$out/rules/claude-code.md` to the working tree.

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
  multi-element lists. Kiro docs explicitly require array
  form for multi-pattern — a previous comma-joined string
  form was silently interpreted as one literal pattern and
  matched nothing. Fix landed in commit 5a97f09.
- `agentsmd` — identity function. Returns `fragment.text` raw,
  no frontmatter. AGENTS.md is a flat, always-loaded file; there's
  nothing to scope.

### Orchestration details worth knowing

- **Scoped files skip commonFragments.** Before commit 1075bc4,
  every scoped rule file prepended the full coding-standards
  header on top of its scope-specific content, duplicating ~80
  lines against always-loaded common.md. Fixed in
  `mkDevComposed` by gating `commonFragments` on `package == "monorepo"`.
- **Dev fragment location discriminator.** Since commit de3dd12,
  each entry in `devFragmentNames.<category>` may be either a
  bare string (legacy, reads `dev/fragments/<category>/<name>.md`)
  or an attrset `{ location, name, dir }`:
  - `location = "dev"` (default) → `dev/fragments/<dir>/<name>.md`
  - `location = "package"` → `packages/<dir>/fragments/dev/<name>.md`
  - `location = "module"` → `modules/<dir>/fragments/dev/<name>.md`
    The `dir` field defaults to the category key but is explicit
    when they differ (e.g., category "ai-module" pointing at
    `modules/ai/`).
- **Path scoping is a list, not a string.** `packagePaths` must
  hold Nix lists; pre-quoted comma-joined strings produced broken
  YAML for Claude and Kiro before commit 5a97f09.
- **Priority is for intra-composition ordering only.** Never
  emitted to frontmatter. Dev fragments default to priority 5,
  published fragments typically 10.
- **SHA256 dedup runs before priority sort.** Two fragments with
  identical text are collapsed; the survivor's priority wins.

### docsite pipeline is different (and not yet DRY)

`packages/fragments-docs/` is NOT a fragment-markdown reader.
It exposes `passthru.generators`:

- `snippets.*` — small tables embedded in prose pages via
  `{{#include ../generated/snippets/<name>.md}}`. Data-driven
  from `dev/data.nix`.
- Full-page generators (`overlayPackages`, `mcpServers`,
  `libApi`, `typesRef`, `aiMapping`) — emit complete mdbook
  pages from nix-evaluated data OR read static markdown from
  `packages/fragments-docs/pages/`.

**Dev fragments do not currently feed the docsite.** A future
"Contributing / Architecture" section would need a new
generator in `fragments-docs` that reads dev fragments by path
(same inputs `mkDevFragment` uses), strips frontmatter, and
wraps for mdbook. Single-source DRY across steering files
AND docsite — tracked as Checkpoint 7 of the
steering-fragments design spec.

### Extension points (how to add things)

- **New dev fragment**: create markdown file at the right
  location, add to `devFragmentNames.<category>` in
  `dev/generate.nix`, run
  `devenv tasks run --mode before generate:instructions`.
- **New content package published fragment**: create markdown
  at `packages/<pkg>/fragments/<name>.md`, declare in the
  package's `passthru.fragments.<name>` using
  `fragmentsLib.mkFragment { text = builtins.readFile ...; }`.
  If dev instruction files should include it, add to
  `extraPublishedFragments.<category>` in `dev/generate.nix`.
- **New ecosystem transform** (e.g., Codex): add function to
  `packages/fragments-ai/default.nix` `passthru.transforms.<name>`,
  wire into `mkEcosystemFile` in `dev/generate.nix`, add a new
  `instructions-<ecosystem>` derivation in `flake.nix`, add
  the corresponding `generate:instructions:<ecosystem>` task in
  `dev/tasks/generate.nix`.
- **New docsite snippet**: add function to
  `packages/fragments-docs/default.nix` `passthru.generators.snippets`,
  wire into the `site-snippets` runCommand in `flake.nix`.

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
- **Monorepo profile vs scoped profile differs semantically**.
  Only `monorepo` gets commonFragments + swsFragments. Scoped
  categories are intentionally lean. Don't "fix" this by
  re-adding commonFragments — that's the context-rot bug that
  was removed.
