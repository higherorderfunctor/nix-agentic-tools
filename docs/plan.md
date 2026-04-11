# nix-agentic-tools Backlog

> Single source of truth for remaining work. Lives on the working
> branch. **Never merges to main** — PR extraction filters it out.
> cspell + treefmt are configured to skip this file.
>
> Ordered by confidence / effort. Easy wins at the top, larger
> initiatives at the bottom. Memory files carry extended context
> where noted — `memory/<name>.md` references are relative to
> `~/.claude/projects/-home-caubut-Documents-projects-nix-agentic-tools/memory/`.

## Current status (2026-04-11)

**nix-update migration ~95% complete.** nvfetcher deleted. All overlay
packages have inline hashes managed by nix-update. Auto-computed
versions from source (`overlays/lib.nix`). 40/42 packages build.
CI pipeline restructured (build outside devenv, warm cache last) but
NOT pushed — testing locally first.

**Remaining before push:**
- End-to-end `devenv tasks run update:all` test (running now)
- Verify devenv shell works

---

## Backlog: nvfetcher reference cleanup

55 stale references across the repo after nix-update migration.
Fix fragments first → regenerate → cascade fixes 40+ generated files.

### Dead code (fix directly)
- [ ] `overlays/default.nix:25` — comment references deleted `memory/project_nvfetcher_overlay_pattern.md`
- [ ] `config/cspell/cspell.json:27` — filename glob references deleted `config/nvfetcher/nvfetcher.toml`
- [ ] `config/cspell/project-terms.txt:98` — `nvfetcher` in dictionary (keep if historical docs mention it)
- [ ] `.gitignore:37-38` — shake database glob for deleted nvfetcher output
- [ ] `dev/generate.nix:150-153` — `nvfetcher.toml` in path scope
- [ ] `dev/generate.nix:695,705,732,737-738` — CONTRIBUTING.md template nvfetcher workflow text

### Stale docs (fix directly)
- [ ] `overlays/README.md` — entire file describes nvfetcher pattern, needs full rewrite
- [ ] `overlays/mcp-servers/serena-mcp.nix:8`, `nixos-mcp.nix:8` — "No nvfetcher entry" comments
- [ ] `packages/kiro-cli/default.nix:5` — "nvfetcher-only entry" comment
- [ ] `packages/serena-mcp/lib/mkSerena.nix:7`, `packages/nixos-mcp/lib/mkNixos.nix:7` — "not nvfetcher-tracked"
- [ ] `packages/claude-code/docs/buddy-activation.md:77` — "pins via nvfetcher"
- [ ] `packages/stacked-workflows/references/nix-workflow.md:38-67` — nvfetcher workflow steps
- [ ] `dev/references/agnix.md:8` — "tracking latest via nvfetcher"
- [ ] `dev/notes/overlay-cache-hit-parity-fix.md` — nv.version references
- [ ] `dev/notes/claude-code-npm-contingency.md` — nvfetcher migration plan (done)
- [ ] `dev/skills/repo-review/personalities/nix-expert.md:33` — "Is nvfetcher integration correct?"

### Fragment source files (fix → regenerate → cascades to 16 steering files)
- [ ] `dev/fragments/mcp-servers/overlay-guide.md` — entire file is nvfetcher + hashes.json pattern
- [ ] `dev/fragments/ai-clis/packaging-guide.md:21-62` — nvfetcher version tracking section
- [ ] `dev/fragments/overlays/overlay-pattern.md:41` — `nvSourcesOverlay` reference
- [ ] `dev/fragments/overlays/cache-hit-parity.md:44` — `nv.version` in code example
- [ ] `dev/fragments/nix-standards/nix-standards.md:5-7` — `nv-sources.<key>` and `hashes.json` rules
- [ ] `dev/fragments/packaging/naming-conventions.md:8` — "nvfetcher keys use upstream project names"
- [ ] `dev/fragments/packaging/platforms.md:10-21` — nvfetcher nightly pattern
- [ ] `dev/fragments/monorepo/change-propagation.md:11` — `nvfetcher.toml keys` in checklist

### New backlog items
- [ ] Bun overlay for node-based binaries (port from `nixos-config/overlays/bun-overlay.nix`, publish in `ai.*`)
- [ ] Switch node-based MCP servers and tools to run with bun
- [ ] Single source of truth for `flake.nix` + `devenv.yaml` inputs (DRY)
- [ ] Document unfree guard pattern as architecture fragment fanned out to ecosystem docs + contributing
- [ ] Update overlays/README.md table for nix-update migration
- [ ] Garnix CI exploration — garnix for builds, GHA for orchestration, cachix for distribution (see `memory/project_garnix_exploration.md`)

---

## Previous status (2026-04-10, pre-migration)

**CI pipeline (`update.yml`) debugging in progress.** Waiting for a
clean run before further tweaks. Recent fixes:

