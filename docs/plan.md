# nix-agentic-tools Plan

> Living document. Single source of truth for remaining work.
> Lives on `sentinel/monorepo-plan` (and the current working
> branch `refactor/ai-factory-architecture` that will take it
> over). **Never merges to main** — PR extraction filters this
> file out. Because of that, cspell is configured to skip it,
> so backlog entries can reference novel tool names, commit
> SHAs, nix store hashes, etc. without ceremony.
>
> Structure is **sequential dependency**, not priority. Later
> sections are blocked on earlier ones by a named dependency
> (spec → implementation → expansion → polish). "Parallel"
> sections are not blocked on the spec/implementation chain
> and can be picked up between blocking steps when context
> allows.

## Pivot decision (2026-04-08)

The prior architecture-foundation + records+adapter approach
(see `archive/phase-2a-refactor` at `cdbd37a`) is being replaced
with a **typed-factory + per-package-directory** design. The
universally-useful pieces of that work (fragment nodes +
`mkRenderer` + `3x → 1x` compose fix + design notes + golden
tests) were ported forward in commit `f088d40` on this branch.
The rest (ecosystem records, HM adapter, `ai-options.nix`,
inline fanout replacements, 22 safety-net fixtures) will be
reshaped under the new contract.

**New architectural north star (post-factory-rollout):**

- **Scoped overlay namespace** — `pkgs.ai.*` replaces the old
  flat top-level (`pkgs.claude-code`, `pkgs.any-buddy`,
  `pkgs.nix-mcp-servers.*`, `pkgs.agnix`, `pkgs.git-*`, …).
  Everything AI-adjacent lives under `pkgs.ai.*`.
- **Drop `programs.{claude-code,copilot-cli,kiro-cli}` HM
  modules as fanout targets entirely.** The stand-alone HM
  modules were a bridging device while upstream HM had no
  support; they added fanout duplication and ceremony we no
  longer want. The factory IS the surface — it writes files
  directly from its config callbacks under `home.file.*`
  (HM) or `files.*` (devenv). No upstream module delegation.
- **Generic AI-app factory.** `lib.ai.app.mkAiApp` is the
  factory-of-factory — "app" deliberately chosen over "cli"
  because the factory/transformer system handles daemons and
  services (e.g. an open-claw-style background app with an
  IPC interface), not just CLIs. Each concrete instance lives
  as
  `lib.ai.apps.mk<Name>` (e.g. `lib.ai.apps.mkClaude`,
  `lib.ai.apps.mkCopilot`, `lib.ai.apps.mkKiro`), produced by
  per-package `packages/<name>/lib/mk<Name>.nix` files that
  get walked into `lib.ai.apps` via `collectFacet` + barrel
  merge in flake.nix.
- **Generic MCP-server factory.** `lib.ai.mcpServer.mkMcpServer`
  is the sibling factory for MCP servers. Concrete instances
  at `lib.ai.mcpServers.mk<Name>`.
- **Named MCP servers allowing duplicates.** Multiple logical
  servers can wrap the same upstream package (e.g. two
  `github-mcp` instances against different endpoints). Names
  are logical, not package-derived.
- **Per-package typed options (no dynamic extras contract).**
  Each factory-of-factory declares its options as a plain Nix
  submodule under `ai.<name>.*`. The current `mkClaude.nix`
  declares `buddy` and `memory` + `settings` as submodule
  options directly; no `extraOptions` / `onSet` lambda
  contract. Single-consumer architecture — static options are
  simpler.
- **Shared cross-app options via `sharedOptions.nix`.** The
  factory declares `ai.mcpServers`, `ai.instructions`,
  `ai.skills` once in `lib/ai/sharedOptions.nix`; `mkAiApp`
  merges per-app overrides on top and threads the merged view
  into each factory's config callback.
- **Per-package directory layout.** `packages/<name>/` holds
  everything a single package owns: `default.nix`, `lib/`
  (per-package factory-of-factory), `modules/homeManager/`,
  `modules/devenv/`, `docs/` (per-package architecture
  fragments), `hashes.json`, and any wrapper/patching code.
  Bazel-style: "everything about X lives under X".
- **Single consumer, unstable interface.** User is the only
  consumer right now. Correctness of the design wins over
  consumer-stability. Breaking changes are fine during this
  window.

**What survives from the Phase 2a records+adapter design:**

- The _pattern_ — records-as-data feeding a backend-agnostic
  adapter — survives in a simpler shape: each factory
  exposes its transformer via
  `transformers.markdown = lib.ai.transformers.<name>` and
  writes files under its own config callback. No global
  `passthru.ai.ecosystem` registry; the per-package factory
  IS the registry entry via `collectFacet`.
- The `markdownTransformer` + per-ecosystem split survives as
  `lib/ai/transformers/{claude,copilot,kiro,agentsmd}.nix`.
- The `pushDownProperties` trap lesson survives (dispatch
  must read from record/cfg, not close over outer state).
- The fragment-node + `mkRenderer` library is the transformer
  substrate every factory composes against.

The Q1-Q8 "Target architecture" section below is kept as
historical context for the pivot brainstorm. All eight
questions are ANSWERED by the landed M1-M16 factory rollout.

## Architecture (current state — post-rollout 2026-04-08)

- **Standalone devenv CLI** for dev shell (not flake-based).
- **`pkgs.ai.*` scoped overlay** — LANDED in M7. All 24
  binary packages under `pkgs.ai.*`. Overlay composition
  walks `packages/*/default.nix` via flake.nix's barrel
  walker.
- **`ai.*` module surface** — LANDED as the factory barrel at
  `homeManagerModules.nix-agentic-tools` and
  `devenvModules.nix-agentic-tools`. Built by `collectFacet
["modules" "homeManager"]` / `collectFacet ["modules"
"devenv"]` walking `packages/*/modules/`. Shared options
  declared once in `lib/ai/sharedOptions.nix`. Per-app
  factories (`lib.ai.apps.mk<Name>`) close over the
  per-ecosystem transformer and the baseline render pipeline.
  **Each factory writes files DIRECTLY** — no delegation to
  `programs.<cli>.*` upstream modules.
- **Config parity** — lib, HM, and devenv must align in
  capability. Parity is driven by `sharedOptions.nix` +
  each factory's config callback handling both backends.
- **Content packages** — published content (skills, fragments)
  lives in `packages/` as derivations with `passthru` for
  eval-time composition.
- **Fragment system** — `lib/fragments.nix` provides node
  constructors (`mkRaw`, `mkLink`, `mkInclude`, `mkBlock`),
  `defaultHandlers`, and `mkRenderer`, plus `compose` +
  `mkFragment`. 14 golden tests in `checks/fragments-eval.nix`.
- **treefmt** via devenv built-in module.
- **devenv MCP** uses public `mcp.devenv.sh` (local Boehm GC
  bug).
- **Buddy** — the full activation-time HM module
  (fingerprint caching, Bun wrapper cli.js patching, sops-nix
  userId, companion reset) lives at
  `modules/claude-code-buddy/default.nix` as REFERENCE ONLY.
  It is NOT exposed by `homeManagerModules.nix-agentic-tools`
  — the factory barrel only imports
  `collectFacet ["modules" "homeManager"]` from per-package
  dirs, and no package exports buddy yet. HM consumers that
  want buddy currently get only the `mkClaude.nix` stub
  (`mkdir -p $HOME/.local/state/claude-code-buddy`). Full
  absorption into `packages/claude-code/lib/mkClaude.nix` is
  tracked as A1 in the Ideal architecture gate below.
- **Architecture fragments** — path-scoped per-ecosystem,
  single markdown source feeds Claude/Copilot/Kiro/AGENTS.md
  plus the mdbook contributing section. Always-loaded budget
  reduced ~27k → ~5k tokens across all four ecosystems.

## Sequence

The blocking chain, with named dependencies:

1. **DONE — Target architecture spec.** Q1-Q8 answered in
   `docs/superpowers/specs/2026-04-08-ai-factory-architecture-design.md`.
2. **DONE — Factory implementation rollout M1-M16.** See
   "Factory rollout status" below for the commit log.
3. **Now (blocking main merge):** Ideal architecture gate —
   land items A1-A10 to absorb the legacy `modules/` tree
   into per-package factory callbacks, then delete `modules/`
   entirely. See "Ideal architecture gate (blocks main merge)"
   below. No new patterns; each item is a mechanical port
   from a named source file to a named target.
4. **Next (blocked on ideal architecture gate):** Re-chunk
   the branch into PR-sized batches for the main merge.
   Chunks 1-7 already landed; chunks 8-17 + factory + A/B
   absorption commits get re-chunked under the factory
   layout.
5. **Post-merge (blocked on main merge):** Ecosystem
   expansion — nixos-config integration, add OpenAI Codex
   as 4th ecosystem, migrate nixos-config off its vendored
   packages onto the factory surface.
6. **Parallel (not blocked):** Fragment system maintenance,
   repo hygiene, CI polish, doc site gaps. Pick from these
   between blocking steps when context allows.
7. **Backlog (defer):** Everything else. Park until the
   blocking chain is stable.

---

## Factory rollout status (2026-04-08)

**Milestones 1–16 landed.** The branch is content-complete and
converged: factory architecture + sentinel chunks 8–17 + Phase 2a
transformer design + doc site build pipeline + M13-era consumer
fixes are all present in one tree. Ready for re-chunking into
PR-sized batches for the main merge.

All 24 binary packages live under `pkgs.ai.*`. The factory
primitives (`lib.ai.app.mkAiApp`, `lib.ai.apps.mk*`,
`lib.ai.mcpServer.mkMcpServer`, `lib.ai.sharedOptions`,
`lib.ai.transformers.*`) are green with golden tests, and the
HM + devenv module barrels (`homeManagerModules.nix-agentic-tools`,
`devenvModules.nix-agentic-tools`) are wired with module-eval
tests. `nix flake check` and `nix build .#docs` both green.

Full rollout commit log on `refactor/ai-factory-architecture`:

