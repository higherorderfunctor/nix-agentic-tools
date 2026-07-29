# Build the done-right typed hook option surface (B2)

> **Living plan** (dev-living-workflow, FULL tier, CLI mode). This doc is the
> human-readable face; the **authoritative machine state is out-of-repo** at
> `${XDG_STATE_HOME:-~/.local/state}/living-workflows/nix-agentic-tools/typed-hook-surface/`
> (`state.json` + `journal.ndjson`). The out-of-repo `state.json` is
> authoritative; this doc is a synced snapshot for humans + cross-session merge.
>
> **living_doc_baseline:** `v8-onyx-moor-rowan` (master:
> `.claude/skills/dev-living-workflow/references/living-plan-bootstrap.md`).
>
> **⏸ PAUSED 2026-07-21 for a 3-session unify** (see CROSS-SESSION MERGE
> CONTEXT). This doc was flushed to disk at operator request so a merge session
> can consume it.

## NORTH STAR

The typed hook **option surface is the PRODUCT** — a complete, correct interface
exposing ALL hooks across BOTH ecosystems (Claude Code + Kiro CLI), so different
memory systems can be wired in to **eval/compare** and telemetry can be wired in
to **measure hook effectiveness**. Options are designed **RIGHT on their own
merits**; implementations (autoMemory, other memory systems, telemetry) **map
onto** the options — never the reverse. `hooksJson` is a surgical bridge shaped
to the autoMemory pilot; it is **not** the destination and gets retired.

Provenance: continues the typed-hooks thread landed in PRs #418 (typed Kiro
hooks) + #433 (real-file delivery, tui/v3 parity, captured fixture). See memory
`project_typed_hooks_assessment` and
`docs/plans/typed-hooks-across-clis-assessment.md` §8 (design) + §14.

## CURRENT POSITION

- **Phase:** P1 (design + skeleton the surface) — first net-new unit **u1 done +
  committed**.
- **Class:** `mid_batch`, **PARKED** by operator pending a 3-session unify.
- **Committed:** `0222a0eb` on branch `feat/kiro-hook-colocation` (pushed to
  origin) — the Kiro per-record `file` co-location mechanism + module-eval
  golden + fragment maintenance.
- **PR: NOT created** — blocked by a base divergence (below). Do not create it
  or force-push until the base is reconciled.
- **Next action:** on resume, rebase `0222a0eb` onto the **reconciled**
  integration base, adapt the module-eval test to `#433`'s `home.activation` HM
  delivery, reconcile the fragment with `#433`, re-verify the kiro hook checks,
  then open the PR.

## ⚑ CROSS-SESSION MERGE CONTEXT (read this first for the unify)

Three sessions have been colliding on the same hook/delivery surface. **This
session is #2.**

