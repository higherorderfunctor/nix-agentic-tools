# ai.\* factory — collision refactor + pure-eval rollback + Dir helpers

> **Status:** COMPLETE. Refactor landed, consumer migrated, CI green.
> All outstanding items from prior session resolved — see status
> roll-up below.
>
> **Origin:** failed `nixos-config` pin bump on 2026-04-21. Post-
> activation audit exposed three bugs (kiro `.md.md` doubled
> extension, HM orphan-cleanup misses, consumer migration UX), and
> conversation surfaced wider architectural gaps across the
> `ai.*` factory. User directed comprehensive revision before
> re-attempting consumer migration.
>
> **Branch:** `refactor/ai-factory-architecture`
>
> **Retained as historical reference.** Sections 3–12 document the
> design, commit sequence, and testing strategy for future
> archaeology. Day-to-day backlog lives in `docs/plan.md`.

## Status roll-up — 2026-04-21 end of session (late)

### ✅ DONE + hand-verified

All 9 commits from §6 landed and pushed to
`origin refactor/ai-factory-architecture`:

| #   | SHA       | Title                                                      |
| --- | --------- | ---------------------------------------------------------- |
| 1   | `21f8260` | refactor(lib): move lib.\* to lib.ai.\*                    |
| 2   | `056c7ad` | refactor(ai): deprecate sourcePath; pure-eval rollback     |
| 3   | `8cdc370` | refactor(ai): collision-as-failure across all shared pools |
| 4   | `ca85d90` | feat(lib): rulesFromDir + ai.<cli>.rulesDir option         |
| 5   | `1996081` | feat(lib): skillsFromDir + ai.<cli>.skillsDir option       |
| 6   | `e9ce26c` | feat(lib): agentsFromDir + ai.<cli>.agentsDir option       |
| 7   | `fdff369` | feat(claude): hooksFromDir + ai.claude.hooksDir option     |
| 8   | `e65a012` | fix(devenv): stale copilot skills paths                    |
| 9   | `83f459a` | docs(ai): dev fragments for collision + fanout + dir       |

Plus housekeeping:

| SHA       | Title                                                       |
| --------- | ----------------------------------------------------------- |
| `d397ec8` | docs(plan): mark ai-factory-collision refactor EXECUTED     |
| `2733070` | chore(cspell): exclude docs/monorepo-restructure-assessment |

- Consumer (`nixos-config`) edited — `kiroSymlinkSteering` + 15-file
  list replaced by `ai.kiro.rulesDir = ./kiro-config/steering;`, all
  `lib.<x>` → `lib.ai.<x>`. User pin-bumped + activated.
- Post-activation: **kiro `.md.md` bug FIXED** — steering files now
  land as `NN-name.md` under new gen `a91pv5q9...`. Structurally
  impossible to double-suffix by construction.
- **Orphan cleanup DONE** — user ran the `rm` one-liner before
  the session wrapped. Stale symlinks from the failed 2026-04-21
  activation are gone.
- **Dir helper parity VERIFIED** (`lib/ai/dir-helpers.nix`):
  all four helpers use shared `resolveDirArg` normalizer,
  polymorphic `path | { path, filter? }` input, `name → bool`
  filter signature. Default filters: `.md` suffix for rules +
  agents; `_: true` for skills (dirs) + hooks (files). rules
  and agents strip `.md` from keys so emission re-append can't
  double-suffix. Differences between helpers (skills use dirs,
  hooks use `readFile` for inline content) are semantic and
  intentional.
- **Test coverage VERIFIED** — 29 of 31 subagent-claimed tests
  present in `checks/module-eval.nix`: 9 collision + 5 rulesDir
  - 4 skillsDir + 5 agentsDir + 4 hooksDir + 2 sourcePath-rejected.
    The 2 "bake regression" tests claimed in the subagent's report
    are either folded into pre-existing rule-text tests or weren't
    added under that name. Core coverage is present; the 2-test
    gap is low-risk (regression of a pre-existing path).
- **Dev fragments VERIFIED** — `dev/fragments/ai-module/`
  contains `collision-semantics.md`, `dir-helpers.md`,
  `layered-fanout.md` (plus pre-existing `ai-module-fanout.md`).
  Generator rendered them into `.claude/rules/ai-module.md`,
  `.github/instructions/ai-module.instructions.md`, and
  `.kiro/steering/ai-module.md`. Collaborators cloning without
  the user's memory get full architectural context.

