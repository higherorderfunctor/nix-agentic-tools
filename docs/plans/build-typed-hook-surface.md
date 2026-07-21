# Build the done-right typed hook option surface (B2)

> **Living plan** (dev-living-workflow, FULL tier, CLI mode). This doc is the human-readable
> face; the **authoritative machine state is out-of-repo** at
> `${XDG_STATE_HOME:-~/.local/state}/living-workflows/nix-agentic-tools/typed-hook-surface/`
> (`state.json` + `journal.ndjson`). This doc is **committed to the working branch** by operator
> direction (overriding the untracked default — see open-item `oi-plan-doc-untracked`); the machine
> state stays out-of-repo regardless.
>
> **living_doc_baseline:** `v8-onyx-moor-rowan`
> (master: `.claude/skills/dev-living-workflow/references/living-plan-bootstrap.md`).
> The general protocol lives in the master and the harness beside it — this plan **references**
> them (DRY-by-reference) and carries only plan-specific state. Read them, don't restate them.

## NORTH STAR

The typed hook **option surface is the PRODUCT** — a complete, correct interface exposing ALL
hooks across BOTH ecosystems (Claude Code + Kiro CLI), so different memory systems can be wired
in to **eval/compare** and telemetry can be wired in to **measure hook effectiveness**. Options
are designed **RIGHT on their own merits**; implementations (the autoMemory pilot, other memory
systems, telemetry) **map onto** the options — never the reverse. `hooksJson` is a surgical
bridge shaped to the autoMemory pilot; it is **not** the destination and gets retired.

Provenance: continues the typed-hooks thread landed in PRs #418 (typed Kiro hooks) + #433
(real-file delivery, tui/v3 parity, captured fixture). See memory `project_typed_hooks_assessment`
(§14 backlog B2/B3) and `docs/plans/typed-hooks-across-clis-assessment.md` §8 (design) + §14.

## CURRENT POSITION

- **Phase:** P1 — Design + skeleton the done-right typed hook surface
- **Class:** `hitl_opening` — WAIT for the operator to answer the P1 opening HITL batch before
  surface design begins.
- **Next action:** operator answers `oi-colocation`, `oi-telemetry-design`, `oi-namespace`
  (batched below), then P1 design/skeleton work starts in an isolated worktree.

## RESUME (every session)

Follow the master's **EMBEDDED SESSION BOOTSTRAP** (`living-plan-bootstrap.md`). Plan-specific
coordinates:

1. **State root** (out-of-repo, survives worktree teardown):
   `${XDG_STATE_HOME:-~/.local/state}/living-workflows/nix-agentic-tools/typed-hook-surface/`.
   Read `state.json` (authoritative) + `journal.ndjson`. `current_position.next_action` is the
   steer; `open_items` is the live register.
