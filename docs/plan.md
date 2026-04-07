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

Detail lives in `memory/project_ai_claude_passthrough.md`. Tasks
2, 2b, and the consumer verification landed 2026-04-08 (plan
`docs/superpowers/plans/2026-04-08-skills-fanout-fix.md`,
deleted after close-out). Tasks 3-7 and Task D remain — draft a
fresh plan from the memory when ready to execute the next chunk.

- [x] **Task 2: Route `ai.skills` Claude fanout through
      `programs.claude-code.skills`** — landed 2026-04-08 in
      commit `62c247b`. HM Claude branch now delegates skills
      through the upstream option, matching Copilot/Kiro. Layout
      B (real dir with per-file symlinks) confirmed end-to-end on
      a real consumer.

- [x] **Task 2b: Devenv skills fanout parity (Option A
      implemented)** — landed 2026-04-08 across commits `03af9d3`
      (walker helper), `18c6a40` + `9c94e2f` (extension module +
      registration), `8421d75` + `61205a7` (copilot/kiro walker
      refactor), `97ac174` (ai.nix pure-fanout cleanup), `1c98fe3`
      (devshell eval check). Plus follow-up fixes: `8655130`
      (walker handles string paths), `1695263` (buddy activation
      `exit 0` → `if/fi`), `991e23a` (stacked-workflows cruft
      filter), `5a14a0c` (real fix — path literal in
      stacked-workflows HM module). Lessons encoded in
      `dev/fragments/hm-modules/module-conventions.md` in commit
      `feeb5fb`.

