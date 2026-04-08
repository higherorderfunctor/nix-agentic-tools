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

**New architectural north star:**

- **Scoped overlay namespace** — `pkgs.ai.*` replaces today's
  flat top-level (`pkgs.claude-code`, `pkgs.any-buddy`,
  `pkgs.nix-mcp-servers.*`, `pkgs.agnix`, `pkgs.git-*`, …).
  Everything AI-adjacent lives under `pkgs.ai.{cli,mcpServer,…}`.
- **Drop `programs.{kiro-cli,copilot-cli}` HM modules entirely.**
  The stand-alone HM modules were a bridging device while
  upstream HM had no support; they add fanout duplication and
  ceremony we no longer want. Consumers get a single unified
  module surface.
- **Typed factories.** `lib.ai.cli.mkCli`,
  `lib.ai.mcpServer.mkMcpServer`, etc. return package+metadata
  bundles that carry everything needed for fanout: package,
  presets, instruction files, option contributions, ecosystem
  transformers, MCP-server bindings.
- **Named MCP servers allowing duplicates.** Multiple logical
  servers can wrap the same upstream package (e.g. two
  `github-mcp` instances against different endpoints). Names
  are logical, not package-derived.
- **Typed extras contract.** CLI factories accept
  `extraOptions = { <name> = { type, default, description,
onSet }; };` — `onSet` is a lambda
  `{ value, cfg, pkgs, lib }: moduleConfigFragment` so extras
  contribute real module config fragments, not opaque
  attrsets. Claude's buddy support becomes an extra under the
  claude-code package, not a separate lib/HM module.
- **Per-package directory layout.** `packages/ai/<name>/` holds
  everything a single package owns: `default.nix`, sibling
  files (`wrapper.nix`, `patching.nix`, `types.nix`),
  `fragments/`, `hashes.json`, and any module/extras code.
  Bazel-style: "everything about X lives under X".
- **Single consumer, unstable interface.** User is the only
  consumer right now. Correctness of the design wins over
  consumer-stability. Breaking changes are fine during this
  window.

**What survives from the records+adapter design:**

- The _pattern_ — records-as-data feeding a backend-agnostic
  adapter — is right. It just needs to live on the package
  (`passthru.ecosystem = { transformer, layout, translators,
extraOptions, upstream }`) instead of being authored by hand
  in `lib/ai-ecosystems/`.
- The `markdownTransformer` + `translators` split survives.
- The `pushDownProperties` trap lesson survives (dispatch must
  read from record, not from `cfg`).
- The fragment-node + `mkRenderer` library is the transformer
  substrate every factory composes against.

See the "Target architecture" section below for the open
decisions that need to be resolved before implementation plans
get written.

## Architecture (current state — post-pivot)

- **Standalone devenv CLI** for dev shell (not flake-based).
- **`pkgs.ai.*` scoped overlay** — single scope for every
  AI-adjacent package the monorepo ships. (Target; current state
  is flat top-level — migration is a TOP item.)
- **Top-level `ai` HM module** for unified config — delegates
  to per-CLI factories' HM handlers.
- **Config parity** — lib, HM, and devenv must align in
  capability. Parity is driven by the factories' records, not
  duplicated by hand.
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
- **Buddy** — activation-time HM module is LANDED and working
  end-to-end. Target state folds it into the claude-code
  package as a typed extra.
- **Architecture fragments** — path-scoped per-ecosystem,
  single markdown source feeds Claude/Copilot/Kiro/AGENTS.md
  plus the mdbook contributing section. Always-loaded budget
  reduced ~27k → ~5k tokens across all four ecosystems.

## Sequence

The blocking chain, with named dependencies:

1. **Now (blocking everything):** Target architecture spec —
   answer Q1–Q8 below, write the design doc.
2. **Next (blocked on spec):** Factory implementation sequence
   — draft a plan against the spec, then land Steps 1–7 of the
   factory rollout under this branch. Commits can be large;
   end-state matters more than git history during this window
   (user will re-chunk for the main merge next week).
3. **Post-factory (blocked on rollout):** Ecosystem expansion
   - nixos-config integration — bring Kiro/Copilot online via
     the factory, add OpenAI Codex as 4th ecosystem, migrate
     nixos-config off its vendored packages onto the factory.
4. **Parallel (not blocked):** Fragment system maintenance,
   repo hygiene, CI polish, doc site gaps. Pick from these
   between blocking steps when context allows.
