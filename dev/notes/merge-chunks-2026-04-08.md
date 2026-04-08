# Sentinel → Main Merge: Chunk Proposal (2026-04-08)

Produced by Phase 2 Task 2.1 of
`docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md`.
This proposal groups every tracked file in the sentinel tip
(commit `31590a3`, mirrored in `sentinel/main-catchup-2026-04-08`
at commit `9fb7874`) into 17 bottom-up chunks for the PR
extraction loop.

## Summary

- **Total tracked files in sentinel tip:** 207 (206 added or
  modified vs `origin/main`, plus `LICENSE` which is unchanged
  from main and therefore NOT part of any chunk)
- **Total diff vs `origin/main`:** 38,116 insertions, 16
  deletions, 206 files
- **Total chunks:** 17
- **Chunks flagged for size review:** 3
  (Chunk 6 large-but-cohesive, Chunk 4 split candidate, Chunk 9
  small)

## Chunking strategy

Bottom-up by dependency order. Each chunk bundles its own files
plus the `flake.nix` edit that registers them with the flake
outputs — **option (c)** from the merge plan. `flake.nix`,
`dev/generate.nix`, `devenv.nix`, `nvfetcher.toml`, and
`.nvfetcher/generated.{nix,json}` all grow incrementally across
chunks and are listed under **"files modified"** in every chunk
that touches them.

No forward references between chunks. No docs-only catchup
commits — docs travel with their feature chunk.

## Shared files that grow across chunks

- `flake.nix` — edited by almost every chunk. Each chunk adds
  only the outputs for the files it introduces. Chunk 1 lands
  the minimal scaffold (inputs, `supportedSystems`, empty
  `overlays`/`packages`/`homeManagerModules`/`devenvModules`/
  `lib`/`checks`).
- `flake.lock` — frozen once at Chunk 1. No later chunk should
  touch it unless an input is added.
- `devenv.nix` — Chunk 1 lands a minimal version (just the base
  devenv imports + cachix pull + dev tools). Chunks 8, 9, 10,
  and 14 extend it with overlay-package usage, `ai.*` config,
  `modules/devenv` import, and tooling wiring respectively.