### ✅ All previously-outstanding items RESOLVED (2026-04-27 verify)

- **SYMPTOM A** — `e65a012` (devenv.nix stale copilot skill paths)
  confirmed green on subsequent update PRs. Closed.
- **SYMPTOM B (ruamel fetchhg)** — verified inactive on
  2026-04-27. flake.nix:24 still declares `inputs.git-hooks.inputs.nixpkgs.follows
= "nixpkgs"` and flake.lock still routes git-hooks's nixpkgs through
  the buried `["devenv","crate2nix","cachix","nixpkgs"]` chain
  (declaration not honored, same state as 2026-04-21). Despite
  that unchanged state, PR #45 (git-hooks update) merged green
  on 2026-04-22 and current PR #70 has all checks passing. Best
  read: the underlying ruamel-yaml-clib derivation got fixed
  upstream during a nixpkgs movement, masking the unresolved
  follows-not-honored anomaly. The follows resolution gap is a
  latent puzzle, not an active blocker. **No action needed unless
  it resurfaces.**
- **Observation 1 (openmem Update-vs-PR parity gap)** — RESOLVED
  via `9b5cbc5` (prime src drvPath before nix-update) +
  `2604eb2` (roll back Phase 0 commit on Phase 1 failure). Root
  cause was IFD: `nix flake prefetch` doesn't materialize the
  src `.drv` that nix-instantiate --strict needs to resolve
  `readFile "${src}/..."` context.
- **Observation 2 (mcp-nixos PR-CI failure)** — RESOLVED. The
  failure was upstream's transitional reference to
  `pyFinal.uncalled-for`; cleared by the nixpkgs bump in PR #51.
