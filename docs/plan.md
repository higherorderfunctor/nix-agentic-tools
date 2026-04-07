# nix-agentic-tools Plan

> Living document. Single source of truth for remaining work.
> Branch: `sentinel/monorepo-plan`.
>
> **Priority rule:** work TOP to MIDDLE to LOWER. Top items unblock
> middle and lower. Ecosystem expansion waits for architecture to
> solidify. Deprioritized items stay parked until the architecture
> and nixos-config integration are stable.

## Authoring notes

Pre-commit runs cspell over this file. When writing backlog
entries, avoid strings that trip the spellchecker on every commit:

- **No literal Nix store hashes.** Use `<HASH>-<name>-<version>`
  or `/nix/store/...-name-version` as placeholders. Real 32-char
  base32 store hashes will always contain novel letter runs cspell
  flags.
- **No raw narinfo URLs.** Describe the path
  (`cachix.org/<hash>.narinfo`) or add the word to
  `.cspell/project-terms.txt` once and reuse.
- **Jargon goes in `.cspell/project-terms.txt`**, not the prose.
  Words like `narinfo` should be added to the allowlist the first
  time they appear. Keep the list alphabetical.

## Architecture (current state)

- **Standalone devenv CLI** for dev shell (not flake-based)
- **Top-level `ai`** namespace for unified config (HM and devenv)
- **Config parity** — lib, HM, and devenv must align in capability
- **Content packages** — published content (skills, fragments)
  lives in `packages/` as derivations with passthru for eval-time
  composition
- **Topic packages** — `fragments-ai`, `fragments-docs` bundle
  content + transforms via passthru
- **Pure fragment lib** — `lib/fragments.nix` provides compose,
  mkFragment, render
- **treefmt** via devenv built-in module
- **devenv MCP** uses public `mcp.devenv.sh` (local Boehm GC bug)
- **Buddy activation-time** rewrite landed; working end-to-end
- **ai.enable dropped** — per-CLI enable is sole gate, flips
  corresponding upstream/devenv enable (both HM and devenv mirror)
- **Architecture fragments** — path-scoped per-ecosystem, single
  markdown source feeds Claude/Copilot/Kiro/AGENTS.md + mdbook
  contributing section

## Priorities

Three tiers:

- **TOP** — Foundational architecture, maintain current fragments,
  integrate nixos-config (complete port to `ai.*`)
- **MIDDLE** — Bring Kiro online, bring Copilot online, add OpenAI
  Codex as 4th ecosystem (in that order)
- **LOWER** — CI polish (except cachix already done), agentic
  tooling (check-drift, check-health, index-repo-docs), PR/stack
  workflow, contributor docs and build-out, doc site polish,
  misc backlog

---

## TOP priority

### Architecture foundation

- [ ] **Overlay cache-hit parity fix** — every compiled overlay
      package must instantiate its own `pkgs` from `inputs.nixpkgs`
      (not consumer `final`/`prev`) so cachix substituters actually
      serve the packages. Current overlays use `final.rust-bin`,
      `prev.git-branchless`, etc., which binds build infrastructure
      to the consumer's nixpkgs → store path drift → cache miss.
      Full fix pattern, file enumeration, and verification protocol
      in `dev/notes/overlay-cache-hit-parity-fix.md`. Related
      fragment: `dev/fragments/overlays/cache-hit-parity.md`.

- [ ] **Consolidate fragment enumeration into single metadata
      table** — `devFragmentNames`, `packagePaths`, and
      `flake.nix`'s `siteArchitecture` runCommand all hand-list
      the same fragments. Adding a new architecture fragment
      requires three coordinated edits. Extract a single
      `fragmentMetadata` attrset in `dev/generate.nix` that
      declares each fragment once with all fields (location, dir,
      name, paths, docsite output path, category), then project it
      into `devFragmentNames` (grouped by category), `packagePaths`
      (grouped by category), and an exported attr that `flake.nix`
      consumes to build `siteArchitecture`. Ideally
      `siteArchitecture` becomes fully auto-discovered.

