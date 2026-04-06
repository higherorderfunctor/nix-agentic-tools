# Generated Docs & Task-Based Generation

> Design spec for generating the doc site, repo docs, and instruction
> files via Nix derivations wrapped in devenv tasks.

## Problem

Content is duplicated across doc site pages, README.md, and instruction
files. Data-driven tables (package lists, option references, server
configs) drift when the code changes. The current generation pipeline
(`devenv.nix` `files.*` + `flake.nix` `apps.generate`) only covers
instruction files, not the doc site or README.

## Design Decisions

| Decision                 | Choice                                                                    | Rationale                                                                                 |
| ------------------------ | ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Doc site authoring model | Three-tier: prose copied, reference generated, mixed uses `{{#include}}`  | Prose stays as markdown; data comes from nix; mdbook's native include handles mixed pages |
| Source layout            | Prose in `dev/docs/`, generated output in `docs/src/` (gitignored)        | Single pipeline, clean separation of authored vs generated                                |
| Generation mechanism     | Nix derivations wrapped in devenv tasks                                   | Nix store caching; tasks for dev ergonomics; derivations work in CI                       |
| Task organization        | By scope: `generate:site:*`, `generate:repo:*`, `generate:instructions:*` | Agents target specific scopes; granular rebuild                                           |
| Instruction migration    | Move from `files.*` to devenv tasks                                       | Consistency with new generation tasks                                                     |
| Skills/settings wiring   | Stay in module system (`files.*` / `home.file`)                           | Immutable store content, just symlinked — no generation step                              |
| Caching                  | Nix store handles it — unchanged inputs = store hit                       | No DIY caching needed                                                                     |

## Architecture

### Source Layout

```
dev/
  docs/                              # authored prose (source of truth)
    SUMMARY.md
    index.md
    assets/                          # logo, images
    getting-started/
      choose-your-path.md            # pure prose
      home-manager.md                # mixed ({{#include}} for tables)
      devenv.md                      # mixed
      manual-lib.md                  # pure prose
    concepts/
      unified-ai-module.md           # mixed
      fragments.md                   # mixed
      credentials.md                 # mixed
      config-parity.md               # mixed
    guides/
      stacked-workflows.md           # mixed
    troubleshooting.md               # pure prose
  fragments/                         # dev-only fragments (existing)
    monorepo/
    ai-clis/
    mcp-servers/
    stacked-workflows/

docs/
  src/                               # GITIGNORED — all generated output
  book.toml                          # committed
  .gitignore                         # committed

packages/
  fragments-docs/                    # NEW — doc site transforms + generators
```

Pages NOT in `dev/docs/` are fully generated from nix:

- `concepts/overlays-packages.md`
- `guides/home-manager.md` (options reference)
- `guides/devenv.md` (options reference)
- `guides/mcp-servers.md` (server reference)
- `reference/lib-api.md`
- `reference/types.md`
- `reference/ai-mapping.md`

### Nix Derivations

Each generation output is a Nix derivation, cached by the store:

```
Derivation                  Inputs                           Output
────────────────────────────────────────────────────────────────────
docs-site-prose             dev/docs/**                      $out/ (copied prose + assets)
docs-site-snippets          pkgs, modules, lib               $out/snippets/*.md
docs-site-reference         pkgs, modules, lib               $out/reference/*.md, guides/*.md, etc.
docs-site                   above three                      $out/ (complete docs/src/)
repo-readme                 fragments, pkgs                  $out/README.md
repo-contributing           fragments                        $out/CONTRIBUTING.md
instructions-claude         fragments, transforms            $out/CLAUDE.md
instructions-copilot        fragments, transforms            $out/.github/**
instructions-kiro           fragments, transforms            $out/.kiro/**
instructions-agents         fragments                        $out/AGENTS.md
```

### Devenv Tasks

```
generate:site:prose        nix build .#docs-site-prose      → cp to docs/src/
generate:site:snippets     nix build .#docs-site-snippets   → cp to docs/src/generated/
generate:site:reference    nix build .#docs-site-reference  → cp to docs/src/
generate:site              meta: prose → snippets → reference

generate:repo:readme       nix build .#repo-readme          → cp to ./README.md
generate:repo:contributing nix build .#repo-contributing    → cp to ./CONTRIBUTING.md
generate:repo              meta: readme + contributing

generate:instructions:claude   nix build .#instructions-claude   → cp to ./CLAUDE.md
generate:instructions:copilot  nix build .#instructions-copilot  → cp to .github/
generate:instructions:kiro     nix build .#instructions-kiro     → cp to .kiro/
generate:instructions:agents   nix build .#instructions-agents   → cp to ./AGENTS.md
generate:instructions          meta: all four

generate:all               meta: site + repo + instructions
```

Task dependency ordering within meta tasks matters:

- `generate:site`: prose first (creates directory structure), then
  snippets (data tables), then reference (may reference snippets)
- Others: no ordering constraints within scope