- `13fe3a3` M1 lib scaffolding + `769c6cf` M1 review fixes
- `b9620d7` M2 claude-code port + `71895b4` M2 cleanup
- `c3b171d` M3 context7-mcp + `c153280` M3 naming fix
- `64791af` M4 copilot/kiro/gateway/any-buddy
- `5ec4587` M5 13 MCP servers + `68dc0f7` M5 cleanup
- `dae9cdf` M6 git tools + agnix
- `87d1ce8` M7 flake packages splat
- (M8 absorbed into M4/M5/M6 — no separate commit)
- `fba89e9` M9 dissolve fragments-ai
- `be0185e` M10 move fragments-docs → devshell
- `0fa3ca6` mkAiApp baseline instruction render pipeline
  (wires `defaults.outputPath` + `transformers.markdown` → `home.file`)
- `2b7653c` M13 import chunks 8–17 content from sentinel
  (modules/ tree, dev/docs/, dev/skills/, CONTRIBUTING, workflows)
- `0788125` + `18100e8` M14 restore lib helpers + devenv integration
  (lib/ai-common.nix, lib/buddy-types.nix, lib/hm-helpers.nix
  restored so modules/ tree evaluates; devenv.nix rewired to
  composed overlay)
- `3452c66` M15 wire doc site build pipeline (lib/options-doc.nix
  ported and adapted for factory modules, mdbook + NuschtOS +
  pagefind derivations restored to flake.nix, nuscht-search input
  added)

**Milestones 11–12 effectively done by M13.** They were organizational
cleanup (dev fragment reorg + Bazel-style devshell) and the M13
convergence import landed both targets as a side effect:

- Per-package docs: `packages/claude-code/docs/buddy-activation.md`
  and `packages/claude-code/docs/claude-code-wrapper.md` are the
  first per-package doc fragments.
- `devshell/` is Bazel-style — `docs-site/`, `instructions/`,
  `mcp-servers/`, `skills/` subdirectories plus `files.nix` +
  `top-level.nix` flat files (single-file, don't need wrapping).
- `dev/fragments/` keeps its 12 topic categories as repo-level
  content (flake, monorepo, nix-standards, overlays, packaging,
  pipeline, ai-clis, ai-skills, devenv, hm-modules, mcp-servers,
  stacked-workflows). These are all cross-cutting topics, not
  package-owned, so moving them under `packages/<name>/docs/`
  would be wrong. They belong here.

Any remaining fragment relocations are tracked as individual
items in the "Future absorption backlog" below rather than as
M11/M12 umbrellas.

### Convergence gap analysis (2026-04-08)

The pre-convergence state of `refactor/ai-factory-architecture`
was missing ~1800 lines of sentinel content. Root cause: the
branch forked from `main` (chunks 1–7 only) and cherry-picked
only factory primitives from `phase-2a-refactor`, stranding
chunks 8–17 content (modules/, dev/docs/, dev/skills/,
workflows, CONTRIBUTING.md, plus the Phase 2a transformer
design updates) on sentinel. nixos-config's pin was pointing at
`sentinel/monorepo-plan` at the time of the fork, so the
divergence showed up as disappeared features from the consumer's
perspective. M13-M15 closed the gap via `git checkout
origin/sentinel/monorepo-plan -- <paths>` rather than a full git
merge (which would have been 153+ conflicts across the factory
restructure).

**Content that survived the gap analysis and is now in-tree:**

- `modules/ai/default.nix` (286 lines) — **DEAD** legacy HM
  module (not imported by any flake output). Marked REFERENCE
  ONLY in commit `23af2a1` with a header banner. Source
  material for A2/A3/A4 absorption.
- `modules/claude-code-buddy/default.nix` (208 lines) —
  **DEAD** buddy activation HM module (fingerprint caching,
  Bun wrapper integration, sops-nix UUID file handling).
  Marked REFERENCE ONLY. Source material for A1 absorption.
- `modules/copilot-cli/default.nix` (222 lines),
  `modules/kiro-cli/default.nix` (272 lines) — **DEAD**
  legacy standalone HM modules. Marked REFERENCE ONLY.
  Source material for A3 and A4 absorption.
- `modules/mcp-servers/servers/*.nix` (12 files, 1145 lines
  including `openmemory-mcp.nix` at 655 lines and
  `github-mcp.nix` at 181 lines) — **LIVE** via
  `lib/mcp.nix:loadServer` which dynamically imports each
  file for consumers of `lib.mkStdioEntry` /
  `lib.mkStdioConfig`. These are the typed options backend
  for the `lib.mkStdioEntry` external API. A5 absorption
  must keep that API working.
- `modules/stacked-workflows/default.nix` (205 lines) —
  **DEAD** legacy HM module. Marked REFERENCE ONLY. Source
  material for A6 absorption.
- `modules/devenv/{ai,copilot,kiro}.nix` + `claude-code-skills/`
  — **LIVE** via `devenv.nix:imports = [./modules/devenv]`.
  These implement the ai.\* fanout for devenv today. A8
  absorption replaces them with the factory's devenv backend.
- `dev/skills/` (index-repo-docs + repo-review) — consumer dev
  skills referenced by `devenv.nix`'s `ai.skills` config.
- `dev/notes/ai-transformer-design.md` — the Phase 2a transformer
  design research notes. The design survives in
  `lib/ai/transformers/*.nix` (per-ecosystem render functions)
  and the `mkAiApp` render wiring.
- Doc site infrastructure — mdbook + NuschtOS search +
  `lib/options-doc.nix` adapted for factory modules.

The modules/ tree is **partly dead code, partly live via
devenv.nix + lib/mcp.nix**. Absorption is tracked as items
A1-A10 in the "Ideal architecture gate" section below. Until
absorption lands, the factory's `mkAiApp` / `mkMcpServer` and
the legacy `modules/` tree coexist: factories drive HM code
paths, `modules/devenv/*` drives the live devenv consumer
paths via `devenv.nix`. Cache-hit parity is preserved because
both sides use the same `ourPkgs` overlay composition.

### Future absorption backlog — SUPERSEDED

> **Note (2026-04-08 afternoon):** the earlier framing of this
> sub-section ("absorb modules/\* into the factory as typed
> extras with `onSet` callbacks") was based on a stale reading
> of the pivot spec that treated the factory as a wrapper around
> upstream `programs.<cli>.*` modules. The actual north star is
> the opposite: the factory IS the surface, writing files
> directly, with no upstream delegation. The replacement
> actionable list lives in **"Ideal architecture gate (blocks
> main merge)"** below (items A1-A10 + B1-B3). Leaving this
> subsection in place as historical context so the re-framing
> is traceable — do NOT work from the items below; work from
> the A/B items in the gate section.

The original items were:

- ~~Absorb `modules/claude-code-buddy/` into
  `packages/claude-code/lib/mkClaude.nix`~~ → A1
- ~~Absorb `modules/copilot-cli/` + `modules/kiro-cli/`
  into factory-of-factories~~ → A3 + A4
- ~~Absorb `modules/mcp-servers/servers/*.nix` typed options
  into each `packages/<mcp>/lib/mk<Name>.nix`~~ → A5
- ~~Absorb `modules/devenv/*` into per-package factory
  devenv modules~~ → A8 (after A7 backend dispatch)
- ~~Absorb `modules/stacked-workflows/` into
  `packages/stacked-workflows-content/`~~ → A6
- ~~Delete `modules/` tree entirely once all absorptions
  land~~ → A10
- ~~`mkAiApp` HM vs devenv backend dispatch~~ → A7
- ~~`github-mcp` + `kagi-mcp` auth option schemas~~ → A9
- ~~Backend-specific render outputs for
  `ai.instructions`~~ → folded into A2 + A3 + A4

---

## Ideal architecture gate (blocks main merge)

**Goal:** before any commit from this branch is chunked into PRs
for the main merge, the architecture must be ideal — no legacy
`modules/` tree as a live consumer path, no stale `pkgs.fragments-ai`
references, no "deferred to later milestone" stubs. The factory
is the SINGLE fanout path; legacy modules live on as reference
content only until absorbed.

### What "ideal" means post-pivot (north star clarifications)

The factory architecture delegates to **upstream** HM / devenv
modules where upstream provides the capability, and implements
**gaps** directly from its own config callback. It does NOT add
an additional layer of our own `programs.<cli>.*` or
`<cli>.*` modules as bridging between `ai.*` and the real
writes. That two-level dance was the pre-factory bridging
pattern captured on the legacy `modules/{copilot-cli,kiro-cli,
claude-code-buddy,stacked-workflows}/*` files and is going
away.

The ideal pattern, ecosystem by ecosystem:

**Claude Code (HM):** Upstream nixpkgs home-manager provides
`programs.claude-code.{enable, package, settings, skills}`.
The factory delegates to these for upstream-provided
capabilities — e.g., `ai.claude.enable = true` sets
`programs.claude-code.enable = mkDefault true`, `ai.claude.settings`
flows into `programs.claude-code.settings`, `mergedSkills`
flows into `programs.claude-code.skills`. For gaps that
upstream doesn't provide (per-instruction rule files at
`.claude/rules/<name>.md`, the buddy activation script, the
LSP env var `ENABLE_LSP_TOOL=1`, etc.), the factory writes
`home.file.*` / `home.activation.*` directly from its config
callback.

**Claude Code (devenv):** Upstream devenv community module
provides `claude.code.{enable, env, mcpServers, model,
permissions.rules}`. The factory delegates to these. Our own
extension `claude.code.skills` is a gap we own (see
`modules/devenv/claude-code-skills/`); after absorption, the
factory writes the skill files to `files.*` directly instead
of going through a `claude.code.skills` option indirection.
Rule files, LSP env, buddy-adjacent bits remain direct
`files.*` writes.

**Copilot CLI (HM and devenv):** No upstream HM or devenv
module. The factory's `mkCopilot.nix` config callback writes
everything directly — settings.json (with the runtime
`jq '.[0] * .[1]'` merge preserved as an activation script
on HM, equivalent strategy for devenv), mcp-config.json,
lsp-config.json, skills/, agents/, rule files,
`.github/instructions/<name>.instructions.md`. Our legacy
`modules/{copilot-cli,devenv/copilot}.nix` modules get
dropped entirely — there is no intermediate `programs.copilot-cli.*`
or `copilot.*` layer in the ideal shape.

**Kiro CLI (HM and devenv):** Same as Copilot — no upstream
module. `mkKiro.nix` writes `.kiro/settings/cli.json`,
`.kiro/settings/mcp.json`, `.kiro/steering/<name>.md`,
`.kiro/skills/`, `.kiro/agents/`, `.kiro/hooks/` directly.
Legacy `modules/{kiro-cli,devenv/kiro}.nix` get dropped.

