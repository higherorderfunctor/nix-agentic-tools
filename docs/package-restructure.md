# Package / module restructure — canonical plan

> **Status:** canonical restructure plan, promoted to `docs/` on 2026-07-24; the
> design decisions are **locked**. The restructure **execution itself has not
> started** on the real tree (Track A/B — see §12). This document replaces the
> 8-document restructure cluster, now archived under `docs/archive/`.
>
> **Written:** 2026-07-23; consolidated + reconciled to the locked design
> 2026-07-24. Supersedes every source listed below.
>
> **Two parts, deliberately separated:** **Part I (§0–10 + Appendices A–C)** is
> a faithful synthesis of the 8 source docs plus verified current state — _what
> the sources said_. **Part II (§11–15)** is added judgment that was **in none
> of the sources** — external ecosystem grounding, a prioritisation argument,
> cross-workstream interfaces, and a risk register. Disagree with Part II
> freely; nothing in it invalidates Part I.
>
> **Reading this for a multi-plan convergence session?** Start at **§13**
> (cross-workstream interfaces), then **§12** (the two-track split), then
> **§15**.

---

## 0. What this retires

The restructure thinking was spread across 8 docs written 2026-04-21 →
2026-05-08, re-derived across sessions because the constraint stack has no
upstream pattern to copy. Everything load-bearing from each is folded in below.
The sources are archived under `docs/archive/` (retained for provenance; nothing
load-bearing was dropped).

| Source doc                              | Date       | What it contributed                                                                                           | Disposition                                            |
| --------------------------------------- | ---------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `slice-architecture-assessment.md`      | 2026-05-08 | **Was canonical.** 4 facets, slice=unit, mixed combinators, thin walker, fixture-first                        | folded in → archive                                    |
| `greenfield-package-shape.md`           | 2026-05-04 | "mixed-eval barrel" diagnosis; uniform-path barrel; facet→consumer walker table                               | folded in → archive                                    |
| `mcp-servers-migration-plan.md`         | 2026-05-04 | **Live migration design.** `overlays/`→`packages/mcp-servers/`; readDir walker; cache-hit parity; phased HITL | folded in → archive                                    |
| `mcp-servers-pilot-plan.md`             | 2026-05-04 | Parallel-sandbox feasibility pilot                                                                            | **already superseded** by the migration plan → archive |
| `slice-nav-design.md`                   | 2026-04-28 | Concern-first merge-up namespace; effect-mcp pre-pilot; stay-green discipline                                 | folded in → archive                                    |
| `name-resolution-gap-analysis.md`       | 2026-04-28 | The 14-site smell catalogue → 4 patterns                                                                      | folded in (Appendix A) → archive                       |
| `monorepo-restructure-assessment.md`    | 2026-04-21 | **Origin.** §11 slice layout; merge-up mechanic; flake-parts post-mortem                                      | folded in → archive                                    |
| `ai-factory-collision-refactor-plan.md` | 2026-04-27 | **COMPLETE / landed.** `lib/*`→`lib/ai/*`, collision-as-failure, Dir helpers                                  | historical foundation → archive                        |

Also absorbed: `concepts.md`'s definition of **self-assembly** (§2), which is
the real goal underneath "DRY".

**One supersession worth knowing:** the pilot plan's parallel-sandbox approach
was _abandoned_ in favour of direct migration after "grill 2" reframed the
constraint. Don't resurrect it. Its value now is its **stop conditions** (§8.3).

---

## 1. Where this actually stands

Since the docs were written, a lot landed. The plan's premises shifted:

- **The ai-factory refactor is DONE and promoted to `main`** (fast-forward
  2026-07-23; `main` is now the protected, squash-only trunk). The old
  "restructure before promotion to avoid a second churn" argument is **void**.
- **The top-level `modules/` dir no longer exists** — it dissolved into
  `packages/<pkg>/modules/{homeManager,devenv}/`. (`AGENTS.md`/`CLAUDE.md` still
  list `modules/` as a key directory — they are stale on exactly this area.)
- **`lib/*` moved under `lib/ai/*`**; fragments moved to `packages/<pkg>/docs/`.
- **Per-package co-location is therefore already achieved.** A large slice of
  the original vision is banked.

**What remains** is the part nobody has done:

1. **Coarser slice regrouping** — `kiro/` owning kiro-cli + kiro-gateway,
   `mcp-servers/` owning all ~14 MCP packages, etc.
2. **Overlay split-prep (D-1)** — derivations live in `overlays/<name>.nix`,
   physically separated from every other facet of the same package. The locked
   direction is **not** to dissolve them into packages but to keep `overlays/`
   as a **split-ready subtree**, sever its 4 relative-path seams via the two
   [OVL] refactors, and extract the tree later if desired (§12).
3. **Merge-up to kill the central registries** — the actual DRY win (§4.4).
4. **Barrel-shape cleanup** — the mixed-eval barrel (§3.2).

**Timing:** `migrate-to-trunk-based` is **FOLDED** into this convergence lineage
and its blocking prerequisites are **satisfied** — the primary checkout switched
to `main`, the docs-subsystem removal landed, and the checkout is synced to
`origin/main` (reaudit X8). The real `packages/` file-moves are Track B, now
**deferred** (Fork 2, d4), so they still don't start yet — but by decision, not
because the trunk migration is in flight. See §9.0.

---

## 2. Vocabulary

- **Self-assembly** _(from `concepts.md` — the architectural target)_: artifacts
  emerge from a small set of composable patterns flowing through Nix's module
  system, rather than being explicitly hand-wired. **This is the real goal
  underneath "DRY"** — DRY alone is a proxy that lets non-composing
  implementations pass. Concretely: _dropping a file in place should be enough;
  no registry edit._
- **Slice** — a self-contained domain directory. Coarser than a package; may own
  several derived packages (`kiro/` = kiro-cli + kiro-gateway). A
  dev-**navigation** unit: open it and see everything about that topic.
- **Facet** — one of the four things a slice can contribute: `pkg`, `lib`, `hm`,
  `devenv`. A slice may contribute _any subset_, including one.
- **Concern** — a cross-cutting registry slices contribute rows to
  (`update.targets`, `transformers`, `mcp.serverModules`, `fragments.scopes`).
- **Merge-up** — a slice sets `config.<concern>.<key>`; the root evaluates all
  slices together; the merged `config.<concern>` _is_ the registry. The central
  file dissolves.
- **Barrel** — a `default.nix` in a package/slice dir that lists its facets as
  an attrset. Whether barrels survive is **RESOLVED (d4): no barrels** — facet
  presence is determined by the `<facet>.nix` filename (§8, Fork 1).

---

## 3. The problem

### 3.1 The re-derivation loop

The architecture has been re-derived from first principles across many sessions
because the constraint stack is genuinely unusual and has **no upstream pattern
to copy wholesale**:

1. **Multi-facet per unit** — each package ships a derivation, an HM module, a
   devenv module, lib helpers, and content. Nixpkgs convention is
   single-derivation packages, so its composition patterns don't fully apply.
2. **HM / devenv parity** — every surface configurable in one must be
   configurable in the other.
3. **devenv as external CLI** — devenv is consumed externally and reads
   `devenv.nix` directly; it does **not** compose with flake-parts' `perSystem`.

Eight overlapping documents _is itself the mess_. This doc plus a locked fixture
is the exit.

**Why no upstream pattern was found — and the part that's genuinely nixpkgs'
fault for not existing.** Nixpkgs _deliberately does not co-locate_ packages
with modules: `pkgs/…/foo` and `nixos/modules/services/foo.nix` live in
different trees, because a package and its service module have different
consumers, different review paths, and different lifecycles. That is a
considered choice, not an oversight — so looking to nixpkgs for a multi-facet
layout was always going to come up empty. It doesn't bind here: this repo is a
_tool distribution_ where a unit genuinely is "a CLI **plus** its config
module," shipped and versioned together by one author. Co-location is right for
this repo and wrong for nixpkgs, and that difference is the whole reason the
constraint stack felt unusual. There _are_ ecosystem answers for repos shaped
like this one — see **§11**.