2. **Warm start:** position = the open phase's earliest not-done work; first commit any orphaned
   status-flip (in the phase's worktree — never the co-occupied main checkout).
3. Load only the working set: this plan + the relevant phase, plus `state.schema.json` and the
   master. Do **not** load the changelog/backlog-rules on a run.
4. Act by `current_position.class`: `hitl_opening`/`phase_boundary` → present the register at a
   high level and WAIT; `mid_batch` → state position in one line and resume.
5. Validate `state.json` against the schema after each mutation:
   `check-jsonschema --schemafile .claude/skills/dev-living-workflow/references/state.schema.json <state.json>`.

## PHASES (greedy scheduler — highest fan-out first)

| id     | phase                                                               | runnable increment                                                                                          | est |
| ------ | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | --- |
| **P1** | Design + skeleton the done-right typed hook surface (Claude + Kiro) | typed options accept the FULL hook set + lower + compose, proven by a module-eval golden that consumes them | 2–3 |
| **P2** | Telemetry hook-fire channel wired through the surface               | a hook fires → a telemetry record is written, as a hermetic contract test extending the tier1b harness      | 1–2 |
| **P3** | Migrate the autoMemory pilot onto the typed surface                 | autoMemory works via typed records (output may change); goldens updated                                     | 1   |
| **P4** | Retire the `hooksJson` bridge + migrate remaining consumers         | `hooksJson` removed/deprecated, all checks green; nixos-config repin is HITL                                | 1   |

**Hard constraint (every phase):** the increment is exercised through the ACTUAL delivery
mechanism (HM activation + devenv enterShell), not a locally-assembled stand-in. A phase declared
done against a test harness records which config/path it proved and asserts that is the shipping
path.

## OPEN-ITEMS REGISTER

Every entry carries its **structural reason** (why it holds its disposition). Full text in
`state.json.open_items`; headers here.

**P1 opening HITL batch (answer these to start P1):**

- `oi-colocation` **[HITL@P1]** — co-location key shape: a `group`/file-key field on each typed
  record **vs** a distinct envelope option packing N records into one Kiro file. _Why HITL:_ the
  surface must express multi-record-per-file without `hooksJson`; turns on option-ergonomics intent.
- `oi-telemetry-design` **[HITL@P1]** — telemetry hook-fire channel design (wrapper→JSONL under
  XDG? shared prepended telemetry hook? opt-in per-record flag?). _Why HITL:_ high fan-out; shapes
  every record's lowering and P2.
- `oi-namespace` **[HITL@P1]** — unify Claude+Kiro under one option shape **vs** keep per-CLI
  `ai.claude.hooks` / `ai.kiro.hooks` with a shared lowering lib. _Why HITL:_ cross-ecosystem
  design intent; affects every consumer + the drift sidecars.

**Held / default (agent-owned unless flagged):**

- `oi-full-hookset` **[DEFAULT:extend-existing-extracted-sidecars, revisable]** — source soft-enums
  from the COMPLETE documented set (Claude 30 / Kiro 7+5) via the drift-checked `*-extracted.json`
  sidecars. _Why default:_ mechanism exists; revisable if the surface changes the sidecar shape.
- `oi-probe-gate` **[HITL@P2]** — do Q2 (Manual/`/remember` didn't fire) + Q3 (Claude subagent
  per-tool) need a live probe before telemetry locks? _Why HITL:_ telemetry over a dead trigger is
  noise; needs a spoon-fed operator-run probe.
- `oi-plan-doc-untracked` **[RESOLVED:committed-to-working-branch]** — operator directed committing
  this plan to the cwd branch (overriding the untracked default). _Structural reason:_ operator
  override of a revisable default; the out-of-repo `state.json` stays authoritative either way.

## PLAN-SPECIFIC STANDING RULES & CONSTRAINTS

Carry the master's **STANDING RULES** verbatim (field-report laundering, completionist mode,
mechanism creep, source-masking, degradation-by-shrug, prove-against-reality, sanctioned-deviation
shapes). Plan-specific constraints (also in `state.json.ecosystem.execution_constraints`):

- **OOM / no parallel fan-out:** single `nix build --max-jobs 1` only; **never** `nix flake check`
  (parallel); cap subagents ≤10 with a bounded queue (openmemory MCP per-subagent OOMs the host).
- **Co-occupied main tree:** the main checkout is occupied by a parallel factory session. Work each
  phase in an **isolated worktree** under `../nix-agentic-tools-worktrees/` based on
  `origin/refactor/ai-factory-architecture`; commit there; integrate by **squash PR**. Never touch
  the factory session's uncommitted files in the main checkout.
- **nixos-config + live switches are HITL.** Commit/push **only when the operator asks.**
- **Forge quirks:** `gh pr create` is hook-blocked → github-mcp `create_pull_request`; thread
  resolve/reply + merge → `GH_ALLOW=1 gh api` (MCP PAT 403s); repo is **squash-only**.

## GIT WORKFLOW (binding)

Phase = branch = worktree = review sitting. At P<n> implementation start: create a worktree +
`feat/<slug>` branch off `origin/refactor/ai-factory-architecture`. Commit often (Conventional
Commits, lowercase-verb subject; unit id in body). Final status-flip commits atomically with its
work. Integrate by squash PR into `refactor/ai-factory-architecture`; address review (fix or
reject-with-comment + resolve thread) before merge. Restore lost content from git, never memory.

## COLD-START SEED

Complete initial state is in `state.json` (position P1/`hitl_opening`; phases P1–P4; the 6
open-items; budget unit=`units`, soft_close_pct=0.7). Derived from the sections above; the live
state file is authoritative after init.