| #   | Session (operator's words)                      | What it owns / did                                                                                                                                                                                                                                                                      |
| --- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | ci fix → **symlink vs real-file fanout**        | The delivery mechanism. Origin `#433` moved **HM** hook delivery `home.file` → `home.activation` real-files; local commits `f12aa5f1` (instruction files symlink→real-file copies) + `a7b3e29d` (idempotent copies over devenv symlinks). Owns HOW hook/instruction files land on disk. |
| 2   | **hook implementation to wire into hooks** ← ME | The typed hook **option surface** (`ai.kiro.hooks` / `ai.claude.hooks`). This session added the per-record **`file` co-location** key so N typed records lower into one envelope — the typed path off the `hooksJson` escape hatch.                                                     |
| 3   | **fixture/lab implementation to test hooks**    | The hook **test harness** (tier1b prototype / hook contract fixtures / agent-primitive labs). Would consume the typed surface (this session's output) as the thing-under-test, and P1c/P2 here overlap with it.                                                                         |

**Intersections the merge must resolve:**

- **#2 ↔ #1 (DIRECT COLLISION, already bit us):** my `file` co-location changes
  the hook **lowering** (`mkAllHookFiles` / `kiroHookRecord` in `mkKiro.nix`);
  `#433` changed the hook **delivery** (HM `home.file` → `home.activation`). The
  lowering is delivery-independent (`mkAllHookFiles` is still the lowering fn on
  `#433`), so **the mechanism composes** — but my **module-eval test** asserts
  the pre-`#433` `home.file` path and **fails on `#433`** (verified). Merge =
  keep my lowering change, re-point the test at `#433`'s `home.activation`
  delivery.
- **#2 ↔ #3:** the typed surface (incl. `file` co-location) is what #3's
  fixtures/labs test the FIRING of. P1c (tier1b graduation) + P2 (telemetry test
  channel) here are #3's territory. Merge = #3's harness consumes the typed
  surface as-shipped.
- **#1 ↔ #3:** delivery mechanism vs the fixtures that assert on delivered files
  — they must agree on real-file vs symlink for both hooks and steering.

**The base-divergence is the mechanical root of the collisions** — see next
section. All three sessions are working in a local checkout that is **9 merged
PRs behind origin**, so they are building on divergent bases and overwriting
each other.

## THE BASE DIVERGENCE (mechanical root cause)

> **RESOLVED 2026-07-21 (converge-agentic-foundations P1):** the divergence
> below is historical. Local == origin at `b3906bd9`; `#433` (`af53cf63`) is an
> ancestor. The five local commits landed rewritten as `c80b1df0` (ci-perf),
> `a7b3e29d` (devenv fix), `b861e783` (this plan doc), `53e01533` (instruction
> regen), `f12aa5f1` (materialize); the pre-rewrite hashes below resolve as
> loose objects but are NOT ancestors of HEAD.

The local `refactor/ai-factory-architecture` checkout **diverged from origin at
`010dbe15`**:

- **origin has, local lacks (9 merged PRs):** `#433` (real-file HM hook delivery
  — the exact code #1 rewrote), `#424`, `#414`–`#423`, docs.
- **local has, origin lacks (unpushed):** the ~5 local session commits
  (`b75b4ac3` ci-perf, `bd67936f` devenv fix, `3295031a` this plan doc,
  `699a2e4e` instruction regen, `3050f894` materialize).

Consequence for this session: `0222a0eb` was built + verified on the stale local
base. Cherry-picked onto origin `af53cf63` (`#433`) it applies cleanly but the
test then fails (`fromJSON` empty input — `#433` no longer writes
`home.file.".kiro/hooks/…"`). **The `file` co-location mechanism itself is sound
and composes with `#433`.** The plan's original recipe (base on **origin**) was
correct; the `d8` deviation to the local tip was the mistake.

## DECISIONS (resolved this session)

- **`oi-namespace` → per-CLI + shared lib** (`d5`): keep `ai.claude.hooks` /
  `ai.kiro.hooks` distinct, share the lowering lib. Operator filed a plan-local
  follow-up (`oi-namespace-unify-later`) to revisit unifying once main-body work
  drains.
- **`oi-colocation` → per-record `file`/group key** (`d6`): same-`file` records
  lower into one Kiro envelope; flat + mergeable; mirrors Claude event-keying.
  Envelope option rejected. **Implemented in u1.**
- **`oi-telemetry-design` → lowering wrapper → JSONL, OFF by default /
  test-only** (`d7`): a test instrument to exercise hook-fire, NOT general
  telemetry enablement (operator has separate larger telemetry plans). Scopes
  P2.
- `d8` (base = local tip) — **WRONG, superseded by `d9`** (base must be origin;
  local is stale).
- `d10` — operator chose to **WAIT** for the session-#1 (factory) session to
  reconcile local↔origin rather than rebase-now or reconcile-now.

## WHAT LANDED THIS SESSION (u1)

Commit `0222a0eb` "feat(kiro-cli): co-locate typed hook records into shared
envelopes":

- `packages/kiro-cli/lib/mkKiro.nix`: new per-record **`file`** option on
  `kiroHookRecord` (Nix-side grouping key, **stripped** from emitted JSON).
  Replaced one-record→one-envelope `kiroHookEnvelope` with a grouping lowering
  (`kiroHookObject` + `kiroHookFileKey` + `kiroTypedHookFiles`) that `groupBy`s
  `cfg.hooks` on the effective file-key → one `{version,hooks:[…]}` envelope per
  file. Back-compat: `file = null` → file-key = attr name → byte-identical to
  before. Both backends consume `mkAllHookFiles` → parity by construction.
- `checks/module-eval.nix`: golden `module-kiro-hooks-typed-colocation`. **⚠
  asserts the pre-`#433` `home.file` HM delivery — must be re-pointed at
  `home.activation` on merge.**
- `packages/kiro-cli/docs/kiro-auto-memory.md`: bumped `Last verified` →
  2026-07-21; corrected the stale `ai.kiro.hooks` bullet (typed surface + `file`
  key + autoMemory migration path). **⚠ must be reconciled with `#433`'s version
  of this fragment.**

Verified: **8/8 kiro hook module-eval checks green on the local (stale) base**
(7 as cache hits ⇒ byte-identical back-compat). NOT yet verified against `#433`.

## RECONCILIATION (what was already done by session #1 before u1)

Most of the original P1 ("design + skeleton the surface") had **already landed**
on the base: Claude `ai.claude.hooks` per-event map + soft-enum (30 events) +
non-clobber emission; Kiro `ai.kiro.hooks` v3 typed records + soft-enum +
envelope lowering; the `*-extracted.json` sidecars + drift checks. So P1a/P1b
(as originally scoped) were already satisfied; **u1 (the `file` co-location) was
the one genuinely net-new P1 piece** — the enabler for P3 (autoMemory migration
off `hooksJson`) and P4 (retire `hooksJson`).

## PHASES (re-cut against landed reality)

| id     | phase                                                | status                                                                   |
| ------ | ---------------------------------------------------- | ------------------------------------------------------------------------ |
| **P1** | Typed hook surface (Claude + Kiro)                   | surface pre-landed; **`file` co-location = u1 done/committed** (PR owed) |
| **P2** | Telemetry hook-fire test wrapper (off by default)    | pending; overlaps session #3                                             |
| **P3** | Migrate autoMemory onto typed `file`-grouped records | pending; unblocked by u1                                                 |
| **P4** | Retire the `hooksJson` bridge                        | pending; nixos-config repin is HITL                                      |

## OPEN ITEMS (current — full text in `state.json.open_items`)

- `oi-base-divergence` **[DEFERRED:await-factory-reconcile]** — local is 9 PRs
  behind origin; operator waiting on session #1 to reconcile. **The gating
  item.**
- `oi-namespace-unify-later` **[NEEDS-EVIDENCE, pinned]** — revisit unifying
  Claude+Kiro option shapes once main-body work drains.
- `oi-regen-instructions` **[DEFERRED:reconcile-at-integration]** — generated
  instruction files stale vs the fragment source; no CI drift-gate; regen once
  after the unify.
- `oi-full-hookset` [DEFAULT], `oi-probe-gate` [HITL@P2] — unchanged.
- `oi-namespace` / `oi-colocation` / `oi-telemetry-design` — RESOLVED (see
  DECISIONS).

## RESUME / MERGE INSTRUCTIONS

1. Read `state.json` (authoritative) + `journal.ndjson` at the state root above.
2. **Prerequisite:** local↔origin reconciled by session #1 (`oi-base-divergence`
   cleared).
3. Rebase `0222a0eb` onto the reconciled integration base (origin
   `refactor/ai-factory-architecture`, which has `#433`).
4. **Adapt the golden** `module-kiro-hooks-typed-colocation` to `#433`'s
   `home.activation` HM delivery (assert the activation-script content,
   mirroring how `#433` verifies HM hooks — see the existing `module-kiro-*`
   tests on the `#433` base). Reconcile the `kiro-auto-memory.md` fragment with
   `#433`'s version.
5. Re-verify the kiro hook checks single-job
   (`nix build --max-jobs 1 .#checks.<sys>.module-kiro-*`).
6. Open the squash PR into `refactor/ai-factory-architecture`; then
   `oi-regen-instructions`.

## CONSTRAINTS (also in `state.json.ecosystem.execution_constraints`)

- **OOM / no parallel fan-out:** single `nix build --max-jobs 1` only; **never**
  `nix flake check`; cap subagents ≤10 (openmemory MCP per-subagent OOMs the
  host).
- **Co-occupied tree:** isolate work in a worktree; never touch another
  session's uncommitted files.
- **Commit/push only when the operator asks.** nixos-config + live switches are
  HITL.
- **Forge:** `gh pr create` hook-blocked → github-mcp `create_pull_request`;
  squash-only; thread reply/resolve + merge via `GH_ALLOW=1 gh api`.