### 3.2 The mixed-eval barrel

`packages/<name>/default.nix` is a literal attrset mixing three value-kinds with
no signal distinguishing them:

```nix
{
  docs = ./docs;                                        # (1) path / data
  modules.homeManager = ./modules/homeManager;          # (2) path → module dir
  lib.ai.apps.mkClaude = import ./lib/mkClaude.nix;     # (3) DEFERRED FUNCTION
}
```

You cannot tell (1) from (3) without opening the referenced file. Consequences:
consumers must know which keys need applying and with what args;
`mkX = import …` deferred constructors proliferate; scope mechanics
(`callPackage`, `makeScope`) get reconstructed inside slices instead of being
available at the root. Worse, `mkClaude.nix` does eval-time
`readFile`/`fromJSON` on `overlays/claude-code-extracted.json` two dirs up —
invisible from the barrel key.

### 3.3 Facets of one package live in two trees

The derivation is in `overlays/<name>.nix` (+ `-sources.json` /
`-extracted.json` sidecars); everything else is in `packages/<name>/`. Every
barrel carries a comment apologising for this ("binaries are the flat-overlay
exception to Bazel-style").

> **Resolution (D-1):** the fix is **not** to dissolve these into `packages/`
> but to keep `overlays/` as a split-ready subtree and sever its 4 relative-path
> seams (the two [OVL] refactors), extracting the tree later if desired — see
> §12.

### 3.4 The registries (the actual DRY violation)

**The set of packages is re-typed in ~6 places with no single source of truth:**
`packages/default.nix`, `overlays/default.nix`
(flatDrvs/mcpServerDrvs/gitToolDrvs/devToolDrvs),
`packages/mcp-services/…/serverNames` (+ a `modelContextProtocolServers`
sublist), `config/update-matrix.nix`, `flake.nix` package flattening, and
`dev/generate.nix` (`devFragmentNames` + `packagePaths`, since dissolved into
`config.fragments.categories`). Adding or renaming one package touches all of
them.

The gap analysis catalogued **14 name-resolution smells → 4 patterns** (full
table in Appendix A):

| Pattern | Shape                                                    | Sites                                                                                                                                                                   | Cure                                                    |
| ------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| **A**   | central registry decoupled from the data it describes    | #2 update-matrix _(dissolved)_, #6 data.nix, #7 packagePaths _(dissolved)_, #8 cache-hit-parity lists _(dissolved)_, #11 excludePatterns _(dissolved)_ (+ #3 Rust list) | **merge-up**                                            |
| **B**   | convention-based name→file lookup (grep / path template) | #1 update-pkg grep _(ACTIVE BUG, PR #91)_, #5 `lib/mcp.nix` loadServer _(latent: breaks when files move)_                                                               | slice declares its own file, same merge-up              |
| **C**   | within-file regex / comment parsing                      | #12 magic comments _(fails **silently**)_, #13 rev/hash sed                                                                                                             | sidecar-JSON or typed decls — **independent of slices** |
| **D**   | explicit registries that are fine as-is                  | #4 overlays/default.nix, #9 flake flatten, #10 bare-commands scope                                                                                                      | leave alone                                             |

Scored: **8 HIGH** merge-up suitability, 3 medium, 3 low. **9 of 14 are
naturally subsumed by the slice move; 5 are independent.** Site #14
(`*-sources.json` sidecars) is explicitly **not** a smell — it is the _good_
pattern and the reference for what a Pattern-C fix should look like.

### 3.5 Transform duplication

`lib/ai/app/hmTransform.nix` and `devenvTransform.nix` are **~135 near-identical
lines each** — the same six `mergeWithCollisionCheck` calls, the same baseline
`ai.<name>.{enable,package,mcpServers,instructions,rules,rulesDir,skills,skillsDir}`
option block, the same L2b→L3 Dir expansion, duplicated verbatim. This is a
direct violation of the repo's own CLAUDE.md DRY rule and is _independent_ of
the slice move — it can be fixed any time.

---

## 4. Target architecture

### 4.1 Four facets, slice = unit

A slice contributes **any subset** of `pkg`, `lib`, `hm`, `devenv` — including
just one. Data lives inside whichever facet owns it. Everything speculative
(transformers, fragments, skills, tasks, checks, apps) was **eliminated as a
facet**: orchestration is cross-slice and lives at the root; the rest are
_concerns_ (§4.4) or implementation details inside a facet.

"Package" is the wrong word — many slices export no derivation.

### 4.2 Mixed native combinators

Each facet rolls up via the mechanism a Nix reader already knows:

| Facet    | Roll-up mechanism                                   |
| -------- | --------------------------------------------------- |
| `pkg`    | `callPackage` (+ readDir walk — see Fork 3)         |
| `lib`    | recursive attrset merge, **collision-checked**      |
| `hm`     | the consumer's home-manager module-system `imports` |
| `devenv` | the consumer's devenv module-system `imports`       |

Rejected: a unified evalModules-everywhere combinator, which imposes option/
`_module.args` ceremony on `lib` and `pkg` rollups that already merge
idiomatically. Cost accepted: two mental models instead of one. Win: lightest
custom plumbing.

**HM and devenv are two independent `evalModules` passes.** Option
_declarations_ are shared (`lib/ai/sharedOptions.nix`), but **values are
per-eval** — a value set in the HM eval is invisible to the devenv eval. This is
why plain modules (stacked-workflows, living-workflow) must contribute from
_both_ backend modules; getting it wrong silently drops content in one backend.
Preserve this honestly; do not paper over it.

### 4.3 Thin, structural walker

The walker is the **only project-specific code in the composition path** —
discover slices on the filesystem, route each facet's contribution to its native
rollup. Tens of lines. Everything downstream is stock Nix. _Keeping it thin is
the load-bearing property._ Acceptance test: **a reviewer reads the walker + one
slice and can explain the whole composition in under five minutes.**

### 4.4 Merge-up dissolves the central registries

This is the heart. A slice declares its own rows; shared code reads the merged
set; nobody imports across slice boundaries and no central file lists packages.

```nix
# slices/kiro/transformer.nix — self-contained, no cross-slice import
{...}: {
  config.transformers.kiro = { … };
  config.update.targets.kiro-cli = { file = ./overlay.nix; … };
}
```

```nix
# anywhere shared that needs all ecosystems
let transformers = config.transformers;   # { claude, copilot, kiro, … }
```

**Namespace shape is concern-first: `config.<concern>.<slice>`.** Slice is a
directory convention; _concerns_ are the runtime contract, and shared code
always consumes by concern. (Rejected: `config.slices.<name>.<concern>` —
nothing ever wants to "iterate slices" at runtime. Rejected: a flat lib attrset
with no module system — loses the collision detection the factory relies on.)

Registries expected to dissolve — roughly 5–7 namespaces:

| Merged namespace        | Replaces                                                                                            |
| ----------------------- | --------------------------------------------------------------------------------------------------- |
| `update.targets`        | `config/update-matrix.nix` + the hardcoded Rust list (via `dependsOn`)                              |
| `transformers`          | `lib/ai/transformers/default.nix` aggregator                                                        |
| `mcp.serverModules`     | `packages/mcp-services` hardcoded `serverNames`                                                     |
| `fragments.categories`  | `dev/generate.nix` `packagePaths` **+ `devFragmentNames`** (both halves of one per-category record) |
| `docs.descriptions`     | `dev/data.nix` _(lower priority; couples to docsite)_                                               |
| `checks.cacheHitParity` | the 5 hardcoded lists in `checks/cache-hit-parity.nix`                                              |

**Design the namespace shape ONCE, before the first slice lands** — otherwise
slice 2 retrofits.

### 4.5 The slice layout (~7)

| Slice                | Contents                                                                       |
| -------------------- | ------------------------------------------------------------------------------ |
| `claude/`            | claude-code package, modules, transformer, fragments, checks, hooks            |
| `kiro/`              | kiro-cli + kiro-gateway, modules, transformer, fragments, checks               |
| `copilot/`           | copilot-cli, modules, transformer, fragments, checks                           |
| `agnix/`             | one Rust workspace → CLI + MCP + LSP outputs; all three overlay entries        |
| `mcp-servers/`       | all standalone MCP servers; `modelContextProtocol/` sub-slice w/ shared source |
| `git-tools/`         | git-absorb, git-branchless, git-revise                                         |
| `stacked-workflows/` | content package + skills + references + SWS modules                            |

Nesting inside a slice is fine (`mcp-servers/<name>/`). **Slices are not a
published surface** — the combined-merge `homeManagerModules.default` /
`devenvModules.nix-agentic-tools` stays exactly as today.

### 4.6 What stays OUT of slices

**Do NOT invent an `_infrastructure/` or `_repo/` slice — root and `lib/`
already serve that role; a wrapper is noise.**

- Root: `flake.nix`, `devenv.nix`, `devenv.yaml`, `treefmt.nix`
- `lib/ai/app/*` (mkAiApp, hmTransform, devenvTransform) — used by every CLI
  slice
- `lib/ai/{sharedOptions,ai-common,hm-helpers,dir-helpers}.nix`,
  `lib/ai/mcpServer/*`
- `lib/{fragments,mcp,hm-dag,devshell,options-doc}.nix` — genuinely
  cross-cutting
- `dev/generate.nix`, `dev/tasks/`, `dev/scripts/`,
  `dev/fragments/{monorepo,pipeline}/`
- `config/`, and `checks/` entries testing cross-slice invariants
- **Root owns tasks / checks / apps** (Cargo/npm/Bazel workspace-vs-package
  split)

### 4.7 Hard constraints

These are not preferences. Violating any is a stop.

1. **`devenv shell` standalone must keep working.** It's the daily driver and
   the consumer contract. ⇒ **flake-parts is off the table** (§7).
2. **Consumer surface stays byte-identical.** `nix eval` of
   `homeManagerModules.default` and `pkgs.<name>` unchanged; nixos-config sees
   nothing until explicitly wanted. Flat `pkgs.<name>` outputs preserved via the
   existing flattening.
3. **Cache-hit parity stays green** at every commit (`checks.cache-hit-parity`).
   The `ourPkgs` pattern is load-bearing — never introduce `final.X` build
   inputs in a migrated `package.nix`.
4. **`ensureUnfreeCheck` stays at the `overlays/default.nix` boundary** — don't
   duplicate it inside slices.
5. **`nix flake check` green after every commit.** No flag days.
6. **`git add` new files before any `nix flake check` / `.#` eval** — flakes
   only see tracked files.
7. **Never touch nixos-config without explicit approval.**

---

## 5. Locked decisions

| #   | Decision                                                                                                                                                                     | Why                                                                                                                                                                                                                                                                                                                                                             |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | The goal is **dev-navigation slices**, not publishing slices                                                                                                                 | The pain is hunting `dev/`, `lib/`, `overlays/`, `checks/` for one topic                                                                                                                                                                                                                                                                                        |
| D2  | Slices are **coarser than packages**; a slice may own many packages                                                                                                          | "Where is X stuff?" gets exactly one answer                                                                                                                                                                                                                                                                                                                     |
| D3  | **~7 slices** (§4.5)                                                                                                                                                         | Coarse grouping of ~28 packages + overlays/checks/fragments                                                                                                                                                                                                                                                                                                     |
| D4  | **Module merge-up**, concern-first `config.<concern>.<slice>`                                                                                                                | Kills cross-slice imports _and_ central registries in one mechanic                                                                                                                                                                                                                                                                                              |
| D5  | **Flake-parts rejected**                                                                                                                                                     | Breaks `devenv shell` standalone; goal is layout + merge-up, not a framework migration                                                                                                                                                                                                                                                                          |
| D6  | **Combined-merge stays the published surface**; per-slice published modules optional/TBD                                                                                     | Slices are a dev-nav unit; external API is a separate, deferrable call                                                                                                                                                                                                                                                                                          |
| D7  | **Four facets only** (pkg/lib/hm/devenv)                                                                                                                                     | Speculative facets had no load-bearing use case                                                                                                                                                                                                                                                                                                                 |
| D8  | **Mixed native combinators**, not module-system-everywhere                                                                                                                   | Avoids evalModules ceremony on lib/pkg                                                                                                                                                                                                                                                                                                                          |
| D9  | **Root owns tasks/checks/apps**                                                                                                                                              | Orchestration is inherently cross-slice                                                                                                                                                                                                                                                                                                                         |
| D10 | **Thin structural walker** — hard budget **~150 lines**; past that the abstraction is losing                                                                                 | Only project-specific code in the path; thinness _is_ the property. Every auto-discovery framework accretes special cases, and this one already has its first before a line is written (the migration plan chose `readDir` over `packagesFromDirectoryRecursive` "given inter-package deps and namespace shaping"). Treat growth as a design smell, not a to-do |
| D11 | **Move the obvious, leave the ambiguous**                                                                                                                                    | Resolving everything in one pass is analysis paralysis                                                                                                                                                                                                                                                                                                          |
| D12 | **Infrastructure stays at root/lib/dev**                                                                                                                                     | No `_infrastructure/` slice                                                                                                                                                                                                                                                                                                                                     |
| D13 | **`lib.ai` two-layer policy:** shared helpers flat at `lib.ai.<helper>`; slice contributions at `lib.ai.<namespace>.<slice>` ⚠️ **weakest decision in this table — see §14** | The two layers aren't contradictory but need a stated policy. Two different addressing schemes in one attrset is a smell; consider separating the contribution namespace out of `lib.ai` entirely before relying on this                                                                                                                                        |
| D14 | **Multi-output sources:** agnix = one slice, three outputs; modelcontextprotocol = shared-source sub-slice                                                                   | One slice per cohesive source                                                                                                                                                                                                                                                                                                                                   |
| D15 | **Pilot one slice before the rest**                                                                                                                                          | Merge-up edge cases are cheaper to debug once                                                                                                                                                                                                                                                                                                                   |
| D16 | **Stay-green via coexistence + atomic file moves** (§9.1)                                                                                                                    | Proven at this scale by the collision refactor                                                                                                                                                                                                                                                                                                                  |
| D17 | **Update-pipeline cleanup is empirical/opportunistic**, not a mass conversion                                                                                                | The homebrew script accreted fixes for real `nix-update` edge cases; a blanket revert re-discovers old bugs                                                                                                                                                                                                                                                     |
| D18 | **Sidecars disfavoured by default**, per-package decision only where `nix-update` genuinely can't express it                                                                 | Avoid a policy that spreads a workaround                                                                                                                                                                                                                                                                                                                        |
| D19 | **Preserve flat `pkgs.<name>`** via existing flattening (Policy A)                                                                                                           | Zero nixos-config impact                                                                                                                                                                                                                                                                                                                                        |
| D20 | **One package per commit** during mechanical migration                                                                                                                       | Each commit independently revertible                                                                                                                                                                                                                                                                                                                            |

---

## 6. The kiro-vs-mcp-servers pilot question (resolved)

The origin doc proposed **kiro** as the pilot (smallest cohesive multi-package
slice, no shared-source complications). The gap analysis then showed **kiro
alone never exercises update-target merge-up at all**, because kiro packages use
`--use-update-script`, not the git-URL Phase-0 path.

Resolution — a **two-step** validation:

- **Pre-pilot:** migrate exactly one update-target (**`effect-mcp`**) into
  `config.update.targets`. ~2 days, one concern, one package, **no slice move**.
  `effect-mcp` was chosen because it's overlay-native (not a nixpkgs
  `overrideAttrs`), has no credentials, is a single package, and is mature — the
  cleanest case to debug if the namespace shape needs adjustment.