### packages/fragments-docs/

New topic package following the `fragments-ai` pattern:

```nix
pkgs.fragments-docs
  # derivation: doc page templates
  passthru.transforms = {
    page       # { title } → fragment → full markdown page
    section    # { heading, level? } → fragment → markdown section
    table      # { headers, rows } → fragment → markdown table
  }
  passthru.generators = {
    overlayPackages  # pkgs → markdown (overlay + package reference page)
    mcpServers       # pkgs → markdown (per-server reference sections)
    optionsReference # modules → markdown (options tables)
    aiMapping        # modules → markdown (fanout mapping tables)
    libApi           # lib sources → markdown (function reference)
    typesReference   # modules → markdown (type definitions)
    snippets = {
      overlayTable     # pkgs → markdown table snippet
      cliTable         # pkgs → markdown table snippet
      parityMatrix     # modules → markdown table snippet
      aiMappingTable   # modules → markdown table snippet
      serverTable      # pkgs → markdown table snippet
      skillTable       # pkgs → markdown table snippet
    }
  }
```

Generators close over nix-evaluated data and produce complete markdown.
Snippets produce table fragments for `{{#include}}` in mixed pages.

### Mixed Page Example

`dev/docs/getting-started/home-manager.md`:

```markdown
## 2. Apply the overlay

{{#include ../../generated/snippets/overlay-table.md}}

You can also apply individual overlays...
```

The snippet `overlay-table.md` is generated by
`fragments-docs.passthru.generators.snippets.overlayTable` and written
to `docs/src/generated/snippets/overlay-table.md` by the
`docs-site-snippets` derivation.

### What Stays in Module System (`files.*` / `home.file`)

- `.claude/skills/*` — symlinks to store skill directories
- `.github/skills/*`, `.kiro/skills/*` — same
- `.claude/settings.json`, `.claude/settings.local.json`
- `.mcp.json` — MCP server config
- `.copilot/*`, `.kiro/settings/*` — CLI settings
- `.pre-commit-config.yaml` — git hooks config

These are immutable store content, just symlinked — no generation step.

### What Gets Removed

- `devenv.nix` `files.*` entries for: CLAUDE.md, AGENTS.md,
  `.claude/rules/*`, `.github/copilot-instructions.md`,
  `.github/instructions/*`, `.kiro/steering/*`
- `devenv.nix` `mkEcosystemFiles`, `mkEcosystemFile`, `mkDevComposed`,
  `mkDevFragment`, `agentsContent`, and all supporting let bindings
  for instruction composition
- `flake.nix` `apps.generate` — replaced by derivations + tasks
- `docs/src/**` from git tracking — gitignored, generated

### Architecture Dev Fragment

A new dev fragment `dev/fragments/monorepo/generation-architecture.md`
documents the generation pipeline for AI session steering. Gets composed
into CLAUDE.md and AGENTS.md so every session has context about:

- Three-tier doc site model (prose/reference/mixed)
- Task-based generation with nix derivation caching
- Source layout (`dev/docs/` vs `docs/src/`)
- What stays in module system vs what's generated by tasks

## Sub-Phases

### Phase 3a — Instruction task migration

Migrate `files.*` + `apps.generate` to `generate:instructions:*` tasks.
No new content generation — same fragment composition, same transforms,
same output. Verify byte-identical. Removes `mkEcosystemFiles` from
devenv.nix and `apps.generate` from flake.nix.

### Phase 3b — Repo doc generation

Add `generate:repo:*` tasks. README.md generated from fragments + nix
data (package tables, server lists from overlay introspection).
CONTRIBUTING.md generated from fragments. Both committed (front door).
Proves nix data injection pattern.

### Phase 3c — Doc site generation

Create `packages/fragments-docs/`. Move prose to `dev/docs/`. Add
`generate:site:*` tasks. Gitignore `docs/src/`. `generate:all` meta
task. Wire `devenv up docs` to generate then serve.

## Verification

Each sub-phase has its own verification:

- **3a:** Byte-identical instruction files, `devenv test` passes,
  `nix build .#instructions-*` works
- **3b:** README.md contains all current sections with correct data,
  CONTRIBUTING.md exists, both committed
- **3c:** `devenv up docs` serves the site, all pages render, data
  tables match current content, `nix build .#docs-site` works

## Risks

**Scope:** This is a large refactor touching devenv.nix, flake.nix,
the entire doc site, and README. Sub-phasing mitigates — each phase
is independently testable.

**Hot reload latency:** `generate:site:prose` is a copy (~instant).
`generate:site:snippets` requires nix eval (~300ms). Acceptable.

**mdbook include paths:** `{{#include}}` paths are relative to the
markdown file's location in `docs/src/`. Must calculate paths correctly
from each mixed page to `generated/snippets/`.

**Derivation rebuilds:** If fragments change, all instruction
derivations rebuild. This is correct behavior — fragment changes
should propagate everywhere.