- [ ] **`ai` HM module should `imports` its deps** —
      `homeManagerModules.ai` should pull in `claude-code-buddy`,
      `copilot-cli`, `kiro-cli` via `imports = [ ... ]` so
      consumers get a single import. Currently the `ai` module
      references `programs.copilot-cli` / `programs.kiro-cli`
      unconditionally inside `mkIf cfg.copilot.enable` blocks,
      forcing consumers to manually import those modules. Real-world
      surfaced 2026-04-06: nixos-config had to add four surgical
      imports where one should suffice. Pick option (a): `ai/default.nix`
      adds `imports = [ ../claude-code-buddy ../copilot-cli ../kiro-cli ];`.

- [ ] **Drop standalone `claude-code-buddy` HM module** — fold
      the buddy option into a single `claude-code` HM module that
      augments upstream `programs.claude-code` (mirrors how
      `copilot-cli` and `kiro-cli` modules work). Eliminates the
      awkward `homeManagerModules.claude-code-buddy` consumers have
      to know about. The `ai` module's `imports` (above) brings it
      in transparently. Naming decision needed: keep as
      `programs.claude-code.buddy` or move to
      `programs.claude-code-extras.buddy` to avoid conflict with
      upstream HM's claude-code module if it ever adds its own
      `buddy` option.

- [ ] **Bundle `any-buddy` into claude-code package** — currently
      its own overlay package at `packages/ai-clis/any-buddy.nix`
      exposed at `pkgs.any-buddy`, solely for the buddy activation
      script. Move the source tree into the claude-code package as
      a private passthru (`pkgs.claude-code.passthru.anyBuddy`) and
      update the buddy module to pull it from there. Removes one
      top-level package export. General refactor pattern worth
      adopting: when a single `packages/<group>/<name>.nix` gets
      unwieldy, convert to `packages/<group>/<name>/default.nix`
      with sibling files in the same directory (`wrapper.nix`,
      `patching.nix`). Don't pre-split — do it when a single file
      gets unwieldy.

- [ ] **Claude-code npm distribution removal contingency** — monitor
      `@anthropic-ai/claude-code` publish frequency. If Anthropic
      stops publishing to npm, follow the migration plan in
      `dev/notes/claude-code-npm-contingency.md` (nvfetcher swap
      to binary fetch + one of three buddy fallback options,
      option 3 blocked by closed-source sourcemap leak). Related
      fragment: `packages/ai-clis/fragments/dev/buddy-activation.md`.

- [ ] **Set `DISABLE_AUTOUPDATER=1` defensively in claude-code
      wrapper env** — claude-code runs a background autoupdater
      that downloads new binaries and rewrites them at the install
      path. Inappropriate for a nix-managed store path. Also set
      `DISABLE_INSTALLATION_CHECKS=1` to silence the "Claude Code
      has switched from npm to native installer" snackbar.
      Touch points: either the Bun wrapper script in
      `packages/ai-clis/claude-code.nix` (always-on) or
      `programs.claude-code.settings.env` in the ai HM module
      (overridable). Design question: which is more appropriate?

### ai.claude.\* full passthrough

Detail lives in `memory/project_ai_claude_passthrough.md`. Task 2
is BLOCKING for the rest. Draft a fresh plan from the memory when
ready to execute this chunk.

- [ ] **Task 2 (BLOCKING): Route `ai.skills` Claude fanout through
      `programs.claude-code.skills`** — currently writes
      `home.file` directly, which collides with per-Claude
      `ai.claude.skills` and produces Layout A (single dir symlink)
      instead of Layout B (real dir with per-file symlinks). Blocks
      Tasks 3-7. Consumer transition note: migrated users hit
      "would be clobbered" on first activation; `home-manager switch -b backup`
      once.

- [ ] **Task 2b: Devenv skills fanout parity (Option A
      recommended)** — HM all three ecosystems produce Layout B;
      devenv all three produce Layout A. devenv's `files.*.source`
      cannot walk recursively (see
      `memory/project_devenv_files_internals.md`). Option A: add
      `mkDevenvSkillEntries` helper to `lib/hm-helpers.nix` that
      walks the source dir at eval time with `builtins.readDir`.
      Option C (upstream PR to cachix/devenv `recursive` field) can
      happen in parallel. Copilot `configDir` verification needed
      (`.github` vs `.copilot`).

