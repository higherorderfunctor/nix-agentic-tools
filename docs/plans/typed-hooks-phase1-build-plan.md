# Typed Hooks — Phase-1 build plan (Track B)

> **⚠ SUPERSEDED (2026-07-21) by `build-typed-hook-surface.md`** — kept for
> provenance only. This is the 2026-07-20 predecessor build plan; its gate
> framing below (P1a start-here / P1b factory-gated / P1c probe-blocked) is
> **STALE**: the factory session has since landed the emission fix and the typed
> surface, so P1a/P1b were largely already done. For current, reconciled state
> see `build-typed-hook-surface.md` (esp. its `⚑ CROSS-SESSION MERGE CONTEXT`);
> the deep design is in `typed-hooks-across-clis-assessment.md`.

> Branch `refactor/ai-factory-architecture`. Plan-of-record for the **autonomous
> Phase-1** track chosen 2026-07-20. Parent:
> `typed-hooks-across-clis-assessment.md` (§8 architecture, §9 verification, §10
> drift, §13 decisions, §14 phasing). Decisions **D1–D10 confirmed as
> recommended**. Do **not** commit code until asked; `nixos-config` + the live
> probe are HITL; no parallel subagent fan-out (single `--max-jobs 1`
> builds/evals).

## 0. Dependency reality (why Track B is not a clean monolith)

Two hard dependencies constrain the order:

1. **Typed options lower into the Claude emission path that the factory session
   is redefining.** The typed `ai.claude.hooks` event-map (D8) must emit into
   `files.".claude/settings.json".json.hooks`
   - `.claude/hooks/<name>` — which is _exactly_ the fix in
     `handoff-devenv-hooks-bug.md` STEP 2 (it replaces the `mkClaude.nix:539`
     `//`-clobber). That fix is **handed to the ai.\* factory session**, and its
     STEP 3 touches `checks/module-eval.nix` where my T1 tests live. ⇒ **P1b
     depends on that fix landing** (or on an explicit decision to absorb it here
     — but the handoff says it is not ours).
2. **The probe (Track A) was deferred.** So D3's exact Kiro trigger set (Q2) and
   the Tier-1b graduation (Q4 captured fixtures) are **not yet available**.
   P1b's Kiro typing degrades to the binary-confirmed subset; P1c cannot
   complete at all.

Result: Phase 1 splits into one **immediately-executable** slice (P1a) and two
**gated** slices (P1b factory-gated + probe-degraded; P1c probe-blocked).

## P1a — Provenance & drift machinery ▸ START HERE (collision-free, no probe)

Touches only NEW files + additive edits to files **outside** the factory
session's declared hook territory (`mkClaude.nix` emission, `module-eval.nix`
hook stubs). Load-bearing-first order:

### P1a.1 — Promote the draft sidecars (SSOT + provenance store) — §10

- **Create** `packages/claude-code/hook-events.json` from
  `docs/plans/typed-hooks-research/hooks-surface-draft/claude-code.hooks-surface.json`.
- **Create** `packages/kiro-cli/hook-triggers.json` (new `packages/kiro-cli/`
  sibling) from the Kiro draft.
- **Reconcile `typedEvents`** to the set we _actually_ type in Phase 1. The
  Claude draft currently lists the **classic-9**, but D2 Phase-1 wires only the
  **PoC-5** (`PreToolUse, PostToolUse, UserPromptSubmit, SessionStart, Stop`).
  The D10 **blocking** drift guard must fire only on removal of an event we
  truly wire → set `typedEvents = PoC-5` now; keep `binaryEventVocabulary`
  (full 30) as the advisory diff target; record `curatedTarget = classic-9` as a
  forward marker (Phase 2 grows `typedEvents` → classic-9).
- **Field markers stay event-scoped** (§18 conclusion): the sidecar carries NO
  `schemaFieldMarkers` for stdin/stdout field names (binary-grep unsafe for
  fields). Correct as drafted.
- Provenance block already stamped (`binaryVersion 2.1.214 / 2.13.0`, `docsUrl`,
  `lastVerifiedDate`).

### P1a.2 — Advisory binary-grep drift check (hermetic, in `nix flake check`) — §10, D10

- **Create** `checks/hooks-drift.nix`, adapting
  `checks/model-staleness-claude.nix` (advisory tail)
  - the committed `docs/plans/typed-hooks-research/drift-extract.prototype.sh`
    extraction logic.
  * Claude anchor: `grep -aoE '"PreToolUse"(,"[A-Za-z]+")+'` on the store
    binary.
  * Kiro anchor: **PascalCase** trigger literals (avoid the `ChatTriggerType`
    camelCase telemetry red herring — the drift-extract prototype already
    anchors correctly).
  * **Advisory** on new/unknown tokens (warn, never fail) per D10 additions arm.
- **Union** at `flake.nix:216` (append ` // hooksDriftCheck` to the checks
  aggregate; add the `import ./checks/hooks-drift.nix` binding above `in`).
  Additive one-liner; low collision.
- Verify: `nix flake check` (or a single
  `nix build .#checks.<sys>.hooks-drift --max-jobs 1`) is green on current
  binaries; a fixture with an injected removed token still passes (advisory) and
  emits the warning text.

### P1a.3 — `extraExtract` sidecar regen on version bump — §10

