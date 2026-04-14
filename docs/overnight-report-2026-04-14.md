<!-- TODO: remove this file before merging to main -->

# Session Report — 2026-04-13/14

## CI Update Pipeline — Working

Renovate-style per-dependency PRs operational. 6/7 PRs passed CI on
both platforms. The 1 failure (nuscht-search) was a pre-existing docs
build bug (unescaped mdbook include directive) — now fixed.

Key fixes landed today:

- IFD warm step: `nix eval --apply mapAttrs p.version` (not attrNames — lazy!)
- Removed redundant `nix flake check --no-build` from ci.yml (IFD incompatible)
- Base SHA comparison for worktree branches (prevents rogue PRs)
- PR title updates on existing PRs
- Prevent amending base commit when no update exists
- treefmt pre-commit hook added (was missing — only ran on shell entry)
- Docs build fix (escaped mdbook include in fragment prose)
- Cleaned debug workarounds (NIX_CONFIG, prefetch_sources)

## Knowledge Codification

5 agents extracted learnings into fragments + groomed backlog/memories:

**New fragments (fan out to all AI ecosystem instructions):**

- `overlays/ifd-patterns.md` — IFD eval gotchas, CI warm step, .drv locality
- `overlays/unfree-guard.md` — ensureUnfreeCheck pattern
- `pipeline/update-pipeline.md` — ninja DAG, worktree isolation, rev bump flow
- `pipeline/ci-update-workflow.md` — Renovate PRs, App token, warm step

**Updated:** `devenv/files-internals.md` — instruction auto-regen via gen import

**Backlog groomed:** (-3000 lines)

- Removed completed nvfetcher section, historical status, superpowers specs
- Folded human-todo.md items into plan.md
- Added: cachix override warnings, git-branchless migration
- Updated stale nvfetcher references in remaining items

**Memories groomed:**

- 9 previously unlisted files indexed in MEMORY.md
- 4 update pipeline design files moved to stale section
- CI v4 design rewritten for implemented Renovate model
- Plan state updated to current branch/status

## Additional overnight work

**Bun runtime switch** — 7 JS-based MCP servers switched from node
to bun runtime wrappers (git-intel-mcp, openmemory-mcp, effect-mcp,
filesystem-mcp, memory-mcp, sequential-thinking-mcp). Build tools
(npm/pnpm) unchanged. All builds verified. Removed unused nodejs
from inherit bindings.

**gitleaks pre-commit hook** — added `gitleaks protect --staged` for
secret scanning. Uses nixpkgs gitleaks package.

**cspell plural research** — no automatic plural support. Must add
both forms explicitly. Closed the backlog item.

**Backlog items marked done:**

- Bun runtime switch (runtime only, build migration deferred)
- gitleaks secret scanning
- cspell plural research
- Unfree guard documentation (fragment created)
- CI GITHUB_TOKEN workaround (GitHub App)
- CI v4 implementation (Renovate-style)
- Single source of truth for inputs (generate-devenv-yaml.nix)

## State

Branch: `refactor/ai-factory-architecture` at `d3b0415`
All checks pass locally.