- **File reorganization landed** (`babab01`): config files →
  `config/`, generated files → `overlays/sources/`. cspell dictionary
  path resolved (CWD-relative, `config/cspell/` excluded from
  spell checking to avoid nested config auto-discovery collision).

- **Hash chicken-and-egg fixed** (`c399f79`): stale dep hashes
  (e.g. agnix cargoHash) broke `devenv print-dev-env` because overlay
  packages are in the shell's packages list. Hash computation now
  runs BEFORE devenv eval using the lightweight CI shell (`nix develop
  .#ci`). `update-hashes.sh` also fixed to use `builtins.currentSystem`
  instead of hardcoded x86_64-linux.

- **CI logging enabled** (`affd2ca`): `print-build-logs = true` in
  nix config so nix emits fetch/build progress to stderr in non-TTY
  CI. `devenv print-dev-env > /dev/null` keeps stderr visible while
  suppressing the giant env dump.

- **Workflow split planned**: current single workflow runs full cycle
  on every push to feature branch. Backlog item added to split into
  update-on-main-schedule + build-on-PR after merge.

**Next**: wait for CI run to complete, review logs, fix any remaining
issues. Then: overlays/README.md table update, darwin hash verification.

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
      — proof case for the overlay override pattern. Uses nvfetcher
      GitHub source + runCommandLocal unpack + fetchPnpmDeps.

- [ ] **Convert remaining 6 from-scratch overlays to nixpkgs
      overrides** — same pattern as context7-mcp. Switch nvfetcher
      from npm/PyPI tarballs to GitHub source, override nixpkgs
      derivation, compute dep hashes. Match build tool to source
      (e.g., pnpm lockfile → pnpm build, not npm). Strip
      `allowUnfree` where not needed. Packages:
      fetch-mcp (`mcp-server-fetch`), github-mcp
      (`github-mcp-server`), git-mcp (`mcp-server-git`),
      git-revise (`git-revise`), mcp-language-server
      (`mcp-language-server`), mcp-proxy (`mcp-proxy`).
      Pattern: `memory/project_nvfetcher_overlay_pattern.md`.

- [ ] **Audit all overlay source + build tools against upstream** —
      MANUAL USER REVIEW REQUIRED. For each package, verify:
      (a) nvfetcher fetches from GitHub (not npm/PyPI) unless no
      GitHub source exists (flag to user), (b) build tool matches
      source lockfile (pnpm lockfile → pnpm build, not npm),
      (c) allowUnfree stripped unless actually needed. For packages
      NOT in nixpkgs, prefer GitHub source with releases over
      registry tarballs. User will inspect each one.

- [ ] **Regenerate instruction files** — run
      `devenv tasks run --mode before generate:instructions` and
      commit any changes after overlay/factory refactors.

- [ ] **Update architecture fragments for factory structure** —
      `.claude/rules/*.md` may reference deleted `modules/` paths.
      Audit each fragment and fix stale prose.

- [ ] **Clean up `lib/options-doc.nix` stubs** — consolidate ad-hoc
      stub extensions from Tasks 3-6.

- [ ] **Verify cspell project-terms.txt** — audit for stale terms.

- [ ] **Update AI instruction fragments with architecture decisions**
      — small decisions made during implementation should be codified
      into dev fragments so they fan out to all ecosystems. Decisions
      to document:
      - nvfetcher pattern: GitHub source over npm/PyPI, scoped-tag
        workaround, runCommandLocal unpack, fetchPnpmDeps with
        finalAttrs (see `memory/project_nvfetcher_overlay_pattern.md`)
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
        input (NOT nvfetcher) and consume
        `inputs.<name>.packages.${system}.default`. Let upstream own
        their build. nvfetcher is for packages without flakes or where
        we override nixpkgs.
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

- [ ] **Pre-main-merge cleanup: remove `docs/human-todo.md`** —
      scratch file for user notes during dev. Also remove its entry
      from `cspell.json` ignorePaths + `devenv.nix` cspell excludes.

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
- [ ] Structural checks (symlinks, fragments, nvfetcher keys)

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
      single-exec from GPG-signed manifest. nvfetcher migration is
      straightforward (copy `kiro-cli.nix` binary-fetch pattern).
      Buddy patching requires extracting/modifying embedded JS inside
      the Bun single-exec binary's `.bun` ELF section (Linux) or
      `__BUN,__bun` Mach-O section (macOS).

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

      **Touch points:** nvfetcher.toml, claude-code.nix (buildNpmPackage
      → binary fetch), hashes.json (per-platform binary hashes),
      claude-code-buddy module, buddy-customization.md, delete
      claude-code-package-lock.json
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
- [ ] Fragment metadata consolidation follow-up
- [ ] Document hm-modules / claude-code scope overlap (moot post-buddy-absorption)