5. **Backlog (defer):** Everything else. Park until the
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

- `modules/ai/default.nix` (286 lines) — legacy HM module with
  per-CLI gating and fanout; kept as reference, not consumed by
  flake outputs.
- `modules/claude-code-buddy/default.nix` (208 lines) — buddy
  activation HM module with fingerprint caching, Bun wrapper
  integration, sops-nix UUID file handling; still consumed by
  `modules/ai/default.nix` and transitively by `devenv.nix`
  via `modules/devenv/`.
- `modules/copilot-cli/default.nix` (222 lines), `modules/kiro-cli/default.nix`
  (272 lines) — legacy standalone HM modules for the per-CLI
  surfaces. These were slated for deletion under Q5 of the spec
  but are kept in-tree during the convergence window so nixos-config
  can still pin against them until the factory migration.
- `modules/mcp-servers/servers/*.nix` (12 files, 1145 lines
  including `openmemory-mcp.nix` at 655 lines and
  `github-mcp.nix` at 181 lines) — legacy per-server typed option
  schemas. The factory's `mkMcpServer` uses simpler
  `commonSchema`; absorbing the typed-options work into each
  `packages/<mcp>/lib/mk<Name>.nix` is pending.
- `modules/stacked-workflows/default.nix` (205 lines) — legacy HM
  module for stacked-workflows skill/git-config fanout.
- `modules/devenv/{ai,copilot,kiro}.nix` + `claude-code-skills/` —
  legacy devenv modules still consumed by `devenv.nix` via
  `imports = [ ./modules/devenv ]`. Pre-factory integration;
  works in parallel with the factory devenv module barrel.
- `dev/skills/` (index-repo-docs + repo-review) — consumer dev
  skills referenced by `devenv.nix`'s `ai.skills` config.
- `dev/notes/ai-transformer-design.md` — the Phase 2a transformer
  design research notes. The design survives in
  `lib/ai/transformers/*.nix` (per-ecosystem render functions)
  and the `mkAiApp` render wiring.
- Doc site infrastructure — mdbook + NuschtOS search +
  `lib/options-doc.nix` adapted for factory modules.

The modules/ tree is **imported but not absorbed into factories**.
Absorption is tracked as the "Future absorption backlog" section
below. Until absorption lands, the factory's `mkAiApp` /
`mkMcpServer` and the legacy `modules/` tree coexist: factories
drive new code paths, `modules/` drives the pre-factory consumer
paths via `devenv.nix`. Cache-hit parity is preserved because
both sides use the same `ourPkgs` overlay composition.

### Future absorption backlog

These items finish the factory architecture pivot. Each one
absorbs legacy `modules/` content into the per-package factory
directories, then deletes the corresponding legacy tree. Order
doesn't matter — each is independent — but the `modules/` tree
cannot be deleted until all sub-items land.

- [ ] **Absorb `modules/claude-code-buddy/` into
      `packages/claude-code/lib/mkClaude.nix`** — port the 208-line
      buddy HM module (fingerprint caching, Bun wrapper
      integration, sops-nix UUID file handling, activation
      script) into the claude-code factory as a typed extra.
      Extras contract: `extraOptions.buddy = { type = submodule
      …; onSet = { value, cfg, pkgs, lib }: { home.activation.…
= …; }; };`. Resolves Q6 from the spec. Blocked on
      confirming `onSet` can introduce activation scripts.
- [ ] **Absorb `modules/copilot-cli/` + `modules/kiro-cli/`
      into factory-of-factories** — 222 + 272 lines of HM
      module surface ported to `packages/copilot-cli/lib/mkCopilot.nix`
      and `packages/kiro-cli/lib/mkKiro.nix`. Resolves the
      "Drop `programs.{copilot-cli,kiro-cli}` HM modules
      entirely" directive from the pivot. Coordinate with the
      nixos-config Kiro/Copilot migration below.
- [ ] **Absorb `modules/mcp-servers/servers/*.nix` typed options
      into each `packages/<mcp>/lib/mk<Name>.nix`** — 12 servers,
      ~1145 lines total, with `openmemory-mcp.nix` at 655 lines
      and `github-mcp.nix` at 181 lines being the largest.
      Each server's typed option schema moves under its
      per-package factory call. The factory's simpler
      `commonSchema` stays as the default fallback; typed
      options become per-server customizations.