- **Pilot:** the first real slice, exercising module-merge across **both** HM
  and devenv eval boundaries with several concerns at once.

The `mcp-servers` migration plan (2026-05-04, the newest of the two lineages)
picks **`mcp-servers` as that first slice** rather than kiro, because it forces
the hard cases immediately: multi-output-from-one-source, sub-namespace
preservation, and cache-hit parity. That's the recommended pilot (§9.3) — but
see Fork 2.

---

## 7. Rejected options — do not re-litigate

Consolidated from all 8 sources, with the reason each died.

**Architecture**

- **Full flake-parts migration** — breaks `devenv shell` standalone (two eval
  paths, no bridge); benefit was only a slightly cleaner `flake.nix`.
- **`flake.aiPackages` registry (`lazyAttrsOf types.raw`) + `materialize`** —
  not a canonical flake-parts pattern; `types.raw` uses `mergeOneOption` and
  **throws on duplicate definition**, breaking multi-contributor merge;
  `materialize`'s `isFunction v → v final` is _not_ equivalent to
  `callPackage v {}` and breaks auto-fill.
- **`self'.packages.foo` inside `checks`** — confirmed infinite-recursion trap
  (flake-parts #22). Use `config.packages.foo` in the same `perSystem`.
- **`filterAttrs`-based aggregate `ai.all` module** — the claim that
  `filterAttrs` "inspects names without forcing values" is **false**; forcing
  `attrNames` resolves the same attrset including the `all` key. Use a static
  enumerated `imports` list.
- **Haumea auto-discovery** — 25 explicit imports isn't a burden; adding an
  input to solve nothing is net negative.
- **`_class = "devenv"` tags** — devenv doesn't enforce a class; no safety gain.
  (`_class = homeManager/nixos` _is_ worth doing — real enforcement since
  23.05.)
- **Module-system-everywhere combinator** — ceremony on facets that merge
  natively.
- **Per-slice `tasks`/`checks`/`apps` facets** — no load-bearing use case.
- **Per-slice three-file modules (`home-manager.nix`+`nixos.nix`+`devenv.nix`)**
  — duplicates the existing factory's delegation. The factory is simpler.
- **`aiInternal.*` namespace with `types.raw`** — same multi-contributor
  footgun; the convention can be a plain `let` if wanted.

**Naming / surface**

- **Rename `devenvModules.nix-agentic-tools` → `.ai.<slice>`** — breaking
  consumer change for cosmetic symmetry; `devenvModules` isn't even a
  standardised output.
- **Slice-first namespace `config.slices.<name>.<concern>`** — no runtime use
  case.
- **Flat lib attrset without the module system** — loses collision detection.

**Process**

- **Parallel-sandbox pilot** _(the whole `mcp-servers-pilot-plan.md`)_ —
  abandoned after grill 2 reframed the constraint; direct migration chosen
  instead.
- **Mass conversion of the update pipeline** up front or baked into slice-nav —
  risks rediscovering the bugs the homebrew script exists to work around.
- **End-to-end consumer integration test in the fixture** — highest fidelity but
  time disappears there; the cheaper bar is enough.
- **Treating `*-sources.json` sidecars as a smell** — they're the _good_
  pattern.
- **Standalone skills-without-Nix** — skills are a CI artifact at most; modules
  can be the only path for content artifacts.

---

## 8. Decisions — naming + Forks 1–3 locked (d4, 2026-07-24); Forks 4–6 still open

> **RESOLVED — d4 (2026-07-24, operator-approved).** The P1 opening decision
> batch (§7) was answered, each on recommendation. Locked:
>
> - **Naming:** keep `slice`/`facet`/`concern` — _no_ rename to std
>   `cell`/`cellblock`. Adopt std's **file-level convention** + the §11 process
>   rule, and cite nix-community `std` + nixpkgs `pkgs/by-name/` as the external
>   **ANCHOR** — take the anchor, not the words.
> - **Fork 1 — no barrels** (filesystem convention).
> - **Fork 2 — defer coarse slices** (Track B), probably indefinitely.
> - **Fork 3 — `builtins.readDir`** discovery (candidate 1 below).
>
> Forks 4 (sidecar-JSON), 5 (walker placement), 6 (per-slice published modules)
> are **still open** — d4 did not touch them. Each fork's option analysis is
> retained below as rationale / rejected-alternatives; nothing is deleted.

### Naming — keep slice/facet/concern _(RESOLVED, d4)_

**Decision:** keep the existing vocabulary; do not rename to std's
`cell`/`cellblock`. The value of §11 is the external anchor and the process
rule, not the words — the vocab already maps 1:1 onto the walker; "cell" is more
overloaded, "cellblock" drags in std's CLI/action semantics this design
explicitly rejects, and "concern" has no std analogue, so a token rename would
leave a _mixed_ vocabulary. What is adopted from std is its **file-level
convention** (facet presence by filename) and the "check the ecosystem first"
process rule (§11), with std + `pkgs/by-name/` cited as the anchor (already
done).

**Rejected alternative:** rename to std terms (`cell`/`cellblock`) — dropped
because the load-bearing thing is the anchor validating this file-level shape,
not the terminology, and adopting the words without the framework buys nothing.

### Fork 1 — barrels or no barrels _(the big one)_

> **Decision (d4): no barrels — filesystem convention.** The rationale and the
> rejected barrel alternative below are retained.

**The two newest docs disagree, four days apart:**

- `mcp-servers-migration-plan.md` (05-04) uses **barrels**:
  `packages/mcp-servers/<name>/default.nix` = `{ package = ./package.nix; }`, a
  literal attrset of paths, walked by a slice `overlay.nix`.
- `slice-architecture-assessment.md` (05-08) **drops** them: facet presence is
  determined by `<facet>.nix` existing at the slice root. "Reintroduce barrels
  only if _what does this slice contribute?_ becomes hard to answer at a
  glance."

Trade-off: a barrel is greppable and statically introspectable without a
`readDir`, at the cost of one more file per slice to keep in sync (and a file
that can lie). Filesystem convention has zero boilerplate but you must `ls` to
know.

**The fixture implements no-barrel** and ships the barrel alternative
side-by-side at
`private/slice-fixture/slices/alpha-cli/default.nix.barrel-example` so you can
compare the two shapes directly.

> **Recommendation (editorial):** take **no-barrel / filesystem convention**,
> and stop deliberating — this fork is being over-thought. Both shapes work at
> 28 packages. Filesystem convention matches where the ecosystem is drifting
> (nixpkgs `pkgs/by-name/` and std both discover this way, §11) and has zero
> boilerplate; a hand-maintained barrel is one more file per slice that _can
> lie_. If static introspection ("what does this slice ship?") ever becomes a
> real tooling need, **generate** an index from the walker — don't hand-maintain
> one. **Critically: Track A (§12) does not depend on this fork at all**, so it
> must not block anything.

### Fork 2 — coarse slices, or leave packages flat?

> **Decision (d4): defer coarse slices (Track B), probably indefinitely.** The
> rationale below is retained.

Per-package co-location already landed (§1). The remaining question is only
whether to _regroup_ into coarse slices (`kiro/` = 2 packages, `mcp-servers/` =
~14) or stop here. The fixture supports both in one walker (`bravo-servers` is
coarse, `alpha-cli` is effectively single).

> **Recommendation (editorial): defer it, probably indefinitely.** This is the
> single most expensive item in the plan and the one with the least remaining
> payoff, because the big win it was designed to deliver — co-location —
> _already landed by another route_. What's left is navigation ergonomics, paid
> for with a rename across ~12 propagation surfaces (§10) that collides with
> every in-flight workstream (§13). Do Track A first (§12) and re-evaluate; my
> prediction is it feels a lot less urgent once the central registries are gone.
> See §14 for what would change my mind.

### Fork 3 — discovery mechanism

> **Decision (d4): `builtins.readDir` + manual filtering (candidate 1 below).**
> This is the explicit one-line decision the section previously lacked — the
> fixture walker already discovers this way (`walker.nix:41`, `dirsIn` over
> `readDir`) and §11 leans on it, but §8 never stated it. Candidates 2
> (`packagesFromDirectoryRecursive`) and 3 (barrel keys) are rejected; the
> reasons are in the candidate notes below.

Three candidates, all live in the sources:

1. **`builtins.readDir` + manual filtering** — the migration plan's choice,
   explicitly _"more predictable than `packagesFromDirectoryRecursive` given
   inter-package deps and namespace shaping"_.
2. **`lib.filesystem.packagesFromDirectoryRecursive`** — the pilot plan's choice
   (pythonPackages-style self-assembly).
3. **Barrel keys** — falls out of Fork 1.

### Fork 4 — sidecar-JSON adoption for Pattern C

Sites #12/#13 (magic comments, rev/hash sed) are _independent_ of slices. Extend
the `*-sources.json` pattern to all main-tracking packages, or convert
opportunistically per package? Default per D18 is opportunistic.

### Fork 5 — walker placement and public API

`flake.nix` inline vs `lib/walker.nix`. The fixture puts it at `lib/walker.nix`;
its walker _is_ the API-by-example.

### Fork 6 — per-slice published modules

Stay combined-merge-only (D6), or eventually publish
`homeManagerModules.ai.<slice>`? Deferrable until consumer demand exists.

---

## 9. Execution plan

> ⚠️ **Read §12 before executing this section.** §9 is the plan _as the sources
> framed it_ — one continuous rollout ending in a full slice regrouping. §12
> argues that plan bundles two independent refactors of very different value,
> and proposes splitting it into Track A (do this) and Track B (defer). §9.2 and
> §9.3-Phase-1 survive that split intact; §9.3-Phase-3 and §9.4's regrouping are
> Track B.

### 9.0 Prerequisites (blocking)

Prerequisites 1–3 are **satisfied** (reaudit X8); `migrate-to-trunk-based` is
**FOLDED** into this convergence lineage:

1. ~~`migrate-to-trunk-based` completes~~ — **✓ done.** Primary checkout
   switched to `main`; `refactor/ai-factory-architecture` retired. (PR #467 is
   now a separate operator-owned paused plan — see §13 — not a blocker.)
2. ~~The docs-subsystem removal lands~~ — **✓ done.**
3. ~~Local checkout synced to `origin/main`~~ — **✓ done.**
4. **Forks 1–3 decided** (§8) — the fixture exists to settle them. **✓ met — d4
   (2026-07-24): no-barrel / defer-coarse-slices / `readDir`.**

Independent of all the above and safe to do any time: **de-duplicate
`hmTransform`/`devenvTransform`** (§3.5).

### 9.1 Stay-green discipline

**Invariants at every commit:** builds clean; `nix flake check` green; published
HM

- devenv surface byte-identical; cache-hit parity green; **no flag days**.

Two mechanisms, by migration kind:

- **Data-registry migrations (Pattern A/B — sites #2, #5, #6, #7, #8, #11)** →
  **coexistence**:
  1. Introduce the option shape. Consuming code **falls back to the old path**
     when a name isn't in the merged set. Both paths work; no functional change
     yet.
  2. Migrate contributors **one at a time**, each a small commit: _"add slice
     X's declaration, remove its old-path entry."_
  3. Delete the fallback only when no consumer remains — one cleanup commit per
     namespace.
- **Directory-layout changes (file moves)** → **atomic per slice**. When
  `overlays/kiro-gateway.nix` becomes `slices/kiro/kiro-gateway/overlay.nix`,
  the old path either exists or doesn't — there's no useful fallback. One commit
  (or a tight series) per slice.

Coexistence boilerplate is the cost; it's **bounded** — it exits when the last
slice lands. The collision refactor already proved this pattern at this scale.

### 9.2 Pre-pilot — one concern, one package (~2 days)

1. Introduce `config.update.targets` in a **new `lib/update.nix`** (RESOLVED —
   d4, 2026-07-24: keep update concerns separable from
   `lib/ai/sharedOptions.nix`; answers R-Q2 / open decision #2, formerly "decide
   during execution"). Type: `attrsOf (submodule { file; flags; dependsOn; })`,
   default `{}`.
2. Modify `dev/scripts/update-pkg.sh` to read the merged set via
   `nix eval --json .#updateTargets.<name>` first, **falling back to the
   existing grep path** when absent. No other changes — Phase-0 homebrew stays.
3. Migrate **`effect-mcp`** only.

**Done when:** `nix flake check` passes; a local update run produces _identical_
output for `effect-mcp` before and after; `nix eval .#updateTargets.effect-mcp`
resolves; CI green on linux-x64 + darwin-arm64; **you review and approve before
any slice work**.

**Contingency:** if the namespace shape doesn't work, **stop and revise this
doc**. No commitment to rollout until the foundation is settled.

> Measure the eval cost: this adds a `nix eval` per update target (~1–2s cold ×
> ~17 packages ≈ 30s/run). Probably fine; worth confirming.

### 9.3 Pilot — first slice (`mcp-servers`)

Per the migration plan, phased with a **HITL STOP at every phase boundary**:

- **Phase 1** — slice scaffold + wire the slice walker + migrate `effect-mcp`'s
  `package.nix` (a **verbatim port** of `overlays/mcp-servers/effect-mcp.nix`,
  same `{inputs, final, ...}` signature, same `ourPkgs` pattern). Replace
  `overlays/default.nix`'s hand-rolled `mcpServerDrvs` with the slice walker.
- **Phase 2** — the `modelContextProtocol` sub-slice: shared `source.nix`
  imported directly by sub-packages (**not** walked), sub-namespace preserved at
  `pkgs.ai.mcpServers.modelContextProtocol.*`.
- **Phase 3** — mechanical migration of the remaining MCPs, **one package per
  commit**.

The slice walker takes `{inputs, final}` (no third arg — it builds an attrset,
not an overlay layer); per-package files keep `{inputs, final, ...}`.

**What to learn before doing the other six slices:**

- Does merge-up hold at **both** HM and devenv eval sides, or does one surprise?
- Does the top-level walker accommodate nested slice dirs?
- Do fragment scopes still work with the new paths?
- Are there `lib/` files that looked shared but are actually slice-specific?
  (Move them — shrinks `lib/` further.)

### 9.4 Rollout + registry sweep

Remaining slices one at a time (D15/D16), then dissolve the remaining Pattern-A
registries, then **add a CI check that fails on any cross-slice import**
(`import ../<other-slice>/`). Fix site #10's glob (one line) when the moves
land.

### 9.5 Stop conditions

Inherited from the pilot plan — if any of these surface, **pause for review
rather than powering through**:

1. The directory walker needs a workaround that isn't a simple filter.
2. `evalModules` rejects a contribution file for any reason beyond missing
   options or syntax errors.
3. The merge-up walker double-counts, picks up non-contribution files, or needs
   post-hoc filtering.
4. Adding a new package requires **any** edit outside its own directory.
5. A factory file needs modification to work in the new scope.

**Acceptance test for self-assembly:** after the wiring is done, adding a
brand-new package requires **zero** edits to any barrel, registry, scope, or
walker — you just drop files in place.

---

## 10. Change-propagation checklist

Every slice move must update these **in the same commit** or `nix flake check`
fails. The propagation surface is currently _partially broken already_ —
`AGENTS.md`/`CLAUDE.md` still document the retired top-level `modules/`.

- [ ] `flake.nix` output lists + package flattening
- [ ] `packages/default.nix` barrel
- [ ] `overlays/default.nix` group composition + export lists
- [ ] `config/update-matrix.nix` (until dissolved)
- [ ] `config/fragment-categories.nix` rows (was: `dev/generate.nix`
      `devFragmentNames` + `packagePaths` globs — dissolved into
      `config.fragments.categories`)
- [ ] `config/cache-hit-parity-targets.nix` rows (was:
      `checks/cache-hit-parity.nix` package lists — dissolved into
      `config.checks.cacheHitParity`); `checks/bare-commands.nix` glob
- [ ] `packages/mcp-services/.../serverNames` (until dissolved)
- [ ] HM module registrations; devshell's hand-listed 5 modules
      (`lib/devshell.nix`)
- [ ] README feature matrix + server reference
- [ ] CI workflow matrices
- [ ] **Co-located architecture fragments** — update the `Last verified:`
      marker; the repo enforces this
- [ ] `AGENTS.md` / `CLAUDE.md` key-directories section _(already stale — fix)_

---

## Appendix A — the 14 name-resolution sites

| #   | Site                                 | Smell                                                                          | Pattern | Severity                                                                               |
| --- | ------------------------------------ | ------------------------------------------------------------------------------ | ------- | -------------------------------------------------------------------------------------- |
| 1   | `update-pkg.sh:34-35`                | substring-greps `overlays/` for the git-URL basename, takes `head -1`          | B       | **ACTIVE BUG** — PR #91: `servers.git` matched `agnix.nix`'s comment                   |
| 2   | `config/update-matrix.nix`           | central update registry decoupled from files                                   | A       | **DISSOLVED** → `config.update.targets` (`config/update-targets.nix`)                  |
| 3   | `generate-update-ninja.nix:38`       | hardcoded `elem name ["agnix" "git-absorb" "git-branchless"]` for Rust DAG dep | A-like  | silent foot-gun on a new Rust pkg                                                      |
| 4   | `overlays/default.nix`               | explicit per-package import list                                               | D       | clean today; structural target                                                         |
| 5   | `lib/mcp.nix:22`                     | `import ../packages/${name}/modules/mcp-server.nix` (string-interpolated path) | B       | **LATENT — breaks loudly when files move**                                             |
| 6   | `dev/data.nix`                       | repo-wide description registry                                                 | A       | structural; long-term DRY win                                                          |
| 7   | `dev/generate.nix:89`                | `packagePaths` glob registry (+ `devFragmentNames`)                            | A       | **DISSOLVED** → `config.fragments.categories` (`config/fragment-categories.nix`)       |
| 8   | `checks/cache-hit-parity.nix:61-120` | 5 hardcoded package lists                                                      | A       | **DISSOLVED** → `config.checks.cacheHitParity` (`config/cache-hit-parity-targets.nix`) |
| 9   | `flake.nix:391-396`                  | manual flatten + hand-maintained rename                                        | D       | low friction                                                                           |
| 10  | `checks/bare-commands.nix:32`        | hardcoded scan-scope glob                                                      | D       | trivial one-line fix on move                                                           |
| 11  | `update-matrix.nix`                  | `excludePatterns` regex registry                                               | A       | **DISSOLVED** → `config.update.excludePatterns`                                        |
| 12  | `update-pkg.sh:80-104`               | awk-parsed `# upstream:` magic comments                                        | C       | **fails SILENTLY** (no rebuild, wrong version persists)                                |
| 13  | `update-pkg.sh:38-51`                | regex sed of first `rev=`/`hash=`                                              | C       | latent for multi-source overlays                                                       |
| 14  | `*-sources.json` sidecars            | **NOT a smell — the good pattern**                                             | —       | reference for Pattern-C fixes                                                          |

---

## Appendix B — the fixture

`private/slice-fixture/` (gitignored, plain-file Nix — **not** a flake, because
flakes only see tracked files). A domain-free mock of the shape: four asymmetric
slices — `alpha-cli` (all 4 facets + 3 concerns, ≈ claude-code), `bravo-servers`
(multi-package shared `source.nix`, ≈ modelcontextprotocol), `charlie-lib`
(lib-only leaf), `delta-tools` (pkg-only, ≈ git-tools).

Run: `nix eval -f private/slice-fixture checks.summary --raw`

**Verified working (9/9 structural checks):**

- a slice consumes **another slice's lib at eval time** with no cross-slice
  import (`nix build … buildable.alpha-cli` → `greeting=charlie-lib::greeting`)
- the lib rollup merges with **collision detection**
- all four merged registries assemble from slice contributions (`update.targets`
  incl. `dependsOn ["rust-overlay"]`, `transformers`, `mcp.serverModules`,
  `fragments.scopes`)
- HM and devenv produce **independent** option surfaces
- a slice may contribute a **subset** of facets

**Deliberately not answered:** real builds, real HM/devenv consumer wiring,
domain content. Those come back after the shape is settled.

---

## Appendix C — provenance

Supersession chain, so nothing is silently lost:

- `monorepo-restructure-assessment.md` (04-21) assessed an external architecture
  dump written without repo access. Verdict: **directionally right on filesystem
  co-location, mechanically bug-prone in specifics — keep concepts, don't
  transliterate code.** Its §11 (added 04-22) supersedes its own §§8–10 and is
  the origin of the slice design.
- `name-resolution-gap-analysis.md` (04-28) extended §8 with **8 sites the
  assessment never enumerated** (#2,#3,#6,#7,#8,#9,#11,#12,#13).
- `slice-nav-design.md` (04-28) locked the merge-up namespace + stay-green
  discipline and **overrode the assessment's kiro-only pilot** (§6).
- `ai-factory-collision-refactor-plan.md` (04-27) **COMPLETE** — 9 commits
  landed: `lib/*`→`lib/ai/*`, collision-as-failure,
  `rulesFromDir`/`skillsFromDir`/ `agentsFromDir`/`hooksFromDir`. It is the
  foundation this builds on and the proof that the coexistence pattern works at
  this scale.
- `greenfield-package-shape.md` (05-04) diagnosed the mixed-eval barrel.
- `mcp-servers-pilot-plan.md` (05-04) → **superseded** by
  `mcp-servers-migration-plan.md` (05-04) — parallel sandbox abandoned for
  direct migration after grill 2.
- `slice-architecture-assessment.md` (05-08) widened greenfield from one package
  to slice composition and **dropped the per-slice barrel** — the Fork 1
  disagreement.

Two prior corrections worth preserving: the `project_slice_nav_design` memory
and an earlier audit both mis-identified `slice-nav-design.md` as canonical; by
git author date and explicit supersession headers,
`slice-architecture-assessment.md` was the newest live thinking. **This document
now supersedes all of them.**

---

---

# Part II — External grounding and editorial

> Everything above (§0–10, Appendices A–C) is a faithful synthesis of the 8
> source docs plus verified current state. **Everything below was in none of
> them** — it is added judgment (Claude, 2026-07-23). It is marked separately so
> you can disagree with the opinions without doubting the synthesis. Where it's
> a recommendation, it says so; where it's a fact about the ecosystem, go verify
> it.

## 11. Where this sits in the Nix ecosystem

**The headline: this design is not bespoke. It is a re-derivation of `std`.**

None of the 8 source docs ever benchmarked the design against the ecosystem.
Three months and eight documents went into re-deriving, from first principles, a
pattern that has at least three named implementations. **That absence is the
single biggest process failure in this whole lineage** — and it's most of why
the architecture kept getting re-derived: with no external anchor, every session
restarted the argument.

### The landscape

| Project                     | Grouping                                                | Discovery                            | Relation to this design                    |
| --------------------------- | ------------------------------------------------------- | ------------------------------------ | ------------------------------------------ |
| **divnix/std**              | **topic-first** — "cells"                               | filesystem → typed "cell blocks"     | ← **this design, essentially**             |
| **divnix/hive**             | std cells + NixOS fleets                                | as std                               | std applied to machine configs             |
| **snowfall-lib**            | type-first (`packages/`, `modules/nixos/`, `overlays/`) | filesystem convention                | auto-wiring, but grouped by _what it is_   |
| **numtide/blueprint**       | type-first, fixed folder layout                         | filesystem convention                | convention-over-configuration flake wiring |
| **flake-parts**             | neither — a module-composition layer                    | explicit imports                     | rejected here for a real reason (D5)       |
| **nixpkgs `pkgs/by-name/`** | flat, sharded                                           | filesystem convention, `package.nix` | validates the _file-level_ conventions     |

### What maps to what

`std`'s **cell** is your **slice** (a topic directory). `std`'s **cell blocks**
are your **facets** — typed contributions whose _type_ determines how the walker
routes them to an output. Same idea, same mechanism, arrived at independently.

Two more independent validations worth knowing:

- **`pkgs/by-name/` uses exactly the filename (`package.nix`) and exactly the
  no-barrel filesystem discovery this design lands on.** Nixpkgs moved this way
  to kill a hand-maintained registry — the _same_ motivation as §3.4. That's
  Fork 1 and Fork 3 answered by the largest Nix repo in existence.
- **Merge-up is not exotic.** `config.<concern>.<slice>` merging across slices
  is precisely what `services.<foo>` already does across NixOS modules. You are
  applying the module system's existing merge semantics to repo metadata instead
  of machine config. That's why it gets collision detection for free.

### Recommendation: steal the vocabulary, don't take the dependency

**Do not adopt `std`.** It is opinionated, brings its own CLI and mental model,
would require migrating ~28 packages into someone else's abstraction, and — most
importantly — is very likely to collide with `devenv`-standalone the same way
flake-parts does (D5/§4.7-1). That constraint killed flake-parts and would
probably kill std too.

Hand-rolling is defensible **specifically because the walker stays small** — the
fixture's is **136 lines total / 82 code** (verified `wc -l`), still under D10's
~150-line ceiling, and that is what keeps "we hand-rolled instead of adopting
std" true. But the headroom is **thin, not comfortable**: 136 total is already
~91% of the ceiling, and that is the _fixture_ walker — the real (non-fixture)
one still has to grow the §12 coexistence/fallback paths (the per-registry
old-path fallback the additive migration requires), so D10's budget is closer
than a first read suggests. The conclusion survives — a sub-150 hand-rolled
walker beats dragging in `std` here — but treat the remaining headroom as nearly
spent, not generous: the moment the real walker crosses ~150 lines, "hand-rolled
instead of std" stops being true and you're maintaining a framework badly.
Re-open this section then.

### Process rule worth adopting

> Before re-deriving an architecture, spend 30 minutes checking whether the
> ecosystem already named it. Record the answer — including "nothing fits,
> because X" — in the design doc. Had any of the 8 docs done this, most of them
> wouldn't exist.

## 12. Editorial: unbundle the two refactors

**The core claim: this plan bundles two independent refactors with very
different value-to-cost ratios, and the low-value one is what makes the whole
thing look expensive and risky.**

### Track A — self-assembly / registry dissolution ✅ recommended

Kill the hand-maintained registries. Each unit declares its own rows; shared
code reads the merged set.

- Dissolve `config/update-matrix.nix` → `config.update.targets` (+ the hardcoded
  Rust list, smell #3, via `dependsOn`)
- Dissolve the transformer aggregator, `mcp-services` `serverNames`,
  `dev/generate.nix` `packagePaths` (**done** — merged with `devFragmentNames`
  into `config.fragments.categories`), the 5 `cache-hit-parity` lists
- Collapse the ~6-place package list toward one source of truth
- Fix **#1** (active bug, wrong-file greps landing in main) and **#12** (silent
  failure — wrong version persists with no error)
- De-duplicate `hmTransform`/`devenvTransform` (~135 lines, §3.5)

**Why this is the good half:**

- It is **additive**. Coexistence (§9.1) means old and new paths work
  simultaneously; nothing has a flag day.
- It requires **no directory churn**, so it never fought the now-folded
  `migrate-to-trunk-based` and does not widen PR #467's conflicts — #467 is a
  separate, operator-owned paused plan (§13).
- It fixes **two live defects**, not just aesthetics.
- **It does not depend on Forks 1, 2, or 3.** Merge-up works identically whether
  slices are coarse or flat and whether facets are discovered by barrel or by
  filesystem. This is the key unlock: _the undecided design questions are not
  blockers for the valuable work._
- The coexistence pattern is already proven at this scale by the collision
  refactor.

**Rough cost:** the pre-pilot is ~2 days (§9.2). Each subsequent registry is a
bounded, independently-revertible series. No estimate exists in the sources for
the full sweep; treat each namespace as its own small project.

### Track B — topic regrouping into ~7 slices ⏸️ defer

Move `kiro-cli` + `kiro-gateway` into `kiro/`, all MCP servers into
`mcp-servers/`, etc. (The original framing also dissolved `overlays/` into the
owning slices; that overlay-dissolution piece is now **REJECTED by gate D-1** —
see "The overlay question" below — leaving Track B as the `packages/` topic
regrouping only.)

**Why this is the weak half — now:**

- **The win it was designed to deliver already landed by another route.** When
  the top-level `modules/` dissolved into `packages/<pkg>/modules/`, per-package
  co-location — the thing §3.3 complains about — was largely achieved. What
  remains is _coarser_ grouping, i.e. navigation ergonomics.
- **The cost is a rename across ~12 propagation surfaces** (§10), in a repo
  whose propagation surface is _already_ partially broken
  (`AGENTS.md`/`CLAUDE.md` still document the retired `modules/`).
- **It collides with essentially every in-flight workstream** (§13).
- The original urgency argument — "restructure before promotion to avoid a
  second churn" — is **void**: promotion already happened (§1).

**The overlay question — RESOLVED by gate D-1 (keep `overlays/` split-ready):**
the seam §3.3 complains about ("facets live in two trees") is real, but the
locked resolution is **not** to dissolve `overlays/` into the package dirs.
Instead, keep `overlays/` as **one split-ready subtree** and sever its 4
relative-path seams via the two [OVL] refactors — TOP-9 relocates the 2
cross-boundary build sources _into_ `overlays/`; TOP-10 exposes
`*-extracted.json` via `passthru.extracted` — then, per **d4 decision 4**,
**absorb nixos-config's 14 `sources.json` overlays** into that same subtree so
the whole tree can be **extracted later as one unit** if desired. This fixes the
two-trees seam with no package-dir churn and keeps the overlay's `ourPkgs`
cache-hit-parity architecture (which already treats the overlay as a standalone
unit) intact.

> **REJECTED — d4 (2026-07-24): overlay DISSOLUTION (Track A2) is rejected by
> gate D-1.** The alternative was to dissolve `overlays/<name>.nix` into the
> owning package dir — its appeal was fixing the "facets live in two trees"
> complaint (§3.3) directly; it is mechanical, does **not** require coarse
> slices, and can be done per-package inside today's layout (the greenfield doc
> sized the barrel+overlay migration at **~12–20 packages, ~8–16h aggregate**).
> It was dropped because dissolving INTO packages scatters today's single
> extraction-shaped tree across N dirs and turns the 4 visible seams into
> intra-package edges — strictly _harder_ to extract later, the opposite of the
> split-ready direction the operator locked.

### Recommended sequencing

> **RESOLVED — d4 (2026-07-24): overlay DISSOLUTION (Track A2) is REJECTED by
> gate D-1; keep `overlays/` as a split-ready subtree and extract later.** Step
> 2 below is therefore the two [OVL] split-prep refactors plus the 14-overlay
> absorption, not a dissolution into package dirs.

1. **Track A** (registries + the two live bugs + transform de-dup)
2. **Overlay split-prep (D-1)** — the two [OVL] refactors (TOP-9 relocates the 2
   cross-boundary build sources _into_ `overlays/`; TOP-10 exposes
   `*-extracted.json` via `passthru.extracted`), then absorb nixos-config's 14
   `sources.json` overlays into the split-ready `overlays/` subtree (d4 decision
   4).
3. **Re-evaluate Track B.** Prediction: with the registries gone and `overlays/`
   a clean split-ready subtree, coarse topic dirs will feel like a nice-to-have.
   If it still itches then, it's cheap to do as a pure `git mv` series (the
   trunk migration is already settled — `migrate-to-trunk-based` is folded).

## 13. Cross-workstream interfaces (for the convergence session)

This restructure does not live alone. Below is what it touches, what must land
first, and the open questions a convergence session has to resolve. _(Workstream
state as of 2026-07-23; re-verify before acting — several are moving.)_

| Workstream                                                   | Overlap with this plan                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Ordering                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`migrate-to-trunk-based`** (**FOLDED**; prereqs satisfied) | Checkout switch off `refactor`, `refactor` retirement, and the docs-subsystem removal are **done** (reaudit X8). Any `packages/` move (Track B, now deferred) would have multiplied its conflict surface                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | **No longer a live blocker** — it folded and its prereqs are met; Track B is deferred by decision                                                                                                                                                                                                                 |
| **Backlog grooming Initiative 1** (archive sweep)            | The 8 sources are meant to `git mv` → `docs/archive/`. **Initiative 2 was this synthesis — now done.**                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | Blocked on the question below about `docs/` surviving                                                                                                                                                                                                                                                             |
| **`mcp-remote-http-secrets`** (draft PR #467)                | Carries known conflicts in `packages/kiro-cli/lib/mkKiro.nix` + `checks/module-eval.nix`. Now a **separate, operator-owned paused plan** (paused until this plan lands), **not** an in-flight migration                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Operator owns its resumption; land/migrate **before** any `packages/` move                                                                                                                                                                                                                                        |
| **`converge-agentic-foundations` P3** (paused)               | Typed-surface work edits `lib/ai/`, `mkClaude.nix`, `mkKiro.nix`, `hooksJson` retirement — **the same files** Track B moves. Track A's `config.update.targets` option lives in a **new `lib/update.nix`** (RESOLVED d4 — deliberately _not_ `lib/ai/sharedOptions.nix`), so that seam no longer overlaps converge P3's typed-surface files. **Also:** the D-1 overlay split-prep's TOP-10 (`passthru.extracted` re-plumb — an _active_ phase, not deferred) edits `mkClaude.nix:186` (`effortLevels` enum) and `mkKiro.nix:75` (`hookTriggers` enum) — the same typed-surface files — landing **before** converge P3 resumes, so P3 rebases over the re-plumbed enum sources, not only over Track B's deferred file-moves | Option placement **resolved (d4): `lib/update.nix`**, which removes the option-placement conflict; the `mkClaude`/`mkKiro` overlap remains — now from **both** Track B's deferred moves _and_ TOP-10's active enum re-plumb, so converge P3 must rebase over the re-plumbed `effortLevels`/`hookTriggers` sources |
| **Update pipeline v4 + transitive-hash gap (#144)**          | Track A's centrepiece **is** dissolving `update-matrix.nix` and changing `update-pkg.sh`. #144 (refresh only touches the named hash) is adjacent surgery on the same script                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Coordinate — do not run both independently                                                                                                                                                                                                                                                                        |
| **Fragment pipeline** (`dev/generate.nix`)                   | Track A dissolves `packagePaths`, which lives in `dev/generate.nix` — owned by the fragment pipeline, not this plan                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | **RESOLVED (2026-07-24)** — dissolved under `converge-repo-foundations` together with `devFragmentNames` into `config.fragments.categories`                                                                                                                                                                       |
| **`hmTransform`/`devenvTransform` de-dup**                   | Touches `lib/ai/app/`, which typed-surface work also touches                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Cheap and independent — but sequence against typed-surface                                                                                                                                                                                                                                                        |
| **Repo defects (`mkClaude.nix:659`)**                        | `mkClaude.nix` is the ~800-line reference file; defect fixes there conflict with moving it                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Fix defects first; they're smaller                                                                                                                                                                                                                                                                                |

### Questions the convergence session must answer

1. **Does `docs/` survive the docs-subsystem removal?** The removal targets the
   _docsite_ (mdbook/pagefind, `.#docs`/`.#docs-site`, nuschtos, gh-pages, Pages
   settings) — plain markdown under `docs/` most likely survives. This doc has
   been promoted to `docs/` and the 8 sources archived under `docs/archive/` on
   that assumption; the **unconfirmed** part is whether the removal will later
   force them elsewhere.
2. **Where does `config.update.targets` live** — **RESOLVED (d4, 2026-07-24,
   operator-approved): a new `lib/update.nix`**, _not_
   `lib/ai/sharedOptions.nix`, to keep update-pipeline concerns separable from
   the shared AI option declarations (answers R-Q2 and the §9.2 "decide during
   execution" note). _Rejected alternative:_ co-locating in
   `lib/ai/sharedOptions.nix` — dropped because it would couple update concerns
   to the typed-surface file converge P3 edits, re-creating the two-way conflict
   this separation avoids.
3. **Who owns `dev/generate.nix`** when `packagePaths` dissolves — **RESOLVED
   (2026-07-24): dissolved under the `converge-repo-foundations` plan**, not
   this one. `packagePaths` and `devFragmentNames` merged into
   `config.fragments.categories` (`config/fragment-categories.nix` +
   `lib/fragments-registry.nix`), following the same option-module shape as
   `config.update.targets` and `config.checks.cacheHitParity`.
4. **Does Track A go before or after converge P3's typed-surface delivery?**
   They touch adjacent files in `lib/ai/`.
5. **Is the update-pipeline work (#144 + Track A's `update-matrix` dissolution)
   one workstream or two?** Arguably one.

## 14. Risk register + what would change my mind

### Risks

| Risk                                                                  | Signal it's happening                                            | Mitigation                                                                   |
| --------------------------------------------------------------------- | ---------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| **Walker accretion** — the abstraction becomes the maintenance burden | Walker > ~150 lines; per-slice special cases                     | D10 budget as a hard gate; re-open §11 if breached                           |
| **Coexistence boilerplate outlives its purpose**                      | Fallback paths still present after the last contributor migrated | One cleanup commit **per namespace**, tracked (§9.1 step 3)                  |
| **Eval-cost regression** in the update pipeline                       | `nix eval` per target ≈ 1–2s cold × ~17 pkgs ≈ 30s/run           | Measure during the pre-pilot; batch into one eval if it bites                |
| **Cache-hit parity regression**                                       | `checks.cache-hit-parity` red                                    | It's a gate at every commit; never introduce `final.X` inputs                |
| **Propagation surface already broken**                                | `AGENTS.md`/`CLAUDE.md` still list `modules/`                    | Fix the stale orientation docs _before_ adding more moves                    |
| **Doc rot round two**                                                 | This doc drifts like its 8 predecessors                          | It supersedes them _and they are archived_ — one doc, or the disease returns |

### What would change my mind

**On deferring Track B (§12).** I'd reverse if any of these turn out true:

- Navigation pain is costing **measurable** time — if you regularly hunt across
  `dev/`, `lib/`, `overlays/`, `checks/` for one topic, that's real and I'm
  underweighting it. _Test: notice how often it actually happens over a week._
- A **per-slice published module surface** becomes a consumer requirement
  (Fork 6) — slices would then be an API, not just navigation, which changes the
  calculus.
- Coarse grouping turns out to be what makes merge-up tractable. _I don't
  believe this_ — the fixture demonstrates merge-up working with both coarse and
  flat slices in one walker — but if implementation shows otherwise, Track A and
  B re-couple and B gets promoted.

**On no-barrel (Fork 1).** I'd reverse if `nix eval`-time introspection of "what
does this slice contribute?" becomes a genuine tooling need that a _generated_
index can't serve.

**On not adopting std (§11).** I'd reverse if the walker breaks its line budget
_and_ std turns out to compose with `devenv`-standalone. Both would have to be
true.

### What I am least confident about

- **D13's two-layer `lib.ai`** — flagged in §5. Two addressing schemes in one
  attrset. I suspect this wants separating before anything depends on it.
- **Whether `mcp-servers` or `kiro` is the better first slice** (§6) if Track B
  ever runs. The sources disagree; `mcp-servers` forces the hard cases early,
  which is either the right call or a way to fail on the most complex case
  first.
- **The exact `docs/` survival question** (§13) — I have not verified it.

## 15. If you only do three things

1. **De-duplicate `hmTransform`/`devenvTransform`.** ~135 duplicated lines,
   violates the repo's own DRY rule, **completely independent** of every fork,
   workstream, and blocker in this document. Free money, today.
2. **Run the `effect-mcp` pre-pilot (§9.2), then dissolve `update-matrix.nix`.**
   This is Track A's beachhead, proves the merge-up namespace on one package
   with a fallback, and needs **no** fork decided.
3. **Fix smells #1 and #12.** These are _live defects_, not refactors — #1 lands
   wrong-file edits in main (PR #91), #12 fails **silently**, leaving a stale
   version with no error. They've been deferred as "will be fixed by the
   restructure," which has now not happened for three months.

Everything else in this document can wait for the convergence session.
