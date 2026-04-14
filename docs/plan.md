# nix-agentic-tools Backlog

> Single source of truth for remaining work. Lives on the working
> branch. **Never merges to main** — PR extraction filters it out.
> cspell + treefmt are configured to skip this file.
>
> Ordered by confidence / effort. Easy wins at the top, larger
> initiatives at the bottom. Memory files carry extended context
> where noted — `memory/<name>.md` references are relative to
> `~/.claude/projects/-home-caubut-Documents-projects-nix-agentic-tools/memory/`.

## Current status (2026-04-13)

**nix-update migration complete and pushed.** nvfetcher deleted. All
overlay packages have inline hashes managed by nix-update + ninja
DAG pipeline. Auto-computed versions from source (`overlays/lib.nix`).
CI pipeline restructured and actively running. Update pipeline uses
git worktrees + flock merge for parallel per-package updates.

---

### Backlog items
- [ ] Bun overlay for node-based binaries (port from `nixos-config/overlays/bun-overlay.nix`, publish in `ai.*`)
- [ ] Switch node-based MCP servers and tools to run with bun
- [ ] Single source of truth for `flake.nix` + `devenv.yaml` inputs (DRY)
- [ ] Document unfree guard pattern as architecture fragment fanned out to ecosystem docs + contributing
- [x] Update overlays/README.md table for nix-update migration
- [ ] Garnix CI exploration — garnix for builds, GHA for orchestration, cachix for distribution (see `memory/project_garnix_exploration.md`)
- [x] Update `.claude/rules/claude-code.md` buddy-activation fragment — updated for binary patching
- [ ] Fragment source linter — verify that every `<!-- Fragment: path -->` comment in generated files points to a source file that exists. Catch stale generated files, missing regen, or deleted sources.
- [ ] CI GITHUB_TOKEN workaround — PRs by `github-actions[bot]` don't trigger `pull_request` events in ci.yml. Need PAT, GitHub App token, or `workflow_dispatch` bridge. See `memory/project_ci_v4_design.md`.
- [ ] Commit hook regeneration — pre-commit hook should regenerate instruction files (same as devenv shell entry) and re-stage. DRY with `dev/generate.nix`. May need fingerprint cache to avoid ~2-5s nix build on every commit. See `docs/overnight-report-2026-04-13.md`.
- [ ] Nix doc comments as fragments — extract RFC 145 `/**` comments from `.nix` source files into the fragment pipeline. Custom extractor needed (nixdoc expects flat attrsets, our overlays are functions). See `memory/reference_nix_doc_tooling.md`.
- [ ] overlays/README.md table from nix eval — reflect overlay metadata at eval time, string-interpolate into a fragment. See `docs/overnight-report-2026-04-13.md` "code→markdown" section.
- [ ] Ecosystem-specific instructions in fragment comments — Claude transform injects `<!-- This file is generated. Edit the source fragment. -->` or similar. Research how other projects handle generated-but-committed file instructions.
- [ ] Code→markdown reflection pattern — general approach for inferring documentation from nix eval data instead of hand-maintained markdown. overlays/README.md is the first candidate.

### Update pipeline improvements

- [x] Fix pre-commit hook to re-stage formatted files — treefmt-restage hook added
- [x] Dirty tree guard at start of pipeline — ninja init step
- [x] Per-package ninja targets (replaced devenv DAG with ninja DAG)
- [x] Audit main-branch packages — all use --version skip, context7 + github converted
- [x] Parallel per-package updates via git worktrees + flock merge
- [x] Version tracking in update report (old → new in UPDATED/HELD BACK entries)
- [x] Smoke tests on all packages with binaries
- [x] Unit/integration tests enabled on 7+ packages (~1720 tests total)
- [ ] CI v4 "Stage, Validate, Push" — cross-platform validation before commit (designed, not pushed)

---

## Architecture summary

Factory rollout + ideal-architecture gate COMPLETE (2026-04-08/09).
All 24 binary packages under `pkgs.ai.*`. Factory primitives at
`lib/ai/app/{mkAiApp,hmTransform,devenvTransform}.nix`. Three CLI
factories absorbed full fanout:
- Claude: delegates to upstream `programs.claude-code.*` (HM) /
  `claude.code.*` (devenv) + gap writes; buddy activation ported