- [ ] **Task 3: `ai.claude.memory` passthrough** — mirror upstream
      `memory.{text,source}` submodule, mutual exclusion asserted
      upstream.

- [ ] **Task 4: `ai.claude.settings` freeform JSON passthrough** —
      `pkgs.formats.json {}` type. Covers effortLevel, permissions,
      enableAllProjectMcpServers, enabledPlugins, theme, hooks,
      statusLine. Fanout via `mkMerge` (not `mkDefault`) so consumer
      `programs.claude-code.settings` stays composable.

- [ ] **Task 5: `ai.claude.mcpServers` + `enableMcpIntegration`
      passthrough** — separate from cross-ecosystem `ai.mcpServers`
      bridge (different backlog item).

- [ ] **Task 6: `ai.claude.skills` + `ai.claude.skillsDir`
      passthrough** — depends on Task 2. Uses `mkMerge` with
      cross-ecosystem `ai.skills`; per-Claude overrides win.

- [ ] **Task 7: `ai.claude.plugins` + `ai.claude.marketplaces`
      passthrough** — declarative option only. Plugin install
      activation script (`installClaudePlugins`) stays bespoke in
      the consumer for now.

- [ ] **Task D: Devenv ai module mirror** — after Tasks 3-7 land
      on HM side, mirror each option on `modules/devenv/ai.nix`
      with identical types and fanout semantics, respecting
      devenv's `files.*` / `claude.code.*` native options.

- [ ] **`ai.claude.*` full passthrough: architectural gap** —
      overarching intent is that `ai.claude.*` mirrors EVERY option
      from `programs.claude-code.*`. Same for `ai.copilot` and
      `ai.kiro` vs their respective `programs.*` modules. Tasks
      above are the concrete Claude-side work; Copilot/Kiro
      analogous passthroughs are separate plans (MIDDLE tier).

### Architecture fragment maintenance

These are the follow-ups from the Checkpoint 8 multi-reviewer
audit of the steering-fragments work. Low individual risk, high
cumulative value.

- [ ] **Codify gap: ai.skills layout** — create new scoped
      architecture fragment documenting the "all three branches
      delegate through `programs.<cli>.skills`, no direct home.file
      writes" decision + the 2026-04-06 consumer clobber story.
      Source content:
      `memory/project_ai_skills_layout.md`. Scope to
      `modules/ai/**`, `packages/**/fragments/**`, and
      `lib/hm-helpers.nix`. Lets fresh clones understand the
      constraint without needing memory access.

- [ ] **Codify gap: devenv files internals** — create new scoped
      architecture fragment documenting the devenv `files.*`
      option's structural constraints (no recursive walk,
      silent-fail on dir-vs-symlink conflict, `mkDevenvSkillEntries`
      workaround). Source content:
      `memory/project_devenv_files_internals.md`. Scope to
      `modules/devenv/**`, `lib/hm-helpers.nix`.

- [ ] **Add scope→fragment map to the self-maintenance directive**
      — the always-loaded `dev/fragments/monorepo/architecture-fragments.md`
      doesn't tell sessions which fragment covers which scope.
      Either hand-maintain a table in the fragment OR generate one
      from `packagePaths` via a new nix expression embedded at
      generation time.

- [ ] **Introduction → Contributing link** — the mdbook introduction
      page (`dev/docs/index.md`) doesn't mention the new
      Contributing / Architecture section. Add a short section.

- [ ] **Soften agent-directed language in docsite copies of
      fragments** — architecture fragments use imperative phrasing
      ("stop and fix it", "MUST be updated") that reads as jarring
      in the mdbook. Option (a): rewrite imperative directives as
      declarative design contracts. Option (c): add a
      docsite-specific intro blurb framing the tone. Option (a)
      cleaner.

- [ ] **Include commit subject in Last-verified markers** — extend
      `Last verified: 2026-04-07 (commit a3c05f3)` to
      `Last verified: 2026-04-07 (commit a3c05f3 — subject)`. Apply
      to all 7 existing fragments + document the format in the
      always-loaded architecture-fragments fragment.