The consumer-facing `ai.*` surface:

1. **`ai.*` is the sole consumer-facing surface.** Consumers
   set `ai.claude.enable` / `ai.skills` / `ai.instructions` /
   `ai.mcpServers` / per-app overrides
   (`ai.<name>.skills`, `ai.<name>.mcpServers`, etc.). There
   is NO master `ai.enable` switch; each per-app enable is
   the sole gate. Consumers NEVER touch `programs.<cli>.*` or
   `<cli>.*` directly — the factory handles all delegation to
   upstream internally.
2. **Factory-of-factories implement fanout in their config
   callbacks.** `packages/<name>/lib/mk<Name>.nix` owns BOTH
   the upstream-delegate writes (`programs.claude-code.skills
= mergedSkills` when HM upstream provides skills) AND the
   direct gap writes (`home.file.".claude/rules/foo.md".text =
renderedRule` when upstream has no rule-file option). Per
   ecosystem, the callback makes the delegate-vs-direct
   choice based on what upstream provides.
3. **Per-package typed options.** Each factory declares its
   own options as static Nix submodule fields under
   `ai.<name>.*` (e.g., `ai.claude.buddy`, `ai.claude.memory`,
   `ai.claude.settings`). No dynamic extras contract — single
   consumer, static schemas keep things simple.
4. **Shared cross-app options fan out via `mkAiApp`.** The
   `sharedOptions.nix` declares `ai.skills`, `ai.instructions`,
   `ai.mcpServers` once; `mkAiApp` merges per-app overrides
   on top and threads the merged view into each factory's
   config callback for fanout. Each factory decides how the
   merged view lands on disk (delegate vs direct).
5. **HM vs devenv backend dispatch is a single decision.**
   `mkAiApp` currently writes `home.file.${outputPath}` for the
   baseline instruction render. The backend dispatch chooses
   between `home.file.*` (HM) and `files.*` (devenv) — same
   option tree, different write target. This is a narrow,
   single-point dispatch, not a per-factory divergence.

### Blocking absorption work

Each item below must land before this branch is re-chunked for
main. Order is flexible — the items are mostly independent and
can be worked on in any sequence — but the `modules/` tree
cannot be deleted (the final gate) until every item above it
lands. All items preserve the existing factory scaffolding and
use upstream HM/devenv modules where they exist; nothing
introduces a new architectural pattern.

- [ ] **A1: Port buddy activation into `mkClaude.nix` config
      callback as a gap implementation.** Source:
      `modules/claude-code-buddy/default.nix` (208 lines).
      **Upstream check:** buddy is NOT in upstream
      `programs.claude-code.*`; it's our own addition, so
      the factory implements it directly (no upstream
      delegation). Target: expand `mkClaude.nix`'s `buddy`
      submodule from `{enable, statePath}` to the full
      surface (`species`, `rarity`, `eyes`, `hat`, `shiny`,
      `peak`, `dump`, `userId.text`, `userId.file`,
      `outputLogs`) — declared as `ai.claude.buddy.*` module
      options owned by the factory. Replace the `mkdir -p`
      stub with the full fingerprint + Bun wrapper cli.js
      patch + companion reset activation script, written as
      `home.activation.claudeBuddy` directly (no
      `programs.claude-code.buddy` intermediate option —
      that was our pre-factory bridging-module extension and
      gets dropped). Invariants to preserve (from
      `.claude/rules/claude-code.md`): no `exit` in
      activation blocks, Bun-vs-Node hash consistency,
      `if`/`fi` short-circuit for fingerprint match,
      companion reset on fingerprint mismatch. Add
      `checks/factory-eval.nix` test cases for the buddy
      option shape and the activation script content.
- [ ] **A2: Port claude-code fanout into `mkClaude.nix` config
      callback — delegate to upstream `programs.claude-code.*`
      (HM) + `claude.code.*` (devenv) where they exist, write
      directly for gaps.** Source: `modules/ai/default.nix`
      claude branch (lines ~217-244 plus mcpServers helpers).
      **Upstream delegation (use upstream options):**
      `programs.claude-code.enable = mkDefault true`,
      `programs.claude-code.package = ai.claude.package`,
      `programs.claude-code.settings = ai.claude.settings`
      (freeform merge including `settings.model` +
      `settings.env.*`), `programs.claude-code.skills =
mergedSkills`. Devenv upstream: `claude.code.enable`,
      `claude.code.env`, `claude.code.mcpServers`,
      `claude.code.model`, `claude.code.permissions.rules`
      — delegate to those. **Gap writes (direct `home.file.*`
      / `files.*`):** `.claude/rules/<name>.md` per
      `mergedInstructions` entry using
      `fragmentsLib.mkRenderer claudeTransformer {package = name;}`
      for curried frontmatter (the baseline mkAiApp render
      path only emits a single concatenated file — per
      -instruction rule files need the callback),
      `ENABLE_LSP_TOOL` via
      `programs.claude-code.settings.env.ENABLE_LSP_TOOL`
      when `mergedServers` / lspServers are set (still a
      delegate since settings is upstream). **mcpServers
      delegation:** `programs.claude-code.settings.mcpServers`
      (HM — upstream accepts freeform settings) or
      `claude.code.mcpServers` (devenv upstream). Delete the
      `modules/ai/default.nix` claude branch source material
      from the absorption source list in this plan when
      done.
- [ ] **A3: Port copilot fanout into `mkCopilot.nix` config
      callback — write everything directly (no upstream
      module exists).** Source: `modules/copilot-cli/default.nix`
      (222 lines) plus `modules/ai/default.nix` copilot
      branch (lines ~246-265) plus `modules/devenv/copilot.nix`
      (115 lines). **Upstream check:** neither nixpkgs
      home-manager nor upstream devenv has a `copilot-cli`
      module. Our legacy `modules/{copilot-cli,devenv/copilot}.nix`
      was OUR bridging layer — it gets dropped entirely.
      Target: factory callback writes directly:
      `.config/github-copilot/settings.json`,
      `.config/github-copilot/mcp-config.json`,
      `.config/github-copilot/lsp-config.json`,
      `.config/github-copilot/skills/<name>`, and the
      per-instruction files under
      `.github/instructions/<name>.instructions.md` using
      `copilotTransformer`. Preserve the settings.json
      runtime-merge pattern (`jq -s '.[0] * .[1]'`) from the
      legacy module as an activation script — it protects
      runtime-added `trusted_folders` across rebuilds.
- [ ] **A4: Port kiro fanout into `mkKiro.nix` config
      callback — write everything directly (no upstream
      module exists).** Source: `modules/kiro-cli/default.nix`
      (272 lines) plus `modules/ai/default.nix` kiro branch
      (lines ~267-286) plus `modules/devenv/kiro.nix` (153
      lines). **Upstream check:** no upstream HM or devenv
      module for kiro. Our legacy `modules/{kiro-cli,devenv/kiro}.nix`
      was OUR bridging layer — it gets dropped entirely.
      Target: factory callback writes directly
      `.kiro/settings/cli.json`, `.kiro/settings/mcp.json`,
      `.kiro/steering/<name>.md`, `.kiro/skills/<name>`,
      `.kiro/agents/`, `.kiro/hooks/`. Preserve the
      steering file YAML frontmatter semantics
      (`inclusion: always|fileMatch`, `fileMatchPattern` as
      a YAML list — regressions here silently nuke fragment
      scoping). Same settings.json runtime-merge pattern as
      A3 for the cli.json file.
- [ ] **A5: Port typed MCP server option schemas into
      `packages/<mcp>/modules/mcp-server.nix` (or similar)
      and rewire `lib/mcp.nix:loadServer` to find them.**
      Source: `modules/mcp-servers/servers/*.nix` (12 files,
      ~1145 lines — openmemory-mcp 655, github-mcp 181, the
      rest short). The existing server modules carry:
      (a) typed `settings` option schemas (e.g., github-mcp's
      `toolsets`, `readOnly`, `ghHost`), (b) working credentials
      via `mcpLib.mkCredentialsOption` (see A9 note),
      (c) `modes.{stdio,http}` command strings, (d) `settingsToEnv`
      / `settingsToArgs` projection functions. **Target**: move
      each server's content under its per-package directory
      (e.g., `packages/github-mcp/modules/mcp-server.nix`) so
      `packages/<name>/` holds everything the server owns.
      Rewire `lib/mcp.nix:loadServer` from
      `../modules/mcp-servers/servers/${name}.nix` to
      `../packages/${name}/modules/mcp-server.nix` (mechanical
      path substitution). **Critical:** the external API
      `lib.mkStdioEntry` / `lib.mkHttpEntry` / `lib.mkStdioConfig`
      MUST keep working unchanged. nixos-config uses it today
      at the pinned commit `f341bcb`; any regression breaks
      the consumer. Verification: after the move,
      `nix eval .#lib.mkStdioEntry` returns a function with
      the same shape, and setting `settings.credentials.file`
      still flows through to `mkSecretsWrapper` at runtime.
      (Note: the factory's `mkMcpServer` +
      `packages/<mcp>/lib/mk<Name>.nix` files under
      `lib.ai.mcpServers.*` are a SEPARATE, newer API that
      has `options = {};` today. Either delete them as YAGNI
      until a consumer needs them, or wire them to re-read
      from the same `modules/mcp-server.nix` files so the
      two APIs stay in sync. Pick whichever is cleaner at
      port time — no consumer is blocking on the newer API.)
- [ ] **A6: Port stacked-workflows HM module into
      `packages/stacked-workflows-content/modules/homeManager/default.nix`.**
      Source: `modules/stacked-workflows/default.nix` (205
      lines). Target: the content package becomes a full factory
      participant via the `modules.homeManager` facet walked by
      `collectFacet ["modules" "homeManager"]` in flake.nix.
      Port git-config-full / git-config-minimal presets +
      skill fanout to the factory path (Claude / Copilot / Kiro
      branches each write their own skill files directly, no
      `programs.<cli>.skills` delegation).
