## Fragment Pipeline Architecture

> **Last verified:** 2026-09-25 — category declaration is SPLIT: shared
> categories in `config/fragment-categories.nix`, owner-specific ones in the
> owning package's `registry.nix`, merged by `lib/facets/registry.nix`. The
> orchestration layer produces content; `ai.*` renders and writes it.
>
> **Settled — do not relitigate.** Full lineage:
> `git show 25ec0738:dev/fragments/pipeline/fragment-pipeline.md`.
>
> - The old dual-registry split (`packagePaths` + `devFragmentNames`) is gone,
>   dissolved into the single `config.fragments.categories` registry
>   (2026-07-24). Don't resurrect the split — one registry drives both fragment
>   composition and category scoping.

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
   published fragments into CONTENT: the orientation (`context`), one rule per
   scoped category (`rules`), README and CONTRIBUTING. It renders no instruction
   file. `dev/ai.nix` hands `context` and `rules` to `ai.*`, whose runtimes
   apply the transforms and write the files.

### Data flow for a scoped rule

Concrete example: the `claude-code` category reaching every runtime:

1. `mkDevComposed "claude-code"` in `dev/generate.nix` reads the fragment
   sources from `config.fragments.categories.claude-code.sources` and calls
   `mkDevFragment` on each. The location discriminator
   (`"dev" | "devshell" | "package"`) controls where on disk the markdown is
   read from.
2. `compose { fragments = devFrags; }` sorts by priority, dedupes by SHA256, and
   concatenates. Scoped categories do NOT include commonFragments — only the
   root `monorepo` profile does, to avoid duplicating shared content across the
   always-loaded context and every scoped rule.
3. `rules.claude-code` becomes
   `{ text; matcher = <the category's scopes>; references = <its source documents>; }`,
   and `dev/ai.nix` sets it as `ai.rules.claude-code`.
4. `ai.*` renders it per runtime: `.claude/rules/claude-code.md` with `paths:`,
   `.github/instructions/claude-code.instructions.md` with `applyTo:`,
   `.kiro/steering/claude-code.md` with `inclusion: fileMatch`, and, for Codex,
   an entry in AGENTS.md's path-scoped index linking the source documents.

Single source and registry, four runtime shapes, one writer per file.

### Generated outputs are not binary-cache artifacts

The `repo-contributing` / `repo-readme` derivations are buildable flake packages
because generation tasks copy their formatted output into the working tree. They
are repository-local render products, not consumer packages. The authenticated
all-packages CI job therefore filters them out before invoking `nix-fast-build`;
otherwise every source revision and platform uploads another nearly identical
output to Cachix. `nix flake check` still builds the drift check in a
read-only-cache job, so excluding these outputs from the publishing job does not
remove validation. The instruction files have no package at all: `ai.*` writes
them.

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
  AGENTS.md is a flat, always-loaded file, so it cannot enforce glob scopes. Its
  `renderKeyed` writes the context, then a compact `## Path-scoped rules` index
  of every scoped rule that names `references`, then the inlined rules; Codex
  applies that index manually.

### Orchestration details worth knowing

- **Scoped files skip commonFragments.** Before commit 1075bc4, every scoped
  rule file prepended the full coding-standards header on top of its
  scope-specific content, duplicating ~80 lines against the always-loaded
  orientation. Fixed in `mkDevComposed` by gating `commonFragments` on
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
    Package-specific architecture such as Semble and Stacked Workflows uses the
    package location rather than a parallel dev-only tree.
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
  `config.fragments.categories.<category>.sources`, then run
  `devenv tasks run --mode before generate:all`. WHICH file declares the
  category depends on who owns it: a shared/workspace category lives in
  `config/fragment-categories.nix`, while an owner-specific one lives in that
  package's `registry.nix` (the `claude-code` category above is declared in
  `packages/claude-code/registry.nix`). `lib/facets/registry.nix` merges the two
  sources.
- **New content package published fragment**: create markdown at
  `packages/<pkg>/fragments/<name>.md`, declare in the package's
  `passthru.fragments.<name>` using
  `fragmentsLib.mkFragment { text = builtins.readFile ...; }`. If dev
  instruction files should include it, add to
  `extraPublishedFragments.<category>` in `dev/generate.nix`.
- **New runtime or transform**: it belongs to `ai.*` (a runtime factory and its
  transformer), not to the generator. This repository picks it up by enabling
  the runtime in `dev/ai.nix`.

- **Flat-consumer routing is derived, not curated.** `dev/generate.nix` resolves
  each source entry once for both fragment composition and a rule's
  `references`, and `ai.*` derives AGENTS.md's index from `matcher` and
  `references`. Do not add a parallel Codex-only path/source table: it would be
  a fifth registry and could silently diverge from the scoped runtime files.

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
  gets commonFragments. Scoped categories are intentionally lean. The
  delegate-sizing and stacked-workflow routing rules are separate `ai.*` rules,
  never orientation text. Don't "fix" this by re-adding commonFragments — that's
  the context-rot bug that was removed.