- [ ] **Absorb `modules/devenv/*` into per-package factory
      devenv modules** — `ai.nix`, `copilot.nix`, `kiro.nix`,
      `mcp-common.nix`, `claude-code-skills/` move under
      `packages/<name>/modules/devenv/`. The factory's devenv
      module barrel then walks packages instead of importing
      a central `modules/devenv/default.nix`.
- [ ] **Absorb `modules/stacked-workflows/` into
      `packages/stacked-workflows-content/`** — 205-line HM
      module for stacked-workflows skill/git-config fanout
      moves under the content package. The content package
      becomes a full factory participant.
- [ ] **Delete `modules/` tree entirely once all absorptions
      land** — with all content ported, `modules/` can be
      removed. `devenv.nix` stops importing `./modules/devenv`
      and switches to `devenvModules.nix-agentic-tools` from
      the factory. `lib/{ai-common,buddy-types,hm-helpers}.nix`
      can also be removed (they were only restored to keep
      `modules/` evaluating).

Additional factory-architecture work that isn't tied to the
modules/ tree:

- [ ] **`mkAiApp` HM vs devenv backend dispatch** — the current
      render wiring writes to `home.file` regardless of backend.
      In a real devenv context this is a type error absorbed by
      stubs in `lib/options-doc.nix:devenvStubModule`. The
      factory should dispatch: `home.file.<outputPath>` for HM
      backends, `files.<outputPath>` for devenv backends. The
      factory captures the render output via
      `_module.args.aiTransformers` so the dispatch can happen
      after the fact. Marked DEFERRED in `lib/ai/app/mkAiApp.nix`.
- [ ] **`github-mcp` + `kagi-mcp` auth option schemas** —
      TODO comments in `packages/github-mcp/lib/mkGithubMcp.nix`
      and `packages/kagi-mcp/lib/mkKagiMcp.nix`. Needs concrete
      option schemas + credential handling (sops-nix pass-through).
- [ ] **Backend-specific render outputs for
      `ai.instructions`** — today the baseline wires every
      ecosystem's rendered instructions into one home.file
      path per app. Per-ecosystem fanout (e.g.,
      `.claude/CLAUDE.md`, `.github/copilot-instructions.md`,
      `.kiro/steering/*.md`, `AGENTS.md`) still lives in
      `modules/ai/default.nix` and should be ported into
      `mkAiApp` once the backend dispatch above lands. The
      `lib/ai/transformers/{claude,copilot,kiro,agentsmd}.nix`
      per-ecosystem transformers are ready and waiting.

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

## Next: factory implementation sequence

Blocked on the spec above. Commits during this sequence can
be large — user cares about end state over clean git history
during the rollout window; re-chunking for the main merge
happens the week after. Tentative shape, not yet detailed
enough for execution:

- [ ] **Step 1: Land `lib/ai/` factory primitives** — minimum
      viable `mkCli` + `mkMcpServer` in `lib/ai/` + the typed
      extras contract + golden tests that exercise the return
      shape chosen in Q1 and the handler-split chosen in Q2.
- [ ] **Step 2: Port one CLI package as proof** — claude-code
      first (biggest test case: wrapper chain, activation-time
      buddy, presets, fragments, HM module, devenv module).
      Target directory: `packages/ai/claude-code/`. Delete
      `packages/ai-clis/claude-code.nix`,
      `packages/ai-clis/any-buddy.nix`, `lib/buddy-types.nix`,
      `modules/claude-code-buddy/` in the same PR.
- [ ] **Step 3: Port one MCP server as proof** — pick one with
      no credential/bridge overhead first (e.g. `fetch-mcp`
      or `context7-mcp`). Validates `mkMcpServer` +
      named-duplicate story + fragment attach.
- [ ] **Step 4: Drop `programs.{copilot-cli,kiro-cli}` HM
      modules.** Port copilot-cli and kiro-cli under
      `packages/ai/` using the factory; verify parity with
      existing options via a one-shot diff test; then delete
      the stand-alone HM modules. This is the
      biggest-blast-radius change of the pivot.
- [ ] **Step 5: Port everything else** — remaining MCP
      servers, remaining AI CLIs, re-home `any-buddy` under
      claude-code, move external servers registry out of
      `flake.nix`.
- [ ] **Step 6: Flatten `ai-ecosystems/` away.** Each CLI
      package carries its own ecosystem record in
      `passthru.ai.ecosystem`. `modules/ai/default.nix`
      becomes a registry walker that invokes each package's
      handler(s). Delete `lib/ai-ecosystems/`, re-introduce
      the safety-net fixtures from the archive (`checks/
module-eval.nix`, 22 tests) translated to the new
      registry shape.