- Copilot: direct writes (no upstream); wrapper + env + agents + lsp
- Kiro: direct writes (no upstream); wrapper + env + agents + hooks + lsp + steering

Stacked-workflows absorbed as a plain module in
`packages/stacked-workflows/modules/homeManager/`. `modules/` tree
deleted. `devenv.nix` swapped to factory barrel. `nix flake check`
+ `nix build .#docs` + `devenv shell` green.

For full architecture details see `memory/project_factory_architecture.md`.
For known gaps and open questions see `memory/project_factory_known_gaps.md`.

Backup branches (DO NOT GC):
- `archive/phase-2a-refactor` at `cdbd37a`
- `archive/sentinel-pre-takeover` at `55371a9`

---

## Easy wins / light cleanup

High confidence, small scope. Good for review sessions.

- [x] **Review devenv overlay wiring** — devenv.nix now uses native
      `overlays = [...]` instead of manual aiPkgs/contentPkgs
      composition. allowUnfree via devenv.yaml.

- [x] **Move `lib/hm-helpers.nix` + `lib/ai-common.nix` into `lib/ai/`**
- [x] **Group overlay packages under `pkgs.ai.{mcpServers,lspServers}`
      + `pkgs.gitTools`**
- [x] **Refactor `mkDevFragment` location discriminator as attrset
      lookup**
- [x] **context7-mcp: override nixpkgs instead of from-scratch build**
      — proof case for the overlay override pattern. Uses inline
      GitHub source + nixpkgs override + fetchPnpmDeps.

- [ ] **Convert remaining 6 from-scratch overlays to nixpkgs
      overrides** — same pattern as context7-mcp. Override nixpkgs
      derivation with inline GitHub source, compute dep hashes.
      Match build tool to source (e.g., pnpm lockfile → pnpm
      build, not npm). Strip `allowUnfree` where not needed.
      Packages: fetch-mcp (`mcp-server-fetch`), github-mcp
      (`github-mcp-server`), git-mcp (`mcp-server-git`),
      git-revise (`git-revise`), mcp-language-server
      (`mcp-language-server`), mcp-proxy (`mcp-proxy`).

- [ ] **Audit all overlay source + build tools against upstream** —
      MANUAL USER REVIEW REQUIRED. For each package, verify:
      (a) source fetches from GitHub (not npm/PyPI) unless no
      GitHub source exists (flag to user), (b) build tool matches
      source lockfile (pnpm lockfile → pnpm build, not npm),
      (c) allowUnfree stripped unless actually needed. For packages
      NOT in nixpkgs, prefer GitHub source with releases over
      registry tarballs. User will inspect each one.

- [x] **Regenerate instruction files** — now auto-generated via
      devenv files.* on shell entry (2026-04-12).

- [x] **Update architecture fragments for factory structure** —
      buddy-activation + wrapper-chain fragments updated for binary
      patching. nvfetcher refs removed from all fragments.

- [ ] **Cachix/substituter override warnings for consumers** — warn
      when a consumer overrides this flake's nixpkgs or other inputs,
      causing cachix cache misses. If cachix is not in substitutors,
      warn about available prebuilt binaries. Only warn if cachix is
      configured but inputs are overridden (not if cachix is absent
      entirely). Warnings only, never break builds. Optionally provide
      a way to disable warnings. Tricky across module systems
      (HM, devenv, overlay-only).