- **Extend** `overlays/claude-code.nix:69` `extraExtract` to regenerate
  `hook-events.json` (event-enum grep + provenance restamp) in the same update
  PR as the existing `models.json` regen, via `mkClaudeExtract`
  (`overlays/lib.nix:119`).
- **Add** an `extraExtract` to `overlays/kiro-cli.nix` (has **none** today) that
  regenerates `hook-triggers.json` + restamps provenance.
- **Register** both in `config/update-matrix.nix` so a bump can't silently drift
  the enum.
- Verify: dry-run the extract shell against the pinned store binary; diff output
  == committed sidecar (byte-parity), single `--max-jobs 1`.

**P1a exit criteria:** sidecars committed as SSOT; advisory drift check green +
unioned; regen wired so the next version bump refreshes the fingerprint. No
dependency on the factory session or the probe.

## P1b — Typed option surface ⚠ GATED (factory emission fix + D3 probe)

Do **not** start until the factory session's `handoff-devenv-hooks-bug.md` fix
has landed (defines the lowering target) **or** you explicitly decide to absorb
that fix here (re-decision — the handoff scopes it elsewhere).

### P1b.1 — Claude event-map typing (D2 PoC-5, D8 migration) — `mkClaude.nix`

- Repurpose `ai.claude.hooks` (`mkClaude.nix:249`) → **keyed-by-event map**
  `attrsOf (listOf { matcher?; hooks = listOf handler; })`, handler a tagged
  union over `type ∈ {command,http,prompt,agent,mcp_tool}`, event names a **soft
  enum** read from `hook-events.json` (never hard-coded), freeform JSON tail for
  un-modeled events (D4).
- Move script bodies → `ai.claude.hookScripts` / keep `hooksDir` (D8). Keep
  freeform `settings.hooks` as a deprecated escape hatch.
- Lower via `mkHookScript` (absolute store path, strict-mode header) into the
  emission target the factory fix establishes. **Collides with handoff STEP 2**
  → coordinate.

### P1b.2 — Kiro record typing (D3) — `mkKiro.nix`

- Type
  `ai.kiro.hooks.<name> = { trigger; matcher?; action{type,command|prompt}; timeout?; enabled?; description? }`
  (`mkKiro.nix:315`), `trigger` a **soft enum** from `hook-triggers.json`.
- **Probe-degraded:** type only the binary-confirmed subset
  `{SessionStart, Stop, PreToolUse, PostToolUse, UserPromptSubmit, Manual}`;
  leave the 5 documented-but-absent triggers soft-enum-only until Q2 settles.
  Keep the raw `ai.kiro.hooksJson` escape hatch so **autoMemory keeps working
  byte-identical** (D9).

### P1b.3 — T1 emission golden tests — `checks/module-eval.nix`

- Prove each typed event → correct `settings.json.hooks` / envelope JSON on
  **both** HM + devenv (byte-parity), reusing the
  `kiro-auto-memory-hm-devenv-parity` pattern. **Collides with handoff STEP 3**
  (which also adds a devenv hook golden) → coordinate so the devenv golden isn't
  double-authored; un-stub `claude.code` (`module-eval.nix:112`) as that fix
  requires.

## P1c — Tier-1b graduation ⛔ BLOCKED (needs Track A probe)

Promote `tier1b-prototype/` → `checks/hook-contract-tests.nix` (union at
`flake.nix:216`). Its README graduation gate needs **both**: (#1) real emitted
hook scripts from P1b, and (#2) the Tier-2 probe having replaced each fixture's
documented `stdin` with a captured payload (`provenance: captured@<ver>`). #2 is
impossible without Track A. **Deferred until the probe runs.**

## Gate & coordination summary

| Slice               | Starts now? | Blocks        | Shared-file touches                                               | Collision w/ factory session         |
| ------------------- | ----------- | ------------- | ----------------------------------------------------------------- | ------------------------------------ |
| P1a.1 sidecars      | ✅          | —             | new `packages/*/hook-*.json`                                      | none                                 |
| P1a.2 drift check   | ✅          | —             | new `checks/`, `flake.nix:216` append                             | none                                 |
| P1a.3 extract regen | ✅          | —             | `overlays/{claude-code,kiro-cli}.nix`, `config/update-matrix.nix` | none (overlays ≠ its hook territory) |
| P1b.1 Claude typing | ❌          | factory fix   | `mkClaude.nix` emission                                           | **direct** (handoff STEP 2)          |
| P1b.2 Kiro typing   | ⚠           | Q2 (degraded) | `mkKiro.nix`                                                      | low (fix is Claude-only)             |
| P1b.3 T1 goldens    | ❌          | factory fix   | `checks/module-eval.nix`                                          | **direct** (handoff STEP 3)          |
| P1c tier1b graduate | ⛔          | Track A probe | `checks/`, `flake.nix`                                            | none, but probe-blocked              |

## Open items for the user

1. **ai.\* factory-session status?** Active / done-and-landed / never-picked-up.
   Decides whether P1b can follow P1a, and whether the emission fix is coming or
   must be re-decided.
2. **Start with P1a?** It is the whole collision-free, probe-free surface — real
   §10 value delivered now while P1b's prerequisite resolves.

## Guardrails (restated)

- No parallel subagent fan-out (OOMs — openmemory MCP per subagent); single
  `--max-jobs 1` only.
- `nixos-config` + live probe are HITL. No commit/push until asked.
- Do not modify/move/`git clean` the factory session's files; keep P1a additive.