- `dev/generate.nix` — Chunk 3 lands it with a **minimal**
  `devFragmentNames` covering only `monorepo`, `flake`,
  `packaging`, `nix-standards`, `pipeline` (the categories
  whose fragment files also land in Chunk 3). Later chunks
  that add more dev fragments also edit `devFragmentNames` and
  `packagePaths` to register them (otherwise
  `builtins.readFile` in `mkDevFragment` fails at eval time
  because the referenced file doesn't exist yet).
- `nvfetcher.toml` — grows across Chunks 5, 6, 7. Chunk 5
  adds the 4 git-tools Rust packages, Chunk 6 adds the 14
  MCP server entries, Chunk 7 adds the 4 AI CLI entries.
- `.nvfetcher/generated.nix` + `.nvfetcher/generated.json` —
  grow incrementally in lockstep with `nvfetcher.toml`.
  Regenerate via `nix run .#update` (or `nvfetcher` directly)
  at the time each overlay chunk is being prepared, using that
  chunk's version of `nvfetcher.toml`.

## Chunk list

### Chunk 1: Flake scaffold + pre-commit hooks

- **Slug:** `flake-scaffold`
- **PR title:** `chore(flake): scaffold monorepo flake, devenv, and pre-commit`
- **Rationale:** First chunk. Creates the flake skeleton that
  every subsequent chunk extends. Without this, `nix flake
check` can't even parse. Produces a `flake.nix` with all
  inputs declared but empty outputs (no overlays, no packages,
  no modules, no lib yet).
- **Dependencies:** none (first chunk)
- **Lines (rough):** ~1,617 (dominated by `flake.lock` at 381
  and `.cspell/project-terms.txt` at 142)
- **Files added:**
  - `.agnix.toml` (26)
  - `.cspell/project-terms.txt` (142)
  - `.envrc` (5)
  - `.gitignore` (39)
  - `cspell.json` (28)
  - `devenv.lock` (300)
  - `devenv.nix` — **scaffold version only** (base imports,
    cachix pull, dev tools; NO `ai.*` config, NO overlay
    packages yet)
  - `devenv.yaml` (16)
  - `flake.lock` (381)
  - `flake.nix` — **scaffold version** (all `inputs`, empty
    `overlays.default`, empty `packages`/`homeManagerModules`/
    `devenvModules`/`lib`/`checks`)
  - `treefmt.nix` (32)

### Chunk 2: Shared lib primitives + devshell modules

- **Slug:** `lib-primitives`
- **PR title:** `feat(lib): add fragments, hm-helpers, types, mcp, and devshell primitives`
- **Rationale:** Pure lib functions and the standalone devshell
  modules that every downstream package and module depends on.
  `lib/devshell.nix` imports `../devshell/*.nix`, so
  `devshell/*` travels with `lib/` in the same chunk. No
  derivations, no options, no test infra yet.
- **Dependencies:** Chunk 1
- **Lines (rough):** ~1,332
- **Files added:**
  - `devshell/files.nix`
  - `devshell/instructions/default.nix`
  - `devshell/mcp-servers/default.nix`
  - `devshell/skills/stacked-workflows.nix`
  - `devshell/top-level.nix`
  - `lib/ai-common.nix`
  - `lib/buddy-types.nix`
  - `lib/devshell.nix`
  - `lib/fragments.nix`
  - `lib/hm-helpers.nix`
  - `lib/mcp.nix`
  - `lib/options-doc.nix`
- **Files modified:**
  - `flake.nix` — populate the `lib` output attrset with
    `fragments`/`presets`/`compose`/`mkFragment`/`mkFrontmatter`/
    `render`/`mcpLib`/`mkAgenticShell`/`mkMcpConfig`/`mapTools`/
    `externalServers`/`gitConfig`/`gitConfigFull`. Note:
    `gitConfig`/`gitConfigFull` reference
    `./modules/stacked-workflows/git-config*.nix` which don't
    exist until Chunk 8 — **land those two re-exports in Chunk
    8 instead, not Chunk 2**. Also note: `lib.presets` reads
    from `packages/coding-standards` and
    `packages/stacked-workflows`, so defer `presets` to Chunk 4. Chunk 2's `lib` output is the subset that doesn't
    depend on later chunks.

### Chunk 3: Fragment pipeline + fragments-ai transforms

- **Slug:** `fragment-pipeline`
- **PR title:** `feat(fragments): add fragments-ai transforms and dev/generate pipeline`
- **Rationale:** The fragment composition and transformation
  pipeline. Lands `packages/fragments-ai/` (pure data-driven
  Nix, no derivations for compiled code), the always-loaded
  monorepo fragments, and the scoped fragment categories whose
  fragment-source files travel with this chunk. Chunk 3's
  `devFragmentNames` is minimal (only categories whose files
  exist now); later chunks ADD to it as they land their own
  scoped fragments.
- **Dependencies:** Chunks 1, 2 (needs `lib/fragments.nix`)
- **Lines (rough):** ~1,625
- **Files added:**
  - `dev/fragments/flake/binary-cache.md`
  - `dev/fragments/monorepo/architecture-fragments.md`
  - `dev/fragments/monorepo/build-commands.md`
  - `dev/fragments/monorepo/change-propagation.md`
  - `dev/fragments/monorepo/linting.md`
  - `dev/fragments/monorepo/project-overview.md`
  - `dev/fragments/nix-standards/nix-standards.md`
  - `dev/fragments/packaging/naming-conventions.md`
  - `dev/fragments/packaging/platforms.md`
  - `dev/fragments/pipeline/fragment-pipeline.md`
  - `dev/fragments/pipeline/generation-architecture.md`
  - `dev/generate.nix` — **reduced form**: `devFragmentNames`
    initially covers only `monorepo`, `flake`, `packaging`,
    `nix-standards`, `pipeline`. `extraPublishedFragments`
    starts empty or lists only coding-standards (which lands
    in Chunk 4 — defer adding it until then).
  - `dev/tasks/generate.nix`
  - `packages/fragments-ai/default.nix`
  - `packages/fragments-ai/templates/claude.md`
  - `packages/fragments-ai/templates/copilot.md`
  - `packages/fragments-ai/templates/kiro.md`
- **Files modified:**
  - `flake.nix` — add `overlays.fragments-ai` and
    compose into `overlays.default`; add
    `packages.instructions-{agents,claude,copilot,kiro}`
    derivations; add devenv import of `dev/tasks/generate.nix`
    (or wire the task set another way).
  - `devenv.nix` — import `dev/tasks/generate.nix` so
    `devenv tasks run generate:instructions:*` works.

### Chunk 4: Content packages (coding-standards, stacked-workflows, fragments-docs)

- **Slug:** `content-packages`
- **PR title:** `feat(packages): add coding-standards, stacked-workflows, and fragments-docs content packages`
- **Rationale:** Content-only packages (markdown fragments and
  content derivations). No compiled code, no dependency hashes.
  These produce the `pkgs.coding-standards`,
  `pkgs.stacked-workflows-content`, and `pkgs.fragments-docs`
  derivations that `dev/generate.nix` consumes via
  `passthru.fragments` and that the HM
  `modules/stacked-workflows/` consumes via
  `passthru.skillsDir`. Bundles `packages/fragments-docs/` (the
  page generators for the docsite) here rather than splitting
  because `fragments-docs/default.nix` is the logical home for
  its `pages/` directory and the page generators aren't used
  by any chunk before Chunk 12.
- **Dependencies:** Chunks 1, 2, 3
- **Lines (rough):** ~4,730 (coding-standards ~121,
  stacked-workflows ~3,709, fragments-docs ~900)
- **Files added (coding-standards):**
  - `packages/coding-standards/default.nix`
  - `packages/coding-standards/fragments/coding-standards.md`
  - `packages/coding-standards/fragments/commit-convention.md`
  - `packages/coding-standards/fragments/config-parity.md`
  - `packages/coding-standards/fragments/tooling-preference.md`
  - `packages/coding-standards/fragments/validation.md`
- **Files added (stacked-workflows):**
  - `packages/stacked-workflows/default.nix`
  - `packages/stacked-workflows/fragments/routing-table.md`
  - `packages/stacked-workflows/references/git-absorb.md`
  - `packages/stacked-workflows/references/git-branchless.md`
  - `packages/stacked-workflows/references/git-revise.md`
  - `packages/stacked-workflows/references/nix-workflow.md`
  - `packages/stacked-workflows/references/philosophy.md`
  - `packages/stacked-workflows/references/recommended-config.md`
  - `packages/stacked-workflows/skills/stack-fix/SKILL.md`
  - `packages/stacked-workflows/skills/stack-fix/references/git-absorb.md`
    (symlink → `../../../references/git-absorb.md`)
  - `packages/stacked-workflows/skills/stack-fix/references/git-branchless.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-plan/SKILL.md`
  - `packages/stacked-workflows/skills/stack-plan/references/git-branchless.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-plan/references/philosophy.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-split/SKILL.md`
  - `packages/stacked-workflows/skills/stack-split/references/git-branchless.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-split/references/philosophy.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-submit/SKILL.md`
  - `packages/stacked-workflows/skills/stack-submit/references/git-branchless.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-summary/SKILL.md`
  - `packages/stacked-workflows/skills/stack-summary/references/git-branchless.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-summary/references/philosophy.md`
    (symlink)
  - `packages/stacked-workflows/skills/stack-test/SKILL.md`
  - `packages/stacked-workflows/skills/stack-test/references/git-branchless.md`
    (symlink)
- **Files added (fragments-docs):**
  - `packages/fragments-docs/default.nix`
  - `packages/fragments-docs/pages/ai-mapping.md`
  - `packages/fragments-docs/pages/devenv-footer.md`
  - `packages/fragments-docs/pages/devenv-header.md`
  - `packages/fragments-docs/pages/home-manager-footer.md`
  - `packages/fragments-docs/pages/home-manager-header.md`
  - `packages/fragments-docs/pages/lib-api.md`
  - `packages/fragments-docs/pages/types.md`
- **Files modified:**
  - `flake.nix` — add `overlays.{coding-standards,
stacked-workflows, fragments-docs}` and compose into
    `overlays.default`; add `packages.{coding-standards,
fragments-ai, fragments-docs, stacked-workflows-content,
repo-readme, repo-contributing}` derivations.
  - `dev/generate.nix` — populate
    `extraPublishedFragments.monorepo` and
    `extraPublishedFragments.stacked-workflows` with
    `swsFragments`; read `commonFragments` from
    `pkgs.coding-standards.passthru.fragments`.
  - `lib` output in `flake.nix` — add `presets.nix-agentic-tools-dev`
    which composes coding-standards + sws fragments (could
    not exist before Chunk 4).

### Chunk 5: Overlay — git-tools

- **Slug:** `overlay-git-tools`
- **PR title:** `feat(git-tools): add agnix, git-absorb, git-branchless, git-revise overlay`
- **Rationale:** First compiled overlay. Introduces the
  **`ourPkgs` cache-hit-parity pattern** described in
  `dev/fragments/overlays/cache-hit-parity.md` (note: fragment
  file lands in Chunk 15; the pattern itself is load-bearing
  here but requires no architecture fragment to work). Adds
  `rust-overlay` as a compose target for the Rust packages.
- **Dependencies:** Chunks 1 (flake inputs), 2 (nothing from
  lib is actually used but the compose-ability matters)
- **Lines (rough):** ~218 (+ nvfetcher entries)
- **Files added:**
  - `packages/git-tools/agnix.nix`
  - `packages/git-tools/default.nix`
  - `packages/git-tools/git-absorb.nix`
  - `packages/git-tools/git-branchless.nix`
  - `packages/git-tools/git-revise.nix`
  - `packages/git-tools/hashes.json`
  - `packages/git-tools/sources.nix`
- **Files modified:**
  - `flake.nix` — add `overlays.git-tools`, compose into
    `overlays.default`, expose `packages.{agnix, git-absorb,
git-branchless, git-revise}`.
  - `nvfetcher.toml` — add `[agnix]`, `[git-absorb]`,
    `[git-branchless]`, `[git-revise]` entries (4 sections).
  - `.nvfetcher/generated.nix` — regenerate from the new
    `nvfetcher.toml`.
  - `.nvfetcher/generated.json` — regenerate.
  - `devenv.nix` — start consuming `agnix` from the git-tools
    overlay (the `gitToolsPkgs = pkgs.extend ...` block and
    `inherit (gitToolsPkgs) agnix;` + adding `agnix` to
    `packages`).

### Chunk 6: Overlay — mcp-servers (14 packages, single PR)

- **Slug:** `overlay-mcp-servers`
- **PR title:** `feat(mcp-servers): add mcp-servers overlay with 14 server packages`
- **Rationale:** Single PR for all 14 MCP server packages
  because splitting produces N tiny PRs with identical shape
  (same overlay composition, same `sources.nix` merge, same
  `hashes.json` sidecar). They share `default.nix`/
  `sources.nix`/`hashes.json` and the overlay composition at
  the `packages.nix-mcp-servers.*` level — splitting would
  require either N incremental PRs that each touch the same
  shared files or an awkward per-language split (npm / Python
  / Go). The bulk of the line count is vendored npm lockfiles
  (4 files, ~14,100 lines), which are essentially
  review-passthrough.
- **Dependencies:** Chunks 1, 5 (shares the `ourPkgs` pattern
  established in git-tools)
- **Lines (rough):** ~14,609 total; ~14,121 are generated
  lockfiles; ~488 are hand-written Nix + hashes + a small
  `sources.nix`
- **Files added:**
  - `packages/mcp-servers/context7-mcp.nix`
  - `packages/mcp-servers/default.nix`
  - `packages/mcp-servers/effect-mcp.nix`
  - `packages/mcp-servers/fetch-mcp.nix`
  - `packages/mcp-servers/git-intel-mcp.nix`
  - `packages/mcp-servers/git-mcp.nix`
  - `packages/mcp-servers/github-mcp.nix`
  - `packages/mcp-servers/hashes.json`
  - `packages/mcp-servers/kagi-mcp.nix`
  - `packages/mcp-servers/locks/context7-mcp-package-lock.json`
  - `packages/mcp-servers/locks/git-intel-mcp-package-lock.json`
  - `packages/mcp-servers/locks/openmemory-mcp-package-lock.json`
  - `packages/mcp-servers/locks/sequential-thinking-mcp-package-lock.json`
  - `packages/mcp-servers/mcp-language-server.nix`
  - `packages/mcp-servers/mcp-proxy.nix`
  - `packages/mcp-servers/nixos-mcp.nix`
  - `packages/mcp-servers/openmemory-mcp.nix`
  - `packages/mcp-servers/sequential-thinking-mcp.nix`
  - `packages/mcp-servers/serena-mcp.nix`
  - `packages/mcp-servers/sources.nix`
  - `packages/mcp-servers/sympy-mcp.nix`
- **Files modified:**
  - `flake.nix` — add `overlays.mcp-servers`, compose into
    `overlays.default`, add the `inherit (pkgs.nix-mcp-servers)
context7-mcp effect-mcp ...` block to `packages`.
  - `nvfetcher.toml` — add 14 MCP entries (context7-mcp,
    effect-mcp, github-mcp-server, git-intel-mcp, kagiapi,
    kagimcp, mcp-language-server, mcp-proxy, mcp-server-fetch,
    mcp-server-git, openmemory-mcp, sequential-thinking-mcp,
    sympy-mcp, and serena is sourced via `inputs.serena`).
  - `.nvfetcher/generated.nix` — regenerate.
  - `.nvfetcher/generated.json` — regenerate.

### Chunk 7: Overlay — ai-clis (claude-code, copilot-cli, kiro-cli, kiro-gateway, any-buddy)

- **Slug:** `overlay-ai-clis`
- **PR title:** `feat(ai-clis): add claude-code, copilot-cli, kiro-cli, kiro-gateway, any-buddy overlay`
- **Rationale:** Introduces the AI CLI packages including the
  claude-code wrapper chain (nixpkgs base → Bun wrapper) and
  the any-buddy worker. Does NOT include
  `packages/ai-clis/fragments/dev/*.md` (those land in Chunk
  15 alongside the scoped `claude-code` fragment registration).
- **Dependencies:** Chunks 1, 5 (`ourPkgs` pattern)
- **Lines (rough):** ~671
- **Files added:**
  - `packages/ai-clis/any-buddy.nix`
  - `packages/ai-clis/claude-code.nix`
  - `packages/ai-clis/copilot-cli.nix`
  - `packages/ai-clis/default.nix`
  - `packages/ai-clis/hashes.json`
  - `packages/ai-clis/kiro-cli.nix`
  - `packages/ai-clis/kiro-gateway.nix`
  - `packages/ai-clis/locks/claude-code-package-lock.json`
  - `packages/ai-clis/sources.nix`
- **Files modified:**
  - `flake.nix` — add `overlays.ai-clis`, compose into
    `overlays.default`, add `inherit (pkgs) any-buddy
claude-code github-copilot-cli kiro-cli kiro-gateway;`.
  - `nvfetcher.toml` — add `[any-buddy]`, `[claude-code]`,
    `[github-copilot-cli]`, `[kiro-cli]`, `[kiro-cli-darwin]`,
    `[kiro-gateway]` entries.
  - `.nvfetcher/generated.nix` — regenerate.
  - `.nvfetcher/generated.json` — regenerate.

### Chunk 8: HM modules — ecosystem CLIs (copilot, kiro, mcp, buddy, stacked-workflows)

- **Slug:** `hm-ecosystem-modules`
- **PR title:** `feat(modules): add copilot-cli, kiro-cli, mcp-servers, claude-code-buddy, stacked-workflows HM modules`
- **Rationale:** First wave of HM modules — ecosystem-specific
  options that wrap the underlying packages. Includes the
  stacked-workflows module (which references
  `packages/stacked-workflows` via passthru.skillsDir — added
  in Chunk 4) and the claude-code-buddy module (which consumes
  the any-buddy worker from Chunk 7). Each module is wired
  into `homeManagerModules.<name>` on the flake output.
- **Dependencies:** Chunks 1, 2, 4, 5, 6, 7
- **Lines (rough):** ~2,428 (mcp-servers HM module is the
  largest contributor at ~1,200 lines via 12 server .nix files)
- **Files added:**
  - `modules/claude-code-buddy/default.nix`
  - `modules/copilot-cli/default.nix`
  - `modules/kiro-cli/default.nix`
  - `modules/mcp-servers/default.nix`
  - `modules/mcp-servers/servers/context7-mcp.nix`
  - `modules/mcp-servers/servers/effect-mcp.nix`
  - `modules/mcp-servers/servers/fetch-mcp.nix`
  - `modules/mcp-servers/servers/git-intel-mcp.nix`
  - `modules/mcp-servers/servers/git-mcp.nix`
  - `modules/mcp-servers/servers/github-mcp.nix`
  - `modules/mcp-servers/servers/kagi-mcp.nix`
  - `modules/mcp-servers/servers/nixos-mcp.nix`
  - `modules/mcp-servers/servers/openmemory-mcp.nix`
  - `modules/mcp-servers/servers/sequential-thinking-mcp.nix`
  - `modules/mcp-servers/servers/serena-mcp.nix`
  - `modules/mcp-servers/servers/sympy-mcp.nix`
  - `modules/stacked-workflows/default.nix`
  - `modules/stacked-workflows/git-config-full.nix`
  - `modules/stacked-workflows/git-config.nix`
- **Files modified:**
  - `flake.nix` — add
    `homeManagerModules.{claude-code-buddy, copilot-cli,
kiro-cli, mcp-servers, stacked-workflows}`; add
    `lib.gitConfig`/`lib.gitConfigFull` re-exports (deferred
    from Chunk 2 because they reference files in this chunk).

### Chunk 9: HM module — unified `ai` module

- **Slug:** `hm-ai-module`
- **PR title:** `feat(modules/ai): add unified ai module with per-ecosystem fanout`
- **Rationale:** The unified `ai.*` HM module that fans config
  out to the per-ecosystem modules from Chunk 8. Also lands
  `modules/default.nix` — the top-level module registrar that
  imports all HM modules together. Small chunk, but logically
  distinct from Chunk 8 because it depends on all the
  ecosystem modules existing first. Does NOT include
  `modules/ai/fragments/dev/ai-module-fanout.md` — that lands
  in Chunk 15 along with the scoped `ai-module`
  `devFragmentNames` entry.
- **Dependencies:** Chunks 1, 2, 3, 7, 8
- **Lines (rough):** ~296
- **Files added:**
  - `modules/ai/default.nix`
  - `modules/default.nix`
- **Files modified:**
  - `flake.nix` — add `homeManagerModules.ai` and
    `homeManagerModules.default = ./modules;`.

### Chunk 10: DevEnv modules

- **Slug:** `devenv-modules`
- **PR title:** `feat(modules/devenv): add devenv module counterparts for ai, copilot, kiro, mcp, claude-code-skills`
- **Rationale:** devenv counterparts to the HM modules. Option
  parity with Chunk 8/9 per the config-parity rule. Includes
  the devenv scoped fragment (`files-internals.md`) because
  the fragment documents the devenv `files.*` option directly
  and the `devFragmentNames.devenv` entry lands with it.
- **Dependencies:** Chunks 1, 2, 3, 8, 9
- **Lines (rough):** ~775
- **Files added:**
  - `dev/fragments/devenv/files-internals.md`
  - `modules/devenv/ai.nix`
  - `modules/devenv/claude-code-skills/default.nix`
  - `modules/devenv/copilot.nix`
  - `modules/devenv/default.nix`
  - `modules/devenv/kiro.nix`
  - `modules/devenv/mcp-common.nix`
- **Files modified:**
  - `flake.nix` — add `devenvModules.{ai, claude-code-skills,
copilot, default, kiro}` output.
  - `dev/generate.nix` — add `"devenv"` to `devFragmentNames`
    (`devFragmentNames.devenv = ["files-internals"];`) and add
    the corresponding `packagePaths.devenv` scope.
  - `devenv.nix` — add the `imports = [./modules/devenv];`
    line and populate the `ai = { claude.enable = true; ... }`
    block.

### Chunk 11: Checks (module-eval, devshell-eval, cache-hit-parity)

- **Slug:** `checks`
- **PR title:** `test(checks): add module-eval, devshell-eval, and cache-hit-parity checks`
- **Rationale:** Evaluation-only checks that exercise the HM
  and devenv modules. Includes `cache-hit-parity.nix` which
  requires the `inputs.nixpkgs-test` second nixpkgs pin (the
  single flake input addition in this entire merge, after
  Chunk 1's initial input set). This is the one chunk that
  adds to `inputs` and is explicitly called out in the plan.
- **Dependencies:** Chunks 1, 2, 5, 6, 7, 8, 9, 10
- **Lines (rough):** ~533
- **Files added:**
  - `checks/cache-hit-parity.nix`
  - `checks/devshell-eval.nix`
  - `checks/module-eval.nix`
- **Files modified:**
  - `flake.nix` — add `inputs.nixpkgs-test.url =
"github:NixOS/nixpkgs/master";`; wire
    `checks = forAllSystems (...)` to compose
    `moduleChecks // devshellChecks // parityChecks`.
  - `flake.lock` — add the nixpkgs-test lock entry.
    **Exception to "flake.lock frozen at Chunk 1" — this is
    the only chunk that touches it intentionally.**

### Chunk 12: Doc site — prose + structure

- **Slug:** `docs-site-prose`
- **PR title:** `docs(site): add mdbook prose (getting-started, concepts, guides, troubleshooting)`
- **Rationale:** mdbook scaffolding and authored prose. Just
  the static markdown + mdbook config + the
  `packages.docs-site-prose` derivation that copies `dev/docs/`
  into the store. Does NOT build the full site — the full
  `packages.docs` assembly lands in Chunk 13.
- **Dependencies:** Chunks 1, 4 (fragments-docs package
  exists)
- **Lines (rough):** ~1,744
- **Files added:**
  - `dev/docs/SUMMARY.md`
  - `dev/docs/assets/favicon.png`
  - `dev/docs/assets/logo.png`
  - `dev/docs/concepts/config-parity.md`
  - `dev/docs/concepts/credentials.md`
  - `dev/docs/concepts/fragments.md`
  - `dev/docs/concepts/unified-ai-module.md`
  - `dev/docs/getting-started/choose-your-path.md`
  - `dev/docs/getting-started/devenv.md`
  - `dev/docs/getting-started/home-manager.md`
  - `dev/docs/getting-started/manual-lib.md`
  - `dev/docs/guides/buddy-customization.md`
  - `dev/docs/guides/stacked-workflows.md`
  - `dev/docs/index.md`
  - `dev/docs/troubleshooting.md`
  - `docs/.gitignore`
  - `docs/book.toml`
- **Files modified:**
  - `flake.nix` — add `packages.docs-site-prose` and
    `packages.docs-site-snippets`.

### Chunk 13: Doc site — generators assembly (`packages.docs`)

- **Slug:** `docs-site-generators`
- **PR title:** `feat(docs): assemble docs site with reference pages, options search, and architecture fragments`
- **Rationale:** The full docsite assembly: `packages.docs`,
  `packages.docs-site-reference`, `packages.docs-options-*`,
  NuschtOS options search wiring, and the
  `siteArchitecture` runCommand that bundles architecture
  fragments as contributing pages. Depends on Chunk 15's
  architecture fragments being in place because
  `siteArchitecture` copies from
  `dev/fragments/{monorepo, pipeline, overlays, hm-modules,
ai-skills, devenv}/*.md` and
  `packages/ai-clis/fragments/dev/*.md` and
  `modules/ai/fragments/dev/ai-module-fanout.md`. **Order
  reconsideration: Chunk 13 must come AFTER Chunk 15** so
  the architecture fragments exist when `siteArchitecture`
  evaluates them. Flag this as an ordering concern — see
  "Open questions".
- **Dependencies:** Chunks 1, 3, 4, 12, AND Chunk 15 (for
  architecture fragments that `siteArchitecture` copies)
- **Lines (rough):** very small (~0 new files; this is
  nearly pure `flake.nix` edits)
- **Files added:** none (all source files already land in
  Chunks 4, 10, 12, 15)
- **Files modified:**
  - `flake.nix` — add `packages.docs`, `packages.docs-site`,
    `packages.docs-site-reference`, `packages.docs-options-hm`,
    `packages.docs-options-devenv`, `packages.docs-options-search`,
    and the `siteArchitecture` runCommand.

### Chunk 14: Dev helpers and scripts

- **Slug:** `dev-helpers`
- **PR title:** `chore(dev): add dev helpers, references, scripts, and internal skills`
- **Rationale:** Dev-only tooling that doesn't affect consumer
  output: internal skills (`index-repo-docs`, `repo-review`),
  reference docs, the context-budget measurement script, the
  `dev/update.nix` runner, the `dev/data.nix` data source used
  by `fragments-docs` generators, and the non-merge-specific
  `dev/notes/`. `dev/notes/` contains pre-existing design
  notes and the `pr-template.md`. The merge-specific
  `merge-chunks-2026-04-08.md` (this file) is sentinel-only
  and does NOT land in any chunk — see "Open questions".
- **Dependencies:** Chunks 1, 4 (`dev/data.nix` is read by
  the `fragments-docs` generators at flake eval time but only
  from the `packages.docs*` derivations landed in Chunks
  12/13, not from chunk 4 itself — so chunk 4 is technically
  enough)
- **Lines (rough):** ~2,831
- **Files added:**
  - `dev/data.nix`
  - `dev/notes/claude-code-npm-contingency.md`
  - `dev/notes/overlay-cache-hit-parity-fix.md`
  - `dev/notes/pr-template.md`
  - `dev/notes/steering-research.md`
  - `dev/references/agnix.md`
  - `dev/references/config-parity.md`
  - `dev/scripts/measure-context.sh`
  - `dev/skills/index-repo-docs/SKILL.md`
  - `dev/skills/repo-review/SKILL.md`
  - `dev/skills/repo-review/personalities/agentic-ux.md`
  - `dev/skills/repo-review/personalities/consistency-auditor.md`
  - `dev/skills/repo-review/personalities/fp-dry-expert.md`
  - `dev/skills/repo-review/personalities/git-expert.md`
  - `dev/skills/repo-review/personalities/human-ux.md`
  - `dev/skills/repo-review/personalities/nix-expert.md`
  - `dev/skills/repo-review/references/config-parity.md`
    (symlink → `../../../references/config-parity.md`)
  - `dev/skills/repo-review/references/git-absorb.md` (symlink)
  - `dev/skills/repo-review/references/git-branchless.md`
    (symlink)
  - `dev/skills/repo-review/references/git-revise.md` (symlink)
  - `dev/skills/repo-review/references/philosophy.md` (symlink)
  - `dev/skills/repo-review/references/recommended-config.md`
    (symlink → `../../../../packages/stacked-workflows/references/recommended-config.md`)
  - `dev/skills/repo-review/review-policy.md`
  - `dev/update.nix`
- **Files modified:**
  - `flake.nix` — add `apps.update = ...;` entry that wraps
    `dev/update.nix` (if the current tip exposes it as a
    flake app — verify at chunk prep time).
  - `devenv.nix` — wire `dev/skills/*` into
    `ai.skills.{index-repo-docs, repo-review}` (these are
    dev-only consumer-side skills). This piece depends on
    Chunk 10 (devenv modules) already being merged.

### Chunk 15: Architecture fragments (scoped)

- **Slug:** `architecture-fragments`
- **PR title:** `docs(fragments): add scoped architecture fragments for AI CLIs, HM modules, MCP overlays, and stacked workflows`
- **Rationale:** Scoped architecture fragments that document
  shapes-of-abstractions, cross-cutting invariants, and known
  pitfalls for the modules and packages already landed. These
  are the `packages/<pkg>/fragments/dev/` and
  `modules/<subdir>/fragments/dev/` co-located fragments PLUS
  the dev-only `dev/fragments/<category>/` fragments that
  weren't needed for the initial pipeline in Chunk 3. Each
  fragment registration requires a corresponding
  `devFragmentNames.<category>` entry and `packagePaths.<category>`
  scope edit to `dev/generate.nix`.
- **Dependencies:** Chunks 3, 7, 9, 8, 5, 6, 4 (the files
  they document must already exist)
- **Lines (rough):** ~1,259
- **Files added:**
  - `dev/fragments/ai-clis/packaging-guide.md`
  - `dev/fragments/ai-skills/skills-fanout-pattern.md`
  - `dev/fragments/hm-modules/module-conventions.md`
  - `dev/fragments/mcp-servers/overlay-guide.md`
  - `dev/fragments/overlays/cache-hit-parity.md`
  - `dev/fragments/stacked-workflows/development.md`
  - `modules/ai/fragments/dev/ai-module-fanout.md`
  - `packages/ai-clis/fragments/dev/buddy-activation.md`
  - `packages/ai-clis/fragments/dev/claude-code-wrapper.md`
- **Files modified:**
  - `dev/generate.nix` — add
    `devFragmentNames.{ai-clis, ai-module, ai-skills,
claude-code, hm-modules, mcp-servers, overlays,
stacked-workflows}` entries (with the correct
    `location`/`dir` metadata for package- and module-scoped
    fragments); add the corresponding `packagePaths.*`
    scopes.

### Chunk 16: CI workflows

- **Slug:** `ci-workflows`
- **PR title:** `ci: add build, docs, and update workflows`
- **Rationale:** GitHub Actions workflows for building
  packages, deploying the docsite to GitHub Pages, and running
  nvfetcher updates on a schedule. Lands last-ish because it
  needs all the package/module chunks and all the doc-site
  infrastructure to be in place to actually pass CI.
- **Dependencies:** Chunks 1-15 (CI runs flake check + package
  builds)
- **Lines (rough):** ~258
- **Files added:**
  - `.github/workflows/ci.yml`
  - `.github/workflows/docs.yml`
  - `.github/workflows/update.yml`

### Chunk 17: Top-of-tree meta (instructions, docs, plan)

- **Slug:** `meta-docs`
- **PR title:** `docs: add CLAUDE.md, AGENTS.md, README.md, CONTRIBUTING.md, and sentinel plan`
- **Rationale:** The top-of-tree instruction/README files that
  should only land once everything they describe is actually
  in the repo. `LICENSE` is already on `origin/main` from an
  earlier PR and is NOT added here. `README.md` and
  `CONTRIBUTING.md` are the committed versions — they're
  generated by `nix run .#generate` but committed for GitHub
  rendering. `CLAUDE.md` and `AGENTS.md` are also
  committed-generated files per the plan's convention.
  `docs/plan.md` and `docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md`
  are deferred to an **open question** — see below.
- **Dependencies:** all previous chunks
- **Lines (rough):** ~2,416 (README ~308, CLAUDE.md ~570,
  AGENTS.md ~570, CONTRIBUTING.md ~50, docs/plan.md ~735 if
  included, the merge plan ~1,184 if included)
- **Files added:**
  - `AGENTS.md`
  - `CLAUDE.md`
  - `CONTRIBUTING.md`
  - `README.md`
  - (optional) `docs/plan.md`
  - (optional) `docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md`

## Files that didn't fit cleanly

No [UNCLEAR] files. Every tracked file in the sentinel tip was
assigned to exactly one chunk. The only file in
`git ls-tree -r HEAD` that's NOT in any chunk is `LICENSE`,
which is already on `origin/main` and therefore NOT part of
this merge at all.

## Chunks flagged for size review

- **Chunk 6 (mcp-servers): ~14,609 lines.** `[LARGE-BUT-COHESIVE]`
  ~14,121 of those lines are generated npm package-lock files
  (openmemory 6,435 + sequential-thinking 3,620 + git-intel
  2,788 + context7 1,278). Hand-written Nix is ~488 lines
  across 21 files. Splitting by language (npm / Python / Go)
  produces 3 PRs that touch the same
  `default.nix`/`sources.nix`/`hashes.json` at each step,
  which is more churn than just landing all 14 at once. GitHub
  diff UI collapses generated lockfiles by default, so the
  actual review surface is small. **Recommendation: land as
  one PR.** Reviewer instruction in PR body: "skip
  `packages/mcp-servers/locks/*.json` — generated by npm".
- **Chunk 4 (content-packages): ~4,730 lines.** `[SPLIT?]`
  Close to the 1,000-line upper bound guidance but still
  cohesive — three content packages that share the same
  fragment-and-passthru shape. Largest contributor is
  `packages/stacked-workflows/` at ~3,709 lines spread across
  15 skill + reference markdown files. Splitting options:
  (a) split `stacked-workflows` into its own PR separate from
  `coding-standards` + `fragments-docs`; (b) split
  `stacked-workflows/skills/*` from
  `stacked-workflows/references/*` (but the references are
  shared via symlink from the skills so this creates
  ordering problems). **Recommendation: land as one PR.** The
  content is mostly review-passthrough markdown; no compiled
  code to scrutinize. If the PR feels too large during the
  loop, split on (a) as the contingency.
- **Chunk 9 (hm-ai-module): ~296 lines.** `[SMALL]` Just two
  files and some `flake.nix` edits. Could merge into Chunk 8
  to form a single "HM modules" PR. **Recommendation: keep
  separate** — Chunk 9 depends on Chunk 8's ecosystem modules
  existing for the fanout to target, and landing them in
  separate PRs makes the layered fanout story easier to
  review. The ai module is architecturally distinct from
  the per-ecosystem modules it wraps.

## Open questions for user approval

1. **Should `docs/plan.md` and `docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md`
   land in Chunk 17 or stay sentinel-only?** User directive
   from the plan doc: "may become the new working stack after
   getting PRs done instead of rebasing old one — but will
   defer that decision". Default: exclude from Chunk 17 and
   keep them on the sentinel branch. Revisit after the PR
   loop completes.
2. **Should `dev/notes/` land in Chunk 14 as proposed, or in
   its own catchall chunk?** Currently bundled in 14.
   `dev/notes/merge-chunks-2026-04-08.md` (this file) is
   sentinel-only regardless — the merge plan created it as
   a sentinel artifact and it should NOT be in any chunk.
   **Open:** should we also exclude `dev/notes/pr-template.md`
   (used by the Phase 1.2 commit on this catchup branch) from
   Chunk 14? It's genuinely useful for future PR work but was
   produced as part of this merge effort. Recommendation:
   include it — it's useful beyond this merge.
3. **Chunk 13 ordering relative to Chunks 14 and 15.** The
   `siteArchitecture` runCommand in `flake.nix` copies from
   architecture fragments that land in Chunk 15. Option A:
   defer the `siteArchitecture` block and the full
   `packages.docs` assembly until AFTER Chunk 15, which means
   Chunk 13 comes between 15 and 16. Option B: land a
   degraded Chunk 13 (no `siteArchitecture`, no
   `packages.docs`) between Chunks 12 and 14, then add those
   pieces on top in an un-numbered 13b after Chunk 15.
   **Recommendation: Option A** — reorder to 1-12, 14, 15,
   13, 16, 17 so Chunk 13 can land the full doc assembly in
   one shot. Alternately, rename the chunks to use the new
   ordering.
4. **Chunk 14's `flake.nix` app wiring.** Verify at chunk
   prep time whether `apps.update` etc. are actually exposed
   in the sentinel tip's `flake.nix`. If not, drop that edit.
5. **`dev/fragments/stacked-workflows/development.md`.** The
   plan lists this under Chunk 15, but it's conceptually
   scoped to stacked-workflows (Chunk 8's HM module or
   Chunk 4's content package). Leaving it in Chunk 15 keeps
   Chunk 4/8 more focused and groups all scoped dev fragments
   together. **Recommendation: keep in Chunk 15 as proposed.**
6. **Chunk 3's `dev/generate.nix` `extraPublishedFragments`
   wiring.** The full version reads
   `pkgs.coding-standards.passthru.fragments`, which doesn't
   exist until Chunk 4. Chunk 3 must either land a reduced
   `dev/generate.nix` (without `extraPublishedFragments`) or
   stub it as `{}`. Chunk 4 then wires the real content.
   **Recommendation: reduced form in Chunk 3, populated in
   Chunk 4.**
7. **Chunk 2's `lib.presets`.** Same issue as #6 — `presets`
   composes coding-standards + stacked-workflows fragments,
   which don't exist until Chunk 4. Defer `lib.presets` to
   Chunk 4's `flake.nix` edit.

## Chunking invariants verified

- [x] Every tracked file is assigned to exactly one chunk
      (verified via `diff /tmp/all-files-sorted.txt
  /tmp/assigned-files.txt`). `LICENSE` is the only
      exception and is already on `origin/main`.
- [x] Dependencies are strictly bottom-up (chunk N only
      depends on chunks 1..N-1), modulo the Chunk 13 ordering
      question noted in Open Questions #3.
- [x] No forward references in the file-to-chunk assignment.
- [x] `flake.nix` edits per chunk are additive (every chunk
      only ADDS outputs; no chunk removes anything a prior
      chunk added).
- [x] Sum of all per-chunk file line counts equals the total
      diff stat: chunks 1-17 = 38,116 insertions matching
      `git diff --stat --diff-filter=AM origin/main HEAD`.
- [x] `flake.lock` is touched by Chunk 1 (initial) and
      Chunk 11 (nixpkgs-test input addition). No other chunk
      touches it.
- [x] `nvfetcher.toml` + `.nvfetcher/generated.*` are touched
      by Chunks 5, 6, 7 (the three overlay chunks).
- [x] `devenv.nix` is touched by Chunks 1 (scaffold), 3
      (generate tasks), 5 (agnix from git-tools), 10
      (modules/devenv import + ai.\*), 14 (dev skill wiring).
- [x] `dev/generate.nix` is touched by Chunks 3 (initial), 4
      (extraPublishedFragments), 10 (devenv category), and
      15 (architecture fragment categories).

## Next step

Phase 2.2: user approval. After approval, Phase 3 begins the
PR loop — one chunk at a time, Copilot-gated.