- [ ] **Migrate git-branchless from custom overlay to upstream flake
      input** — consume `inputs.git-branchless.overlays.default`
      instead of standalone `overlays/git-tools/git-branchless.nix`.
      Thin wrapper for Rust 1.88.0 pin + versionCheckHook strip
      (needed until arxanas/git-branchless#1585 is fixed upstream).
      Remove from nix-update matrix, update via `nix flake update
      git-branchless`. Flake input already added. Design written up in
      a prior spec (deleted during backlog consolidation).

- [ ] **Clean up `lib/options-doc.nix` stubs** — consolidate ad-hoc
      stub extensions from Tasks 3-6.

- [ ] **Verify cspell project-terms.txt** — audit for stale terms.

- [ ] **Update AI instruction fragments with architecture decisions**
      — small decisions made during implementation should be codified
      into dev fragments so they fan out to all ecosystems. Decisions
      to document:
      - Overlay source pattern: inline GitHub source + hash, nix-update
        pipeline, nixpkgs overrides with fetchPnpmDeps/finalAttrs
      - overlay grouping: `pkgs.ai.{mcpServers,lspServers}` +
        `pkgs.gitTools`, agnix mainProgram overrides
      - factory composition: mkAiApp record + hmTransform/devenvTransform
        (see `memory/project_factory_architecture.md`)
      - Claude delegation model: upstream programs.claude-code.* for
        HM capabilities, direct writes for gaps
      - Unfree guard pattern: `ensureUnfreeCheck` wraps unfree packages
        via `final.symlinkJoin` with `meta` so consumer's allowUnfree
        is respected while ourPkgs cache-hit parity is preserved. Novel
        pattern not seen elsewhere in Nix ecosystem. Document heavily:
        why it exists, how it works, the eval-time-only nature of the
        unfree check, the symlinkJoin wrapper mechanics, CI implications.
        (see `memory/project_unfree_guard_pattern.md`)
      - Flake-first source preference: if upstream repo has a nix flake
        that outputs the package (not just devShell), add it as a flake
        input and consume `inputs.<name>.packages.${system}.default`.
        Let upstream own their build. Inline source + overlay is for
        packages without flakes or where we override nixpkgs.
      - Build tool must match source: if source has pnpm-lock.yaml,
        build with pnpm (not npm). If source has Cargo.lock, build
        with cargo. Don't force a different tool than what upstream
        uses.

- [x] **Update script: automated dep hash computation** — implemented
      as `dev/scripts/update-hashes.sh` with auto-discovery via
      `.pnpmDeps`/`.goModules`/`.cargoDeps` nix eval probing. Wired
      into CI phase 2 via `nix develop .#ci`. hashes.json is pure
      output, rebuilt from scratch on each run.

- [ ] **Replace `isRoot = package == "monorepo"` with category
      metadata** — `mkDevComposed` hardcodes a string match. Should
      be explicit category metadata (e.g.,
      `{ includesCommonStandards = true; }`).

- [ ] **Add scope→fragment map to the self-maintenance directive** —
      the always-loaded `dev/fragments/monorepo/architecture-fragments.md`
      doesn't tell sessions which fragment covers which scope.
      Hand-maintain a table or generate from `packagePaths`.

- [ ] **Include commit subject in Last-verified markers** — extend
      the `Last verified:` format across all fragments.

- [ ] **Move `externalServers` registry out of root `flake.nix`** —
      extract to `lib/external-servers.nix` or a content package.
      Currently `lib.externalServers.aws-mcp` is hand-defined inline.

- [x] **Pre-main-merge cleanup: remove `docs/human-todo.md`** —
      scratch file for user notes during dev. Removed along with
      `docs/superpowers/` directory. cspell + treefmt + devenv
      excludes cleaned up.

- [ ] **Rename `devshell/` → `modules/devshell/`** — top-level
      splits modules across `lib/`, `devshell/`, and per-package
      `modules/`. Move `devshell/` for layout consistency. Flagged on
      PR #4 review. Note: `modules/` directory was just deleted in
      A10 — a fresh `modules/devshell/` for the standalone devshell
      would be its own concern, not confused with the old HM tree.

---

## Medium effort

Moderate confidence, needs some investigation or design.

- [ ] **Single source of truth for tool exclude lists** — cspell.json,
      devenv.nix cspell excludes, treefmt.nix excludes all duplicate.
      Build a single Nix attrset with file categories (generated
      published docs → spell YES format NO; plan docs → spell NO
      format NO; tool artifacts → both NO). Each tool config reads
      the category intersection it cares about. See detailed writeup
      in `memory/project_factory_known_gaps.md` open question #6.

- [ ] **Extend `sharedOptions.nix` with `ai.lspServers` +
      `ai.environmentVariables`** — currently per-app only (DRY loss
      between copilot and kiro). The legacy `modules/ai/default.nix`
      had these as cross-ecosystem shared options. Extending
      `sharedOptions.nix` is mechanically the same as the existing
      `ai.skills` / `ai.instructions` / `ai.mcpServers` pattern.
      See `memory/project_factory_known_gaps.md` open question #1.

- [ ] **Consolidate fragment enumeration into single metadata table**
      — `devFragmentNames`, `packagePaths`, and `flake.nix`'s
      `siteArchitecture` all hand-list the same fragments. Extract a
      single `fragmentMetadata` attrset in `dev/generate.nix`.

- [ ] **HM ↔ devenv ai module parity test** — add a parity-check
      eval test in `checks/module-eval.nix` that evaluates both HM
      and devenv modules with equivalent config and spot-checks that
      option paths match.

- [ ] **Copilot CLI integration test** — the factory port (Tasks 4+4b)
      landed without a real consumer driving it. Write an integration
      test: scratch HM profile with `ai.copilot.enable = true` + concrete
      config, `home-manager build`, assert on-disk tree matches expected
      layout + wrapper injects `--additional-mcp-config` flag. See
      detailed writeup in plan commit `3332b2c`.

- [ ] **Kiro CLI integration test** — same as copilot, verify kiro
      factory output matches expected `.kiro/` directory layout,
      steering YAML frontmatter uses array form for `fileMatchPattern`.

- [ ] **Claude-code wrapper env vars** — set `DISABLE_AUTOUPDATER=1`
      and `DISABLE_INSTALLATION_CHECKS=1` defensively in the Bun
      wrapper. Design decision: always-on vs overridable via settings.

- [ ] **AI.skills stacked-workflows special case** — currently
      consumers need to enable stacked-workflows AND set `ai.skills`
      separately. Augment to support a single-line
      `stacked-workflows.enable = true` that pulls SWS skills into
      every enabled ecosystem via `ai.skills`.

- [ ] **Codify gap: ai.skills factory layout** — create a new scoped
      architecture fragment documenting the post-factory skills fanout
      pattern (each factory writes its own skill dirs directly from
      config callbacks). Source: `memory/project_ai_skills_layout.md`.

- [ ] **Codify gap: devenv files internals** — create a new scoped
      architecture fragment. Source:
      `memory/project_devenv_files_internals.md`.

- [ ] **GitHub Pages `docs.yml` workflow** — not yet wired. Base path
      fixes for preview branches also deferred.

- [ ] **Fragment assembler source-path comments** — when `compose`
      produces a final file, inject HTML comments naming the source
      fragments. Helps reviewers audit generated files. Implementation
      lives in `lib/fragments.nix compose`.

---

## Larger initiatives

Lower confidence or broader scope. Needs design/brainstorming.

### nixos-config integration

Goal: consumer fully ported to the `ai.*` factory surface.

- [ ] Wire nix-agentic-tools flake input into nixos-config
- [ ] Migrate AI config blocks to `ai.*` (from direct `programs.*` blocks)
- [ ] End-to-end verification: `home-manager switch` on real consumer
- [ ] Remove vendored AI packages from nixos-config
- [ ] Ollama ownership decision (host-specific vs reusable)
- [ ] Update flake input pin (currently at `f341bcb`, pre-factory)
      — note `pkgs.nix-mcp-servers.*` namespace dissolved in M5,
      `github-copilot-cli` renamed to `copilot-cli` in M4. Consumer
      migration needed. See `memory/project_nixos_config_integration.md`.

### Re-chunk for main merge

Not this week. Start fresh when ready.

- [ ] Stack new branch from main tip
- [ ] Cherry-pick or rebase factory commits into PR-sized chunks
- [ ] Copilot auto-review on each PR (repo already configured)
- [ ] Verify CI green on each chunk

### Add OpenAI Codex (4th ecosystem)

Blocked on factory shape being stable and verified by nixos-config.

- [ ] Package chatgpt-codex CLI under `packages/chatgpt-codex/`
- [ ] Add codex transformer under `lib/ai/transformers/`
- [ ] Wire factory into module barrel via `collectFacet`

### Doc site

- [ ] NuschtOS options browser gaps (All-scope blending, dark mode,
      packages indexing). See `memory/project_nuschtos_search.md`.
- [ ] Generate CONTRIBUTING.md from fragments
- [ ] Consumer migration guide
- [ ] Document binary cache for consumers
- [ ] ADRs for key decisions
- [ ] Introduction → Contributing link in mdbook
- [ ] Soften agent-directed language in docsite fragment copies

### Agentic tooling

- [ ] Drift detection agent/skill set (generated files, upstream
      versions, option surface, cross-config parity)
- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, cross-references)