- [ ] **HM ↔ devenv ai module parity test** — currently enforced
      by code review only. Add a parity-check eval test in
      `checks/module-eval.nix` that evaluates both modules with
      equivalent config and spot-checks that option paths match
      (minus intentional divergences like `ai.claude.buddy`).

- [ ] **Fragment size reduction: `hm-modules` and
      `fragment-pipeline`** — 267 and 186 lines respectively, over
      the 150-line soft budget. Split by sub-concern IF real-world
      usage shows context dilution. Not urgent.

- [ ] **Refactor `mkDevFragment` location discriminator as attrset
      lookup** — current if/else-if branching on `dev | package |
  module` works but extends linearly. Replace with
      `locationBases.${location} or (throw ...)`. Pure cleanup.

- [ ] **Replace `isRoot = package == "monorepo"` with category
      metadata** — `mkDevComposed` hardcodes a string match.
      Should be explicit category metadata (e.g.,
      `{ includesCommonStandards = true; }`). Paired with
      "consolidate fragment enumeration" above.

- [ ] **Document the intentional hm-modules / claude-code scope
      overlap** — both categories' `packagePaths` include
      `modules/claude-code-buddy/**`. Add a comment in
      `dev/generate.nix` explaining the overlap is intentional.

- [ ] **`ai.skills` stacked-workflows special case** — currently
      consumers need `stacked-workflows.integrations.<ecosystem>.enable
  = true` per ecosystem alongside `ai.skills`. Augment
      `ai.skills` to support `ai.skills.stackedWorkflows.enable =
  true` (or similar) that pulls SWS skills + routing table into
      every enabled ecosystem in one line. Keep raw
      `ai.skills.<name> = path` for bring-your-own.

### nixos-config integration

Goal: nixos-config fully ported to `ai.*`. Blocked on Tasks 2-7 of
the ai.claude passthrough (above).

- [ ] **Wire nix-agentic-tools into nixos-config** — HM global +
      devshell per-repo. Flake input, overlay, module imports. Has
      been partially done (HITL work 2026-04-06); verify current
      state and close any gaps.

- [ ] **Migrate nixos-config AI config to `ai.*` unified module**
      — replace hardcoded `programs.claude-code.*` / `copilot.*` /
      `kiro.*` blocks with the `ai.*` fanout. Depends on
      ai.claude.\* full passthrough landing. See
      `memory/project_nixos_config_integration.md` for the 8
      interface contracts and the current vendored package list.

- [ ] **Verify 8 interface contracts hold** — enumerated in
      `memory/project_nixos_config_integration.md`. Refresh the
      memory after integration lands.

- [ ] **Remove vendored AI packages from nixos-config** —
      copilot-cli, kiro-cli, kiro-gateway, ollama HM module (TBD).
      Verify each one's migration path before removal.

- [ ] **Ollama ownership decision** — ollama HM module + model
      management currently in nixos-config (GPU/host-specific).
      Decide: stay in nixos-config (host-specific) or move to
      nix-agentic-tools (reusable)?

- [ ] **Kiro openmemory still raw npx** — not yet using
      `mkStdioEntry`. Fix as part of the nixos-config migration.

### Monitoring / low-urgency TOP

- [ ] **Agentic UX: pre-approve nix-store reads for HM-symlinked
      skills and references** — Claude Code prompts for read
      permission on every resolved `/nix/store` target when
      following symlinks from `~/.claude/skills/`. Five fix options
      to research: global allow rule for `/nix/store/**`,
      per-subtree pre-approval, teach session shortcut, managed
      policy CLAUDE.md, copy instead of symlink. Real-world
      observed 2026-04-07: 10+ minute commit delay from approval
      cycles.

---

## MIDDLE priority

After the architecture foundation solidifies, bring the other
ecosystems online through the completed `ai.*` interface.

### Bring Kiro online (via `ai.kiro.*`)

- [ ] **ai.kiro.\* full passthrough** — mirror every
      `programs.kiro-cli.*` option through `ai.kiro.*`. Same
      pattern as the ai.claude.\* work (TOP). Separate plan to be
      drafted when that chunk is ready.

