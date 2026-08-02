## Fragment Pipeline Architecture

> **Last verified:** 2026-08-02 (commit pending — the generated README now
> documents shared typed Codex profile ownership and devenv's native user-layer
> materialization). Prior: 2026-08-02 (commit pending — Kiro's transformer now
> accepts an explicit typed `always | auto | fileMatch | manual` inclusion mode
> while preserving the legacy paths-derived default, and the shared renderer
> resolves typed path-valued instruction bodies before node normalization).
> Prior 2026-08-02: AGENTS.md now derives a compact source-fragment routing
> index from the category registry for flat consumers, without flattening scoped
> fragment bodies. Prior: 2026-08-01 (generated instruction and repo-document
> derivations remain flake packages but are excluded from the authenticated
> all-packages build, preventing revision-by-revision Cachix churn while
> `nix flake check` retains drift coverage). Prior: 2026-07-24 (the
> `packagePaths` + `devFragmentNames` registries dissolved into
> `config.fragments.categories`). If you touch `lib/fragments.nix`,
> `config/fragment-categories.nix`, `lib/fragments-registry.nix`,
> `dev/generate.nix`, `lib/ai/transformers/`, or any content-package
> `passthru.fragments` surface and this fragment isn't updated in the same
> commit, stop and fix it. This is a cross-cutting pipeline — changes that look
> small in one file frequently ripple into generator outputs for four
> ecosystems.

### The four layers

The fragment pipeline is deliberately layered so the same markdown source can
fan out to many different consumers without duplication:

1. **Primitives (`lib/fragments.nix`)** — pure, target-agnostic. Defines
   `mkFragment { text, description, inclusion, paths, priority }`,
   `compose { fragments, ... }` (priority sort + SHA256 dedup + concat),
   `mkFrontmatter` (flat attrset → YAML header), and `render` (applies a
   transform to a composed fragment). No file I/O, no ecosystem knowledge, no
   hardcoded paths.

2. **Transforms (`lib/ai/transformers/`)** — pure per-ecosystem renderers over
   the shared fragment AST. `lib/ai/default.nix` exposes them as
   `ai.transforms`; callers import that barrel rather than reaching through a
   package passthru. The shared renderer reads path-valued bodies at evaluation
   time before normalizing strings into raw nodes. The former
   `packages/fragments-ai/` package no longer exists.

3. **Content packages (`packages/coding-standards/`,
   `packages/stacked-workflows/`, etc.)** — derivations that ship markdown files
   in the store AND expose the same files as typed fragments via
   `passthru.fragments` and `passthru.presets`. Consumers and the dev generator
   both read from the same passthru surface.

4. **Orchestration (`dev/generate.nix`)** — composes dev-only fragments with
   published fragments, applies transforms, and produces the final output
   strings for each ecosystem + AGENTS.md + README + CONTRIBUTING.

### Data flow for a scoped rule file

Concrete example: generating `.claude/rules/claude-code.md` from the
`claude-code` category:

1. `mkDevComposed "claude-code"` in `dev/generate.nix` reads the fragment
   sources from `config.fragments.categories.claude-code.sources` and calls
   `mkDevFragment` on each. The location discriminator
   (`"dev" | "devshell" | "package"`) controls where on disk the markdown is
   read from.
2. `compose { fragments = devFrags; }` sorts by priority, dedupes by SHA256, and
   concatenates. Scoped categories do NOT include commonFragments — only the
   root `monorepo` profile does, to avoid duplicating shared content across
   always-loaded common.md and every scoped rule file.
3. `mkEcosystemFile "claude-code"` looks up the path scope in
   `config.fragments.categories.claude-code.scopes` and returns a set of
   per-ecosystem renderers. The claude renderer wraps
   `aiTransforms.claude { package = "claude-code"; }` which emits `paths:`
   frontmatter as a YAML list.
4. The flake derivation `packages.<system>.instructions-claude` stores the
   result at a nix store path.
5. The devenv task `generate:instructions:claude` runs
   `nix build .#instructions-claude`, then copies `$out/rules/claude-code.md` to
   the working tree.

The same scoped composition runs through the Copilot and Kiro renderers as well.
The root composition supplies AGENTS.md's always-loaded body, while a separate
registry-derived index routes flat consumers to scoped source documents. Single
source and registry, four ecosystem shapes.

### Generated outputs are not binary-cache artifacts

The four `instructions-*` derivations and the `repo-contributing` /
`repo-readme` derivations are buildable flake packages because generation tasks
copy their formatted output into the working tree. They are repository-local
render products, not consumer packages. The authenticated all-packages CI job
therefore filters them out before invoking `nix-fast-build`; otherwise every
source revision and platform uploads another nearly identical output to Cachix.
`nix flake check` still builds the instruction drift check in a read-only-cache
job, so excluding these outputs from the publishing job does not remove
validation.

### The transforms in detail

`lib/ai/transformers/` defines exactly four renderer modules, exported through
`lib/ai/transformers/default.nix`:

- `claude { package }` — emits a YAML header with `description:` and `paths:`.
  Handles three `paths` shapes: null (no paths key), list (YAML list with quoted
  entries), string (verbatim). Description has a smart default: "Instructions
  for the ${package} package" when paths are set and description is null,
  otherwise omitted or passed through.
- `copilot` — emits `applyTo:` as a quoted string. List input is joined with
  commas (Copilot's native multi-glob syntax). Null input defaults to
  `applyTo: "**"` (global fallback).
- `kiro { name }` — emits `inclusion: always | auto | fileMatch | manual`,
  `name: ${name}`, and optionally `description:` + `fileMatchPattern:`. A null
  inclusion preserves the legacy derivation (`paths = null` → `always`, paths
  set → `fileMatch`); an explicit mode overrides that derivation only for Kiro.
  `auto` requires non-empty name + description, and explicit `fileMatch`
  requires paths. The pattern uses a quoted string for single-element lists and
  inline YAML array syntax for multi-element lists. Kiro docs explicitly require
  array form for multi-pattern — a previous comma-joined string form was
  silently interpreted as one literal pattern and matched nothing. Fix landed in
  commit 5a97f09.
- `agentsmd` — identity function. Returns `fragment.text` raw, no frontmatter.
  AGENTS.md is a flat, always-loaded file, so it cannot enforce glob scopes.
  Repo generation keeps scoped bodies out of that file and emits a compact
  source-routing index instead; Codex applies that index manually.

### Orchestration details worth knowing

- **Scoped files skip commonFragments.** Before commit 1075bc4, every scoped
  rule file prepended the full coding-standards header on top of its
  scope-specific content, duplicating ~80 lines against always-loaded common.md.
  Fixed in `mkDevComposed` by gating `commonFragments` on
  `package == "monorepo"`.
- **Dev fragment location discriminator.** Since commit de3dd12, each entry in
  `config.fragments.categories.<category>.sources` may be either a bare string
  (legacy, reads `dev/fragments/<category>/<name>.md`) or an attrset
  `{ location, name, dir }`:
  - `location = "dev"` (default) → `dev/fragments/<dir>/<name>.md`
  - `location = "package"` → `packages/<dir>/docs/<name>.md`
  - `location = "devshell"` → `devshell/<dir>/docs/<name>.md` The `dir` field
    defaults to null, falling back to the category key, and is explicit when
    they differ (e.g., a category name that does not match its directory).
- **Path scoping is a list, not a string.** The `scopes` field must hold Nix
  lists; pre-quoted comma-joined strings produced broken YAML for Claude and
  Kiro before commit 5a97f09.
- **Priority is for intra-composition ordering only.** Never emitted to
  frontmatter. Dev fragments default to priority 5, published fragments
  typically 10.
- **SHA256 dedup runs before priority sort.** Two fragments with identical text
  are collapsed; the survivor's priority wins.

### Extension points (how to add things)

- **New dev fragment**: create markdown file at the right location, add to
  `config.fragments.categories.<category>.sources` in
  `config/fragment-categories.nix`, run
  `devenv tasks run --mode before generate:all`.
- **New content package published fragment**: create markdown at
  `packages/<pkg>/fragments/<name>.md`, declare in the package's
  `passthru.fragments.<name>` using
  `fragmentsLib.mkFragment { text = builtins.readFile ...; }`. If dev
  instruction files should include it, add to
  `extraPublishedFragments.<category>` in `dev/generate.nix`.
- **New ecosystem transform**: add a function to
  `lib/ai/transformers/<name>.nix` and its `default.nix` barrel, wire it into
  `mkEcosystemFile` in `dev/generate.nix`, add its formatted derivation to
  `dev/instructions.nix` and flake export, then add the corresponding generation
  task in `dev/tasks/generate.nix`.

- **Flat-consumer routing is derived, not curated.** `dev/generate.nix` resolves
  each source entry once for both fragment composition and AGENTS.md links, then
  derives the routing index from `config.fragments.categories`. Do not add a
  parallel Codex-only path/source table: it would be a fifth registry and could
  silently diverge from the scoped runtime projections.

### Gotchas

- **DevEnv task DAG requires `--mode before` for DAG resolution.** Running an
  aggregate alone only runs that top-level task, not its dependency leaves. Use
  `devenv tasks run --mode before generate:all`; this also covers generated repo
  documents such as CONTRIBUTING.md, which an orientation-fragment change can
  affect.
- **New untracked files must be `git add`-ed before `nix build`** can see them
  in the flake context. This trips new fragment creation every time — add the
  file, THEN run the generate task, or the nix build won't find it.
- **devenv caches nix eval** in `.devenv/nix-eval-cache.db`. If task definitions
  change and the tasks look stale, delete that file.
- **Monorepo profile vs scoped profile differs semantically**. Only `monorepo`
  gets commonFragments + swsFragments. Scoped categories are intentionally lean.
  Don't "fix" this by re-adding commonFragments — that's the context-rot bug
  that was removed.