### CI

- [ ] Revert `ci.yml` branch trigger to `[main]` only (after merge)
- [ ] Remove `update.yml` push trigger, keep schedule + dispatch
- [ ] CUDA build verification
- [ ] Review cachix push strategy
- [ ] **Split CI into update + build workflows** —
      Current: single `update.yml` runs full pipeline (update → build → commit)
      on every push to feature branch. Target: `update.yml` on main schedule
      opens PR with updated sources+hashes; `build.yml` triggers on PR open,
      builds per-platform, pushes to cachix. The three-job structure already
      maps to this split. Blocked on: merging to main + stable CI.

---

## Unsorted backlog

Items preserved from previous sessions. May need triage.

- [ ] **Claude-code npm→binary migration + buddy salt patching** —
      Anthropic soft-deprecated npm 2026 in favor of Bun-compiled
      single-exec from GPG-signed manifest. Migration uses the same
      binary-fetch pattern as kiro-cli (inline source + per-platform
      `sources.json`). Buddy patching requires extracting/modifying
      embedded JS inside the Bun single-exec binary's `.bun` ELF
      section (Linux) or `__BUN,__bun` Mach-O section (macOS).

      **Preferred approach (option 2): same-length in-place binary patch.**
      The buddy salt is a fixed 15-byte marker (`friend-2026-401`).
      The Bun module graph payload has NO checksums or signatures —
      locate the salt bytes in the embedded `cli.js` contents via
      the `StandaloneModuleGraph` format (trailer `"\n---- Bun! ----\n"`
      → Offsets struct → CompiledModuleGraphFile[] → StringPointer to
      contents), overwrite in-place, re-codesign on macOS. No pointer
      or offset changes needed for same-length replacement.

      Existing tooling: `lafkpages/bun-decompile` (TypeScript,
      handles old/new format), `@shepherdjerred/bun-decompile` (npm).
      Could also write a minimal Nix-native extractor since the format
      is well-documented (48-byte Offsets struct + 28-byte per-module
      metadata).

      If bytecode is present for the patched module, strip the
      StringPointer (zero it) — Bun falls back to source parsing.

      **Deep technical reference:** `memory/reference_bun_binary_patching.md`

      **Monitoring signal:** check `@anthropic-ai/claude-code` npm
      publish frequency. If Anthropic stops npm while native channel
      keeps updating, that's the trigger.

      **Touch points:** claude-code.nix (buildNpmPackage → binary
      fetch), per-platform sources.json, claude-code-buddy module,
      buddy-customization.md, delete claude-code-package-lock.json
