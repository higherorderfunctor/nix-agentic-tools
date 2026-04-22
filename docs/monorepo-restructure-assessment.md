# Monorepo restructure proposal — assessment

> **Status:** ASSESSMENT ONLY — not a plan to act on.
>
> **Source document:** `/home/caubut/Downloads/nix-agentic-tools-architecture.md`
> produced on Claude web without repo access. Claims validated or refuted below.
>
> **Live plan in flight on a separate session:**
> `docs/ai-factory-collision-refactor-plan.md` — collision-as-failure +
> Dir helpers + `lib.*` → `lib.ai.*` namespace move. This assessment is
> additive to that plan, not a replacement. Overlap is flagged in §7.
>
> **Refined goal (2026-04-22 conversation, supersedes the dump's framing):**
> the real ask is **dev-navigation slices**, not publishing slices. One
> directory per cohesive topic; open it and see everything about that
> topic — code, overlay, checks, docs, fragments, hooks — without
> hunting `dev/`, `lib/`, `overlays/`, `checks/`. Slices are coarser
> than packages: `kiro/` holds kiro-cli + kiro-gateway, `mcp-servers/`
> holds all 12 standalone MCP packages, etc. Published module surface
> stays as today (combined merge). Flake-parts is NOT required — the
> dump used it as an implementation suggestion; the goal is filesystem
> layout + module-system merge-up, not framework migration.
>
> **Author's bottom line on the dump itself:** directionally right on
> filesystem co-location, mechanically bug-prone in specifics
> (`flake.aiPackages` + `materialize`, `filterAttrs`-based aggregate,
> `self'.packages` inside `checks`, flake-parts migration). Keep
> concepts, don't transliterate code. And the biggest structural
> blocker the dump missed: moving to flake-parts `devShells.default`
> would break `devenv shell` standalone mode — which is the author's
> daily driver and the consumer contract. §11 captures the refined
> slice-nav design. §§2–10 remain as validation / reference material
> for the flake-parts proposal itself.

---

## Table of contents

1. [Verdict at a glance](#1-verdict-at-a-glance)
2. [What the dump gets directionally right](#2-what-the-dump-gets-directionally-right)
3. [What the repo already realizes](#3-what-the-repo-already-realizes)
4. [What the dump gets wrong or risky](#4-what-the-dump-gets-wrong-or-risky)
5. [Real current-repo friction the dump ignores](#5-real-current-repo-friction-the-dump-ignores)
6. [Backlog impact](#6-backlog-impact)
7. [Collision with the factory-collision-refactor plan](#7-collision-with-the-factory-collision-refactor-plan)
8. [What's worth keeping](#8-whats-worth-keeping)
9. [What's worth NOT doing](#9-whats-worth-not-doing)
10. [Open questions for the user](#10-open-questions-for-the-user)
11. [Refined goal: dev-nav slices with module-merge](#11-refined-goal-dev-nav-slices-with-module-merge)

---

## 1. Verdict at a glance

The verdicts below cover the dump's concrete proposals. For the
**refined goal** the conversation settled on (dev-nav slices with
module-merge, not flake-parts), see §11.

| Proposed concept                                                       | Worth adopting?                     | Why                                                                                          |
| ---------------------------------------------------------------------- | ----------------------------------- | -------------------------------------------------------------------------------------------- |
| Dev-nav slice layout (see §11 for the refined shape — this is the ask) | **Yes — the actual goal**           | One dir per cohesive topic; code + overlay + checks + docs + fragments co-located            |
| Per-package filesystem layout (`packages/<name>/`)                     | **Already done**                    | 25 packages under `packages/` today — slices re-group these coarser                          |
| Dissolve `overlays/` into per-package / per-slice                      | **Yes — file move**                 | 1:1 mapping for ~90% of cases                                                                |
| Dissolve `dev/` into slices                                            | **Partial**                         | Slice-adjacent fragments/docs move into slices; generator + scripts + CI stay cross-cutting  |
| Migrate to flake-parts                                                 | **No**                              | Not required for slice nav; would break `devenv shell` standalone mode                       |
| `flake.aiPackages` registry + derived overlay                          | **No**                              | `lazyAttrsOf types.raw` breaks multi-contributor merge; `materialize` has bugs               |
| `aiInternal.*` option namespace                                        | **Optional — concept only**         | Nice discipline if adopted by convention; not load-bearing                                   |
| Aggregate `ai.all` module                                              | **Optional — static list only**     | Low-cost ergonomics; skip `filterAttrs` (infinite-recursion risk)                            |
| `_class` tags per module                                               | **Yes — Claude + HM + NixOS sides** | Real enforcement since 23.05; free safety; devenv side no-op                                 |
| Cross-slice CI check (no `../other-slice/` imports)                    | **Yes**                             | Already zero violations today; lock it in                                                    |
| Auto-discovery via `haumea`                                            | **No**                              | Explicit imports fine at this scale; extra input for little gain                             |
| Per-slice `checks.nix` using `self'.packages.foo`                      | **No**                              | Confirmed infinite-recursion footgun (flake-parts issue #22) — use `config.packages.*`       |
| `_class = "devenv"` guard                                              | **No**                              | Devenv doesn't set class; no enforcement today                                               |
| Per-slice published HM/devenv modules                                  | **Optional**                        | Internal slice-merge is the win (§11); external publishing stays as combined-merge for now   |
| Module-system merge-up for slice contributions                         | **Yes — the load-bearing mechanic** | Slices declare `config.lib.ai.<ns>.<name>` upward; shared code reads the merged set downward |

---

## 2. What the dump gets directionally right

**2.1 Co-locate overlay + package.** Today `overlays/mcp-servers/context7-mcp.nix`
and `packages/context7-mcp/` live in two places. The overlay file could move to
`packages/context7-mcp/overlay.nix`. For ~90% of packages this is a pure file
move. The benefit: "where does context7-mcp live?" has one answer, not three
(package dir, overlay file, sources.json).

**2.2 `aiInternal.*` namespace concept.** Separating repo-private helpers
(pre-commit hooks, dev-only devenv modules, fmt scripts for generated files)
from flake outputs is good discipline. Today the repo half-does this:
`dev/scripts/`, `dev/tasks/`, `dev/fragments/monorepo/` are clearly internal,
but they're not guarded by any option mechanism. A convention like "internal
helpers live under `aiInternal.*` options, never `flake.*`" would codify it
without requiring flake-parts.

**2.3 Aggregate modules.** A single `homeManagerModules.ai.all` that imports
every CLI's module, letting consumers `imports = [ … ai.all ]` then cherry-pick
`enable = true`, is a real ergonomic win vs today's `nix-agentic-tools`
monolithic module. Applicable to NixOS + devenv sides too. But the dump's
`filterAttrs`-based implementation is broken (§4.4) — use a static list.

**2.4 `_class` discipline.** Adding `_class = "homeManager"` / `"nixos"` to
module files is free, catches "wrong framework imports" with a readable error,
and is enforced by HM/NixOS since nixpkgs 23.05. Devenv doesn't set a class on
its own evalModules call, so the devenv side won't benefit — but the HM +
NixOS halves will. Memory: `reference_flake_parts_gotchas.md`
("\_class tags — real enforcement") +
`reference_devenv_flake_parts_dual_mode.md` (devenv class absence).

**2.5 Cross-slice import discipline.** The dump's rule "no `import ../<other-slice>/...`
ever" is excellent. Today the repo has ZERO violations of it: every upward import
from `packages/*/` goes to `lib/`, never to another package dir (subagent verified
59 hits, all landing in `lib/`). A structural check that fails CI on any new
cross-slice import would lock this in cheaply.

**2.6 The one inverted dependency is real.** `lib/mcp.nix:22` dynamically
imports `packages/${name}/modules/mcp-server.nix`. This is `lib/` reaching into
`packages/`, which is the opposite of the direction everywhere else.
It's the kind of coupling the dump's architecture would prevent — either by a
module-system option that each MCP package contributes to, or by a static
registry table in `lib/`.

---

## 3. What the repo already realizes

The dump proposes a destination the repo is a long way toward, but the dump
author didn't know this. What's already in place:

- **`packages/<slice>/` layout**: 25 packages, each with `default.nix`,
  most with `docs/`, AI CLIs with `lib/mk<Name>.nix` + `modules/{homeManager,devenv}/` +
  `fragments/`, MCP packages with `modules/mcp-server.nix` (typed schema).
- **Zero cross-slice relative imports**: the discipline the dump describes
  is already in force today.
- **Factory primitives at `lib/ai/app/`**: `mkAiApp.nix`,
  `hmTransform.nix`, `devenvTransform.nix` — a record-based factory that
  abstracts HM + devenv backends. The dump has NO awareness of this and
  its proposed per-slice `modules/home-manager.nix` + `modules/nixos.nix` +
  `modules/devenv.nix` files would duplicate the factory's delegation. The
  existing factory is, in my read, a simpler solution than the dump's three-
  file-per-slice approach — don't trade it for triplication.
- **Shared options declared once** (`lib/ai/sharedOptions.nix`), injected into
  both `homeManagerModules` and `devenvModules` via `flake.nix:121` and :127.
  Matches the dump's "one source of truth" intent.
- **Per-package fragments**: `packages/<name>/fragments/` exists in several
  places. The dump's per-slice fragment idea is already partially realized.
- **Content packages**: `coding-standards` and `stacked-workflows` both
  export `passthru.fragments` that feed the generation pipeline. This
  composition pattern is orthogonal to the dump's proposal — it should stay
  whatever restructure happens.

So the "deep" restructure the dump describes is, in practice, ~60% done.
What remains is mostly file-move (overlay → package dir) and discipline
codification (cross-slice lint, aggregate modules, `_class` tags).

---

## 4. What the dump gets wrong or risky

Each item below is a specific technical claim in the dump that is either
flat wrong, subtly broken, or has material pitfalls the dump didn't mention.
Validated by upstream-docs research (flake-parts, devenv, nixpkgs).

### 4.1 `flake.aiPackages = mkOption { type = lazyAttrsOf types.raw; }`

`types.raw` uses `mergeOneOption` under the hood — it throws an eval error
if the same attribute is defined more than once across modules. If slice A and
slice B both want to register packages via `flake.aiPackages.foo = ...;` and
the attribute names collide (which is fine for per-slice packages since
names differ, but fails immediately if you ever register twice), the
registry explodes.

More importantly, this is **not** a canonical flake-parts pattern.
rust-flake, haskell-flake, and process-compose-flake all carry per-package
metadata directly on per-system options, not a top-level attrset registry
going through a `materialize` function. If the goal is "derive overlay from
a registry," flake-parts' own `easyOverlay` module is closer to the
established pattern.

Memory: `reference_flake_parts_gotchas.md` §"Types for multi-contributor
attrset options" — also affects §4.5 (`aiInternal.lib` same footgun).

### 4.2 `materialize` dispatch has a function-shape bug

Dump's dispatcher:

```nix
if lib.isDerivation v then v
else if lib.isFunction v then v final
else if builtins.isPath v then final.callPackage v { }
else throw "...";
```

`lib.isFunction v` is true for any `{ lib, stdenv, ... }: ...` package
expression (they're native Nix functions). The branch calls `v final` —
passing the overlay's `final` as the sole argument. This is **not** the
same as `final.callPackage v {}`. `callPackage` auto-fills args from its
argument attrset and allows overrides; raw `v final` passes only `final` as
the destructured attrset, with no override hook. Packages that rely on
callPackage auto-fill will break.

Fix if adopting any similar dispatcher: change to `final.callPackage v {}`
for both function and path cases. Reserve the "function" branch for
functions explicitly accepting `final` (the overlay closure pattern),
which is a different shape than a callPackage-shaped package.

Memory: `reference_flake_parts_gotchas.md` §"materialize dispatch bug".

### 4.3 `checks = { foo = self'.packages.foo; }` is an infinite-recursion trap

Confirmed in flake-parts issue #22 (zimbatm). `self'` is the full
per-system outputs attrset, which itself is being constructed by
evaluating all perSystem config — including `checks`. Cycle.

Safe alternative: use `config.packages.foo` (the local perSystem config
reference) from within perSystem. Within the same evaluation, `config.*`
doesn't cycle the same way `self'.*` does. The dump's §7.6 check template
(`ai-claude-code-build = self'.packages.ai-claude-code`) would
infinite-recurse if taken literally.

Memory: `reference_flake_parts_gotchas.md` §"self'.packages.X inside
checks is infinite recursion".

### 4.4 `filterAttrs` on a self-referential attrset can recurse

Dump's aggregate proposal:

```nix
config.flake.homeManagerModules.ai.all = let
  slices = lib.filterAttrs (n: _: n != "all") config.flake.homeManagerModules.ai;
in { imports = lib.attrValues slices; };
```

The dump claims `filterAttrs` "inspects names without forcing values."
False. The nixpkgs implementation passes the value to the predicate:
`pred n set.${n}`. Even though this specific predicate uses `_` to ignore
the value, computing `filterAttrs` forces the name set (evaluating
`attrNames config.flake.homeManagerModules.ai`), which requires that same
attrset to be resolved to at least name level — including the `all` key
currently being defined. Whether this infinite-recurses depends on module-
system evaluation order, but the dump's confidence is unfounded; it's a
known footgun.

Fix: hand-enumerate. A static `imports = [ ./slice-a ./slice-b ./slice-c ]`
list at the aggregate module is boring and works. Or compute the list
outside the module (e.g., from a `let` binding in `flake.nix`), not from
inside the merged config.

Memory: `reference_flake_parts_gotchas.md` §"filterAttrs does force
values".

### 4.5 `types.raw` in `aiInternal.lib` same footgun as 4.1

Same as 4.1, same fix: use `types.lazyAttrsOf types.anything` for
multi-contributor attrsets. Memory: `reference_flake_parts_gotchas.md`
§"Types for multi-contributor attrset options".

### 4.6 `"costs nothing when disabled"` oversold

Option declarations, unconditional `let` bindings, `imports` lists, and
`apply` functions on option types ALL evaluate regardless of
`cfg.enable`. Only the `config = mkIf cfg.enable { ... }` body is gated.
A disabled slice is cheap, not free. For 25 slices this is fine; for
2500 it wouldn't be.

Memory: `reference_flake_parts_gotchas.md` §"Costs nothing when disabled
is oversold".

### 4.7 The biggest structural gap: flake-parts vs `devenv shell` standalone

This is the blocker. The repo today uses `devenv shell` standalone
(`devenv.yaml` + `devenv.nix` at root). The dump proposes wiring the
devShell via `inputs.devenv.lib.mkShell` inside a flake-parts `perSystem`
block. Per devenv docs: **these are two separate evaluation paths with no
bridge**. `devenv shell` reads only `devenv.nix`/`devenv.yaml`. Flake-parts
`devShells.default` is only reachable via `nix develop --no-pure-eval`.

Consequence: if the repo migrates to flake-parts-driven devShells,
`devenv shell` stops working (or quietly loads a different config). The
author would switch their daily flow to `nix develop`, losing tasks,
processes, and devenv-specific niceties. Downstream consumers importing
`devenvModules.nix-agentic-tools` would still work, but the author's
local experience degrades meaningfully.

Alternative: keep `devenv.nix` at root, keep `devenv shell` authoritative
locally, and still publish devenv modules via `flake.devenvModules.*`.
That's what today does. Flake-parts doesn't help here; it'd just add a
second eval path that must be kept in sync by hand.

Memory: `reference_devenv_flake_parts_dual_mode.md` (the whole file
documents this structural risk).

### 4.8 `flake.devenvModules` naming

Dump asks if `flake.devenvModules` is a standardized output. It is
**not**. Devenv itself publishes `flakeModules`, not `devenvModules`. The
community convention is `flake.devenvModules.<name>` as an attrset of
modules, but no upstream schema enforces this. Today the repo uses
`flake.devenvModules.nix-agentic-tools = { ... }` — fine. Proposal to
rename to `flake.devenvModules.ai.<slice>` is **breaking** for current
consumers and gains nothing beyond cosmetic consistency with
`homeManagerModules.ai.<slice>`. Only do this if you're doing the HM side
rename in the same go (and consumers are ready).

Memory: `reference_flake_parts_gotchas.md` §"flake.devenvModules is not
standardized".

### 4.9 Pre-commit hooks: two systems, no bridge

The dump casually mixes `pre-commit.hooks` (devenv submodule) with
`inputs.git-hooks.flakeModule` (flake-parts). These are DIFFERENT
activation paths for the same underlying `cachix/git-hooks.nix` library:

- Devenv `git-hooks.hooks.foo.enable = true` → installs via shellHook
  when user enters devenv shell.
- Flake-parts `inputs.git-hooks.flakeModule` → populates
  `perSystem.pre-commit` and contributes a `checks` derivation for CI.

They **cannot** cross-wire. A declaration in one does not flow into the
other. The repo today uses devenv's `git-hooks.hooks` inside `devenv.nix`
(standalone path). Keep it there. Don't bolt on flake-parts git-hooks
unless CI needs a separate check derivation.

Memory: `reference_devenv_flake_parts_dual_mode.md` §"Pre-commit hooks:
two systems, no cross-wire".

---

## 5. Real current-repo friction the dump ignores

### 5.1 `agnix` is three outputs from one source

`pkgs.ai.agnix` (CLI), `pkgs.ai.mcpServers.agnix-mcp`,
`pkgs.ai.lspServers.agnix-lsp` are split across three overlay files but share
one Rust workspace. Under the dump's "one slice owns one thing" rule, is this
one slice (with a `pkg.nix` returning three derivations) or three slices
sharing a source? The dump doesn't address multi-output source-of-truth
packages. Any serious restructure plan has to pick a convention.

### 5.2 `modelcontextprotocol` source is shared across three MCPs

`overlays/mcp-servers/modelcontextprotocol/default.nix` is one
`fetchFromGitHub` source that produces `fetch-mcp`, `git-mcp`, and
`sequential-thinking-mcp`. Same question as 5.1 — do you co-locate
_ownership_ of the source in one package's dir, or extract a `shared/` slice
that all three import? The dump's "no cross-slice imports" rule conflicts
with the natural representation here.

### 5.3 `mcp-services` is a virtual aggregator

`packages/mcp-services/default.nix` has no derivation and no overlay. It
contributes an HM module that dynamically loads 12 other packages' MCP
schemas. Under the dump's proposal, this is either "an empty slice" or
"not a slice at all." Neither maps cleanly. Today's shape is fine;
forcing it into the dump's mold is cosmetic.

### 5.4 `devshell/docs-site/` lives outside `packages/`

`devshell/docs-site/default.nix` is imported as `fragmentsDocsOverlay` —
it's a content package that happens not to live in `packages/`. If
restructuring, this should probably move to
`packages/fragments-docs/` (which doesn't currently exist). The dump
doesn't mention it.

### 5.5 `lib/ai/transformers/` is slice-adjacent but physically shared

Four transformer files — `claude.nix`, `copilot.nix`, `kiro.nix`,
`agentsmd.nix` — each correspond 1:1 to an ecosystem. Could co-locate
into each slice's dir. But they're consumed via a shared
`lib/ai/transformers/default.nix` aggregator that `lib/ai/default.nix`
re-exports. Moving them per-slice forces either a shared collector
(still cross-cutting) or per-slice `flake.lib.ai.<slice>.transformer`
exports (which breaks the current single-import call site). Not a
blocker, but a cleanup that needs a careful touch.

### 5.6 `lib/mcp.nix:22` dynamic package imports

`builtins.concatMap` over `packages/*/modules/mcp-server.nix` — this is
the one inverted dependency. The dump's architecture would replace it
with a module-system option that each MCP package contributes to (e.g.,
`config.flake.lib.ai.mcpServerRegistry`). That IS a win. Call it out as
a standalone refactor — doesn't require the whole flake-parts migration.

### 5.7 `sources.json` sidecars

`overlays/claude-code-sources.json`, `kiro-cli-sources.json`,
`copilot-cli-sources.json` hold per-platform version/hash data managed by
`mkUpdateScript`. They're per-package but live in `overlays/`. In a
co-location refactor they'd move to `packages/<name>/sources.json`.
Straightforward.

---

## 6. Backlog impact

Cross-referencing against `docs/plan.md` (single flat backlog):

| Backlog item                                                           | Impact                                                                                               |
| ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| "Rename `devshell/` → `modules/devshell/`" (Easy wins)                 | **Subsumed** if co-location happens; becomes "move `devshell/docs-site` → `packages/fragments-docs`" |
| "Move `externalServers` registry out of root `flake.nix`" (Easy wins)  | **Subsumed**; becomes "move to `lib/ai/externalServers.nix` or a content package"                    |
| "Replace `isRoot = package == \"monorepo\"` with category metadata"    | **Independent**; fragment-pipeline concern, unaffected                                               |
| "flake-parts modular per-package flake outputs" (Unsorted)             | **Directly addressed** — this WAS the ask; now has an assessment                                     |
| "Consolidate fragment enumeration into single metadata table" (Medium) | **Independent**, still worth doing                                                                   |
| "HM ↔ devenv ai module parity test" (Medium)                          | **Reinforced** — would verify the factory's backend parity regardless of restructure                 |
| "Codify gap: ai.skills factory layout" (Medium)                        | **Still needed** — restructure doesn't change factory internals                                      |
| "Migrate git-branchless to upstream flake input" (Easy wins)           | **Independent**                                                                                      |
| Aggregate `ai.all` module                                              | **NEW item** — the one thing in the dump not already on backlog                                      |

Nothing in the dump _conflicts_ with existing backlog items. It
subsumes two minor items and adds one (aggregate module). It does NOT
resolve the MCP-server-startup regression or mcp-proxy-auth items —
those are bugs in different layers.

---

## 7. Collision with the factory-collision-refactor plan

The other session's plan (`docs/ai-factory-collision-refactor-plan.md`)
has concrete commits queued:

1. `refactor(lib): move lib.* to lib.ai.*`
2. `refactor(ai): deprecate sourcePath; revert to pure-eval rules`
3. `refactor(ai): collision-as-failure across all shared pools`
4. `feat(lib): lib.ai.rulesFromDir + ai.<cli>.rulesDir option`
5. `feat(lib): lib.ai.skillsFromDir + ai.<cli>.skillsDir option`
6. `feat(lib): lib.ai.agentsFromDir + ai.<cli>.agentsDir option`
7. `feat(claude): lib.ai.hooksFromDir + ai.claude.hooksDir option`
8. `fix(devenv): stale copilot skills paths`
9. `fix(ci): SYMPTOM B fix`
10. Dev fragments for new architecture

### Overlap

- **`lib.* → lib.ai.*` move (Commit 1)**: both plans propose this. BUT
  they propose different _shapes_:
  - Collision plan: **flat** `lib.ai.<helper>` (e.g.,
    `lib.ai.mkStdioEntry`, `lib.ai.rulesFromDir`)
  - Dump: **per-slice** `lib.ai.<slice>.<helper>` (e.g.,
    `lib.ai.claude-code.mkSessionPath`)
    These are not contradictory — the flat `lib.ai.*` can coexist with
    per-slice `lib.ai.<slice>.*` — but they need a deliberate policy:
    "shared helpers at `lib.ai.*`, slice-specific helpers at
    `lib.ai.<slice>.*`." Raise this before the collision plan's Commit 1
    lands, so the new shape accommodates both layers.

### No conflict

- Collision plan touches option semantics (collision-as-failure, Dir
  helpers, `sourcePath` rollback). Dump touches filesystem layout and
  output namespacing. These are orthogonal concerns operating at
  different layers.
- Dev fragments from collision plan would need to live under whichever
  filesystem shape the repo ends up with. If dump's restructure lands
  later, the fragments just move with their slice.

### Sequencing

- The collision plan should proceed as written. It's small, tight, and
  addresses concrete bugs.
- The dump's restructure should be deferred until the collision plan
  lands. Attempting both in flight creates merge pain and confuses
  reviewers.
- When the dump's restructure runs, it builds _on top_ of the collision
  plan — not the other way.

---

## 8. What's worth keeping

In priority order, low risk first:

1. **Structural CI check against cross-slice imports.** Add a `nix flake
check` entry that greps `packages/*/**/*.nix` for
   `import \.\./(?!(lib|\\w+/lib))` and fails if any hit crosses to
   another package. Locks in current state.
2. **`_class` tags on all HM + NixOS module files.** Free safety since
   23.05. Devenv side is no-op but harmless.
3. **Aggregate `ai.all` modules** (static list version, NOT
   `filterAttrs`). Adds consumer ergonomics without restructure.
4. **Move `lib/mcp.nix:22` inverted dep to a module-system registry.**
   Each MCP package contributes to a shared option; `loadServer`
   consumes the merged attrset. Independent cleanup.
5. **Move overlay files into their owning package dir** (~90% 1:1
   mapping). File-move refactor; no semantic change. Do package-by-
   package to keep PRs reviewable.
6. **Move `devshell/docs-site/` → `packages/fragments-docs/`** for
   location consistency.
7. **Move `sources.json` sidecars to owning packages** (`overlays/*-
sources.json` → `packages/<name>/sources.json`). Touches update
   pipeline; verify `mkUpdateScript` path resolution.
8. **`aiInternal.*` option convention** (without flake-parts). Declare
   an `aiInternal` option path in the existing flake; lift internal-
   only helpers under it; treat it as "never reaches outputs" by
   convention.

---

## 9. What's worth NOT doing

1. **Full flake-parts migration.** Cost: breaks `devenv shell`
   standalone flow; forces switching daily dev to `nix develop`; two-
   eval-path drift risk. Benefit: a slightly cleaner `flake.nix` and
   access to treefmt/git-hooks flake modules that already have devenv
   equivalents. Not worth it for this repo at this stage.
2. **`flake.aiPackages` registry + `materialize` dispatch.** Novel
   pattern, not canonical; broken types (`types.raw`) for multi-
   contributor merge; `materialize` has a function-shape bug.
   Conventional per-system `packages.<name>` declarations work fine.
3. **`self'.packages.*` inside `checks`.** Confirmed infinite-
   recursion. Use `config.packages.*` within the same perSystem.
4. **`filterAttrs`-based aggregate modules.** Use a static list.
5. **Rename `flake.devenvModules.nix-agentic-tools` →
   `flake.devenvModules.ai.<slice>`.** Breaking change to consumer
   contract; purely cosmetic.
6. **Haumea auto-discovery.** 25 explicit imports is not a maintenance
   burden; adding an input to solve nothing is a net negative.
7. **`_class = "devenv"` tags.** Devenv doesn't enforce. No safety
   gain; adds noise.

---

## 10. Open questions for the user

- **Is `devenv shell` standalone a hard constraint?** If yes (which I
  assume from current shape), then full flake-parts migration is off the
  table, and this assessment simplifies to "cherry-pick the discipline
  wins, skip the framework migration." If no, §4.7 opens up.
- **On `lib.ai.*` shape** (flat vs per-slice): does the collision plan's
  flat `lib.ai.mkStdioEntry` conflict with a future
  `lib.ai.claude-code.*` namespace, or can they coexist with a policy?
  This needs deciding before collision-plan Commit 1 lands.
- **Overlay co-location timing**: do this as a pre- or post- of the
  collision plan's work? My read is post (collision plan stays small
  and tight), but the file moves would touch `packages/<name>/` dirs
  the collision plan is also editing. Check for conflicts before
  scheduling.
- **Scope of `aiInternal.*` convention**: is it worth introducing
  _without_ the flake-parts mechanical backing? A pure-convention `let
aiInternal = { ... }; in ...` in flake.nix is less rigorous than an
  option type, but also less invasive.
- **Multi-output packages (`agnix`, `modelcontextprotocol` shared
  source)**: resolved in §11 — agnix is one slice with three outputs
  from one source; `modelcontextprotocol` becomes a shared-source
  helper inside the `mcp-servers` slice (or a shallow `_shared/` subdir
  of that slice).

---

## 11. Refined goal: dev-nav slices with module-merge

The 2026-04-22 conversation distilled the real ask. The sections above
(§§2–10) assess the dump as written. This section captures the design
the repo is actually aiming for.

### 11.1 What a slice is (and isn't)

A slice is a **dev-navigation unit**. Open the directory and you see
everything about that topic — source, overlay, modules, checks, hooks,
fragments, docs. You should not have to go hunt `dev/fragments/`,
`lib/`, `overlays/`, `checks/` to find material related to one topic.

Slices are coarser than packages. They group by **cohesive source or
topic**, not by published category. A slice may own multiple derived
packages. Examples:

- `slices/kiro/` owns kiro-cli + kiro-gateway (gateway is
  kiro-specific; both live together).
- `slices/mcp-servers/` owns all 12 standalone MCP servers as one
  slice — dev-nav win; "where's MCP stuff?" has one answer.
- `slices/agnix/` owns the single Rust workspace that produces CLI +
  MCP + LSP outputs (one source → multiple published packages, all in
  one slice).

Slices are **not** a published-module surface. The combined-merge
`homeManagerModules.nix-agentic-tools` / `devenvModules.nix-agentic-tools`
that the repo publishes today stays. Whether per-slice published
modules exist is optional and TBD (§11.4).

### 11.2 Proposed slice count (~7)

| Slice                       | Contents                                                                                                                                         |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `slices/claude/`            | claude-code package, modules, transformer, fragments, checks, claude-specific hooks                                                              |
| `slices/kiro/`              | kiro-cli + kiro-gateway, modules, kiro transformer, fragments, checks                                                                            |
| `slices/copilot/`           | copilot-cli, modules, copilot transformer, fragments, checks                                                                                     |
| `slices/agnix/`             | one Rust workspace → CLI + MCP + LSP published outputs; one slice owns all three overlay entries + fragments + docs                              |
| `slices/mcp-servers/`       | 12 standalone MCP servers (context7, effect, fetch, git-mcp, github-mcp, kagi, nixos, openmemory, sequential-thinking, serena, sympy, git-intel) |
| `slices/git-tools/`         | git-absorb, git-branchless, git-revise                                                                                                           |
| `slices/stacked-workflows/` | content package + skills + references + SWS-specific modules                                                                                     |

Nested structure inside a slice is fine. For `mcp-servers/`,
individual packages still live in `mcp-servers/packages/context7-mcp/`
etc.; a `_shared/modelcontextprotocol/` subdir holds the shared
fetchFromGitHub source that produces `fetch-mcp` + `git-mcp` +
`sequential-thinking-mcp`.

### 11.3 What stays out of slices (infrastructure)

Genuinely cross-cutting machinery remains at repo root or under
`lib/` / `dev/`:

- `flake.nix`, `devenv.nix`, `devenv.yaml`, `treefmt.nix` — root.
- `lib/ai/app/*` (factory primitives `mkAiApp`, `hmTransform`,
  `devenvTransform`) — used by every CLI slice.
- `lib/ai/sharedOptions.nix`, `lib/ai/ai-common.nix`,
  `lib/ai/hm-helpers.nix`, `lib/ai/dir-helpers.nix`,
  `lib/ai/mcpServer/*` — shared types and helpers across CLIs.
- `lib/fragments.nix`, `lib/mcp.nix`, `lib/hm-dag.nix`,
  `lib/devshell.nix`, `lib/options-doc.nix` — genuinely
  cross-cutting.
- `dev/generate.nix`, `dev/tasks/`, `dev/scripts/` (update pipeline),
  `dev/fragments/monorepo/`, `dev/fragments/pipeline/` — monorepo
  orchestration.
- `config/`, `checks/` entries that test cross-slice invariants
  (bare-commands scan, cache-hit-parity, module-eval of the combined
  tree).

**Do NOT invent an `_infrastructure/` or `_repo/` slice.** Root and
`lib/` already serve that role; adding a slice wrapper is noise.

### 11.4 Module-merge: the load-bearing mechanic

Slices must not `import ../<other-slice>/` anything. But they also
shouldn't force shared code to `import ../../slices/<name>/` to
collect contributions. The answer is **module-system merge-up**:
each slice declares its contribution via a `config` path that
aggregates into a namespace read by shared code.

```nix
# slices/kiro/transformer.nix — self-contained, no imports across slices
{ config, lib, ... }: {
  config.lib.ai.transformers.kiro = {
    name = "kiro";
    # … kiro-specific frontmatter renderer
  };
}
```

Shared code reads the merged set:

```nix
# dev/generate.nix, or anywhere else that needs all ecosystems
let
  transformers = config.lib.ai.transformers;  # { claude, copilot, kiro, … }
in
  # iterate / pick one / dispatch on name
```

The existing per-ecosystem aggregator (`lib/ai/transformers/default.nix`)
disappears. The module system does its job: each slice contributes,
shared code consumes, nobody `import`s across slice boundaries.

This is also why **per-slice HM/devenv published modules are optional
but not useless**: even if you never publish `homeManagerModules.ai.kiro`
externally, the slice-internal module boundary gives you the merge-up
pattern for free. It's the load-bearing feature regardless of external
API shape.

### 11.5 Compromise: move the obvious, leave the ambiguous

The `lib/` grep showed many false positives (comments, cross-CLI
type descriptions) alongside genuinely slice-owned code. Attempting
to resolve everything in one pass is analysis paralysis. The path
forward:

**Clean move-outs (no judgment needed):**

- `lib/ai/transformers/kiro.nix` → `slices/kiro/transformer.nix`
- `lib/ai/transformers/claude.nix` → `slices/claude/transformer.nix`
- `lib/ai/transformers/copilot.nix` → `slices/copilot/transformer.nix`
- `lib/ai/transformers/agentsmd.nix` → `dev/` (AGENTS.md is a repo-
  wide convention, not a single ecosystem)
- Per-package overlay files (`overlays/<pkg>.nix`) → the owning
  slice's directory
- Per-package `*-sources.json` sidecars → the owning slice
- `devshell/docs-site/` → a slice or `dev/` (it's the docsite
  pipeline, not an ecosystem)

**Leave in `lib/` for later review:**

- `lib/fragments.nix` (mentions kiro in a comment, but the primitive
  is cross-CLI)
- `lib/mcp.nix` (mentions kiro in a comment; helpers are cross-CLI)
- `lib/ai/ai-common.nix` (type descriptions name kiro for semantic
  contrast; types themselves are cross-CLI)
- `lib/options-doc.nix` (iterates all CLI modules)
- `lib/ai/sharedOptions.nix` (shared option declarations)
- `lib/ai/app/*` (factory primitives used by every CLI slice)

After the obvious moves and the pilot (§11.6), reassess what's left.
The hope is that `lib/` shrinks meaningfully and the remainder is
clearly-cross-cutting — at which point "what belongs in a slice vs
what stays shared" has a clean answer.

### 11.6 Pilot with one slice first

The module-merge pattern has edge cases (option declaration location,
class tags, devenv-side merge, flake output projection) that are
easier to debug with one slice than seven. Pick **kiro** as the pilot:

- Smallest cohesive slice with multiple packages (kiro-cli + kiro-gateway).
- Already has per-package modules + transformer + fragments.
- No shared-source complications.

Pilot scope:

1. Create `slices/kiro/`.
2. Move `packages/kiro-cli/`, `packages/kiro-gateway/` into it.
3. Move `overlays/kiro-cli.nix`, `overlays/kiro-gateway.nix`,
   `overlays/kiro-cli-sources.json` into it.
4. Move `lib/ai/transformers/kiro.nix` into it.
5. Move kiro-scoped fragments from `dev/fragments/` into
   `slices/kiro/fragments/`.
6. Rewire the merge-up: declare the shared namespace option, have
   `slices/kiro/transformer.nix` contribute via `config.lib.ai.transformers.kiro`.
7. Update `dev/generate.nix` + any other consumers to read from the
   merged namespace.
8. Verify `nix flake check`, `devenv test`, `devenv shell`, and the
   combined-merge HM module all still eval and build.

What to learn from the pilot before doing the other six slices:

- Does the module-merge pattern hold up at both HM and devenv eval
  sides, or does one surface surprise?
- Does `packages/default.nix` barrel composition accommodate nested
  slice dirs, or does it need restructuring?
- Do fragments/scoping still work with the new paths?
- Are there cross-cutting `lib/` files that looked shared but were
  actually kiro-specific (move them; shrinks `lib/` further)?

### 11.7 Sharp edges to resolve during the pilot

- **Multi-output slices.** `agnix` (CLI + MCP + LSP from one source)
  and `mcp-servers/_shared/modelcontextprotocol/` (one source →
  three packages). Pilot kiro first; these come later and are
  informed by pilot learnings.
- **Combined-merge module vs per-slice modules.** Keep combined-merge
  as the published surface. Per-slice HM/devenv modules can be added
  later if consumer demand materializes; not a requirement.
- **`dev/fragments/` subdirs.** Which are slice-adjacent (move) vs
  genuinely cross-cutting (stay)? Pilot kiro gives one data point;
  the rest can be decided per-slice during its own move.
- **Cross-slice CI check.** Once slices exist, add a check that fails
  on any `import ../<other-slice>/` — locks in the no-cross-slice
  discipline.

### 11.8 What this supersedes from §§8–10

- §8's "move overlay files into their owning package dir" → now
  "into the owning **slice** directory" (slightly coarser).
- §8's aggregate `ai.all` modules remain optional; lower priority
  than the slice-nav move.
- §10's "flake-parts migration?" → **no, not required**. Slice-nav
  achievable without it.
- §10's "lib.ai shape?" → **flat shared + slice merges up**. Shared
  helpers at `lib.ai.<helper>` (the collision plan's shape); slice
  contributions at `lib.ai.<namespace>.<slice>` (the merge-up
  pattern). Both coexist.
- §10's "multi-output packages" → resolved: one slice per cohesive
  source; agnix and `_shared/modelcontextprotocol/` are the two
  patterns.
- §5's ambiguity flags (agnix multi-output, shared mcp source,
  mcp-services aggregator, `lib/mcp.nix:22` inverted dep) → all
  naturally fit the slice-nav framing; addressed inside the slice
  move rather than as separate cleanups.

---

## Appendix — evidence & sources

Research conducted by three parallel subagents on 2026-04-22:

- **Repo state mapping** (Explore agent, Sonnet): verified 25 packages,
  12 shared-dir mappings, 59 upward imports (all to `lib/`, zero cross-
  slice), 7 ambiguity flags.
- **Flake-parts validation** (general-purpose + WebFetch, Sonnet): 10
  claims checked against flake-parts docs, nixpkgs source,
  rust-flake/haskell-flake/process-compose-flake, GitHub issues.
  Verdicts: 2 TRUE, 1 FALSE, 4 PARTIAL-with-footguns, 3
  FALSE-with-fixes.
- **Devenv integration** (general-purpose + WebFetch, Sonnet): verified
  `devenv.lib.mkShell` API, `perSystem.devenv.shells` preferred path,
  standalone vs flake-parts eval separation, `flake.devenvModules`
  community convention, `_class` absence, hook-system non-bridging.

Original dump: `/home/caubut/Downloads/nix-agentic-tools-architecture.md`
(821 lines, written without repo access).

Other session's live plan:
`docs/ai-factory-collision-refactor-plan.md` (702 lines, awaiting
execution).

Durable findings captured to memory as
`memory/reference_flake_parts_gotchas.md` and
`memory/reference_devenv_flake_parts_dual_mode.md`.