- [ ] **Step 7: Scope overlay under `pkgs.ai.*`.** Final
      restructure of `overlays.default`. Ripples through
      every consumer reference in this repo and in
      nixos-config. Schedule for after Steps 1–6 are green so
      the rename is mechanical.

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

- [ ] **ai.kiro.\* full passthrough** — mirror every
      `programs.kiro-cli.*` option via the factory's typed
      extras contract. Separate plan to be drafted when the
      claude-code port proves the pattern.
- [ ] **nixos-config Kiro migration** — move the consumer's
      Kiro config from direct `programs.kiro-cli.*` to the
      new factory-fed surface.

### Bring Copilot online (via factory)

- [ ] **ai.copilot.\* full passthrough** — mirror every
      `programs.copilot-cli.*` option via the factory's
      typed extras contract. Separate plan to be drafted.
- [ ] **nixos-config Copilot migration** — move consumer
      config.
- [ ] **copilot-cli / kiro-cli DRY** — 7 helpers copy-pasted
      between the old modules. Absorbed into the factory
      port automatically.
- [ ] **MCP server submodule DRY** — duplicated in devenv
      copilot/kiro modules. Absorbed into `mkMcpServer`.

### Add OpenAI Codex (4th ecosystem, LAST)

- [ ] **Package chatgpt-codex CLI + factory registration** —
      follow whatever pattern the claude-code port
      established. Add as 4th ecosystem record.
- [ ] **Add Codex ecosystem transform to `fragments-ai`** —
      curried frontmatter generator for Codex
      steering/instructions format (verify what format Codex
      uses; currently AGENTS.md standard is flat).
- [ ] **Wire Codex into `modules/ai/default.nix`** — the
      registry walker picks it up automatically once the
      package is in place.
- [ ] **Mirror in `modules/devenv/ai.nix`** per config
      parity. Should be free via the factory.

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
- [ ] **Migrate nixos-config AI config to new factory-fed
      `ai.*` module** — replace hardcoded
      `programs.claude-code.*` / `copilot.*` / `kiro.*`
      blocks. See `memory/project_nixos_config_integration.md`
      for the 8 interface contracts and the current vendored
      package list.
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
      architecture fragment documenting the "all three
      branches delegate through `programs.<cli>.skills`, no
      direct home.file writes" decision plus the 2026-04-06
      consumer clobber story. Source content:
      `memory/project_ai_skills_layout.md`. Scope to
      `modules/ai/**`, `packages/**/fragments/**`, and
      `lib/hm-helpers.nix`. Lets fresh clones understand the
      constraint without needing memory access.

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

**Factory rollout M1–M16 landed** (see "Factory rollout
status" above). Branch `refactor/ai-factory-architecture` is
content-complete: factory primitives + all 24 binary packages
under `pkgs.ai.*` + chunks 8–17 imported from sentinel +
transformers wired + doc site build restored + `nix flake
check` and `nix build .#docs` green. Branch has been pushed
to origin along with `archive/phase-2a-refactor` and
`archive/sentinel-pre-takeover` backups.

Two parallel next steps:

1. **Re-chunk for main merge.** User will drive the
   re-chunking into PR-sized batches next week. Milestone
   commit messages (`M1..M16`) provide grouping anchors.
   Chunks 1–7 already landed on main in PRs #3–#11; chunks
   8–17 are now in this branch ready to be re-chunked under
   the factory layout. The merge strategy: stack from main
   with lazy PR extraction + copilot review loops (see
   `project_merge_to_main_strategy.md`).
2. **Start the modules/ tree absorption backlog** (see
   "Future absorption backlog" above). Each sub-item is
   independent and can proceed in parallel with re-chunking.
   The modules/ tree cannot be deleted until all 6
   absorptions land, but individual absorptions unblock
   deletion incrementally. Start with
   `modules/claude-code-buddy/` since it has the clearest
   factory target (`packages/claude-code/lib/mkClaude.nix`)
   and resolves spec question Q6 about extras + activation
   scripts.

The original "Answer Q1–Q8" next action is kept as historical
context in the "Now: target architecture spec" section above;
Q1–Q8 are all answered in
`docs/superpowers/specs/2026-04-08-ai-factory-architecture-design.md`
and implemented across M1–M16.

Both `docs/superpowers/specs/` and `docs/superpowers/plans/`
remain cspell-excluded and never merge to main.