- [ ] **nixos-config Kiro migration** — move the consumer's Kiro
      config from direct `programs.kiro-cli.*` to `ai.kiro.*`.

### Bring Copilot online (via `ai.copilot.*`)

- [ ] **ai.copilot.\* full passthrough** — mirror every
      `programs.copilot-cli.*` option through `ai.copilot.*`.
      Separate plan to be drafted.

- [ ] **nixos-config Copilot migration** — move consumer config.

- [ ] **copilot-cli / kiro-cli DRY** — 7 helpers copy-pasted
      between the modules. Consolidate as part of the
      full-passthrough work.

- [ ] **MCP server submodule DRY** — duplicated in devenv
      copilot/kiro modules. Consolidate.

### Add OpenAI Codex (4th ecosystem, LAST)

- [ ] **Package chatgpt-codex CLI + HM/devenv module** — follow
      the copilot-cli / kiro-cli pattern. Add to `ai.*` unified
      fanout as 4th ecosystem.

- [ ] **Add Codex ecosystem transform to `fragments-ai`** —
      curried frontmatter generator for Codex steering/instructions
      format (verify what format Codex uses; currently AGENTS.md
      standard is flat).

- [ ] **Wire Codex into `modules/ai/default.nix`** — `ai.codex`
      submodule with `enable`/`package`. Per-CLI enable flips
      `programs.chatgpt-codex.enable` via mkDefault.

- [ ] **Mirror in `modules/devenv/ai.nix`** per config parity.

---

## LOWER priority (deferred)

Everything else. Park these until TOP/MIDDLE are stable.

### CI (except cachix)

- [ ] Revert `ci.yml` branch trigger to `[main]` only (after
      sentinel merge)
- [ ] Remove `update.yml` push trigger, keep schedule +
      workflow_dispatch only
- [ ] After cachix: remove flake input overrides in nixos-config
- [ ] GitHub Pages `docs.yml` workflow — not yet wired in Actions.
      Base path fixes for preview branches also deferred.
- [ ] Review CI cachix push strategy — currently pushes on every
      build (upstream dedup handles storage). Re-evaluate if cache
      size becomes a concern

### Agentic tooling

- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, nvfetcher keys,
      module imports)

### Contributor / build-out docs

- [ ] Generate CONTRIBUTING.md from fragments
- [ ] CONTRIBUTING.md content — dev workflow, package patterns,
      module patterns, `devenv up docs` for docs preview
- [ ] Consumer migration guide — replace vendored packages +
      nix-mcp-servers
- [ ] ADRs for key decisions (standalone devenv, fragment pipeline,
      config parity)

### Misc backlog (unsorted)

- [ ] **Fragment metadata consolidation follow-up** — after the
      TOP item lands, also reduce plan.md churn by having this
      file reference the metadata table instead of re-listing
      fragments
- [ ] **Research cspell plural/inflection syntax** — currently
      every inflected form (`fanout`/`fanouts`, `dedup`/
      `deduplicate`) must be added to `.cspell/project-terms.txt`
      separately. Check cspell docs for root-word expansion or
      Hunspell affix files
- [ ] **outOfStoreSymlink helper for runtime state dirs** — Claude
      writes `~/.claude/projects` mid-session. Document the pattern
      or wrap as `ai.claude.persistentDirs`
- [ ] Secret scanning — integrate gitleaks into pre-commit hook
      or CI
- [ ] Auto-display images in terminal — fragment/hook that runs
      `chafa --format=sixel` via `ai.*` fanout
- [ ] cclsp — Claude Code LSP integration (`passthru.withAdapters`)
- [ ] claude-code-nix review — audit github.com/sadjow/claude-code-nix
      for features to adopt
- [ ] cspell permissions — wire via `ai.*` so all ecosystems get
      cspell in Bash allow rules
- [ ] devenv feature audit — explore underused devenv features
      (tasks, services, process dependencies, readiness probes,
      containers, `devenv up` process naming)
- [ ] filesystem-mcp — package + wire to devenv
- [ ] flake-parts — modular per-package flake outputs
- [ ] Fragment content expansion — new presets (code review,
      security, testing)