- [ ] **Drop `modules/devenv/claude-code-skills` extension when
      upstream devenv ships `claude.code.skills`** — the
      2026-04-08 skills fanout fix landed an extension module
      that adds `claude.code.skills` to devenv (file:
      `modules/devenv/claude-code-skills/default.nix`),
      mirroring how `modules/claude-code-buddy/` extends HM's
      `programs.claude-code` with `buddy`. Upstream tracking:
      [cachix/devenv#2441](https://github.com/cachix/devenv/issues/2441).
      When that lands: 1. Bump devenv flake input to a version
      with the upstream option 2. Verify upstream's option shape
      matches ours (or file a compat shim if it diverges) 3. Delete `modules/devenv/claude-code-skills/` (entire
      extension module) 4. Drop the
      `devenvModules.claude-code-skills` entry from `flake.nix` 5. `modules/devenv/ai.nix` Claude branch keeps the same
      delegation line — `claude.code.skills = lib.mapAttrs
(_: mkDefault) cfg.skills;` — it now points at the upstream
      option transparently. No ai.nix changes needed. 6. Update
      `dev/fragments/devenv/files-internals.md` and
      `dev/fragments/ai-skills/skills-fanout-pattern.md` to
      reflect the new state. Copilot and Kiro devenv modules
      (`modules/devenv/copilot.nix`, `modules/devenv/kiro.nix`)
      are ours and continue to use the walker internally — no
      upstream equivalent to delegate to. Devenv doesn't have
      Copilot or Kiro modules at all currently. Low urgency —
      current extension works fine; this is just hygiene cleanup
      if upstream catches up.

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

- [ ] **Always-loaded content audit + dynamic loading fix
      (HIGH IMPACT)** — measured 2026-04-07 startup context for
      this repo: ~27k tokens across CLAUDE.md (4.2k), AGENTS.md
      (19.1k), `.claude/rules/common.md` (4.2k). That's ~13% of
      Claude's effective context budget burned on orientation
      before any actual work. Three distinct bugs cascading:

      **Bug 1: CLAUDE.md triple-loads.** CLAUDE.md is generated
      as `# CLAUDE.md\n\n@AGENTS.md\n\n` followed by content
      that is **byte-identical** to `.claude/rules/common.md`
      body (verified via diff). At session start Claude Code
      loads:

      1. CLAUDE.md content (~4.2k)
      2. The `@AGENTS.md` import inside CLAUDE.md expands to the
         full AGENTS.md (~19.1k)
      3. `.claude/rules/common.md` (auto-loaded, no `paths`
         frontmatter) — same content as CLAUDE.md body (~4.2k)

      So the orientation content is loaded **three times** under
      Claude.

      **Bug 2: AGENTS.md concatenates every scoped fragment.**
      `dev/generate.nix` `agentsContent` builds AGENTS.md as
      `rootComposed.text + concat-of-every-package-content`.
      Since the agents.md standard has no scoping primitive,
      the generator chose to dump everything into one flat file.
      Result: every scoped architecture fragment
      (claude-code-wrapper, buddy-activation, ai-module-fanout,
      ai-skills, devenv-files, hm-modules, overlays, pipeline,
      etc.) ends up in AGENTS.md regardless of relevance to the
      current edit. 1870 lines, 19.1k tokens.

      **Bug 3: always-loaded monorepo content is itself ~390 lines.**
      The `monorepo` category has 10 fragments (architecture-fragments,
      binary-cache, build-commands, change-propagation,
      generation-architecture, linting, naming-conventions,
      nix-standards, platforms, project-overview) composing into
      ~390 lines / ~4k tokens. Several of these don't need to be
      always-loaded — `binary-cache` is only relevant when editing
      `flake.nix`/`nixConfig`, `platforms` only when adding overlay
      packages, etc. The "always-loaded" set has crept into a
      dumping ground.

      **Cross-ecosystem implication.** Each ecosystem has its own
      always-loaded file with the same orientation content:

      | Ecosystem | Always-loaded file                | Lines |
      | --------- | --------------------------------- | ----- |
      | Claude    | CLAUDE.md + .claude/rules/common.md | 392+387 (dup) |
      | Copilot   | .github/copilot-instructions.md   | 391   |
      | Kiro      | .kiro/steering/common.md          | 393   |
      | Codex (future) | AGENTS.md or its own format   | 1870 (currently) |

      Codex (when added as 4th ecosystem in MIDDLE) will hit the
      same problem because it's also flat. Whatever fix lands
      here must factor in all four ecosystems.

      **Fix plan (small, mostly dev/generate.nix):**

      1. **AGENTS.md = orientation only** — drop the per-package
         concatenation in `agentsContent`. AGENTS.md becomes
         `rootComposed.text` plus a small "see scoped files for
         deep dives" pointer. Tools that consume agents.md
         (Codex, generic agents.md-compatible tooling) get
         orientation, not bloat. ~10-line change in
         `dev/generate.nix`.

      2. **CLAUDE.md → minimal stub** — generate as a one-line
         `@AGENTS.md` (or two-line with `# CLAUDE.md\n\n@AGENTS.md`)
         instead of "AGENTS import + body content". Eliminates
         the 4.2k duplicate. Claude follows the import and gets
         the content from AGENTS.md. ~5-line change in
         `dev/generate.nix`.

      3. **Drop common.md generation** — Claude Code already
         loads CLAUDE.md (which `@AGENTS.md` imports). A separate
         common.md in `.claude/rules/` byte-identical to the body
         is pure waste. Remove the `claudeFiles."common.md" = ...`
         line in `dev/generate.nix`. The scoped rule files stay.
         ~3-line change.

      4. **Audit the monorepo always-loaded set** — for each of
         the 10 monorepo fragments, decide: stay always-loaded,
         move to a scoped category, or delete. Likely stays
         always-loaded:

         - architecture-fragments (orientation + self-maintenance,
           critical)
         - project-overview (what is this repo, must-know)
         - build-commands (universal)
         - linting (universal)
         - change-propagation (cross-cutting rule)

         Likely moves to scoped:

         - binary-cache → scoped to `flake.nix`, `devenv.nix`,
           `nixConfig`-touching files
         - platforms → scoped to `nvfetcher.toml`,
           `packages/**/sources.nix`, `packages/**/*.nix`
         - naming-conventions → scoped to `packages/**`,
           `modules/**`
         - nix-standards → scoped to `**/*.nix` (broad but
           specific to nix files)
         - generation-architecture → scoped to `dev/generate.nix`,
           `dev/tasks/**`, `flake.nix` (overlap with
           pipeline fragment — consider merging)

      5. **Apply same shape across all four ecosystems** — once
         the fragment categorization is settled, the per-ecosystem
         outputs follow:

         - Claude: CLAUDE.md = `@AGENTS.md` stub, common.md
           dropped, `.claude/rules/<cat>.md` scoped
         - Copilot: `.github/copilot-instructions.md` = orientation,
           `.github/instructions/<cat>.instructions.md` scoped
         - Kiro: `.kiro/steering/common.md` (`inclusion: always`)
           = orientation, `.kiro/steering/<cat>.md`
           (`inclusion: fileMatch`) scoped
         - Codex (future): AGENTS.md = orientation. Deep dives
           NOT in AGENTS.md. Codex either lacks the deep dives
           or we add a Codex-native scoping mechanism if one
           emerges.

      **Expected reduction:** ~27k → ~5-7k always-loaded tokens
      (~5x reduction). Per-edit total stays similar because
      scoped fragments load on demand, but the constant cost
      drops.

      **Verification:** after the fix, run `claude /memory` (or
      equivalent) to see the loaded file list and token counts.
      Each ecosystem's always-loaded file should be in the
      ~3-5k token range, not 19k.

      **Touch points:**

      - `dev/generate.nix` — `agentsContent`, `claudeFiles`,
        and `monorepo` category fragment list
      - `dev/fragments/monorepo/*` — 5 fragments may be relocated
        to new scoped categories with new `packagePaths` entries
      - `flake.nix` `siteArchitecture` — if any monorepo fragments
        get scoped, they may need to land in the docsite
        contributing section too
      - `dev/fragments/monorepo/architecture-fragments.md` — the
        always-loaded orientation may need updating to reflect
        the new category list and to document the
        "AGENTS.md = orientation, not deep-dives" decision
      - Verify after: run a session in this repo, count loaded
        tokens via `/memory`, confirm ~5x reduction

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

### Doc site polish

- [ ] **NuschtOS options browser: scopes, deep links, dark mode,
      packages** — observed 2026-04-07: the embedded options
      search at `/options/` defaults to the `All` scope which
      blends DevEnv + Home-Manager and shows duplicate entries
      for every parity option (e.g. `ai.claude.enable` appears
      twice in the list with no disambiguation; only the
      detail pane reveals which scope a hit came from). Six
      separable issues, listed roughly in priority order:

      **1. Add a `lib` scope.** `flake.nix:264` `optionsSearch`
      currently passes only two scopes: `DevEnv` and
      `Home-Manager`. The `lib/` API surface (mkAgenticShell,
      fragments.nix primitives, hm-helpers, ai-common types,
      buddy-types) has no options-doc representation at all.
      Either feed `lib` through `nixosOptionsDoc` via a
      synthetic module that wraps each public function as an
      option (cumbersome), or generate a separate static
      reference page in `fragments-docs` and link to it from
      the search UI's empty-state. The current state silently
      pretends `lib` doesn't exist.

      **2. Link the options browser from README and mdbook.**
      Neither `README.md` nor any page under `dev/docs/`
      mentions `/options/` exists. The browser only shows up
      if a visitor stumbles across the URL. Fix: add a top-level
      "Browse options" link in the README feature matrix and a
      dedicated entry in the mdbook left nav (likely
      `dev/docs/index.md` and the SUMMARY scaffold the
      site-prose generator emits). Cross-link each scope:
      `?scope=0` for DevEnv, `?scope=1` for Home-Manager (and
      eventually `?scope=2` for lib).

      **3. Hide the `All` scope (or remove the blended view).**
      The blended view actively misleads — it suggests every
      option is configured the same way across HM and devenv,
      and the duplicate-row display gives no fast way to tell
      them apart. Upstream blocker:
      [NuschtOS/search#244 "How to hide scope `All`"](https://github.com/NuschtOS/search/issues/244)
      (open, unresolved). Related:
      [NuschtOS/search#284](https://github.com/NuschtOS/search/issues/284)
      (request a `?hideScopes=1` query param). Workarounds
      until upstream lands a fix:

      - **(a) Default-route to a non-`All` scope.** Set the
        embed iframe / mdbook link to `?scope=0` so visitors
        land on DevEnv by default, never see `All` unless they
        change the dropdown. Cheap, partial fix.
      - **(b) Run separate `mkSearch` instances per scope and
        deploy each under its own `baseHref`.** Per the
        research, NuschtOS routes are query-param-only
        (`src/app/app.routes.ts` declares a single
        `path: ""`); there is no path-based per-scope URL like
        `/scope/lib`. To get clean canonical URLs
        (`/options/lib/`, `/options/hm/`, `/options/devenv/`)
        we'd publish three sites side by side. More disk +
        more CI work, but produces shareable per-scope
        landing pages and naturally eliminates the blended
        view since each instance has only one scope.
      - **(c) Wait for upstream.** Watch #244, drop the
        workaround when the option lands.

      Decide between (a)+(c) and (b) based on whether canonical
      per-scope URLs are worth ~3x the search build cost.

      **4. Dark mode investigation.** NuschtOS ships dark theme
      support out of the box (kanagawa palette via `@feel/style`,
      see open issue NuschtOS/search#292 for evidence both
      themes coexist). Our deployed instance (screenshot
      2026-04-07) renders light. Unclear whether NuschtOS
      auto-respects `prefers-color-scheme` or needs a config
      flag — the `@feel/style` source isn't in the NuschtOS
      org and the published package metadata is opaque. Action:
      open the deployed `/options/index.html` in a
      dark-prefers-color-scheme browser, see if it flips. If
      not, file an upstream feature request or check if
      `mkMultiSearch` accepts a theme override. Low effort,
      high quality-of-life win for users on dark systems.

      **5. Packages search (separate tool decision).** When
      this work was originally scoped, the intent was for the
      browser to cover BOTH options (like the Options tab on
      search.nixos.org) AND packages (like the Packages tab,
      e.g.
      `https://search.nixos.org/packages?channel=unstable`).
      NuschtOS does not currently index packages — package
      support lives in
      [NuschtOS/search#280 "packages: init"](https://github.com/NuschtOS/search/pull/280)
      which is still a draft (state: DRAFT, large diff). No
      single self-hostable static web tool currently does
      both options and packages: nixos-search (the
      search.nixos.org backend) requires Elasticsearch which
      NuschtOS was explicitly built to avoid; nix-search-tv is
      TUI-only. Three options:

      - **(a) Wait for #280 to merge** and bump the
        `nuscht-search` flake input. Lowest effort, indefinite
        timeline.
      - **(b) Run NuschtOS for options + a second tool for
        packages** side by side. Doubles the surface to maintain
        and the visitor has to know which tab does what.
      - **(c) Generate a static packages page from
        `fragments-docs`.** We already evaluate the overlay
        package list in `packages/fragments-docs/` for the
        snippets pipeline. Could extend to emit a full mdbook
        page with package name + version + description per
        platform — pagefind would index it for free as part of
        the existing full-text search. Not as rich as a faceted
        UI but ships today, with no upstream dependency.

      Pick (c) if we want it now; (a) otherwise. (b) is
      probably worse than either.

      **6. File a discoverable upstream tracking issue.**
      Once we land any of the above, post a comment summarizing
      our use case on NuschtOS/search#244 (and #280 for
      packages) so upstream knows the multi-scope-no-`All`
      workflow has real users. Helps prioritize.

      **Touch points for the in-repo work:**

      - `flake.nix` — `optionsSearch` `mkMultiSearch` config
        (add `lib` scope, possibly switch to `mkSearch` ×3 for
        approach (b))
      - `dev/docs/index.md` + mdbook SUMMARY scaffold —
        navigation links to `/options/<scope>`
      - `README.md` (which is generated from
        `dev/generate.nix:readmeMd`) — feature matrix entry
        + top-of-readme "Browse options" call-out
      - `dev/notes/` — capture decision rationale (which of
        approaches a/b/c, why) once chosen
      - `.cspell/project-terms.txt` — add `kanagawa` if any
        new prose mentions the palette by name

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

**Skills fanout fix landed 2026-04-08** (commits `62c247b` ..
`feeb5fb`). Tasks 2 and 2b complete, consumer verified end-to-end,
lessons encoded in `hm-modules/module-conventions.md` fragment.
Remaining ai.claude.\* passthrough work: Tasks 3-7 (memory,
settings, mcpServers, skills, plugins) and Task D (devenv
mirror). Next plan can cover any subset.

Other TOP priority candidates that are independent of the
passthrough:

- **Always-loaded content audit + dynamic loading fix** — 27k
  tokens loaded at startup, ~13% of context budget. High impact,
  well-scoped investigation + fix.
- **Overlay cache-hit parity fix** — consumers currently rebuild
  from source instead of hitting cachix. Full plan in
  `dev/notes/overlay-cache-hit-parity-fix.md`.
- **`ai` HM module should `imports` its deps** — single-line
  import for consumers instead of four surgical imports.

Pick the next chunk based on user priority.