- **Observation 3 (late PRs #53/#54/#55 with hash mismatches)** —
  RESOLVED. Commit `f277053` eliminated IFD from version
  computation by switching from `vu.readPackageJsonVersion
"${src}/path"` to literal version strings + magic-comment
  parsing in `update-pkg.sh`. The hash-mismatch class disappeared
  with the IFD-elimination + drv-priming combo.
- **Cache-hit parity regression gate** — `5bb3d17` shipped the
  check; `57a2c04` fixed git-branchless (real drift bug surfaced
  by the gate). 18 overlay packages covered, 0 drift.

### Diff of audit outcomes vs pre-activation snapshot

Captured in this session's post-activation audit #2 + the
follow-up orphan cleanup. Key outcomes:

- `.md.md` bug: structurally dead by construction
- No new orphans introduced by the new gen
- Pre-existing orphans from the failed 2026-04-21 activation:
  all cleared by user's manual `rm`
- `~/.kiro/steering/` now holds exactly 15 `NN-name.md`
  symlinks, each pointing at the current HM gen
- Copilot writes to the new path (`~/.copilot/`) only; old
  path (`~/.config/github-copilot/`) is clean

## Table of contents

1. [Context](#1-context)
2. [Post-activation audit](#2-post-activation-audit)
3. [Architecture directives from user](#3-architecture-directives-from-user)
4. [Layered fanout pattern (canonical)](#4-layered-fanout-pattern-canonical)
5. [Scope of this plan](#5-scope-of-this-plan)
6. [Commit sequence](#6-commit-sequence)
7. [Testing strategy](#7-testing-strategy)
8. [Architecture fragments to author](#8-architecture-fragments-to-author)
9. [Consumer migration (nixos-config)](#9-consumer-migration-nixos-config)
10. [CI bug fixes](#10-ci-bug-fixes)
11. [Open questions / deferred](#11-open-questions--deferred)
12. [Review checklist](#12-review-checklist)

---

## 1. Context

The factory now covers Claude / Kiro / Copilot with shared
surfaces: `ai.context`, `ai.rules`, `ai.skills`, `ai.agents`,
`ai.mcpServers`, `ai.lspServers`, `ai.environmentVariables`,
plus per-CLI extensions. This plan retroactively tightens three
cross-cutting concerns the factory got wrong as it grew:

- **Collision semantics** — today shared pools merge silently via
  `//` so a later contributor can silently override an earlier
  one. User wants collisions to be **failure**.
- **Live-edit as a design axis** — `fab4e5c` introduced
  `sourcePath` (nullable string) to preserve out-of-store
  symlinks for live-edit. User has since decided live-edit is
  not worth the impurity (devenv covers iteration). Roll back.
- **Directory-based ingestion UX** — consumer wants to point at
  a directory and have each file become a rule/skill/agent/
  hook, WITHOUT the directory being taken over wholesale (leave
  room for other derivations to contribute to the same dir).

## 2. Post-activation audit

Taken at 2026-04-21 ~19:45 after user ran `home-manager switch`
with nix-agentic-tools pinned to `fbf6a46`.

### Bugs surfaced

**Bug 1 — Kiro steering `.md.md` doubled extension.** 15 of 15
migrated steering files landed as `NN-name.md.md`. Cause: my
consumer migration used `lib.mapAttrs` over `readDir` output
where the key is the full filename (`04-git.md`), and the
factory's emission path appended `.md` again. Every existing
steering file is unreadable by Kiro.

**Bug 2 — HM orphan cleanup miss.** After switch:

- `~/.claude/skills/sws-stack-*` (6 dirs) — still present,
  pointing at OLD gen `1vll2vlk...`
- `~/.claude/rules/stacked-workflows.md` — old gen
- `~/.claude/references/*.md` (6 files) — old gen
- `~/.kiro/steering/stacked-workflows.md` — old gen
- `~/.config/github-copilot/copilot-instructions.md` — old gen
- `~/.config/github-copilot/mcp-config.json` — old gen

New generation `9nzv64i6...` wrote to the NEW paths, but HM did
not clean up the OLD paths. This is documented Layout-B
orphan-cleanup behavior (HM preserves real dirs with symlinks
inside) plus configDir-move orphan behavior (HM doesn't know
the old path exists once the option default changes).

**Bug 3 — Copilot configDir migration.** `164b541` changed HM
default from `.config/github-copilot` to `.copilot`. Consumer
defaulted along with it. Old files are orphans.

### Fixes needed by audit (beyond the comprehensive plan)

- Manual `rm -rf` of the orphan entries (one-time, outside Nix)
- Consumer migration approach change: use `rulesFromDir` helper
  instead of raw `readDir` so extension handling is correct

## 3. Architecture directives from user

Captured verbatim where useful:

### 3.1 Namespace

> "all `lib.*` should be `lib.ai.*`. I cannot think of anything
> that should be top level."

Move every flake-level `lib.*` export to `lib.ai.*`. Including
existing `mkStdioEntry`, `mkHttpEntry`, `mkPackageEntry`,
`renderServer`, `externalServers`, plus all new helpers.

### 3.2 Collision semantics

> "mixing and collision should be a failure. we don't merge over
> keys. its a failure condition."

All shared pools fail on duplicate keys. No silent winner.
Retroactive across:

- `ai.skills` / `ai.<cli>.skills`
- `ai.context` (global, not shared — but detect dupes)
- `ai.rules` / `ai.<cli>.rules`
- `ai.mcpServers` / `ai.<cli>.mcpServers`
- `ai.lspServers` / `ai.<cli>.lspServers`
- `ai.environmentVariables` / `ai.<cli>.environmentVariables`
- `ai.agents` / `ai.<cli>.agents`

Plus the new Dir surfaces (see §4).

Implementation: replace `//` merges with an explicit
collision-detecting merge helper. Emit NixOS `assertions` (eval-
time failure, user-friendly message naming the duplicate key and
both contributing sources) — not `throw` (no source info).

### 3.3 Pure eval + deprecate live-edit

> "ive moved away from live editing so much, was nice when first
> starting but honestly im ready to deprecate. devenv is the
> middle ground."
> "i prefer just to be pure if possible... which is why im
> thinking deprecating string as path."

Roll back `sourcePath` (feature introduced in `fab4e5c`). Rule
text returns to `lines | path` only. Deprecate string-as-path
throughout the factory. Nix path literals only.

### 3.4 Layered fanout pattern

> "original lib and just fan out to singles, then singles fan
> out to per ecosystem (if top level). ecosystem `*dir` fans
> out to ecosystem singles. ecosystem singles fan out to either
> southbound or implementation. all implementation or
> southbound fan out logics is written one at the singles
> ecosystem. everything else just fans out to that eventually."

Documented as §4 below.

### 3.5 Dir options ergonomics

> "i also dont know about excludes = [], maybe filter lambda?
> covers more use cases besides string exact match?"
> "whats the pooint of string at all for paths? not sure we
> need type"
> "just name is fine on the filter"

Dir option is polymorphic: `path` literal OR
`{ path, filter? }` submodule. Filter signature is `name → bool`
(name only, not full attrs — covers the use cases without
over-engineering).

### 3.6 Scope

> "in reverse order on the gaps... i was skills/agents/hooks
> also in the plan."

Dir helpers for: **rules**, **skills**, **agents**, **hooks**.

### 3.7 Documentation for collaborators

> "arch/ai dev type fragments for folks who clone the repo and
> dont have my memory files for all changes made during the plan"

Write dev fragments for the key architectural decisions (not
ephemeral plans — those stay here). Target: a collaborator who
clones the repo without the user's memory has context.

### 3.8 Tests

> "producing test cases for all the new work and changes"

Every new helper, every new option, every collision assertion
gets at least one test in `checks/module-eval.nix` plus
regression tests for the rolled-back `sourcePath` path.

## 4. Layered fanout pattern (canonical)

This is the definitive shape. All future shared concerns follow
this pattern. Applies to any concern X where X is per-file
ingestable.

```
┌─────────────────────────────────────────────────────────────┐
│ L1: Top-level Dir option (optional)                         │
│   ai.<X>Dir = path | { path, filter? }                      │
│   ─ path: Nix path literal (nullable)                       │
│   ─ filter: name → bool (default: all .md files)            │
│   ─ expands to per-file entries internally                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼  fanout via lib.ai.<X>FromDir
┌─────────────────────────────────────────────────────────────┐
│ L2: Top-level singles                                       │
│   ai.<X> = attrsOf <itemModule>                             │
│   ─ cross-ecosystem pool                                    │
│   ─ shape varies by X (skills: dir, rules: file, etc.)      │
│   ─ collision-as-failure within this layer                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼  fanout to each enabled CLI
┌─────────────────────────────────────────────────────────────┐
│ L2b: Per-CLI Dir option (optional)                          │
│   ai.<cli>.<X>Dir = path | { path, filter? }                │
│   ─ same shape as L1                                        │
│   ─ expands to per-file via same lib helper                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼  fanout via lib.ai.<X>FromDir
┌─────────────────────────────────────────────────────────────┐
│ L3: Per-CLI singles                                         │
│   ai.<cli>.<X> = attrsOf <itemModule>                       │
│   ─ per-CLI pool                                            │
│   ─ collision-as-failure within this layer                  │
│   ─ merged with L2 pool contribution for this CLI           │
│   ─ collision-as-failure at merge (no silent overrides)     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼  translation + emission
┌─────────────────────────────────────────────────────────────┐
│ L4: Emission (factory internal only, not user surface)      │
│   - HM: home.file.* or programs.<cli>.* delegation          │
│   - Devenv: files.* emission                                │
│   - Transformer frontmatter per ecosystem                   │
│   - Layout decisions (B vs file-level symlinks)             │
└─────────────────────────────────────────────────────────────┘
```

### Rules

- **Emission logic lives ONLY at L4**, reached from L3. L1/L2/L2b
  are pure fanout — they never touch `home.file.*` or `files.*`.
- **Collision-as-failure happens at every layer boundary**
  (L1→L2 inside one CLI's closure, L2b→L3 inside one CLI's
  closure, L2+L3 merge). Same helper, same error shape.
- **Dir helpers live in `lib.ai.*`** — NOT in the module layer.
  They're pure (path → attrset) and usable outside HM/devenv.
- **No `*Dir` option produces anything that locks the output
  dir wholesale** — always goes through per-file emission. A
  consumer's `home.file.".claude/rules/extra.md".text = …` from
  another derivation still works.
- **Keys retain their filename identity** — if a file is named
  `foo.md` in the source dir, the L2 attribute key is `foo` (the
  factory strips known suffixes before producing keys, and
  re-appends at emission). This fixes the `.md.md` bug.

### What the helpers do, concretely

```nix
# lib/ai/lib.nix (or lib/ai/dir-helpers.nix)

# Common shape:
# pathOrSubmodule : path | { path, filter? }  (polymorphic at call site)
# returns : attrsOf ruleModule-shape

rulesFromDir = pathOrSubmodule:
  let
    cfg = if lib.isPath pathOrSubmodule
          then { path = pathOrSubmodule; filter = defaultMdFilter; }
          else pathOrSubmodule;
    files = builtins.readDir cfg.path;
    mdFiles = lib.filterAttrs (n: t: t == "regular" && cfg.filter n) files;
    stripMd = name: lib.removeSuffix ".md" name;
  in lib.mapAttrs'
       (name: _: lib.nameValuePair (stripMd name) { text = cfg.path + "/${name}"; })
       mdFiles;

# Similar shape for skillsFromDir (directory-of-dirs, each sub-
# dir becomes a skill), agentsFromDir (file-per-agent), hooksFromDir
# (per-file hook declarations — Claude only).
```

Filter default: `name: lib.hasSuffix ".md" name` (rules, skills,
agents). For hooks: `name: lib.hasSuffix ".json" name` or
`.nix` depending on consumer pattern.

### Why this shape

- **Auto-discovery** — consumer points at a dir, everything in
  it lands. Replaces the `kiroSymlinkSteering` helper.
- **Filtering** — `filter = name: !(lib.hasSuffix ".bk" name)`
  is a real use case (user has `gh-repo-settings.bk` backup).
- **Per-file emission** — no directory takeover. Other
  derivations (or consumer's own direct `home.file` calls) can
  contribute to the same dir.
- **Pure-eval** — path literal at call site, never coerces
  string to path.
- **Shared across HM + devenv** — `lib.ai.*` is pure, both
  backends use it identically.

## 5. Scope of this plan

In scope:

- Retroactive collision-as-failure on all 7 existing shared
  pools (rules, skills, context, mcpServers, lspServers,
  environmentVariables, agents) + per-CLI equivalents
- `lib.*` → `lib.ai.*` namespace move (every flake-level
  export, every factory internal consumer, plus consumer
  rename path in nixos-config)
- Deprecate `sourcePath` from `ruleModule` — rollback of
  `fab4e5c` (one commit-ish's worth of changes)
- New `lib.ai.{rulesFromDir, skillsFromDir, agentsFromDir,
hooksFromDir}` helpers
- New `ai.<X>Dir` top-level options (rules, skills, agents,
  hooks)
- New `ai.<cli>.<X>Dir` per-CLI options (same set, minus
  per-ecosystem exclusions — Kiro no agents, Claude only for
  hooks)
- Tests for every new surface + regression tests for
  rolled-back `sourcePath`
- Dev fragments capturing architectural decisions (see §8)
- Consumer migration to `ai.kiro.rulesDir = ./kiro-config/steering`
- SYMPTOM A fix (devenv.nix stale paths)
- SYMPTOM B fix (once root-caused — see §10)

Out of scope:

- MCP startup failures (github-mcp / kagi-mcp) — separate
  investigation
- Codex ecosystem
- mcp-proxy OAuth 2.1
- Typed settings / typed plugins schemas (kept as pending
  backlog items)
- HM orphan-cleanup fixes for Layout B — documented as manual
  `rm -rf` post-switch step

## 6. Commit sequence

Order chosen to keep each commit independently buildable and
reviewable. Each commit includes matching tests.

### Commit 1 — `refactor(lib): move lib.* to lib.ai.*`

- Relocate every flake-level `lib.<x>` to `lib.ai.<x>`
- Internal callers inside factory updated
- Public exports in `flake.nix` repointed under `lib.ai.*`
- No behavior change
- Test: existing tests still green under new names
- Touches: `flake.nix`, every `lib/` file, every
  `packages/*/lib/mk*.nix` consumer of these helpers

### Commit 2 — `refactor(ai): deprecate sourcePath; revert to pure-eval rules`

- Remove `sourcePath` from `ruleModule` in `lib/ai/ai-common.nix`
- Remove `config` threading through `hmTransform.nix` for
  sourcePath branch
- Remove test harness `mkOutOfStoreSymlink` stub in
  `checks/module-eval.nix`
- Relax `text` back to required (was nullable after fab4e5c)
- Update `docs/ai-rules-livelink-plan.md` status → ROLLED BACK
- Regression test: rule with `text = ./foo.md` still works
- Negative test: rule with `sourcePath = "..."` errors with
  "unknown option"

### Commit 3 — `refactor(ai): collision-as-failure across all shared pools`

- Introduce `lib.ai.mergeWithCollisionCheck` (or similar) —
  helper that merges attrs and emits `assertions` entries on
  collision naming both contributors
- Replace every `//` merge of per-CLI pool + top-level pool in
  factory with the new helper
- Emit collision errors through `config.assertions` so they
  surface via module-eval
- Retroactive audit: rules, skills, context, mcpServers,
  lspServers, environmentVariables, agents
- Per-pool tests: collision at each layer boundary fires the
  assertion with expected message shape

### Commit 4 — `feat(lib): lib.ai.rulesFromDir + ai.<cli>.rulesDir option`

- Add `lib.ai.rulesFromDir` helper per §4
- Add `ai.rulesDir` top-level option
- Add `ai.<cli>.rulesDir` per-CLI option for claude, kiro,
  copilot
- Polymorphic input: `path | { path, filter? }`
- `filter` signature: `name → bool`; default keeps `.md` files
- Rule name comes from basename minus `.md`
- Fixes the `.md.md` bug: factory emits `${name}.md`, key is
  `.md`-less
- Tests: path-only form, submodule form, filter form, collision
  between Dir-generated and explicit single

### Commit 5 — `feat(lib): lib.ai.skillsFromDir + ai.<cli>.skillsDir option`

- Same shape as rules, but directory-of-directories input
  (each subdir becomes a skill)
- Per-CLI for claude, kiro, copilot (all three support skills)
- Tests: directory-of-dirs ingestion, collision, filter

### Commit 6 — `feat(lib): lib.ai.agentsFromDir + ai.<cli>.agentsDir option`

- Claude + Copilot only (Kiro excluded — JSON shape differs)
- Tests: per-CLI ingestion, collision

### Commit 7 — `feat(claude): lib.ai.hooksFromDir + ai.claude.hooksDir option`

- Claude-only (hooks are a Claude-specific concept)
- Tests: hooks ingestion, collision

### Commit 8 — `fix(devenv): stale copilot skills paths`

- `devenv.nix:250` — update cleanup path to `.github/skills`
- `devenv.nix:266` — update assertion path to `.github/skills`
- One-line change x2, no test needed (the enterTest step IS
  the test)

### Commit 9 — `fix(ci): <SYMPTOM B fix — pending root cause>`

See §10.2 — can't commit to shape without finishing root-cause
analysis.

### Commit 10 — dev fragments for the new architecture

- `modules/ai/fragments/dev/collision-semantics.md`
- `modules/ai/fragments/dev/layered-fanout.md`
- `modules/ai/fragments/dev/dir-helpers.md`
- Registered in `dev/generate.nix`
- Auto-emits to `.claude/rules/`, `.github/instructions/`,
  `.kiro/steering/` on `devenv tasks run --mode before
generate:instructions`

### Consumer repo (nixos-config) — separate commit, not in this repo

See §9.

## 7. Testing strategy

### Test types

- **Module-eval tests** (`checks/module-eval.nix`) — pure Nix
  eval, no derivation build. Fast. Every new option + every
  collision path gets one.
- **Transformer tests** — frontmatter/content rendering per
  ecosystem for each new Dir-ingested entry.
- **Regression tests** — existing `text = ./foo.md` rules still
  work; existing `ai.<cli>.rules.<name>.text` still works.
- **Negative tests** — dropped `sourcePath` option surfaces a
  useful error; collision fires `assertions` with both
  contributor sources in the message.

### Test shape (module-eval.nix)

```nix
collisionRulesTopVsCli = testHmEval {
  modules = [{
    ai.rules.foo.text = "top";
    ai.claude.rules.foo.text = "cli";
  }];
  assertion = result:
    lib.any
      (a: lib.hasInfix "rule 'foo' declared in both" a.message)
      result.config.assertions;
};

rulesFromDirStripsExtension = testHmEval {
  modules = [{
    ai.kiro.rulesDir = ./fixtures/kiro-steering;
  }];
  assertion = result:
    lib.attrNames result.config.home.file
    |> lib.filter (lib.hasPrefix ".kiro/steering/")
    |> lib.all (p: !lib.hasSuffix ".md.md" p);
};
```

### Test fixture dirs

- `checks/fixtures/kiro-steering/` — ~3 files with `.md`
  extension for the stripping test
- `checks/fixtures/claude-skills/` — 2 skill subdirs for the
  skillsFromDir test
- `checks/fixtures/claude-hooks/` — 1 hook file for hooksFromDir

## 8. Architecture fragments to author

These go in `modules/ai/fragments/dev/` and emit to per-
ecosystem `.claude/rules/`, `.github/instructions/`,
`.kiro/steering/` via `dev/generate.nix`.

Each fragment opens with a `Last verified: <date> (commit X)`
marker per project convention.

### 8.1 `collision-semantics.md`

- Rule: duplicate keys across any shared pool → assertion
  failure
- Why: silent merges mask bugs; explicit failure is loud
- How: `lib.ai.mergeWithCollisionCheck` helper, called from
  every factory pool merge
- Pitfall: when adding a new shared pool, MUST use this helper
  — do NOT `//` merge
- Debugging: look at `config.assertions` values

### 8.2 `layered-fanout.md`

- Canonical 4-layer pattern (copy the ASCII diagram from §4)
- Why: emission logic in one place = less drift
- Adding a new concern X: add L2 option, L3 per-CLI options,
  L4 emission, optionally L1+L2b Dir options
- Pitfall: never emit from L1/L2/L2b — ONLY at L3→L4

### 8.3 `dir-helpers.md`

- `lib.ai.<X>FromDir` helpers: what they do, when to use
- Polymorphic input shape (path vs submodule)
- Filter signature and rationale
- Why pure-eval only (no string-as-path)
- Why live-edit was deprecated (devenv covers it)

### 8.4 Memory update (user's memory, not fragments)

Update `project_factory_architecture.md` memory with:

- Layered fanout pattern summary
- Collision-as-failure convention
- `lib.ai.*` namespace (not `lib.*`)
- Live-edit deprecated, pure-eval only

## 9. Consumer migration (nixos-config)

Separate commit in `nixos-config` repo. Not touched by this
plan's commits.

### 9.1 Pre-flight

- Manual `rm -rf` of orphan HM entries (one-time cleanup):
  ```
  rm -rf ~/.claude/skills/sws-stack-*
  rm ~/.claude/rules/stacked-workflows.md
  rm ~/.claude/references/*.md  # then rebuild, non-sws refs come back
  rm ~/.kiro/steering/*.md.md
  rm ~/.kiro/steering/stacked-workflows.md
  rm ~/.config/github-copilot/copilot-instructions.md
  rm ~/.config/github-copilot/mcp-config.json
  ```
- Pin bump to `refactor/ai-factory-architecture` HEAD (post-
  implementation)

### 9.2 Edits in `home/caubut/features/cli/code/ai/default.nix`

```nix
# Replaces kiroSymlinkSteering helper + kiroSteeringFiles list
ai.kiro.rulesDir = ./kiro-config/steering;

# If consumer wants to exclude backup files:
# ai.kiro.rulesDir = {
#   path = ./kiro-config/steering;
#   filter = name: !(lib.hasSuffix ".bk" name);
# };
```

- Remove `kiroSymlinkSteering` helper fn (~15 lines)
- Remove `kiroSteeringFiles` list
- Remove `ai.kiro.rules = lib.mapAttrs (...) (builtins.readDir ...)`
  from post-activation (the failed attempt)

### 9.3 Rename flake input usages

Every reference to `inputs.nix-agentic-tools.lib.mkStdioEntry`
etc becomes `inputs.nix-agentic-tools.lib.ai.mkStdioEntry`.
Grep across nixos-config, update.

### 9.4 Pre/post activation audit (round 2)

The first pre/post audit (memory: `preactivate_snapshot_2026-
04-21.md` + §2 of this plan) is what surfaced the bugs. It is
DONE. The plan now demands a second round once implementation
lands:

1. **Just before re-activation**: capture a fresh pre-activation
   snapshot of `~/.claude/`, `~/.kiro/`, `~/.copilot/`,
   `~/.config/github-copilot/` (task #57). Reflects the
   current broken state post-orphan-cleanup (manual rm).
2. **User runs `home-manager switch`** with new factory +
   updated consumer (rulesDir) + renamed lib paths.
3. **Just after activation**: audit vs the fresh pre-snapshot
   (task #58). Confirm:
   - All 15 kiro steering files named `NN-name.md` (no `.md.md`)
   - Steering symlinks point at current HM gen (not out-of-
     store — live-edit deprecated)
   - No new orphans introduced
   - `home-manager switch` clean exit
   - Collision assertions don't fire for valid config

## 10. CI bug fixes

### 10.1 SYMPTOM A — devenv.nix stale paths

Root cause: `446f8a6` moved Copilot project skills from
`.config/github-copilot/skills/` to `.github/skills/`, but
`devenv.nix` has two hardcoded references that weren't updated:

- Line 250 (enterShell cleanup) — cleans the old path
- Line 266 (enterTest assertion) — asserts file at old path

Fix: update both lines to `.github/skills/`.

### 10.2 SYMPTOM B — ruamel-yaml-clib fetchhg failure (RESOLVED — inactive)

**Resolution (verified 2026-04-27):** PR #45 (next git-hooks
update, 2026-04-22) merged green; PR #70 (current update) has
all checks passing. flake.nix declaration + flake.lock state
unchanged from the 2026-04-21 snapshot — the follows resolution
anomaly persists but the failure class is gone. Most likely
upstream nixpkgs moved past whatever broken-fetchhg ruamel
derivation was being pulled in. Latent puzzle preserved below
for archaeology if it returns.

**Known so far (evidence-backed):**

- Main's `flake.lock` ALREADY has buried follows for git-hooks:
  `git-hooks.inputs.nixpkgs = ["devenv","crate2nix","cachix","nixpkgs"]`
- Update PR `update/git-hooks` has the SAME follows chain (only
  the git-hooks rev itself changed)
- Resolution check: `["nixpkgs"]` → node `nixpkgs_5`;
  `["devenv","crate2nix","cachix","nixpkgs"]` → node
  `nixpkgs`. These are DIFFERENT nodes.
- `flake.nix:24` declares `inputs.git-hooks.inputs.nixpkgs.follows = "nixpkgs"`
- That declaration is NOT being honored in flake.lock

**Unknown:**

- WHY is the follows declaration not honored?
- Is it a Nix bug, or a local misconfiguration?
- Why does main's CI stay green with the buried follows but
  update/git-hooks fails? (most likely: newer git-hooks rev
  triggers eval of an old-nixpkgs derivation that uses ruamel,
  old nixpkgs's ruamel-yaml-clib uses broken fetchhg)

**Investigation plan before committing a fix (task #54):**

1. Reproduce: spin up a minimal flake with same input
   declaration pattern; confirm whether follows is honored
2. Bisect: check git log of flake.lock for when the buried
   follows first appeared; was it honored at first and then
   regressed, or was it never honored?
3. Check Nix version: run `nix --version`; cross-ref with
   known follows bugs in NixOS/nix issue tracker
4. Try alternative declaration syntax: does
   `inputs.git-hooks.inputs.nixpkgs.follows = "/nixpkgs"` (leading
   slash) differ? Does using flake references in the follows
   value (e.g., the full URL) differ?

**No fix proposed until investigation concludes.** User
directive: "dont guess/check tho". Once root cause is known, fix
becomes one of:

- Correct flake.nix declaration (if we had it wrong)
- Invocation-level fix in `dev/scripts/update-input.sh` (if
  `nix flake update` has a flag/sequence that preserves follows
  correctly)
- Systemic workaround (post-lock-gen follows verifier that
  fails CI if resolution diverges from flake.nix declaration)

## 11. Open questions / deferred

- Whether top-level `ai.context` (single file, not pool) needs
  collision-check — only one entry exists, but add guard
  anyway for uniformity
- Whether `ai.mcpServers` collision error should include
  `renderServer`-generated vs user-provided entries with
  different error phrasing
- Whether we want a `ai.<X>Dir` that produces BOTH L2 (top-
  level) and L2b (per-CLI) entries from a single dir (probably
  not — unnecessary confusion)
- `lib.ai.<X>FromDir` return type: attrset of the itemModule
  shape, or attrset pre-wrapped with `mkMerge`? Attrs is
  simpler — let module system handle merging + collision-check
- Layout B cleanup bug (HM doesn't orphan-clean Layout B dirs)
  — systemic, upstream HM concern. Deferred with a documented
  manual-rm post-switch step.

## 12. Review checklist

Before user approves execution:

- [ ] Scope matches directives (§3)
- [ ] Commit sequence is incrementally testable (§6)
- [ ] Tests cover every new surface (§7)
- [ ] Fragments will help a clone-only collaborator (§8)
- [ ] Consumer migration is concrete and minimal (§9)
- [ ] SYMPTOM A fix verified (§10.1)
- [ ] SYMPTOM B root cause identified + fix concrete (§10.2)
- [ ] User signs off on commit 9's shape (pending root cause)

Before subagent dispatch:

- [ ] Plan approved by user
- [ ] Task list reflects commit sequence
- [ ] Subagent prompts reference this doc
- [ ] Parent session retains context for bug triage

## Changelog

- 2026-04-21 — initial plan written
- 2026-04-27 — all outstanding items resolved; status flipped
  to COMPLETE. SYMPTOM B verified inactive (flake.lock state
  unchanged but failure class gone). Observations 1/2/3 closed
  via `9b5cbc5` + `2604eb2` + `f277053`. Cache-hit parity gate
  added (`5bb3d17`, `57a2c04`).
- 2026-04-21 — post-activation audit added (§2)
- 2026-04-21 — pending: SYMPTOM B root-cause investigation (§10.2)