- [ ] Agentic UX: pre-approve nix-store reads for HM-symlinked skills
- [ ] Richer markdown fragment system: heading-aware merging
- [ ] LLM-friendly inline code commenting conventions fragment
- [ ] Research cspell plural/inflection syntax
- [ ] `outOfStoreSymlink` helper for Claude's `~/.claude/projects`
- [ ] Secret scanning (gitleaks)
- [ ] SecretSpec for MCP credentials
- [ ] cclsp — Claude Code LSP integration
- [ ] claude-code-nix review (github.com/sadjow/claude-code-nix)
- [ ] cspell permissions wired via `ai.*`
- [ ] devenv feature audit (tasks, services, process dependencies)
- [ ] filesystem-mcp package + wire to devenv
- [ ] flake-parts — modular per-package flake outputs
- [ ] Fragment content expansion (code review, security, testing presets)
- [ ] Logo refinement
- [ ] MCP processes for `devenv up` (no-cred servers)
- [ ] Module fragment exposure (servers contributing own fragments)
- [ ] Ollama HM module (if ownership decision keeps it here)
- [ ] `scripts/update` auto-discovery
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp packaging
- [ ] openmemory-mcp typed settings + missing option descriptions
- [ ] `stack-plan` skill: missing git restack after autosquash
- [ ] Rolling stack workflow skill
- [ ] claude-code build approach consumer docs
- [ ] Declutter root dotfiles
- [ ] Fragment metadata consolidation follow-up (see also: Medium effort "Consolidate fragment enumeration")
- [ ] Document hm-modules / claude-code scope overlap (moot post-buddy-absorption)