- [ ] **A7: Implement `mkAiApp` HM vs devenv backend dispatch.**
      Today `mkAiApp` writes `home.file.${outputPath}` regardless
      of backend; in `lib/options-doc.nix:devenvStubModule` the
      `home.file` path is stubbed so devenv module eval absorbs
      the write silently. The dispatch should switch to
      `files.${outputPath}` when running under a devenv module
      eval. One option: pass a `backend = "home-manager" | "devenv"`
      specialArg into each factory module eval and branch inside
      `mkAiApp` on it. Another: two sibling mkAiApp wrappers
      (`mkAiHomeApp` / `mkAiDevenvApp`) that close over the
      backend. Whichever is picked, the A2-A4 factory callbacks
      must use the same dispatch so `home.file` vs `files.*`
      choice is centralized, not duplicated per factory. This
      gates the modules/devenv tree absorption, since today
      modules/devenv/*.nix writes `files.*` directly.
- [ ] **A8: Port modules/devenv/*.nix fanout into the per-package
      factory callbacks (devenv half).** Source:
      `modules/devenv/{ai,copilot,kiro}.nix`,
      `modules/devenv/claude-code-skills/`,
      `modules/devenv/mcp-common.nix`. Target: the same factory
      callbacks A2-A4 write `files.*` instead of `home.file.*`
      via A7's backend dispatch. Delete the legacy `modules/devenv/`
      tree, then rewire `devenv.nix` to import
      `devenvModules.nix-agentic-tools` instead of
      `./modules/devenv`.
- [x] **A9: ~~Add typed auth options to `mkGitHub.nix` +
      `mkKagi.nix`.~~** **NOT NEEDED — auth is already
      settled.** Confirmed 2026-04-08 afternoon:
      `modules/mcp-servers/servers/github-mcp.nix:86`
      already has `credentials =
mcpLib.mkCredentialsOption "GITHUB_PERSONAL_ACCESS_TOKEN"`
      and `modules/mcp-servers/servers/kagi-mcp.nix:25`
      has `credentials = mcpLib.mkCredentialsOption "KAGI_API_KEY"`.
      Consumer path: `lib.mkStdioEntry` → `loadServer` →
      typed server module → `mkSecretsWrapper` generates a
      shell wrapper that reads the file at runtime. This is
      LIVE and used by nixos-config today at the pinned
      commit `f341bcb`:
      ```nix
      github-mcp = inputs.nix-agentic-tools.lib.mkStdioEntry pkgs {
        package = pkgs.nix-mcp-servers.github-mcp;
        settings.credentials.file = config.sops.secrets."${username}-github-api-key".path;
      };
      ```
      The TODO comments I wrote into
      `packages/github-mcp/lib/mkGitHub.nix` and
      `packages/kagi-mcp/lib/mkKagi.nix` earlier this
      session were based on a stale reading — those comments
      need to be corrected to note that auth lives in the
      typed server module schemas, picked up automatically
      when A5 absorbs the typed modules into the per-package
      factory dirs. Folded into A5.
- [ ] **A10: Delete `modules/` tree entirely.** Once A1-A8 land
      (A9 is already settled),
      `modules/` holds nothing that isn't duplicated under
      `packages/<name>/`. `lib/{ai-common,buddy-types,hm-helpers}.nix`
      can also be deleted (they exist solely to keep modules/
      evaluating). Final verification: `git grep -l
"modules/\|ai-common\|buddy-types\|hm-helpers"` returns
      nothing under the active source tree (tests, docs, and
      plan.md itself may keep historical references). At this
      point the branch is ready for main-merge re-chunking.

### Self-contained quick-win extras

Items not on the A1-A10 critical path but worth landing in the
same architectural pass, while the factory code is still hot in
memory:

- [ ] **B1: Verify each mkMcpServer instance gets a fanout
      path.** Today the factory's `sharedOptions.mcpServers`
      gets merged per-app and threaded into `mergedServers`,
      but each factory's config callback has to actually
      serialize that to disk. A2-A4 cover claude/copilot/kiro;
      B1 is the test harness verifying all three produce a
      valid JSON shape per ecosystem (claude mcp.json format,
      copilot mcp-config.json format, kiro settings/mcp.json
      format).
- [ ] **B2: `checks/factory-eval.nix` coverage expansion.**
      Add tests asserting that (a) `ai.claude.enable + ai.skills`
      produces the expected `home.file.".claude/skills/..."`
      entries, (b) `ai.copilot.enable + ai.instructions`
      produces `.github/instructions/<name>.instructions.md`
      with copilot frontmatter, (c) `ai.kiro.enable +
ai.instructions` produces `.kiro/steering/<name>.md`
      with kiro frontmatter + valid YAML
      `fileMatchPattern`. These prevent regressions during
      A1-A10 and after.
- [ ] **B3: Drop the `lib/ai-common.nix` + `lib/buddy-types.nix`
      + `lib/hm-helpers.nix` shim files.** These were restored
      in M14 only so `modules/` evaluates. After A10 deletes
      `modules/`, these can go too. Verify nothing under
      `packages/` / `lib/ai/` / `devshell/` imports them.

### Ordering notes

A9 is already settled (see the `A9` entry above — auth was
shipped at sentinel commit `f341bcb` and is in active use by
nixos-config). Sensible sequence for the remaining items:

A5 first (MCP typed option module relocation, biggest
grep-and-replace surface; also carries the settled A9 auth
along as a side effect) → A7 (backend dispatch, unblocks A2-A4
+ A8 writing to both backends) → A2/A3/A4 in parallel (each
factory gets its fanout; A2 delegates to upstream programs.*
where available, A3/A4 implement directly since no upstream
modules exist) → A1 (buddy, benefits from A2 establishing the
mkClaude config callback shape) → A6 (stacked-workflows,
pure content package) → A8 (devenv wire-up, depends on A7) →
A10 (final delete). B1/B2/B3 can interleave wherever.

Any item in this list that grows beyond mechanical work (new
option shapes not derivable from the source, new pattern
invention) should stop and be escalated before continuing.

---

## Now: target architecture spec

### Open questions

These are the open questions from the pivot brainstorm. Each
needs a written answer before the implementation plan gets
drafted. Extended context in
`memory/project_factory_architecture_pivot.md`.

\*\*STATUS (2026-04-08): ANSWERED in
`docs/superpowers/specs/2026-04-08-ai-factory-architecture-design.md`

- IMPLEMENTED in Milestones 1-10. This section is kept for
  historical reference of the design process.\*\*

* [ ] **Q1: Factory return shape** — does `mkCli` return a
      plain derivation with `passthru.ai = { … }`, a NixOS
      module fragment, or a pair `{ package, module }`?
      Related: where does `passthru.fragments` live, and does
      the HM adapter consume `passthru.ai` directly or go
      through a registry attrset?
* [ ] **Q2: HM/devenv handler split** — single backend-agnostic
      handler (package declares `extraOptions.<name>.onSet`
      once, both HM and devenv call it) vs separate
      `extraOptions.<name>.hmOnSet` / `.devenvOnSet`? Picks the
      complexity/flexibility trade-off.
* [ ] **Q3: Package discovery convention** — `packages/ai/`
      auto-walked by `lib.ai.discoverPackages` vs explicit
      registry in `packages/ai/default.nix`? Affects how
      closely we can approach "add a directory, done".
* [ ] **Q4: `mkCli` × `mkMcpServer` composition** — how does a
      CLI factory declare its default MCP server set, and how
      do named+duplicated server instances compose with
      per-CLI fanout? (E.g. "github-mcp instance A bound to
      ai.claude + ai.copilot, instance B bound to ai.codex".)
* [ ] **Q5: Big-bang vs sequenced rollout** — one squash PR
      that rewrites `packages/`, `lib/`, `modules/`, overlays,
      and flake outputs in one shot, vs a staged sequence
      (factory lib → one package ported as proof → drop
      programs.{copilot,kiro} HM modules → everything else).
      Single-consumer + unstable-interface pushes toward
      big-bang, but staged keeps `nix flake check` green
      between increments.
* [ ] **Q6: Buddy as extra contract** — confirm buddy becomes
      `packages/ai/claude-code/extras/buddy.nix` registered
      via `extraOptions.buddy = { type = submodule …;
default = { }; description = "…"; onSet =
{ value, cfg, pkgs, lib }: { … }; };`. Requires
      resolving whether extras can introduce activation
      scripts (buddy needs one) and if that changes the
      `onSet` return shape.
* [ ] **Q7: Named MCP server duplication story** — naming
      rules (must be unique per-CLI? globally?), how the lib
      keys the set, and whether the `pkgs.ai.mcpServer.<name>`
      overlay exposes a _factory_ or an _instance_.
* [ ] **Q8: Typed extras handler signature** — `onSet =
{ value, cfg, pkgs, lib }: …` returning a module-config
      attrset vs returning a free-form `{ hmConfig,
devenvConfig, packages }` trio. Ties to Q2.

### Deliverable

A written design doc under
`docs/superpowers/specs/2026-04-??-ai-factory-architecture-design.md`
answering Q1–Q8 with the brainstorming skill's usual
approach-alternatives-and-decision format. Only after that
does an implementation plan get drafted.

---

## Next: factory implementation sequence — SUPERSEDED

> **Note (2026-04-08 afternoon):** Steps 1-7 below are the
> pre-rollout tentative sketch. All seven steps landed as
> milestones M1-M15 (see "Factory rollout status" above for the
> commit log). Remaining factory work lives in the "Ideal
> architecture gate" section under items A1-A10. Leaving the
> steps in place as historical context. Steps marked [x] are
> done; the pre-factory framing of Step 6 (registry walker
> built around `modules/ai/default.nix` as a live file) was
> abandoned in favor of the `collectFacet` walker over
> `packages/*/modules/` which is now how the barrel is wired.

- [x] **Step 1: Land `lib/ai/` factory primitives** — landed in
      M1 (`13fe3a3`). Factory primitives live in `lib/ai/`.
- [x] **Step 2: Port one CLI package as proof** — landed in M2
      (`b9620d7`). claude-code under `packages/claude-code/`.
      `packages/ai-clis/claude-code.nix` + `any-buddy.nix`
      deleted as part of the port. `modules/claude-code-buddy/`
      kept as REFERENCE ONLY pending A1.
- [x] **Step 3: Port one MCP server as proof** — landed in M3
      (`c3b171d`). context7-mcp under `packages/context7-mcp/`.
- [x] **Step 4: Drop `programs.{copilot-cli,kiro-cli}` HM
      modules.** Partially landed — the factory-of-factories
      `mkCopilot.nix` / `mkKiro.nix` exist at
      `packages/{copilot-cli,kiro-cli}/lib/` with empty config
      callbacks. Full fanout (writing files directly, no
      `programs.<cli>.*` delegation) is tracked as A3 + A4
      in the Ideal architecture gate.
- [x] **Step 5: Port everything else** — landed in M4-M6
      (`64791af`, `5ec4587`, `dae9cdf`). All 24 binaries under
      `pkgs.ai.*`.
- [x] **Step 6: Flatten `ai-ecosystems/` away.** Landed as
      `collectFacet ["modules" "homeManager"]` +
      `collectFacet ["modules" "devenv"]` walkers over
      `packages/*/modules/` in `flake.nix`. The pre-factory
      framing around "`modules/ai/default.nix` becomes a
      registry walker" was abandoned — that file is dead
      reference content, and the walker lives in flake.nix
      directly.
- [x] **Step 7: Scope overlay under `pkgs.ai.*`.** Landed in
      M7 (`87d1ce8`). Overlay composition walks `packages/*/`
      and publishes under `pkgs.ai.*`.

### Sentinel → main catchup leftovers

Chunks 1–7 landed on main in PRs #3–#11 (see "Done" section
below). Chunks 8–17 were paused pre-pivot and imported into
this branch via M13 (`2b7653c`) on 2026-04-08. They are now
in-tree as the legacy `modules/` reference content, pending
absorption into the factory (see "Future absorption backlog"
above).

- [ ] **Kiro openmemory still raw npx** — not yet using
      `mkStdioEntry`. Fix as part of the MCP-server factory
      port.
- [x] **Import chunks 8–17 content into the refactor branch**
      — LANDED in M13 (`2b7653c`) via targeted
      `git checkout origin/sentinel/monorepo-plan -- <paths>`.
      HM modules wave, devenv modules, devshell subdirectories,
      dev/update, fragments, docsite infrastructure, and
      checks are all present in the branch. Absorption into
      factory-of-factories is tracked in the "Future
      absorption backlog" section above. Backup of the
      original merge plan is in
      `archive/sentinel-pre-takeover:docs/superpowers/plans/2026-04-08-sentinel-to-main-merge.md`.
- [ ] **Re-chunk the converged branch into PR-sized batches
      for main merge** — the branch has ~20 commits across
      16 milestones plus review cleanups and the convergence
      import. Milestone commit messages reference their
      number for grouping. Target PR chunks should line up
      with the factory rollout boundaries (M1 primitives,
      M2-M6 per-ecosystem ports, M7 flake splat, M9-M10
      dissolves, M13 convergence, M14-M15 doc site restore).
      User will drive re-chunking; this plan tracks the
      content-complete state, not the chunk breakdown.

---

## Post-factory: ecosystem expansion

Blocked on the factory implementation sequence landing enough
of Steps 1–7 to support a new CLI. Each item can then be
scheduled independently.

### Bring Kiro online (via factory)

**Stale language note:** the earlier items in this section
talked about "passthrough to `programs.kiro-cli.*`" which is no
longer the factory pattern. The factory writes Kiro's files
directly from `mkKiro.nix`'s config callback — no
`programs.kiro-cli` delegation. The relevant absorption work is
tracked as item A4 in the "Ideal architecture gate" section
above.

- [ ] **~~ai.kiro.\* full passthrough~~** → replaced by A4
      (port kiro fanout into `mkKiro.nix` config callback).
      The factory is the surface, not a wrapper around
      `programs.kiro-cli.*`.
- [ ] **nixos-config Kiro migration** — once A4 lands, move
      the consumer's Kiro config to the `ai.kiro.*` surface
      and remove any direct `programs.kiro-cli.*` references.

### Bring Copilot online (via factory)

**Stale language note:** same as Kiro — the factory writes
Copilot's files directly from `mkCopilot.nix`'s config callback;
no `programs.copilot-cli` delegation.

- [ ] **~~ai.copilot.\* full passthrough~~** → replaced by A3
      (port copilot fanout into `mkCopilot.nix` config
      callback). The factory is the surface, not a wrapper.
- [ ] **nixos-config Copilot migration** — once A3 lands,
      move the consumer's Copilot config to the `ai.copilot.*`
      surface and remove any direct `programs.copilot-cli.*`
      references.
- [x] **copilot-cli / kiro-cli DRY** — obsoleted by A3 + A4.
      The 7 helpers copy-pasted between the old modules get
      absorbed into the per-package factory callbacks directly,
      not "the factory port" as previously framed.
- [x] **MCP server submodule DRY** — obsoleted by A5. The
      duplicated devenv copilot/kiro MCP submodule logic
      becomes a single per-mcp-server factory declaration.

### Add OpenAI Codex (4th ecosystem, LAST)

Blocked on A1-A10 completing — the factory shape must be stable
before adding a 4th ecosystem.

- [ ] **Package chatgpt-codex CLI + factory registration** —
      add `packages/chatgpt-codex/` following the
      claude-code/copilot-cli/kiro-cli pattern: overlay
      contribution + `lib/mkCodex.nix` factory-of-factory
      that calls `lib.ai.app.mkAiApp`. Instance lib gets
      walked into `lib.ai.apps.mkCodex` automatically by
      `collectFacet` in flake.nix.
- [ ] **Add Codex transformer under `lib/ai/transformers/`** —
      new `codex.nix` following the same shape as
      `claude.nix` / `copilot.nix` / `kiro.nix`. Verify what
      scoping format Codex uses (currently the AGENTS.md
      standard is flat, so it may fall through to `agentsmd`).
- [ ] **Wire Codex factory into the module barrel.** The
      `collectFacet ["modules" "homeManager"]` +
      `collectFacet ["modules" "devenv"]` walkers pick it up
      automatically once `packages/chatgpt-codex/modules/`
      exists. No edits to `modules/ai/default.nix` (which is
      dead code reference material by then).

### nixos-config integration

Goal: nixos-config fully ported to the new `ai.*` surface.

- [ ] **Wire nix-agentic-tools into nixos-config** — HM
      global + devshell per-repo. Flake input, overlay,
      module imports. Has been partially done (HITL work
      2026-04-06); verify current state and close any gaps.
      During the factory rollout, nixos-config's flake input
      can pin to `refactor/ai-factory-architecture` or
      whatever branch is current — user has confirmed input
      pin flexibility during this window. End-to-end
      verification checklist the rewrite dropped: - [ ] `home-manager switch` runs cleanly end-to-end
      on the real consumer (not just module-eval) - [ ] copilot-cli activation merge: settings.json
      deep-merge preserves user runtime additions
      across rebuilds - [ ] kiro-cli steering files generate with valid
      YAML frontmatter (`inclusion`,
      `fileMatchPattern`, etc.) - [ ] stacked-workflows integrations wire skill files
      into all three ecosystems (Claude, Copilot,
      Kiro) - [ ] Fresh-clone smoke test: `git clone` to /tmp,
      `devenv test`, verify no rogue `.gitignore` or
      generated files leak into the working tree
- [ ] **Migrate nixos-config AI config to the `ai.*` surface**
      — replace hardcoded `programs.claude-code.*` /
      `copilot.*` / `kiro.*` blocks with `ai.<name>.*`
      (consumer now uses the factory's direct file writes, no
      upstream module delegation). See
      `memory/project_nixos_config_integration.md` for the 8
      interface contracts and the current vendored package
      list.
- [ ] **Verify 8 interface contracts hold** — enumerated in
      `memory/project_nixos_config_integration.md`. Refresh
      the memory after integration lands.
- [ ] **Remove vendored AI packages from nixos-config** —
      copilot-cli, kiro-cli, kiro-gateway, ollama HM module
      (TBD). Verify each one's migration path before
      removal.
- [ ] **Ollama ownership decision** — ollama HM module plus
      model management currently in nixos-config
      (GPU/host-specific). Decide: stay in nixos-config
      (host-specific) or move to nix-agentic-tools
      (reusable)?

### Claude-code quality-of-life

Items that were in the old "TOP leftovers" that are really
ecosystem-level polish and fit here:

- [ ] **Set `DISABLE_AUTOUPDATER=1` defensively in
      claude-code wrapper env** — claude-code runs a
      background autoupdater that downloads new binaries and
      rewrites them at the install path. Inappropriate for a
      nix-managed store path. Also set
      `DISABLE_INSTALLATION_CHECKS=1` to silence the "Claude
      Code has switched from npm to native installer"
      snackbar. Design question during the claude-code
      factory port: always-on (Bun wrapper) vs overridable
      (HM settings)?
- [ ] **Claude-code npm distribution removal contingency** —
      monitor `@anthropic-ai/claude-code` publish frequency.
      If Anthropic stops publishing to npm, follow the
      migration plan in
      `dev/notes/claude-code-npm-contingency.md` (nvfetcher
      swap to binary fetch plus one of three buddy fallback
      options; option 3 blocked by closed-source sourcemap
      leak). Related fragment:
      `packages/ai-clis/fragments/dev/buddy-activation.md`.
- [ ] **Agentic UX: pre-approve nix-store reads for
      HM-symlinked skills and references** — Claude Code
      prompts for read permission on every resolved
      `/nix/store` target when following symlinks from
      `~/.claude/skills/`. Five fix options to research:
      global allow rule for `/nix/store/**`, per-subtree
      pre-approval, teach session shortcut, managed policy
      CLAUDE.md, copy instead of symlink. Real-world
      observed 2026-04-07: 10+ minute commit delay from
      approval cycles.

---

## Parallel: fragment system maintenance

Not blocked on the factory chain. Pick up between blocking
steps when context allows. These are the follow-ups from the
Checkpoint 8 multi-reviewer audit of the steering-fragments
work, plus Phase-1/2a carry-overs. Low individual risk, high
cumulative value.

- [ ] **Consolidate fragment enumeration into single metadata
      table** — `devFragmentNames`, `packagePaths`, and
      `flake.nix`'s `siteArchitecture` runCommand all
      hand-list the same fragments. Adding a new architecture
      fragment requires three coordinated edits. Extract a
      single `fragmentMetadata` attrset in
      `dev/generate.nix` that declares each fragment once
      with all fields (location, dir, name, paths, docsite
      output path, category), then project it into
      `devFragmentNames` (grouped by category),
      `packagePaths` (grouped by category), and an exported
      attr that `flake.nix` consumes to build
      `siteArchitecture`. Ideally `siteArchitecture` becomes
      fully auto-discovered. Pairs with the "Replace `isRoot
= package == "monorepo"` with category metadata" item
      below.

- [ ] **Codify gap: ai.skills layout** — create new scoped
      architecture fragment documenting the post-factory
      skills fanout pattern (each factory writes its own
      `.claude/skills/<name>`, `.github/copilot/skills/<name>`,
      `.kiro/skills/<name>` directly from its config callback
      — no `programs.<cli>.skills` delegation) plus the
      2026-04-06 consumer clobber story for the Layout A → B
      transition. Source content:
      `memory/project_ai_skills_layout.md`. Scope to
      `packages/*/lib/mk*.nix` + `packages/*/modules/`. Lets
      fresh clones understand the constraint without needing
      memory access. Dependent on A2/A3/A4 landing so the
      documented pattern matches reality.

- [ ] **Codify gap: devenv files internals** — create new
      scoped architecture fragment documenting the devenv
      `files.*` option's structural constraints (no recursive
      walk, silent-fail on dir-vs-symlink conflict,
      `mkDevenvSkillEntries` workaround). Source content:
      `memory/project_devenv_files_internals.md`. Scope to
      `modules/devenv/**`, `lib/hm-helpers.nix`.

- [ ] **Add scope→fragment map to the self-maintenance
      directive** — the always-loaded
      `dev/fragments/monorepo/architecture-fragments.md`
      doesn't tell sessions which fragment covers which
      scope. Either hand-maintain a table in the fragment OR
      generate one from `packagePaths` via a new nix
      expression embedded at generation time.

- [ ] **Introduction → Contributing link** — the mdbook
      introduction page (`dev/docs/index.md`) doesn't mention
      the new Contributing / Architecture section. Add a
      short section.

- [ ] **Soften agent-directed language in docsite copies of
      fragments** — architecture fragments use imperative
      phrasing ("stop and fix it", "MUST be updated") that
      reads as jarring in the mdbook. Option (a): rewrite
      imperative directives as declarative design contracts.
      Option (c): add a docsite-specific intro blurb framing
      the tone. Option (a) cleaner.

- [ ] **Include commit subject in Last-verified markers** —
      extend `Last verified: 2026-04-07 (commit a3c05f3)` to
      `Last verified: 2026-04-07 (commit a3c05f3 — subject)`.
      Apply to all 7 existing fragments plus document the
      format in the always-loaded architecture-fragments
      fragment.

- [ ] **HM ↔ devenv ai module parity test** — currently
      enforced by code review only. Add a parity-check eval
      test (translated to the new factory registry shape) in
      `checks/module-eval.nix` that evaluates both modules
      with equivalent config and spot-checks that option
      paths match.

- [ ] **Fragment size reduction: `hm-modules` and
      `fragment-pipeline`** — 267 and 186 lines respectively,
      over the 150-line soft budget. Split by sub-concern IF
      real-world usage shows context dilution. Not urgent.

- [ ] **Refactor `mkDevFragment` location discriminator as
      attrset lookup** — current if/else-if branching on
      `dev | package | module` works but extends linearly.
      Replace with `locationBases.${location} or (throw …)`.
      Pure cleanup.

- [ ] **Replace `isRoot = package == "monorepo"` with
      category metadata** — `mkDevComposed` hardcodes a
      string match. Should be explicit category metadata
      (e.g., `{ includesCommonStandards = true; }`). Paired
      with "consolidate fragment enumeration" above.

- [ ] **Document the intentional hm-modules / claude-code
      scope overlap** — both categories' `packagePaths`
      include `modules/claude-code-buddy/**`. Add a comment
      in `dev/generate.nix` explaining the overlap is
      intentional. (Becomes moot once buddy folds into the
      claude-code package.)

- [ ] **`ai.skills` stacked-workflows special case** —
      currently consumers need
      `stacked-workflows.integrations.<ecosystem>.enable =
true` per ecosystem alongside `ai.skills`. Augment
      `ai.skills` to support
      `ai.skills.stackedWorkflows.enable = true` (or similar)
      that pulls SWS skills + routing table into every
      enabled ecosystem in one line. Keep raw
      `ai.skills.<name> = path` for bring-your-own.

---

## Parallel: repo hygiene & CI polish

Not blocked on the factory chain. Pick up between blocking
steps.

### CI (except cachix)

- [ ] Revert `ci.yml` branch trigger to `[main]` only (after
      sentinel merge)
- [ ] Remove `update.yml` push trigger, keep schedule +
      workflow_dispatch only
- [ ] After cachix: remove flake input overrides in
      nixos-config
- [ ] GitHub Pages `docs.yml` workflow — not yet wired in
      Actions. Base path fixes for preview branches also
      deferred.
- [ ] Review CI cachix push strategy — currently pushes on
      every build (upstream dedup handles storage).
      Re-evaluate if cache size becomes a concern
- [ ] **CUDA build verification** — verify packages that opt
      into `cudaSupport` actually build on `x86_64-linux` in
      CI. Lost from the pre-rewrite backlog; never explicitly
      checked since the matrix was set up.

### Repo hygiene

- [ ] **Single source of truth for tool exclude lists (cspell,
      treefmt, agnix, etc.) with file-category classification**
      — today exclude lists for generated/scratch files are
      duplicated across four places minimum:
      (a) `cspell.json` `ignorePaths` (static config, used by
          direct cspell invocations and IDE extensions)
      (b) `devenv.nix` `git-hooks.hooks.cspell.excludes`
          (pre-commit regex filter; must pre-filter because
          cspell exits 1 with "no files matched" when its entire
          input list is filtered by `ignorePaths` alone)
      (c) `treefmt.nix` `settings.global.excludes` (formatter
          bypass — prevents prettier from corrupting Nix globs
          in markdown, e.g. `*.nix` → `_.nix`)
      (d) (future) agnix, biome, taplo, shellcheck, etc. as they
          grow file-specific excludes
      Any new scratch file path has to be added manually in all
      four places without drift. Rectify by building a single
      Nix attrset (probably under `lib/` or `devshell/`) that
      classifies files into categories and feeds every tool
      config that needs them. Categories needed (with some
      overlap):
      - **Generated published docs** (e.g., doc site output,
        README, CONTRIBUTING) — spell-check YES, format NO
        (tool-generated markdown shouldn't be re-formatted on
        top of the generator)
      - **Generated plan / scratch docs** (e.g., `docs/plan.md`,
        `docs/superpowers/**`) — spell-check NO, format NO
        (sentinel-tip only, never merges to main, PR extraction
        filters them out; no value gating commits on their
        content)
      - **Tool artifacts** (e.g., `.direnv/`, `.nvfetcher/`,
        `result/`, `.devenv/`) — spell-check NO, format NO
        (symlinks / build output / caches)
      - **Vendored code** (e.g., `locks/`, anything fetched) —
        case-by-case; usually both NO
      Each tool config reads the category intersection it
      cares about and projects it into the format that tool
      wants (regex list for pre-commit, glob list for treefmt,
      ignorePaths shape for cspell.json generated via
      `pkgs.writeText`). Zero drift possible.
      **Do NOT take the easy route of making treefmt
      best-effort** (e.g., the way agnix can swallow errors
      silently). If a file can't be formatted, it should be in
      an explicit exclude category — not silently skipped at
      runtime. Best-effort modes hide real problems.
      Spotted 2026-04-08 during the ideal-architecture-gate
      plan commit: plan files had to be added to both
      `cspell.json`, `devenv.nix` cspell excludes, AND
      `treefmt.nix` global excludes in three separate commits
      before the tooling stopped fighting the content. The
      treefmt corruption was real (`*.nix` → `_.nix` markdown
      parsing bug) and only caught because I was watching the
      diff. Deferred for another time; listed here so future
      additions to the scratch-file set don't repeat the same
      duplication.
- [ ] **Declutter root dotfiles** — root currently holds
      `.cspell/`, `.nvfetcher/`, `.agnix.toml`, plus other
      tool configs. Move whatever can be moved into a
      `config/` subdirectory (or each tool's idiomatic
      alternate location) to reduce visual noise at the repo
      root. Some tools (e.g. `.envrc`, `.gitignore`,
      `flake.nix`) MUST stay at root — audit each one before
      moving. Lost from the pre-rewrite backlog; called out
      by the user 2026-04-07.
- [ ] **Rename `devshell/` → `modules/devshell/` for layout
      consistency** — top-level repo currently splits
      modules across three locations: `lib/` (functions),
      `modules/` (HM modules + `modules/devenv/`),
      `devshell/` (standalone modules consumed by
      `mkAgenticShell`). The `devshell/` and `modules/devenv/`
      split is meaningful but the inconsistent root-level vs
      `modules/`-nested placement obscures it. Proposal:
      `modules/devshell/` for the standalone modules,
      leaving `modules/devenv/` and `modules/<hm>/` peers.
      Caller flagged on PR #4 review (2026-04-08). Do as a
      single dedicated PR rather than a chunk.
- [ ] **Move `externalServers` registry out of root
      `flake.nix`** — currently `lib.externalServers.aws-mcp`
      is hand-defined in `flake.nix`. Two viable shapes:
      (a) extract to `lib/external-servers.nix` keyed by
      provider, or (b) ship as a content package
      (`packages/external-servers/`) with `passthru.servers`.
      Caller flagged on PR #4 review (2026-04-08). Backport
      when the registry grows past one entry, or when the
      lib/devshell layout refactor above lands.

### Agentic tooling

- [ ] `apps/check-drift` — detect config parity gaps
- [ ] `apps/check-health` — validate cross-references
- [ ] Structural checks (symlinks, fragments, nvfetcher
      keys, module imports)
- [ ] **Drift detection — agent or skill set covering
      multiple categories** (per user feedback on PR #8,
      2026-04-08). Drift detection is broader than just
      generated instruction files; we likely need a
      dedicated agent or set of skills that periodically (or
      on-demand, or in CI) flag drift across multiple
      categories: - **Generated instruction files** — use the devenv
      tasks pattern from the TOP backlog item. - **Stacking tool versions** — `git-absorb`,
      `git-branchless`, `git-revise`, `agnix`. Detect
      upstream releases that diverge from the pinned
      `nvfetcher` versions. Today this is a manual
      `nix run .#update` cadence. A drift agent could
      ping when upstream tags advance past our pin and
      suggest the bump as a PR. - **LSP/MCP option surface** — when an upstream MCP
      server (or LSP) adds/renames/removes settings, our
      typed `services.mcp-servers.servers.<name>.settings`
      schema falls behind silently. Drift detection
      should compare our typed options against upstream
      README / OpenAPI / config schema and flag
      mismatches. - **Any other upstream changes** — claude-code,
      copilot-cli, kiro-cli, mcp servers, devenv itself.
      Anything tracked via nvfetcher that has a
      settings/CLI/config surface we mirror. - **Cross-config parity** — HM module ↔ devenv module
      option parity (existing concept from
      `feedback_consistency_and_discovery.md`). Could be
      promoted from "manual review" to "drift agent flag".
      Implementation shapes to consider: (a) a Claude Code
      agent that runs daily, queries upstream sources, and
      opens issues; (b) a set of `/drift-*` skills that
      human contributors invoke on demand; (c) CI checks for
      the strict drift cases (instruction files, nvfetcher
      pinned versions). Probably a mix of all three.
      Pre-commit hook is the wrong layer for any of these
      because regen/network in pre-commit slows down every
      commit.

### Contributor / build-out docs

- [ ] Generate CONTRIBUTING.md from fragments
- [ ] CONTRIBUTING.md content — dev workflow, package
      patterns, module patterns, `devenv up docs` for docs
      preview
- [ ] Consumer migration guide — replace vendored packages + nix-mcp-servers
- [ ] **Document binary cache for consumers** — current
      `nix-agentic-tools.cachix.org` substituter setup is
      documented internally (`memory/project_cachix_setup.md`)
      but consumers don't have a public-facing "how to opt
      in" page (`extra-substituters` +
      `extra-trusted-public-keys` snippet, `cachix use`
      instructions, sandbox flag notes). Lost from the
      pre-rewrite backlog.
- [ ] ADRs for key decisions (standalone devenv, fragment
      pipeline, config parity, factory architecture)

### Doc site polish

- [ ] **NuschtOS options browser gaps** — observed
      2026-04-07, `/options/` defaults to the `All` scope
      which blends DevEnv + Home-Manager and shows duplicate
      rows for every parity option with no way to
      disambiguate them in the list view. Plus dark mode
      renders light, and packages indexing is missing
      entirely. Full technical research (PR #280 viability,
      patch sizes for #244/#284, dark-mode investigation,
      maintainer responsiveness, alternative tools
      considered) lives in
      `memory/project_nuschtos_search.md`. **Chosen strategy
      (2026-04-07): (A)+(C) — wait on PR #280 upstream, file
      a small upstream PR ourselves for #244/#284 when
      convenient. Not a fork.** Concrete in-repo work: - [ ] Add a `lib` scope to `flake.nix` `optionsSearch`
      (`lib/` API surface has no options-doc
      representation today — needs a synthetic-module
      wrapper or a static reference page in
      `fragments-docs`) - [ ] Link the options browser from README and
      mdbook (`README.md` and `dev/docs/index.md`
      both omit `/options/`); use `?scope=0`/
      `?scope=1` query-param deep links per scope
      (NuschtOS has no path-based per-scope URLs) - [ ] Workaround the `All`-scope blending: change
      the in-repo links to default-route to
      `?scope=0` so visitors never see the blended
      view unless they change the dropdown - [ ] Investigate dark mode: open the deployed
      `/options/index.html` in a
      `prefers-color-scheme: dark` browser, see if
      it flips; if not, fetch `@feel/style` from npm
      and check whether `$theme-mode: dark` SCSS
      override works - [ ] (Optional, when budget allows) File the
      combined #244+#284 upstream PR — ~25 lines,
      single commit, patch shape documented in the
      memory file; tag both issues - [ ] (Optional, if package search becomes
      critical-path before PR #280 merges) Generate
      a static packages page from `fragments-docs`
      and let pagefind index it — uses the overlay
      package list we already evaluate for the
      snippets pipeline

### Misc backlog (unsorted)

- [ ] **Fragment assembler should leave inline source-path
      comments in generated outputs** — when `compose`
      produces a final file (CLAUDE.md, AGENTS.md,
      copilot-instructions.md, etc.), inject HTML comments
      at two levels: (1) top-of-file comment naming the
      source file that defines the composition (e.g.,
      `<!-- generated from dev/generate.nix — do not edit -->`);
      (2) above each composed fragment, a comment naming the
      source markdown path (e.g., `<!-- packages/
coding-standards/fragments/coding-standards.md -->`).
      Reasoning from user 2026-04-08 PR #7 review: makes it
      obvious to a reviewer that (a) the file is generated
      and (b) they should review the fragment SOURCE rather
      than the composed output (except when there's an
      ordering/dedup issue, in which case the source-path
      comments help locate the offending fragments).
      Implementation likely lives in `lib/fragments.nix`
      `compose` (interleave comments between fragment text
      segments) and the four ecosystem transforms in
      `packages/fragments-ai/` (top-of-file comments after
      the YAML frontmatter). HTML comments are markdown-safe
      and won't render visibly in mdbook or AI tool
      consumers. Verify Copilot/Claude/Kiro tolerate the
      comments — none should choke on `<!-- … -->` but
      worth a quick check.
- [ ] **Richer markdown fragment system: heading-aware
      merging** — assess the value of a fragment system that
      knows about markdown heading levels and can MERGE
      fragments under the same heading rather than
      concatenating them as opaque blobs. Use case from
      user 2026-04-08: combining "coding conventions"
      sections from multiple packages (coding-standards,
      ai-clis, mcp-servers, etc.) into a single coherent
      `## Coding Conventions` section with
      package-contributed `### <subsection>` blocks. Today,
      the best you can do is structure each fragment to
      start at the right heading level and rely on document
      order; there's no compile-time merge or de-dup of
      headings across fragments. **Honest assessment
      requested.** Considerations: (1) markdown is a
      fundamentally string-concatenation format — any
      "merge" requires either a markdown AST parser at eval
      time (heavy, would need a Nix-side parser since we
      don't have one) OR a strict naming convention (each
      fragment names its parent heading and the assembler
      groups by name). (2) The Nix evaluator isn't a great
      place for AST parsing — better to do this via a
      string-template DSL where fragments declare
      `{ heading = "Coding Conventions"; level = 2;
subsection = "## Bash"; text = "…"; }`. (3) This
      crosses into "fragment system as document model"
      territory which is a meaningful expansion of scope —
      counter-question is whether the docsite would benefit
      too (which would justify it more) or whether it's
      only the AI instruction pipeline (in which case maybe
      leave it as string-concatenation and rely on
      convention). Don't build this until there's a
      concrete second use case driving the design,
      otherwise risk premature abstraction.
- [ ] **LLM-friendly inline code commenting conventions** —
      author a coding-standards fragment (or extend an
      existing one) that codifies code-comment patterns
      specifically aimed at making implementations traceable
      for LLMs as well as humans. Goal: when an LLM (or
      human) is reading a derivation, override, wrapper, or
      composed module, the comments should give it enough
      breadcrumbs to find the canonical upstream source
      without having to guess.

      Concrete example from chunk 5/6 review feedback
      (2026-04-08): when overriding a nixpkgs package in an
      overlay (e.g.,
      `git-branchless = ourPkgs.git-branchless.override (…)`,
      `github-mcp = ourPkgs.buildGoModule { … }`), include
      an inline comment with a permalink to the upstream
      nixpkgs derivation we're overriding. Today an LLM
      trying to understand "where does the actual buildPhase
      live?" has to grep nixpkgs blindly; with a permalink
      it's one click.

      Other rules to consider (not exhaustive):
      - **Override comments** — link to the upstream
        derivation being overridden (e.g.,
        `# upstream: github.com/NixOS/nixpkgs/tree/<rev>/pkgs/…`).
      - **Wrapper chain comments** — for Bun/Node wrapper
        chains (claude-code), document the wrap order with
        a short ASCII diagram of which derivation feeds
        which.
      - **Function-arg destructuring shape** — when a
        per-package overlay file uses a non-obvious
        function shape (e.g., `{inputs}: {nv-sources, …}: …`),
        comment why and link to the
        `dev/fragments/overlays/overlay-pattern.md`
        fragment that documents the convention.
      - **passthru fields** — when a derivation exports
        `passthru.<name>` for downstream consumers,
        include a brief note ("consumed by
        `lib/mcp.nix:mkPackageEntry`", etc.) so LLMs
        reading the consumer side can grep backwards.
      - **Sidecar files** — when a directory ships a
        sidecar (`hashes.json`, `locks/*`,
        `*-package-lock.json`), document the convention in
        the directory's `default.nix` or a `README.md` so
        an LLM doesn't have to infer the relationship.
      - **`ourPkgs` instantiation reasoning** — already
        documented in the cache-hit-parity fragment, but
        each per-package overlay file should also have a
        terse comment pointing back to the fragment so a
        reviewer scanning a single file gets the
        cross-reference for free.

      Output: a new dev fragment under
      `dev/fragments/coding-standards/` (or similar) that
      lays these out as a checklist contributors run
      through when adding a new derivation/overlay/wrapper.
      Could also be a `/comment-audit` skill that scans
      recently changed `.nix` files and flags missing
      comments.

- [ ] **Fragment metadata consolidation follow-up** — after
      the TOP item lands, also reduce plan.md churn by
      having this file reference the metadata table instead
      of re-listing fragments
- [ ] **Research cspell plural/inflection syntax** —
      currently every inflected form
      (`fanout`/`fanouts`, `dedup`/`deduplicate`) must be
      added to `.cspell/project-terms.txt` separately.
      Check cspell docs for root-word expansion or
      Hunspell affix files
- [ ] **outOfStoreSymlink helper for runtime state dirs** —
      Claude writes `~/.claude/projects` mid-session.
      Document the pattern or wrap as
      `ai.claude.persistentDirs`
- [ ] Secret scanning — integrate gitleaks into pre-commit
      hook or CI
- [ ] **SecretSpec for MCP credentials** — declarative
      secrets provider abstraction for MCP server
      credentials. Pre-rewrite backlog had this; condensed
      to memory but never landed in the new plan structure.
      Pairs well with the bridge/credentials pattern in
      `lib/mcp/` and the per-server credential handling in
      `modules/mcp-servers/`. Folds naturally into the
      `mkMcpServer` factory's credential contract.
- [ ] Auto-display images in terminal — fragment/hook that
      runs `chafa --format=sixel` via `ai.*` fanout
- [ ] cclsp — Claude Code LSP integration
      (`passthru.withAdapters`)
- [ ] claude-code-nix review — audit
      github.com/sadjow/claude-code-nix for features to
      adopt
- [ ] cspell permissions — wire via `ai.*` so all
      ecosystems get cspell in Bash allow rules
- [ ] devenv feature audit — explore underused devenv
      features (tasks, services, process dependencies,
      readiness probes, containers, `devenv up` process
      naming)
- [ ] filesystem-mcp — package + wire to devenv
- [ ] flake-parts — modular per-package flake outputs
- [ ] Fragment content expansion — new presets (code
      review, security, testing)
- [ ] HM/devenv modules as packages — research NixOS
      module packaging patterns for FP composition.
      Becomes moot if the factory design subsumes it.
- [ ] Logo refinement — higher quality SVG/PNG
- [ ] MCP processes — no-cred servers for `devenv up`
- [ ] Module fragment exposure — MCP servers contributing
      own fragments. Direct fit for `mkMcpServer`'s
      `passthru.ai.fragments`.
- [ ] Ollama HM module (if kept in this repo per decision
      above)
- [ ] `scripts/update` auto-discovery — scan nix files for
      hashes instead of hardcoded package lists
- [ ] atlassian-mcp, gitlab-mcp, slack-mcp packaging
- [ ] openmemory-mcp typed settings + missing option
      descriptions (11 attrTag variants)
- [ ] `stack-plan` skill: missing git restack after
      autosquash fixup pattern
- [ ] Repo review re-run — DRY + FP audit of fragment
      system, generation pipeline, doc site. Use
      `/repo-review` with fragment focus
- [ ] Rolling stack workflow skill
- [ ] claude-code build approach consumer docs — Bun
      wrapper, buddy state location, cli.js writable copy,
      hash routing

---

## Done (history)

Major completed milestones worth tracking. Detailed task
lists for each are in git history; the commit-level
breakdown lives in memory (`project_plan_state.md`) and
session memories.

### Phase 1 / 2a foundation (2026-04-07 to 2026-04-08)

- **Phase 1 landed on sentinel then ported forward to this
  branch (commit `f088d40`):** fragment node constructors
  (`mkRaw`, `mkLink`, `mkInclude`, `mkBlock`),
  `defaultHandlers`, `mkRenderer`, 14 golden tests in
  `checks/fragments-eval.nix`, `dev/generate.nix` 3x→1x
  compose fix + `composedByPkg` → `composedByPackage`
  rename, `dev/notes/ai-transformer-design.md` research
  notes.
- **Phase 2a records+adapter design — ARCHIVED as
  `archive/phase-2a-refactor` (`cdbd37a`).** The pattern
  survives the pivot; the files (`lib/ai-ecosystems/`,
  `lib/mk-ai-ecosystem-hm-module.nix`, `lib/ai-options.nix`,
  `modules/ai/default.nix` rewrite, `checks/module-eval.nix`
  22 safety-net fixtures) will be reshaped as
  package-carried `passthru.ai.ecosystem` records under the
  factory design. Reference the archive branch for the
  adapter's `pushDownProperties` fix and `mkMerge`
  handling.

### Architecture foundation (2026-04-08, on sentinel)

- **Phase 1:** `ai` HM module imports its deps
  (single-import consumer) — `761f8ba`.
- **Phase 2:** Always-loaded content audit ~27k → ~5k
  tokens across all four ecosystems (~5x reduction) —
  `432cabb`, `be6333e`, `c4f4aff`, `a9f991b`.
- **Phase 3:** Overlay cache-hit parity fix across 22
  compiled packages + regression gate via
  `checks.cache-hit-parity` (TDD red → green) — `f341bcb`.
- Skills fanout fix (Tasks 2 + 2b) — `62c247b` …
  `feeb5fb`, closed out by `8aa4991`.

### Sentinel → main catchup, chunks 1–7 (2026-04-08)

- **PR #3 chunk 1** `flake-scaffold` — flake skeleton +
  pre-commit
- **PR #4 chunk 2** `lib-primitives` — lib + devshell
  modules
- **PR #5 chunk 3** `fragment-pipeline` — reduced
  `dev/generate.nix` + fragments-ai + 11 dev fragments
  across 5 categories
- **PR #6 chunk 4a** `coding-standards` — content package
  - first `commonFragments` wiring
- **PR #7 chunk 4b** `stacked-workflows-content` — sws
  content + routing-table + un-gitignored AGENTS.md +
  `.github/copilot-instructions.md`
- **PR #8 chunk 4c** `fragments-docs` — page generators +
  new `dev/fragments/overlays/overlay-pattern.md` +
  `build-commands.md` codifying devenv tasks as canonical
  regen UX
- **PR #9 chunk 5** `overlay-git-tools` — first compiled
  overlay, `nvSourcesOverlay` exposing `final.nv-sources`,
  agnix moved to its own `packages/agnix/` (linter/LSP/MCP,
  not a git tool)
- **PR #10 chunk 6** `overlay-mcp-servers` — 14 MCP
  servers + serena/mcp-nixos flake inputs
- **PR #11 chunk 7** `overlay-ai-clis` —
  claude-code/copilot-cli/kiro-cli/kiro-gateway/any-buddy.

### Fragment system + generation (2026-04-04 to 2026-04-07)

- Phase 1: FP refactor — target-agnostic core +
  fragments-ai
- Phase 2: DRY audit — CLAUDE.md generated, fragments
  consolidated
- Phase 3a: Instruction task migration (nix derivations +
  devenv tasks)
- Phase 3b: Repo doc generation — README + CONTRIBUTING
  from nix data (README committed, CONTRIBUTING deferred
  per LOWER above)
- Phase 3c: Doc site generation — prose/reference/
  snippets pipeline
- Phase 4: `nixosOptionsDoc` (281 HM + 64 devenv),
  NuschtOS/search, Pagefind
- Dynamic generators: overlay, MCP servers, credentials,
  skills, routing
- `{{#include}}` snippets in all mixed pages

### Buddy (2026-04-06 to 2026-04-07)

- `pkgs.claude-code.withBuddy` build-time design
  (superseded)
- Activation-time HM module rewrite — Bun wrapper +
  fingerprint caching + sops-nix integration
- Null coercion fix for peak/dump
- `any-buddy` rename (dropped `-source` suffix)
- Buddy working end-to-end on user's host

### Steering fragments (Checkpoints 2–8, 2026-04-07)

- Context rot research (`dev/notes/steering-research.md`)
- Prerequisite frontmatter fix: `packagePaths` → lists,
  Kiro transform → inline YAML array
- Generator extension: `mkDevFragment` location
  discriminator
- Scoped rule file dedup fix (~80 lines per file saved)
- 7 architecture fragments: `architecture-fragments`,
  `claude-code-wrapper`, `buddy-activation`,
  `ai-module-fanout`, `overlay-cache-hit-parity`,
  `fragment-pipeline`, `hm-module-conventions`
- Devenv ai module parity fix (dropped master `ai.enable`)
- Consumer doc updates (4 files)
- Docsite wiring: `siteArchitecture` derivation +
  `docs/src/contributing/architecture/`
- Multi-reviewer audit (6 parallel reviewers)

### CI & Cachix (2026-04-06)

- `ci.yml` — devenv test + package build matrix + cachix
  push (2-arch: x86_64-linux, aarch64-darwin)
- `update.yml` — daily nvfetcher update pipeline (devenv
  tasks)
- Binary cache: `nix-agentic-tools` cachix (50G plan)

---

## Next action

**Factory rollout M1–M16 landed**, plus convergence cleanup
(commits `23af2a1` legacy-module REFERENCE ONLY banners +
devenv transformer compat fix, `da5dc20` M16 plan update).
Branch `refactor/ai-factory-architecture` is architecturally
content-complete but NOT yet ready for main merge — the
modules/ tree still contains pre-factory fanout logic that
must be absorbed into the per-package factories before
chunking. User directive (2026-04-08): "I dont want to merge
to main non-absorbed things into the current architecture."
**Re-chunking will NOT happen this week** — targeted for
late next week, only after the ideal architecture gate below
is fully landed.

**Sequential next steps (this order):**

1. **Work items A1-A10 in "Ideal architecture gate (blocks
   main merge)"** above. These are ten mechanical absorption
   tasks that move fanout logic from `modules/` into each
   package's `lib/mk<Name>.nix` config callback, plus the
   backend dispatch in `mkAiApp`, plus the final `modules/`
   tree deletion. No new architectural patterns — each item
   is a directed port from a known source file to a known
   target. Sensible ordering:
   A5 (mcp typed options, biggest grep-and-replace surface)
   → A7 (backend dispatch, unblocks A2-A4 writing to both
   backends) → A2/A3/A4 in parallel (per-factory fanout)
   → A1 (buddy, benefits from A2 callback shape) →
   A6 (stacked-workflows content package) →
   A8 (devenv wire-up, depends on A7) →
   A9 (mcp auth options) → A10 (final delete).
2. **B1-B3 interleave wherever.** Self-contained quick wins
   that pair well with the A items touching the same files.
3. **Re-chunk for main merge — targeted late next week,
   NOT this week.** Once A1-A10 + B1-B3 land, the branch is
   ready for PR-sized chunking. Milestone commit messages
   (`M1..M16`, plus the A/B commits) provide grouping
   anchors. Chunks 1–7 already landed on main in PRs #3–#11;
   chunks 8–17 content + factory + absorption gets re-chunked
   under the factory layout. Strategy: stack from main with
   lazy PR extraction + copilot review loops (see
   `project_merge_to_main_strategy.md`).

The original "Answer Q1–Q8" next action is kept as historical
context in the "Now: target architecture spec" section above;
Q1–Q8 are all answered in
`docs/superpowers/specs/2026-04-08-ai-factory-architecture-design.md`
and implemented across M1–M16. The "Next: factory
implementation sequence" Steps 1-7 section below is also
superseded — marked [x] with final landing commits.

Both `docs/superpowers/specs/` and `docs/superpowers/plans/`
remain cspell-excluded and never merge to main.