- [ ] HM/devenv modules as packages — research NixOS module
      packaging patterns for FP composition
- [ ] Logo refinement — higher quality SVG/PNG
- [ ] MCP processes — no-cred servers for `devenv up`
- [ ] Module fragment exposure — MCP servers contributing own
      fragments
- [ ] Ollama HM module (if kept in this repo per decision above)
- [ ] `scripts/update` auto-discovery — scan nix files for
      hashes instead of hardcoded package lists
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp packaging
- [ ] openmemory-mcp typed settings + missing option descriptions
      (11 attrTag variants)
- [ ] `stack-plan` skill: missing git restack after autosquash
      fixup pattern
- [ ] Repo review re-run — DRY + FP audit of fragment system,
      generation pipeline, doc site. Use `/repo-review` with
      fragment focus
- [ ] Rolling stack workflow skill
- [ ] claude-code build approach consumer docs — Bun wrapper,
      buddy state location, cli.js writable copy, hash routing

---

## Done (history)

Major completed milestones worth tracking. Detailed task lists
for each are in git history; the commit-level breakdown lives in
memory (`project_plan_state.md`) and the session memories.

### Fragment system + generation (2026-04-04 to 2026-04-07)

- Phase 1: FP refactor — target-agnostic core + fragments-ai
- Phase 2: DRY audit — CLAUDE.md generated, fragments
  consolidated
- Phase 3a: Instruction task migration (nix derivations + devenv
  tasks)
- Phase 3b: Repo doc generation — README + CONTRIBUTING from nix
  data (README committed, CONTRIBUTING deferred per LOWER above)
- Phase 3c: Doc site generation — prose/reference/snippets
  pipeline
- Phase 4: `nixosOptionsDoc` (281 HM + 64 devenv), NuschtOS/search,
  Pagefind
- Dynamic generators: overlay, MCP servers, credentials, skills,
  routing
- `{{#include}}` snippets in all mixed pages

### Buddy (2026-04-06 to 2026-04-07)

- `pkgs.claude-code.withBuddy` build-time design (superseded)
- Activation-time HM module rewrite — Bun wrapper + fingerprint
  caching + sops-nix integration
- Null coercion fix for peak/dump
- `any-buddy` rename (dropped `-source` suffix)
- Buddy working end-to-end on user's host

### Steering fragments (Checkpoints 2-8, 2026-04-07)

- Context rot research (`dev/notes/steering-research.md`)
- Prerequisite frontmatter fix: `packagePaths` → lists, Kiro
  transform → inline YAML array
- Generator extension: `mkDevFragment` location discriminator
- Scoped rule file dedup fix (~80 lines per file saved)
- 7 architecture fragments: `architecture-fragments`,
  `claude-code-wrapper`, `buddy-activation`, `ai-module-fanout`,
  `overlay-cache-hit-parity`, `fragment-pipeline`,
  `hm-module-conventions`
- Devenv ai module parity fix (dropped master `ai.enable`)
- Consumer doc updates (4 files)
- Docsite wiring: `siteArchitecture` derivation +
  `docs/src/contributing/architecture/`
- Multi-reviewer audit (6 parallel reviewers)

### CI & Cachix (2026-04-06)

- `ci.yml` — devenv test + package build matrix + cachix push
  (2-arch: x86_64-linux, aarch64-darwin)
- `update.yml` — daily nvfetcher update pipeline (devenv tasks)
- Binary cache: `nix-agentic-tools` cachix (50G plan)

### Backlog grooming (2026-04-07)

- Removed superseded superpowers plan (`with-buddy.md`)
- Removed mostly-done superpowers plan (`pre-hitl-next-steps.md`)
- Extracted long-form content to `dev/notes/` (overlay cache-hit,
  npm contingency)
- Condensed ai-claude-passthrough plan to memory
- Rewrote plan.md with priority tiers (this file)

---

## Next action

**Draft a plan for Task 2 (skills fanout fix) from
`memory/project_ai_claude_passthrough.md`.** It's BLOCKING all of
the ai.claude.\* passthrough work, which in turn is BLOCKING
nixos-config full migration to `ai.*`. Single session, small
diff, high unblock value.
