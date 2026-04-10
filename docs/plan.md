# nix-agentic-tools Backlog

> Single source of truth for remaining work. Lives on the working
> branch. **Never merges to main** — PR extraction filters it out.
> cspell + treefmt are configured to skip this file.
>
> Ordered by confidence / effort. Easy wins at the top, larger
> initiatives at the bottom. Memory files carry extended context
> where noted — `memory/<name>.md` references are relative to
> `~/.claude/projects/-home-caubut-Documents-projects-nix-agentic-tools/memory/`.

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

- [ ] **Update script: automated dep hash computation** — the update
      pipeline should compute pnpmDepsHash / vendorHash / npmDepsHash
      without manual copy-paste. Pattern: set hash to dummy → `nix
      build .#<pkg>.pnpmDeps 2>&1 | grep "got:" | awk '{print $2}'`
      → write to hashes.json. Target: fully automated hourly GitHub
      Actions (Copilot-driven). No AI needed.
      See `memory/project_nvfetcher_overlay_pattern.md` for details.

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

---

## Unsorted backlog

Items preserved from previous sessions. May need triage.

- [ ] Claude-code npm distribution removal contingency
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
