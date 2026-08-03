# Kiro-CLI auto-memory

> **What this document is.** A _living_ design + execution plan for giving
> `kiro-cli` persistent cross-session "auto memory" comparable to Claude Code's
> `.remember/` tiered buffer + native `MEMORY.md` systems. Unlike the one-shot
> autonomous plans in this directory, this doc is **maintained across
> sessions**: each session performs the current **Next task**, records what it
> learned, rewrites the **Bootstrap prompt** to point at whatever is next, and
> commits — so the git history of this file _is_ the project history.
>
> **Per-session protocol (do this every time):**
>
> 1. Read this whole file first (it is self-contained; you should not need to
>    re-run research).
> 2. Do the **Next task** (see the section of that name).
> 3. Append results to the **Session log** and **Decisions log**. These are
>    **append-only** — mark items done, never delete prior items.
> 4. Update **Target architecture** / **Open empirical questions** if findings
>    changed them.
> 5. Rewrite the **Bootstrap prompt** to describe the _new_ Next task, and keep
>    its **Operating protocol** section current with any how-to-function change
>    (the Bootstrap is the single source of truth for how to run a session).
> 6. Commit with a Conventional Commit (`docs(plans): …`). Run
>    `treefmt docs/plans/kiro-cli-auto-memory.md` before committing.

---

> **Implementation map (STAGE 6, S15).** The end-to-end current-code map now
> lives in the package-scoped architecture fragment
> `packages/kiro-cli/docs/kiro-auto-memory.md` (scope-globbed; fans out to
> `.claude/rules/kiro-cli.md`, `.github/instructions/kiro-cli.instructions.md`,
> `.kiro/steering/kiro-cli.md`). THIS plan stays the design + decision + session
> record; the fragment is the code map and carries the mandatory
> `Last verified:` maintenance marker. Keep them in sync.

---

## Bootstrap prompt (read first)

```
⚠ PLAN CLOSED (end of session 17, 2026-07-14). The kiro-cli auto-memory
workstream is DONE — the in-repo code + the nixos-config consumer are complete
and the loop is proven end-to-end in a nix/devenv workspace. Do NOT reopen or
"resume" this plan. The remaining memory work is a NEW living plan the USER
drafts via the living workflow (see STATE(17) + "Backlog — next rolling plan" +
memory `automemory-rolling-plan`). This file is kept as the closed design +
decision + session record; read STATE(17) first for the close-out + next steps.

(Historical resume instructions, retained for provenance:)
Resume the kiro-cli auto-memory work. FIRST read
docs/plans/kiro-cli-auto-memory.md in full — it is self-contained (design,
decisions, session history, AND the operating protocol below). You should not
need external context or to re-run research.

── OPERATING PROTOCOL (how to run a session; KEEP THIS SECTION UPDATED) ──
This bootstrap is the single source of truth for BOTH how to function and the
current state/next task. Any change to how sessions should operate goes HERE, in
the same commit — future sessions inherit it by reading the doc.
- Peer stance: act as a same-level, adversarial peer. Push back, challenge
  assumptions, disagree openly. Do not defer or rubber-stamp.
- Classification confidence: if you cannot classify a directive or decision with
  high confidence, STOP and ask — do not guess.
- Session scoping (short sessions to manage context): at session START pick ONE
  bounded chunk (an implementation / testing / research / discussion round)
  sized to finish in a single session, and budget for any research or discussion
  it needs. State the plan before diving in; don't over-reach past it.
- Implementation order is AGENT-owned — do NOT ask the user "which chunk next?".
  Sequence the backlog as an agile vertical slice: each stage must leave the
  system in a WORKING, shippable state; among eligible stages pick the most
  load-bearing (unblocks/enables the most, or turns dead code into a running
  loop); pull a correctness bug forward only when it would otherwise ship in the
  first working slice built on that component; hardening nothing yet depends on
  comes after there is a loop to harden; prefer self-contained work over work
  needing an external daemon/Postgres/HITL. The frozen stage order lives in the
  current STATE block. (User directive, S8. Does NOT override asking on
  source/hash/build-tool choices or the nixos-config / test HITL gates.)
- Session END: (1) update the plan — Session log, Decisions log, Target
  architecture, Open questions, and THIS bootstrap (state + next task + any
  how-to-function change) — treefmt, then commit (docs(plans): …). (2) PUSH the
  branch to origin — STANDING AUTHORIZATION, do NOT ask the user to push (user
  directive S12; keep the refactor branch backed up on origin,
  [[feedback_push_backups]]). (3) ALSO emit a paste-able handoff prompt in chat
  for the next round.
- Handoff prompt = convenience pointer to resume + a catch for LATE tuning that
  arrives after you have committed; the doc/bootstrap stays the single source of
  truth and the handoff must not contradict it.
- Logs are append-only (mark done, never delete). Keep experiments in scratch;
  never touch the real repo tree or ~/.kiro global config; on an auth wall STOP
  and report (do not authenticate). `--trust-all-tools` is gone under v3 →
  permissions.yaml.
- USER-run tests (the HITL live-TUI test) are GUIDED SYNCHRONOUSLY, never handed
  off async: when the code path that needs one is ready, walk the user through it
  one spoon-fed step at a time and wait at each step (busy/ADHD user —
  [[feedback_hitl_walk_through_live]]). It stays a checkpoint; you never invoke it
  for them ([[feedback_nixos_config_hitl]]). BEFORE handing over the interactive
  baton, DE-RISK everything non-interactive yourself (OOM-safe): verify the generated
  config, and SMOKE the pipeline against real data (e.g. drive the hook wrapper with a
  real transcript on stdin) so the user's TUI time tests ONLY the irreducible
  closed-binary behavior — this both saves their time and catches version-drift (S13:
  re-validated the D23 parser on a kiro-cli minor bump before the live run).

── STATE (end of session 17) — PLAN CLOSED ──
Session 17 (2026-07-13/14) executed the consumer flip (item A) AND uncovered + fixed the delivery reality for
kiro v3. **This living plan is now CLOSED.** The in-repo code + the nixos-config consumer are done and the
auto-memory loop is proven end-to-end in a nix/devenv workspace. Do NOT reopen this plan — remaining work is a
SEPARATE, NEW memory living plan the USER drafts via the living workflow (see "Backlog — next rolling plan"
below + memory `automemory-rolling-plan`).
- **Consumer flip (A) — DONE (nixos-config).** Fresh `automemory` Postgres DB running in PARALLEL with the
  legacy `openmemory` (the MODEL keeps legacy for now); native-HTTP `openmemory-mcp` fleet daemon → automemory
  (dev-no-auth, tier=deep, vecDim=768, ollama). kiro `ai.kiro.hooks`/`.rules` spliced; `omEnv` derived from the
  daemon's `settingsToEnv` via `lib.ai.loadServer` (Q11 lockstep — verified by a lib-only eval). NO re-key /
  migration: the 9af0f95 base schema has `project_id` natively on a FRESH DB (verified in db.js — its runtime
  PG migrator is dead code AND short-circuits on user_id, so in-place migration was NOT viable; a fresh DB
  sidesteps it). Backend add→query round-trip verified against automemory.
- **Flake race-fix — DONE + PUSHED (58536a4c).** The 9af0f95 daemon creates the pgvector table `v vector`
  (no dimension) then builds an HNSW index → pgvector rejects it ("column does not have dimensions"); a
  persistent daemon can win the create-race vs the ai-pg bootstrap, leaving an undimensioned table that breaks
  ALL openmemory writes. Fixed in the `openmemory-mcp` MODULE (not the consumer): a new `settingsToPreStart`
  service-schema hook → the fleet systemd `ExecStartPre` pre-creates the dimensioned
  `openmemory_vectors(v vector(<vecDim>), … project_id)` before the daemon inits. Proven reproducibly by
  dropping automemory + re-activating (zero manual steps). (D34)
- **THE BIG FINDING — kiro v3 hooks are WORKSPACE-local + must be REAL files. (D35)** `/hooks` showed 0 for
  the global HM install. Kiro v3 discovers hooks ONLY under the launch cwd's `.kiro/hooks/` — never global
  `~/.kiro/hooks/` (kirodotdev/Kiro #5440/#7737/#9075; only steering + skills load globally) — AND its
  `read_dir` scan SKIPS store symlinks. S13 "passed" only because its harness used PROJECT-LOCAL REAL files —
  the global HM path was never actually exercised. So global HM `ai.kiro.hooks` was doubly wrong (global +
  symlink); the devenv path (project-local) was right on location, wrong on symlinks. See memory
  `kiro-v3-hooks-workspace-local`.
- **devenv hook delivery fix — DONE + committed local (e73972a5; PUSH via sync/rebase). (D36)** `mkKiro.nix`
  now writes devenv kiro hooks as REAL files via `enterShell`
  (`install -m 0644 <writeText> .kiro/hooks/<name>.json`), not devenv `files.*` symlinks. Steering/agents stay
  symlinks (they load fine). module-eval updated (`enterShell` stub + adapted parity/writes-hooks tests,
  GREEN); fragment + tracked router regenerated. Hooks now LOAD live in this repo (user confirmed `/hooks`
  lists the 4). Test-wired via a gitignored `devenv.local.nix` (host-specific `omEnv` → automemory).
- **Process lesson recorded:** never hand-patch runtime/DB state to mask a broken declarative activation — fix
  in nix (reusable module), then re-activate from the FRESH/broken state to prove reproducibility (memory
  `no-manual-masking-activation`; the pgvector race was first mis-fixed by a manual DROP+recreate).
NEXT (a NEW memory living plan — USER drafts it via the living workflow; do NOT reopen this plan):
1. Per-workspace hook delivery for NON-NIX repos (e.g. `~/Documents/work/gdp`) — a direnv/manual symlink→COPY
   into each repo's `.kiro/hooks/`; the devenv real-file fix only covers nix/devenv projects.
2. Live firing test in this repo (take turns → verify `~/.kiro-memory/<repo>/now.md` + the automemory archive
   grow) — the loop is wired; only the in-session observation remains.
3. The memory-integration backlog (module ergonomics `ai.autoMemory`, retire legacy openmemory + give the
   model the new DB, encourage-LLM-to-use-memory, louder/observable, Graphiti+neo4j, drop `remember`, mimic
   Claude's `/dream`) — see "Backlog — next rolling plan" below + memory `automemory-rolling-plan`.

── STATE (end of session 16) ──
Session 16 (2026-07-13) landed OPTION B (D33) — Manual `/remember` now FORCES an immediate distill. This
closes the one correctness gap the STAGE-6 review surfaced; the workstream's in-repo code + docs are COMPLETE.
Self-serve; all green; PUSHED. The user picked B over the HITL consumer flip (A), which stays the sole
remaining item (user-gated).
- **Deliverable:** `mkWrapper` in `packages/kiro-cli/lib/autoMemory.nix` gains a `force` flag; the Manual
  wrapper alone sets `force=true` → bakes `export KIRO_MEMORY_FORCE=1` (AFTER the baked env, so it wins over a
  consumer's `env`), which the distiller's `main()` already honors (`KIRO_MEMORY_FORCE==="1"` → `force:true` →
  `shouldDistill` bypassed). Manual is now exactly the Stop wrapper `+ force`; Stop stays debounced. So
  `/remember` is a deterministic immediate distill (D3 intent), and the steering anchor's "force an immediate
  distill" line is no longer over-promising. Also aligned the Manual `mkHook` description with the header
  comment ("…forces an immediate distill past the debounce" — a review consistency nit).
- **TDD:** new module-eval check `module-kiro-auto-memory-manual-forces` (realizes the manual + stop wrappers,
  greps manual has `export KIRO_MEMORY_FORCE=1` / stop has none), proven RED→GREEN OOM-safely
  (getFlake-inputs-only targeted `nix-build` of the single check); cat'd the realized manual wrapper to confirm
  placement.
- **Fragment maintained in the SAME commit** (repo doctrine): `packages/kiro-cli/docs/kiro-auto-memory.md` —
  data-flow row (Manual → force-distill/D33), a "Manual forces" env-contract bullet, the FORCE knob note,
  invariant #10, Known-gap bullet removed, `manual-forces` added to the test enumeration. Routers regenerated
  via `devenv tasks run --mode before generate:instructions` (only the tracked
  `.github/instructions/kiro-cli.instructions.md` is committed; `.claude/rules` + `.kiro/steering` are
  gitignored mirrors).
- **Adversarial review (4-lens: correctness / test-adversarial / doc-fidelity / DRY-convention + per-finding
  refute; 8 agents): 1 CONFIRMED / 3 refuted.** The confirmed (doc-fidelity): the minted D33 dangled in THIS
  plan (the fragment header names it the D# SSOT) and STATE(15) mislabeled the fix "(D32)" — FIXED here (this
  D33 entry + the "(D32)"→"(D33)" correction). 3 refuted: an ordering-test nice-to-have (guards a nonsensical
  `KIRO_MEMORY_FORCE=0` config; sibling tests are presence-only); "plan-doc live status still says B un-landed"
  (correctly out-of-scope for the feat commit — handled in THIS docs(plans) update: Status + STATE + D33 + S16);
  the Manual `description` "fallback" wording (cosmetic — fixed anyway, self-introduced asymmetry).
- **Commits:** `feat(kiro-cli): force immediate distill on Manual /remember` (autoMemory.nix + module-eval +
  fragment + tracked router) + `docs(plans): record S16 — manual-force landed (D33)` (this doc). Pushed.
NEXT = only (A) the nixos-config CONSUMER FLIP remains (HITL, user-gated — do NOT self-start): openmemory
stdio→http daemon, Postgres re-key `anonymous`→`dev-no-auth`, feed `autoMemory.nix`'s `omEnv` +
`omPgPasswordFile` from the daemon's `settingsToEnv` (Q10/Q11). The in-repo code + docs are complete; there is
no self-serve work left. OOM: bounded evalModules / drv-build / getFlake-inputs only.

── STATE (end of session 15) ──
Session 15 (2026-07-13) landed STAGE 6 — the D26 comprehensive implementation doc. This is the FINAL stage
of the workstream; ALL CODE (stages 1–5b) AND the doc are now done. Self-serve; all green; PUSHED.
- **Deliverable:** `packages/kiro-cli/docs/kiro-auto-memory.md` — a package-scoped architecture fragment
  (location=package, D26) explaining the WHOLE auto-memory system end-to-end for BOTH an LLM revising the
  code AND a human: the auto-READ/auto-WRITE frame; the write distiller pipeline + corrected D23 schema +
  debounce OR-gate + tail-flush watermark (D24) + buffer O_EXCL lock (D23b) + the ordering guarantees; the
  hybrid recall + `BackendQuery` seam (D31); worktree-shared `project_id` (D19/D20); the v3 hook set + the
  HOME/`KIRO_MEMORY_*`/`OM_*` env contract + secret-never-baked (D31); the three role bins + bun-wrapper
  idiom (D25) + the `openmemory-mem` 3rd-bin seam (D29); the module surface (`ai.kiro.hooks`/`.rules`, B5
  parity); an invariants checklist; not-done/tuning; and debugging entry points. `Last verified: 2026-07-13`
  + a mandatory-maintenance trigger per the repo's fragment doctrine.
- **Registered** in `dev/generate.nix`: a new `kiro-cli` category in `devFragmentNames` (location=package)
  + `packagePaths` (scoped to `overlays/kiro-memory-distiller.nix` + `packages/kiro-cli/**` +
  `overlays/mcp-servers/openmemory-mem/**`). Fans out to `.claude/rules/kiro-cli.md`, the TRACKED
  `.github/instructions/kiro-cli.instructions.md`, and `.kiro/steering/kiro-cli.md` — all 3 ecosystem
  transforms verified (Copilot comma-`applyTo`, Claude `paths:` list, Kiro `fileMatchPattern:` array).
  Cross-linked from `overlays/README.md` (+ a stale `bun test (58)`→`(80)` fix) and this plan.
- **Adversarial review (4-lens + per-finding refute; 14 agents): 5 CONFIRMED / 5 refuted; all 5 FIXED
  before landing.** Two medium: (i) the pipeline-order summary listed select-then-gate → corrected to
  gate-BEFORE-parse (the cheap pre-parse gate; distill() runs shouldDistill before selectUndistilledTurns);
  (ii) **THE REAL FIND — the Manual `/remember` hook does NOT force.** `manualWrapper` is byte-identical to
  `stopWrapper` and sets no `KIRO_MEMORY_FORCE`, so `/remember` runs the SAME debounced path as `Stop` and
  can silently no-op — contradicting D3 (deterministic immediate distill) + the steering anchor's "force an
  immediate distill" promise. Three low, all fixed: "file-IO-only" (the sync path also forks git per Stop +
  openmemory-mem per turn at a 5 s SIGKILL cap); "every write is temp+rename atomic" (false for archive.md's
  appendFileSync — scoped to the whole-file tiers); "three tiers, only one live read" (recall() does two).
- **Manual-force gap NOT landed this session.** The fix is a 1-line `export KIRO_MEMORY_FORCE=1` in
  `manualWrapper` only (the distiller already honors it), but it is a code change to code the user FROZE
  after 5b and it reshapes the abstraction the doc describes. So STAGE 6 stayed doc-only: the gap is
  documented as a KNOWN GAP in the fragment (honest, not masked — [[feedback_no_masking_fixes]]) and
  SURFACED for the user's decision, per [[feedback_wait_for_review]] + [[feedback_run_decisions_by_user]].
- **De-risk (OOM-safe):** built each `instructions-{copilot,claude,kiro}` derivation individually (lazy
  flake-parts attrs — no heavy overlay/checks eval; RAM held ~15 GB free); verified the generated router
  frontmatter; nothing interactive.
- **FROZEN STAGE ORDER (agent-owned) — ALL DONE:**
    1. D24 tail-loss ✅ (S8)  ·  2. Nix-package the distiller ✅ (S9)  ·  3. v3 hook set + steering anchor ✅
    (S10, D27)  ·  4. D23b buffer lockfile ✅ (S11, D28)  ·  5a. openmemory-mem SDK helper ✅ (S12, D29)  ·
    HITL live-TUI test ✅ (S13, D30)  ·  5b. Read hook + backend wiring ✅ (S14, D31)  ·  6. Comprehensive
    implementation doc ✅ (S15, D32)
NEXT = the workstream's CODE + DOC are COMPLETE. Two items remain, BOTH outside the frozen stage order and
BOTH gated on a USER decision (do NOT self-start): (A) the nixos-config CONSUMER FLIP (HITL) — openmemory
stdio→http daemon, Postgres re-key `anonymous`→`dev-no-auth`, feed `autoMemory.nix`'s `omEnv` +
`omPgPasswordFile` from the daemon's `settingsToEnv` (Q10/Q11). (B) the MANUAL-FORCE 1-line fix (D33) — add
`export KIRO_MEMORY_FORCE=1` to `manualWrapper` so `/remember` actually forces (recommended, but a change to
otherwise-frozen code → user's call). If (B) is approved it is a tiny `feat(kiro-cli)` + a doc touch-up
(drop the Known-gap note + the fragment's data-flow row); if declined, the Known-gap note stays honest. OOM:
bounded evalModules / drv-build / getFlake-inputs only.

── STATE (end of session 14) ──
Session 14 (2026-07-13) landed STAGE 5b — the READ side + the openmemory backend wiring (D31). This is
the FINAL code stage; only the STAGE-6 comprehensive doc and the HITL consumer flip remain. Self-serve;
all green; NOT yet pushed (origin was at 7df7f194 = the S13 tip).
- **The one open design question is resolved: Option C (hybrid recall).** The `UserPromptSubmit` hook's
  stdin `prompt` is EMPTY (D12), so "query openmemory with the user's prompt" is impossible — the query
  is seeded from the distilled buffer, not the prompt. And the distilled `now.md` was, until now, NEVER
  read back into context (the steering anchor is a static store symlink). So the recall hook injects, per
  turn: (1) the live `now.md` tier (the always-available base — works TODAY with the daemon down), PLUS
  (2) a best-effort openmemory archive query seeded by `now.md` (the archive tier — lights up after the
  consumer flip). It degrades gracefully (daemon down ⇒ recent tier alone) and is faithful to the Claude
  `.remember` + openmemory blueprint. The user delegated the call ("pick the best, not the surgical
  route; log tuning paths"); C is the best because it is the deliverable this stage is NAMED for
  (archive-RAG) and is what 5a's `query` subcommand was built for.
- **Landed (code):**
  - `overlays/kiro-memory-distiller/distiller.ts` — a `--read` mode (`mainRead`) as a 3rd role bin
    `kiro-memory-recall`, mirroring `--flush`/`kiro-memory-flush`. New exports: `BackendQuery` (the read
    seam, symmetric with `BackendWrite`), `RecallConfig`, `formatRecall` (pure composer: fenced
    `## Recent working context` + `## Related from project memory`, both bounded), `recall` (orchestrator:
    read now.md → seed → best-effort `backendQuery` → compose), plus `defaultBackendQuery` (shells to
    `openmemory-mem query --project-id <id> --limit <n>`, seed on stdin, best-effort "" on failure —
    symmetric with `defaultBackendWrite`). `project_id` keys BOTH the buffer path and the query scope
    (D19), so the read sees exactly what the write produced.
  - `overlays/kiro-memory-distiller.nix` — the 3rd `kiro-memory-recall` (`--read`) bin + install smoke;
    stays backend-agnostic (openmemory-mem is bound by the wiring layer, not here → a future markdown-only
    backend reuses it).
  - `packages/kiro-cli/lib/autoMemory.nix` — a 4th `UserPromptSubmit → recall` hook entry (a 4th entry in
    the SAME one-file envelope, per D30 — no split); puts `openmemory-mem` (a bin of
    `pkgs.ai.mcpServers.openmemory-mcp`) on EVERY wrapper's PATH (write paths call `add`, read calls
    `query`); threads `OM_*` connection env via a baked `omEnv` attrset; runtime-cats the Postgres
    password from `omPgPasswordFile` (a runtime STRING path — NEVER baked into the world-readable store,
    `[[feedback_mimic_sops_secrets]]`); asserts `OM_PG_PASSWORD` is not in the merged `bakedEnv`
    (`env // omEnv`). Defaults (`omEnv={}`, `omPgPasswordFile=null`) ⇒ backend best-effort-fails ⇒ file
    buffer alone (the current host state until the flip).
- **TDD + adversarial review (like every prior stage).** 11 new bun tests (80 total, TDD red→green) + 2
  new module-eval checks (a build-and-grep of the recall AND a write-path wrapper for PATH/omEnv/runtime-
  password; a two-route `rejects-baked-password`). 4-lens review (correctness / nix-wiring / contract-
  fidelity / test-adversarial) + per-finding refute (16 agents): **0 CONFIRMED, 9 PARTIAL, 3 REFUTED.**
  8 partials FIXED before landing: the medium **password-guard gap** (two lenses — the guard covered only
  `omEnv`, but `bakedEnv = env // omEnv`, so a secret via `env` still baked → broadened to `bakedEnv`);
  `formatRecall`'s true char bound for `maxChars < marker` + codepoint-safe truncation (the exact 5a
  fmt_matches surrogate fix); `archiveLimit` integer-coercion (a fractional `KIRO_MEMORY_RECALL_LIMIT`
  silently killed the archive tier); a write-wrapper grep; header/ordering test assertions. The 1 deferred
  partial (P3, per-turn synchronous `openmemory-mem` spawn latency) is a post-flip TUNING path (not
  reachable in the 5b default), logged below.
- **De-risk (non-interactive, OOM-safe — getFlake INPUTS only + targeted `nix-build`):** built the
  distiller overlay (80 bun tests in checkPhase + the 3-bin install smoke) + all 6 module-eval checks, then
  drove the **built** `kiro-memory-recall` bin on real data twice — (a) degraded (no `openmemory-mem` on
  PATH ⇒ recent tier only) and (b) archive path with a fake `openmemory-mem` on PATH, confirming it invokes
  `query --project-id <slug> --limit 3` with the `now.md` seed on stdin and injects BOTH tiers.
- **TUNING PATHS (logged for the expected tuning rounds; NONE block the flip):**
  1. P3 — the recall hook spawns `openmemory-mem` synchronously per prompt (5 s timeout). Sub-perceptible
     + symmetric with the landed write path, and inert in the 5b default (no backend). Post-flip, if the
     per-turn Postgres query is felt, add a debounce/short-TTL cache or an async fork. MEASURE first (B4).
  2. Seed strategy — currently the whole `now.md`; alternatives: last turn only, a synthetic keyword query.
  3. Recent-tier depth — `now.md` only today; could add a bounded `recent.md` tail (more continuity vs more
     per-turn context budget). The composer is structured so this is a localized change.
  4. Injection size — `KIRO_MEMORY_RECALL_MAX_CHARS` (4000) / `KIRO_MEMORY_RECALL_LIMIT` (3) are operator
     knobs; tune once real archive hits are observed post-flip.
  5. Buffer/archive dedup — archive hits (seeded by now.md) may echo the recent tier; a dedup pass would
     cut redundancy (non-trivial fuzzy match — deferred).
- **FROZEN STAGE ORDER (agent-owned):**
    1. D24 tail-loss  ✅ DONE (S8)
    2. Nix-package the distiller  ✅ DONE (S9)
    3. v3 hook set + `--flush` SessionStart + steering anchor  ✅ DONE (S10, D27)
    4. D23b buffer lockfile (O_EXCL mutex)  ✅ DONE (S11, D28)
    5a. openmemory-mem SDK helper binary  ✅ DONE (S12, D29)
    HITL live-TUI test  ✅ DONE (S13, D30 — passed)
    5b. Read hook + openmemory-mem→PATH + `OM_*`/password env (autoMemory.nix)  ✅ DONE (S14, D31)
    6. Comprehensive implementation doc (FINAL) — the D26 backlog fragment.  ← NEXT
NEXT = STAGE 6: the D26 comprehensive implementation doc (a package-scoped architecture fragment,
`packages/kiro-cli/docs/kiro-auto-memory.md`, registered in `dev/generate.nix` `devFragmentNames.kiro-cli`,
scope-globbed to `packages/kiro-cli/**` + `overlays/kiro-memory-distiller.nix`; run `devenv tasks run
--mode before generate:instructions` after). It explains the WHOLE system end-to-end for BOTH an LLM
revising the code and a human — the read/write tiers, the distiller pipeline + schema (D23), the v3 hook
set + the HOME/`KIRO_MEMORY_*`/`OM_*` env contract, the two→three role bins + packaging idiom (D25), the
recall read side + `BackendQuery` seam (D31), the module surface (`ai.kiro.hooks`/`.rules`, B5 parity), and
the load-bearing invariants (worktree-shared project_id D19/D20, debounce OR-gate + tail-flush D24, buffer
lock D23b, secret-never-baked D31). Now safe to write: stages 3–5b have stopped reshaping the abstraction.
The nixos-config consumer flip (openmemory stdio→http daemon, Postgres re-key, full `OM_*` from the daemon's
settingsToEnv, Q10/Q11) stays HITL and is a SEPARATE track from STAGE 6. OOM: bounded evalModules /
drv-build / getFlake-inputs only.

── STATE (end of session 13) ──
Session 13 (2026-07-13) ran THE HITL LIVE-TUI TEST (D30) — the user-run trusted-TUI checkpoint deferred
since S3, guided synchronously. **ALL THREE CHECKS PASSED on kiro-cli 2.12.0** (a bump from the 2.11.1
of S1–S12; the run doubles as re-validation). This satisfies D27's LIVE-TEST CHECKPOINT — the last
closed-binary unknown gating the consumer flip — and settles the load-bearing question STAGE 5b rode on.
No production code changed; the plan + a one-line harness-hint fix are self-contained. NOT yet pushed.
- **The decisive result — one file fires three hooks (NO split needed):** `/hooks` in the live trusted
  TUI listed all three from the single `.kiro/hooks/kiro-memory.json` envelope — `kiro-memory-distill`
  (Stop), `kiro-memory-flush` (SessionStart), `kiro-memory-remember` (Manual). STAGE 5b therefore adds
  its UserPromptSubmit read hook as a **4th entry in the same envelope**, not a per-hook file split.
- **Write loop proven end-to-end on the live session:** after quitting, the scratch `.state` file was
  keyed on the LIVE session id (`sess_f3248b29…`) — proving kiro fired the Stop hook AND delivered the
  `{session_id,cwd}` stdin — and `now.md` grew 0→320 B with the correct distilled turn (Ask + answer +
  `_tools: read_file_`). Turn 2 was correctly cooldown-skipped (first Stop distilled at `lastRunMs=0` ⇒
  `cooledDown`; turn 2 within 90 s + under the 12-line threshold): the D24 OR-gate + D8 debounce seen
  live. Per Q6, quit added no Stop. Steering `inclusion: always` injects: the model quoted the anchor's
  title line ("# Persistent project memory (auto-maintained)") and named the rule.
- **Agent pre-flight (non-interactive, OOM-safe) BEFORE the user's TUI time:** verified the generated
  envelope + all three wrappers (HOME `:?` guard + `KIRO_MEMORY_DIR` scratch redirect + REALIZED
  distiller bins), then drove the stop wrapper as kiro would (`{session_id,cwd}` on stdin, `FORCE=1`)
  against a REAL 2.12.0 `messages.jsonl` → `distilled:2`. So the **D23 parser schema did NOT drift on
  2.12.0** and the whole write pipeline works on real data — narrowing the live test to the irreducible
  closed-binary behaviors. (Method now baked into the OPERATING PROTOCOL's USER-run-tests bullet.)
- **kiro-cli 2.12.0 launch forms (harness hint):** the `chat` subcommand accepts `--tui --v3`
  (`kiro-cli chat --tui --v3`; `chat` also exposes `--agent-engine {v1,v2,v3}`, `--mode
  {default,spec}`, `-a/--trust-all-tools`) — verified live. The **top-level launcher ALSO still
  accepts `--v3`/`--tui`** on 2.12.0 (verified via `--help-all` Options block + a parse-only `--help`
  check), consistent with the 2.8.1 [[project_kiro_v3_engine_mode]] launcher semantics — so the
  harness's original `kiro-cli --v3 --tui` hint was **NOT broken**. Switched the printed hint to the
  `chat` form actually exercised this session (both work); no other harness change.
- **FROZEN STAGE ORDER (agent-owned):**
    1. D24 tail-loss  ✅ DONE (S8)
    2. Nix-package the distiller  ✅ DONE (S9)
    3. v3 hook set + `--flush` SessionStart + steering anchor  ✅ DONE (S10, D27)
    4. D23b buffer lockfile (O_EXCL mutex)  ✅ DONE (S11, D28)
    5a. openmemory-mem SDK helper binary (add/query, project_id)  ✅ DONE (S12, D29)
    HITL live-TUI test (gates the consumer flip; can reshape 5b's wiring)  ✅ DONE (S13, D30 — passed,
        no reshape needed: one file fires three hooks)
    5b. Wire openmemory-mem → hook PATH + UserPromptSubmit archive-RAG read hook + `OM_PG*`/`OM_USER_ID`
        env (autoMemory.nix), as a 4th entry in the existing one-file envelope.  ← NEXT
    6. Comprehensive implementation doc (FINAL) — the D26 backlog fragment, after 5b settles.
NEXT = STAGE 5b: in `packages/kiro-cli/lib/autoMemory.nix`, (i) put `openmemory-mem` on the hook
wrappers' PATH (it ships as the 3rd bin of `pkgs.openmemory-mcp` from D29 — add it via `makeWrapper
--suffix`/`--prefix PATH` or reference it absolutely the way the distiller does git), (ii) add the
deferred **UserPromptSubmit** archive-RAG read hook (query `openmemory-mem query --project-id <id>`,
inject a bounded result to stdout — this is where the B3 interface measurement finally happens: decide
how much to inject), and (iii) thread the `OM_PG*` connection env + `OM_USER_ID` (align to the daemon
tenant `dev-no-auth`, Q10) into the wrapper env. All self-serve/testable at the module-eval + drv-build
level; the nixos-config consumer flip (openmemory stdio→http daemon, Postgres re-key, Q10/Q11) stays
HITL and is NOT part of 5b. OOM: bounded evalModules / drv-build / getFlake-inputs only.

── STATE (end of session 12) ──
Session 12 (2026-07-13) landed STAGE 5a — the `openmemory-mem` SDK helper binary (the backend
`add`/`query` seam, D19/D20), the LAST backend-code piece. Self-contained; the 5b hook wiring +
consumer flip stay ahead. All green: 30 bun tests (TDD), treefmt + cspell clean, OOM-safe build (the
checkPhase runs all 30 tests in the nix sandbox), 4-lens adversarial review + per-finding refute
(0 CONFIRMED, 1 REFUTED, 3 PARTIAL — all 3 actioned). NOT pushed (origin was at 531e5b4 = the S11 tip).
- **Verified the SDK FIRST (rev 9af0f95 source, not memory — "the version you RUN ≠ the source you
  READ"):** `new Memory(user_id?)`; `mem.add(content,{project_id})`; `mem.search(query,{project_id,
  limit})` → rows {id,score,primary_sector,salience,content,…}. The SDK path goes STRAIGHT to Postgres
  (add_hsg_memory/hsg_query), BYPASSING the HTTP serve daemon's tenant layer → Q10's tenant_mismatch
  CANNOT bite the helper (it fires only on the model's HTTP calls). A write with user_id undefined
  defaults to "anonymous"; search applies NO user filter when unset → the helper's own write→read loop
  is self-consistent; `OM_USER_ID` aligns the write user_id to the daemon tenant (`dev-no-auth`) at
  the consumer flip.
- **Landed:** `overlays/mcp-servers/openmemory-mem/openmemory-mem.{ts,test.ts}` — a PURE CLI core
  (parseArgs / formatHits / normalizeRows / runMem) with the Memory SDK as an INJECTED seam
  (`MemoryBackend`); the real backend is built LAZILY (dynamic import of the co-packaged
  `./dist/index.js`, which connects to Postgres on load) only in the `import.meta.main` entry, so the
  bun suite NEVER loads dist/PG (mirrors the distiller's `backendWrite` injection). CLI contract
  matches the distiller's `defaultBackendWrite` byte-for-byte: `openmemory-mem add --project-id <id>`
  + stdin; plus `query --project-id <id> [--limit n]` (stdin = query) for the deferred read hook.
  `formatHits` mirrors openmemory's own `fmt_matches`.
- **Packaged as the 3rd bin of openmemory-mcp** (D20 "from the openmemory package"), NOT a separate
  overlay — shares the exact `dist/` + `node_modules` the daemon runs → SDK/Postgres-schema lockstep
  (Q11). `overlays/mcp-servers/openmemory-mcp.nix`: a `checkPhase` runs the bun suite in-sandbox
  (isolated temp dir so bun ignores the upstream vitest suite); `installPhase` cp's the helper next to
  `dist/` + a 3rd `makeWrapper` bin; an empty-stdin `postInstallCheck` smoke (short-circuits before
  any dist/PG load) via `runHook postInstallCheck`. Repo-local helper src → cache-hit parity holds.
- **Review: 0 CONFIRMED, 1 REFUTED, 3 PARTIAL (all low, all actioned; D29).** REFUTED (empirically, on
  Nix 2.34.4): a claim that interpolating the repo-local `memHelper`/`memTest` path literals pulls the
  WHOLE flake source into the drv context → churn; the verifier proved file-literal interpolation is
  content-addressed (byte-identical to `builtins.path`), so the drv re-hashes ONLY when the helper/test
  bytes change (confirmed live: `wlkk…` → `c3h6…` on the fix). PARTIAL fixes: (1) extracted+exported
  `normalizeRows` (the drift-prone SDK row→Hit projection, previously untested until the consumer flip)
  + 2 unit tests; (2) codepoint-aware `trunc` (a UTF-16 slice split surrogate pairs on astral content →
  lone-surrogate garble; proven old→NOT-well-formed / new→well-formed) + astral + trimEnd-boundary
  tests; (3) `parseArgs` rejects a flag-shaped `--project-id` value (`--project-id --limit` no longer
  silently parses `projectId="--limit"`).
- **5a/5b SPLIT (D29):** STAGE 5 split so the HITL de-risk precedes the HITL-reshapeable wiring. 5a
  (the helper binary) is HITL-INDEPENDENT and shipped now (the user's named NEXT — the backendWrite
  seam). 5b (wire `openmemory-mem` onto the hook PATH + the deferred UserPromptSubmit archive-RAG read
  hook + the `OM_PG*`/`OM_USER_ID` env contract, all in `autoMemory.nix`) is DEFERRED until AFTER the
  HITL — that wiring rides on the one-file-3-hooks model the HITL can reshape.
- **FROZEN STAGE ORDER (agent-owned):**
    1. D24 tail-loss  ✅ DONE (S8)
    2. Nix-package the distiller  ✅ DONE (S9)
    3. v3 hook set + `--flush` SessionStart + steering anchor  ✅ DONE (S10, D27)
    4. D23b buffer lockfile (O_EXCL mutex)  ✅ DONE (S11, D28)
    5a. openmemory-mem SDK helper binary (add/query, project_id)  ✅ DONE (S12, D29)
    5b. Wire openmemory-mem → hook PATH + UserPromptSubmit read hook + `OM_PG*`/`OM_USER_ID` env
        (autoMemory.nix) — GATED on the HITL result.  ← NEXT (do the HITL first)
    6. Comprehensive implementation doc (FINAL) — the D26 backlog fragment, after 5b settles.
NEXT = the HITL live-TUI test (USER-run, GUIDED synchronously — spoon-feed the steps, do NOT hand off
async; [[feedback_hitl_walk_through_live]]), THEN STAGE 5b. Per D27 the HITL can reshape the STAGE-3
one-file-3-hooks wiring the 5b read side rides on, so it precedes 5b. Harness:
`bash dev/scripts/kiro-memory-hitl.sh`. The consumer flip stays HITL (Q10/Q11 gate only the flip).

── STATE (end of session 11) ──
Session 11 (2026-07-13) landed STAGE 4 — the D23b per-project buffer lockfile (D28). Self-serve;
isolated to overlays/kiro-memory-distiller/ (distiller.ts + tests) + a cspell bump. The distiller loop is
now concurrency-safe across sibling worktrees. All green: 67 bun tests (TDD), treefmt + cspell clean,
built OOM-safely (67 tests in the nix checkPhase sandbox), 4-lens adversarial review + per-finding
refute (2 CONFIRMED fixed, 4 PARTIAL adjudicated, 0 survived un-actioned).
- **Landed:** exported `withBufferLock(lockPath, {now?,sleep?,ttlMs?,maxWaitMs?,backoffMs?}, critical)`
  — mkdir; spin (bounded by maxWaitMs on an injectable clock) trying `tryAcquireLock` (writeFile temp
  + `linkSync` → atomic EEXIST-on-collision, the canonical local-fs mutex, no empty-file window);
  break a stale lock (recorded ts > ttlMs old); run `critical` under the lock; release in `finally`;
  propagate a throw after release. `distill()` wraps ONLY the SHARED-buffer RMW
  (loadBuffer→rollTiers→write buffer.json/now.md/recent.md/archive.md) at `<projDir>/.buffer.lock`;
  the per-session `.state/<sid>.json` stays OUTSIDE (not cross-process shared). Sync `Atomics.wait`
  sleep (no event loop — matches the sync distiller, D8/D27). `DistillResult.skipped` gains `"locked"`.
- **Review CONFIRMED + FIXED before landing (D28):**
  (1) MEDIUM data-loss REGRESSION — a locked skip wrote NO `.state`, but `flushSessionTails` discovers
      recoverable sessions ONLY via `.state/*.json`, so a session whose sole/final Stop timed out on
      the lock was invisible to the recovery net → its turns permanently dropped (pre-D23b every first
      Stop wrote `.state`). FIX: the locked skip now writes `.state` with the LOADED (unchanged)
      values — discoverable by flush's `size > lastTranscriptSize` gate, retry semantics intact
      (nothing advanced, no turn marked distilled). Regression-locked by an end-to-end
      lock-skip → drop-lock → SessionStart-flush-rediscovers test.
  (2) LOW test-gap — no test round-tripped withBufferLock's OWN token through the staleness reader (a
      future drop of `ts` → every contended lock reads as infinitely-old → both break-and-enter →
      total mutex defeat, all tests still green). ADDED a self-contention round-trip test + a
      garbage-content-lock break test.
- **Review PARTIAL (adjudicated, all low):** the stale-break/release unlink by PATH with no
  holder-identity check, so a live-but-slow/suspended holder past ttlMs can be broken (not only a
  *dead* one) and a resumed holder can free a successor's lock → a concurrent critical section.
  Bounded to a lost UPDATE (writeAtomic keeps it corruption-free; dropped turns survive in `.state`
  distilled[] + the backend, missing only from the rebuildable file-buffer tier) — squarely inside
  D23b's stated best-effort scope. The overstated doc comment was CORRECTED in place. DECLINED a
  subprocess real-race test (flaky, best-effort, bounded impact); kernel-flock / identity-checked
  break-release noted as future hardening if the residual bites.
- **HITL live-TUI harness is COMMITTED + turnkey (USER-run): `dev/scripts/kiro-memory-hitl.{nix,sh}`.**
  The `.nix` assembles a scratch `.kiro/{hooks,steering}` tree from the REAL generators — autoMemory.nix
  (hooks) + the kiro transformer (steering `inclusion: always`) — so it CANNOT go stale (it always builds
  the current output; reuse it across STAGE 5 / kiro-version bumps). `bash dev/scripts/kiro-memory-hitl.sh`
  builds it OOM-safely (getFlake inputs only), wires a throwaway trusted-TUI git project, and prints the 3
  checks. `home=null` → HOME-guard-only + `KIRO_MEMORY_DIR=/tmp/kiro-mem-hitl` scratch write target
  (nothing lands in ~/.kiro config OR ~/.kiro-memory; kiro still reads its own ~/.kiro/sessions). Run it
  EARLY — it de-risks the loop and gates the consumer flip; if kiro won't fire 3 hooks from one file, split
  to one-file-per-hook (trivial) and fold into D27.
- **FROZEN STAGE ORDER (agent-owned):**
    1. D24 tail-loss  ✅ DONE (S8)
    2. Nix-package the distiller  ✅ DONE (S9)
    3. v3 hook set + `--flush` SessionStart + steering anchor  ✅ DONE (S10, D27)
    4. D23b buffer lockfile (O_EXCL mutex)  ✅ DONE (S11, D28)
    5. openmemory-mem SDK helper (add/query, project_id) — backend enrichment; the file buffer works
       without it; needs the serve daemon + Postgres to integration-test. Also unblocks the deferred
       UserPromptSubmit archive-RAG read channel (D27).  ← NEXT
    6. Comprehensive implementation doc (FINAL) — the D26 backlog fragment, after 5 settles.
NEXT = STAGE 5 (openmemory-mem SDK helper) — the last CODE stage; agent's call next session. Per D27,
run the HITL live-TUI test FIRST (it can reshape the STAGE-3 wiring the read side rides on). The
consumer flip + live-TUI test stay HITL (Q10/Q11 gate only the flip).

── STATE (end of session 10) ──
Session 10 (2026-07-12) landed STAGE 3 — the FIRST end-to-end auto-memory wiring (D27). Self-serve
in nix-agentic-tools; the nixos-config consumer splice + the live trusted-TUI test stay HITL.
- **Landed:** `packages/kiro-cli/lib/autoMemory.nix` — a generator `{lib, pkgs, home?null, env?{},
  timeout?30}: {hooks; rules;}` exported as `lib.ai.apps.kiroAutoMemory`. Produces VALUES for the
  existing `ai.kiro.hooks` (one `kiro-memory.json` `{version,hooks:[Stop,SessionStart,Manual]}`
  envelope) and `ai.kiro.rules` (a `kiro-auto-memory` steering anchor, `paths=null` → `inclusion:
  always`). No new module axis (B5). Bins referenced by absolute store path via
  `getExe' pkgs.ai.kiro-memory-distiller`; wrappers are strict-mode `writeShellScript`.
- **HOME contract hardened (S10 review):** wrappers ALWAYS fail-loud-guard HOME (unset AND empty)
  and bake only a non-empty path — an empty-string `home` can no longer emit `export HOME=''`
  (silent cwd-relative loss). See D27.
- **Sync distiller (D27 refines B3 over D8):** synchronous, not `nohup &` — debounced + file-IO-only
  + sub-second. Revisit at STAGE 5 (network SDK write).
- **Verified OOM-safely:** targeted generator eval + built wrappers (all 3 HOME branches) + 4
  module-eval tests incl. HM↔devenv byte-parity, all via bounded `evalModules` (no flake eval).
  4-lens adversarial review + refute: 2 CONFIRMED (the HOME gap — FIXED), 1 PARTIAL (the D27 label —
  now recorded), 1 REFUTED, 1 clean. cspell/deadnix/statix/treefmt clean.
- **FROZEN STAGE ORDER (agent-owned):**
    1. D24 tail-loss  ✅ DONE (S8)
    2. Nix-package the distiller  ✅ DONE (S9)
    3. v3 hook set + `--flush` SessionStart + steering anchor  ✅ DONE (S10, D27)
    4. D23b buffer lockfile (O_EXCL mutex) — pull now if immediate multi-worktree concurrent loops
       are expected; else it can trail the SDK helper.  ← NEXT
    5. openmemory-mem SDK helper (add/query, project_id) — backend enrichment; the file buffer works
       without it; needs the serve daemon + Postgres to integration-test.
    6. Comprehensive implementation doc (FINAL) — the D26 backlog fragment, after 3–5 settle.
- **HITL live-TUI test — WHEN & HOW (user-run, gates the consumer flip):** run it EARLY — it
  de-risks the load-bearing assumption everything downstream rides on. It does NOT block STAGE 4/5
  CODE, but SHOULD precede the nixos-config consumer flip and ideally the STAGE-5 SDK investment: if
  the one-file-3-hooks model or the stdin-through-`exec "$@"` path is wrong, the wiring changes.
  HOW (keep it in SCRATCH — never the real `~/.kiro`): point a throwaway kiro config's
  `ai.kiro.hooks`/`ai.kiro.rules` at `kiroAutoMemory.{hooks,rules}` (with `home` set), open a
  trusted TUI, run 2–3 turns then quit, and check (a) `/hooks` lists all three, (b)
  `~/.kiro-memory/<project>/{now,recent}.md` grew, (c) the steering anchor shows in context. Report
  back; the next session folds results into D27 + the frozen order (split to one-file-per-hook if
  needed). This is the ONLY remaining unknown for the write loop; the nix wiring is eval-proven.
NEXT = STAGE 4 (D23b buffer lockfile) OR STAGE 5 (SDK helper) — agent's call next session; the
consumer flip + live-TUI test remain HITL (Q10/Q11 gate only the flip).

── STATE (end of session 9) ──
Session 9 (2026-07-12) landed STAGE 2 — nix-packaged the distiller as a derivation.
Self-serve; the distiller is now a buildable/cachix-able flake package but still UNWIRED
(no hook/module consumer yet — that is STAGE 3). All green: the 58 bun tests run IN the nix
sandbox via checkPhase, the targeted build is clean, treefmt + cspell clean, adversarially
reviewed (4-lens workflow + per-finding refute — 0 confirmed defects).
- **Landed:** `overlays/kiro-memory-distiller.nix` — a dependency-free (node: built-ins only,
  so NO buildNpmPackage/npmDepsHash) `ourPkgs.stdenvNoCC.mkDerivation` over
  `overlays/kiro-memory-distiller/distiller.ts`. Mirrors the openmemory-mcp bun-wrapper idiom
  (`makeWrapper ${bun}/bin/bun --add-flags <entry>`), NOT `bun build --compile` (no in-repo
  precedent; bun is already in the closure; a wrapper is smaller + transparent). TWO role bins
  from one drv (like openmemory-mcp/-serve): `kiro-memory-distiller` (Stop/Manual → main()) +
  `kiro-memory-flush` (SessionStart → `distiller.ts --flush` → mainFlush()) — so STAGE 3's hooks
  reference a bare absolute path per role with no arg plumbing. git on the wrapper PATH via
  `--suffix` (ambient-first) because the distiller shells out to `git --git-common-dir` (D19
  project_id); `openmemory-mem` stays best-effort-absent (STAGE 5). checkPhase runs the 58-test
  suite in-sandbox (real fail = build fail, no masking); installCheck pipes `{}` to both bins
  (exit-0 smoke). Registered in `overlays/default.nix` flatDrvs → auto-flattens to
  `.#kiro-memory-distiller` / `pkgs.ai.kiro-memory-distiller` (no flake.nix edit); added to the
  cache-hit-parity allowlist (aiCliPackages) + the `overlays/README.md` index. version="0.1.0"
  (in-repo, no upstream/rev — the first in-repo-source overlay pkg, so NOT in update-matrix, like
  the content pkgs); license=unlicense (repo LICENSE, free → the unfree guard passes it unwrapped).
- **OOM method (reused, works):** validated with a TARGETED `nix-build --expr` importing ONLY this
  overlay + the flake's pinned nixpkgs (`getFlake … .inputs.nixpkgs` — inputs only, NOT outputs),
  so no packages/checks/modules eval → no flake-eval OOM even with a live kiro TUI + opm procs
  running. Built `/nix/store/mkc…-kiro-memory-distiller-0.1.0`; both wrappers exec bun by absolute
  path with git suffixed on PATH.
- **Adversarial review (4-lens + refute; 6 agents): 0 CONFIRMED, 1 PARTIAL, 1 REFUTED.** See D25.
  - PARTIAL (dev/data.nix): the distiller is absent from the user-facing generated-docs SSOT.
    DECIDED intentional — it is internal hook plumbing, never a user-run CLI, consistent with the
    curated ai-cli/overlay tables already omitting claude-code (from overlayPackages) and agnix.
    No structural check enforces data.nix completeness; nothing breaks. No change made.
  - REFUTED (overlay header omits HOME): correctly refuted for the header (HOME is a universal
    inherited var, not a wrapper-baked decision). BUT the real STAGE-3 requirement below is now
    recorded so the next session cannot miss it.
- **STAGE-3 wiring requirement (from the refuted-but-real HOME finding):** the v3 hook `action`
  env MUST export `HOME` — the distiller derives `sessionsDir`/`memoryDir` from it
  (`resolveCliEnv`), and if HOME is stripped it silently writes to a cwd-relative `.kiro-memory`
  (exit 0, memory-loss). It MAY also set the `KIRO_MEMORY_*` overrides
  (SESSIONS_DIR/DIR/MIN_NEW_LINES/COOLDOWN_MS/MAX_NOW/MAX_RECENT/FORCE). Reference the two bins by
  absolute store path via `pkgs.ai.kiro-memory-distiller` (`getExe'`).
- **FROZEN STAGE ORDER (updated; agent-owned per the protocol bullet):**
    1. D24 tail-loss (OR gate + flushSessionTails)  ✅ DONE (S8)
    2. Nix-package the distiller as a derivation  ✅ DONE (S9)
    3. Emit the v3 Stop hook + `--flush` SessionStart hook + steering anchor via ai.kiro.hooks /
       ai.kiro.rules — THE first working end-to-end loop ships here (the load-bearing slice),
       adversarially verified vs the real option surface. OOM: drv-build / lib-only evals only.
       The hook action env MUST export HOME (see above).  ← NEXT
    4. D23b buffer lockfile (O_EXCL mutex around loadBuffer→rollTiers→write) — pull BEFORE stage 3
       if immediate multi-worktree concurrent loops are expected.
    5. openmemory-mem SDK helper (add/query, project_id) — backend enrichment; the file buffer
       already works without it; needs the serve daemon + Postgres to integration-test, so it is
       the last CODE stage.
    6. Comprehensive implementation doc (FINAL) — a package-scoped architecture fragment
       (location=package, `packages/kiro-cli/docs/kiro-auto-memory.md`, registered in
       `dev/generate.nix` `devFragmentNames.kiro-cli`, scope-globbed to `packages/kiro-cli/**` +
       `overlays/kiro-memory-distiller.nix`) that explains the WHOLE auto-memory system end-to-end
       — read/write tiers, the distiller pipeline (parse→select→distill→rollTiers→buffer→backend)
       + schema (D23), the v3 hook wiring + the mandatory HOME/`KIRO_MEMORY_*` env contract, the
       two role bins + packaging idiom (D25), the module surface (`ai.kiro.hooks`/`.rules`, B5
       parity), and the load-bearing invariants (worktree-shared project_id D19/D20, debounce
       OR-gate + tail-flush D24, buffer lock D23b). ONE source → per-ecosystem scoped router files
       for an LLM revising the code AND readable prose for a human; cross-link from
       `overlays/README.md` + a top-level README/docs pointer. LAST by design — documenting a
       moving target violates the repo's own stale-fragment doctrine, so finalize only after
       stages 3–5 stop reshaping the abstraction. (User backlog item, 2026-07-12; D26.)
NEXT = STAGE 3: emit the v3 hook set + steering anchor (Q10/Q11 still gate only the consumer flip;
HITL stays on the nixos-config side).

── STATE (end of session 8) ──
Session 8 (2026-07-12) landed D24 — the deferred tail-loss fix (D23a). Self-serve;
the distiller is still UNWIRED (no nix/module consumer yet), so the change is
isolated to overlays/kiro-memory-distiller/. All green (58 bun tests, TDD), treefmt +
cspell clean, adversarially reviewed (4-lens workflow + per-finding verify — the
watermark defect below was CAUGHT and fixed BEFORE landing).
- **Landed:** shouldDistill debounce gate AND→OR (batch-when-busy / flush-when-quiet
  — this is the actual tail-loss fix); new flushSessionTails() SessionStart scan that
  force-distills prior sessions whose transcript grew past a recorded byte size (new
  DistillState.lastTranscriptSize); CLI `--flush` dispatch + mainFlush(); DRY
  resolveCliEnv/readMeta/transcriptLines helpers. cspell term: unflushed.
- **Review caught + fixed (D24):** the stat-gate never advanced lastTranscriptSize on
  a grown-but-no-new-complete-turn force run → EVERY legacy pre-D24 state file (+ any
  aborted/in-flight tail) would re-read+parse on EVERY SessionStart forever. Fixed by
  advancing ONLY the flush watermark on distill's no-new-turns path (guarded on
  growth; debounce baselines untouched). Efficiency-only, but unbounded → fixed before
  wiring. Deferred-with-reason: flushSessionTails can force-distill a LIVE
  cross-worktree session (same class as the deferred D23b lock; verified NOT new
  data-loss). See D24.
- **IMPLEMENTATION ORDER is now AGENT-owned** (user directive; see the new protocol
  bullet). FROZEN STAGE ORDER for the rest of Checkpoint 2:
    1. D24 tail-loss (OR gate + flushSessionTails)  ✅ DONE (S8)
    2. Nix-package the distiller (+ future helper) as derivations — the artifact the
       hook wiring depends on.  ← NEXT
    3. Emit the v3 Stop hook + `--flush` SessionStart hook + steering anchor via
       ai.kiro.hooks / ai.kiro.rules — THE first working end-to-end loop ships here
       (the load-bearing slice), adversarially verified vs the real option surface.
       OOM: drv-build / lib-only evals only.
    4. D23b buffer lockfile (O_EXCL mutex around loadBuffer→rollTiers→write) — pull
       BEFORE stage 3 if immediate multi-worktree concurrent loops are expected.
    5. openmemory-mem SDK helper (add/query, project_id) — backend enrichment; the
       file buffer already works without it; needs the serve daemon + Postgres to
       integration-test, so it goes last.
NEXT = STAGE 2: nix-package the distiller as a derivation (Q10/Q11 still gate only the
consumer flip; HITL stays on the nixos-config side).

── STATE (end of session 7) ──
Session 7 (2026-07-11) built CHECKPOINT 2, PART 1: the deterministic Stop-hook
DISTILLER CORE, and CORRECTED the messages.jsonl schema the plan had wrong. All
self-serve; committed to nix-agentic-tools (d50fae0), nixos-config untouched.
- **Landed:** `overlays/kiro-memory-distiller/{distiller.ts,distiller.test.ts}` (bun/TS,
  47 TDD tests, treefmt+cspell clean, real-transcript validated). Pure functions:
  parseTranscript, selectUndistilledTurns (execId dedup), deriveProjectId (D19
  worktree-shared slug), shouldDistill (debounce), formatTurnBlock, rollTiers; plus
  distill() + fs/git wrappers + a CLI main() (stdin {session_id,cwd} + env config).
  Language = bun/TS per directive; TS is covered by treefmt (prettier) so the
  earlier "TS untooled" worry is void. cspell terms added: cooldown, sess.
- **SCHEMA CORRECTION (D23):** real messages.jsonl = `{id,payload,timestamp}`,
  discriminator `payload.type` (NOT top-level `.type` as D12/Q7 said). And
  **`promptTurnSummaries` is BILLING data** (`{unit,usage,usedTools}` in
  usage_summary), NOT a semantic summary → the B3/D12 "reuse it as the primary
  distillation" shortcut is DEAD. Distillation derives from user.content +
  assistant Say content instead. `user` has no executionId (positional assoc).
- **Adversarially reviewed** (4-lens workflow + adjudicator, 9 findings). Applied:
  state-before-backend dup-guard, unique atomic temp names, corrupt-buffer
  preservation, backend timeout, readFileSync/main try-catch, session_id
  path-traversal validation, git-ENOENT warn, turn_start prompt-leak fix, usedTools
  dedup. **DEFERRED two review fixes (see D23):** (i) the debounce gate is still AND
  → the LAST turn of a session below threshold is dropped (no v3 SessionEnd hook);
  next session should flip to OR (flush-on-quiet) AND add a SessionStart cross-session
  tail-flush. (ii) concurrent worktree distillers RMW the shared buffer with no lock
  → add a per-project O_EXCL lockfile mutex.
NEXT = the rest of Checkpoint 2: (a) OR-gate + tail-flush + buffer lockfile (the two
deferred review fixes); (b) the `openmemory-mem` SDK helper binary (add/query,
project_id — needs the serve daemon/Postgres to integration-test); (c) nix-package
the distiller (+ helper) as derivations; (d) emit the v3 hook set via ai.kiro.hooks +
steering anchor via ai.kiro.rules, adversarially verified against the real option
surface (OOM: drv-build / lib-only evals only). Q10/Q11 still gate only the consumer flip.

── STATE (end of session 6) ──
Session 6 (2026-07-11) executed CHECKPOINT 1 — the native-HTTP openmemory server
module — and CLOSED the deferred Q9 confirm on OUR actual nix artifact. All
self-serve (scratch daemon + probe, cleaned up; no nixos-config / ~/.kiro touched):
- **Empirical: our built `openmemory-mcp-serve` serves a WORKING `/mcp`.** Realised
  the openmemory-mcp derivation straight from its on-disk `.drv`
  (`nix build <drv>^out`) to skip the flake-eval OOM (a live kiro TUI + ~7 lingering
  `opm mcp` procs were eating RAM); it substituted the exact CI/cachix output
  `nnd6fka…-openmemory-mcp-1.3.3+9af0f95` (consumer-identical). Drove it with a REAL
  MCP SDK client (`StreamableHTTPClientTransport`) + curl under
  `OM_DEV_ALLOW_NO_AUTH=true`: no-auth `initialize`→200, both OAuth well-knowns→404,
  `tools/list`→7 tools INCL. `openmemory_store_project` (absent in 1.3.3) — the
  9af0f95 per-request transport, no 500s. D21's A/B now holds on the real artifact.
- **The gap was narrower than B0 said.** The `services.mcp-servers` fleet ALREADY
  wires openmemory as native-HTTP (in serverNames; `meta.modes.http =
  "openmemory-mcp-serve"`, not "bridge"; generic machinery emits the systemd unit +
  OM_* env + `{type=http; url=…:19758/mcp}` via `mkHttpEntry`). Only the D18 no-auth
  knob was missing.
- **Landed (nix-agentic-tools):** typed `devAllowNoAuth` (`nullOr bool`) →
  http-gated `OM_DEV_ALLOW_NO_AUTH` in `settingsToEnv`
  (packages/openmemory-mcp/modules/mcp-server.nix) + 2 platform-independent
  module-eval tests. Verified pre-land by a lib-only targeted `settingsToEnv` eval +
  a 3-lens adversarial workflow (correctness could not refute the systemd-env +
  mcpConfig-url trace, incl. the escapeShellArg→systemd-EXTRACT_UNQUOTE question).
  See D22 + Session-6 log.
- **Method note (reusable):** this host OOMs on flake eval, but `nix build <drv>^out`
  on a pre-existing on-disk `.drv` builds/substitutes WITHOUT re-evaluating the flake.
NEXT = Checkpoint 2 (v3 hook set + debounced distiller). The user can OPTIONALLY do a
SAFE live daemon smoke on nixos-config first (throwaway store), but the FULL consumer
flip against the real ai-pg Postgres stays gated on Q11 (1.3.3→9af0f95 project_id DB
migration) + Q10 (tenant/user_id guidance).

── STATE (end of session 5) ──
Session 5 (2026-07-11) RESOLVED Q9 — the residual gate — with a CORRECTION the
user's pushback forced (do not conclude from one failed handshake). Findings,
all self-serve (scratch `opm serve` daemon + real MCP SDK client + curl + upstream
source; no real config touched):
- **Native `opm serve` DOES mount `POST /mcp`** and answers a no-auth `initialize`
  (200) under `OM_DEV_ALLOW_NO_AUTH=true`; both OAuth well-knowns 404 — the exact
  fingerprint of the 4 kiro-working http servers (D15). D16/D18 CONFIRMED live.
- **BUT the INSTALLED npx (openmemory-js 1.3.3 = npm `latest`) is BROKEN for real
  HTTP MCP clients:** its `/mcp` uses ONE shared `StreamableHTTPServerTransport`
  (`sessionIdGenerator: undefined`) connected ONCE and reused, so `initialize`
  succeeds (200) then EVERY next request (`notifications/initialized`, `tools/list`)
  500s. A spec client always sends `notifications/initialized`, so it never reaches
  `tools/list`. Reproduced by BOTH the real SDK client AND raw curl.
- **The fix already exists on upstream `main` (rev 9af0f95) — which OUR overlay
  ALREADY PINS.** main creates a FRESH transport+server PER REQUEST (code comment:
  "MCP SDK 1.27 rejects re-initialization on a single transport instance") AND adds
  the `openmemory_store_project` + `project_id` tooling D19/D20 need (1.3.3 has
  NEITHER). A/B repro with the real SDK client+server: shared→FAIL, per-request→PASS.
- **So D16/D17 native daemon is VALIDATED — but the flip is ALSO a version change:**
  the daemon MUST be our nix pkg `openmemory-mcp-serve` (builds rev 9af0f95), NOT
  `npx openmemory-js serve` (=1.3.3, broken `/mcp`). stdio works today only because
  stdio is single-session (the shared-transport bug can't bite it).
- **RAM win CONFIRMED huge:** live = 15 openmemory procs / 1,190 MB (~90 MB per
  `opm mcp` child, from subagent fan-out); one daemon = 86 MB → ~93% / ~1.1 GB saved.
- New residual follow-ups for Part B: Q10 (tenant vs `user_id` under http no-auth)
  and Q11 (1.3.3→9af0f95 DB `project_id`/schema migration). Neither blocks Ckpt 1.
See D21 + Session-5 log. NEXT = Checkpoint 1 (the daemon server module), whose first
step is the deferred empirical confirm: `nix build .#openmemory-mcp` then drive its
built `openmemory-mcp-serve` with a real client (deferred here — this host OOMs on
local eval).

── STATE (end of session 4) ──
Session 4 (2026-07-11) resolved the openmemory TRANSPORT + ISOLATION questions
Part B's archive tier depends on — triggered by a user ask to get openmemory OFF
per-subagent stdio (RAM bomb: each subagent fan-out spawns its own ~100MB
`npx openmemory-js mcp`). Empirically settled (verified live, not doc-trusted):
- **D5 SUPERSEDED (D15):** kiro-cli 2.11.1 ACCEPTS no-auth, non-PRM
  streamable-HTTP MCP — proven live (the user's effect/fetch/gitlab/nixos servers
  are all `type=http` in `~/.kiro/settings/mcp.json`; each 404s both OAuth
  well-knowns and answers a no-auth `POST /mcp` initialize with 200). The
  OAuth/PRM gap in `[[project_mcp_proxy_kiro2_auth_gap]]` was real on kiro 2.0/2.2
  (issue #8151) but NOT on 2.11.1 — that memory is corrected.
- **openmemory `opm serve` (D16)** natively mounts `POST /mcp` (streamable-HTTP,
  stateless, same tool surface as stdio) PLUS the REST API. Fix = a native HTTP
  daemon, no shim/mcp-proxy.
- **Decision (D17/D18):** ONE `openmemory-mcp-serve` systemd daemon, no-auth
  `dev-no-auth` (`OM_DEV_ALLOW_NO_AUTH=true`), 127.0.0.1:PORT, against the SHARED
  ai-pg Postgres; flip kiro/Claude/Copilot's openmemory entry stdio→http → RAM
  bomb solved (one process for all fan-outs). Store is Postgres (OM_PG_*), not the
  default SQLite → no file-contention; openmemory embeddings are ollama/remote
  (no in-process ML) so the ~100MB is Node + pg/ioredis/sqlite3 + aws/google/openai
  SDKs + doc parsers, amortized once in the daemon.
- **Isolation (user decision, D19/D20):** SOFT per-project via `project_id`, keyed
  on the CANONICAL REPO ROOT shared across worktrees
  (`git rev-parse --git-common-dir` → parent dir → slug), so all worktrees of one
  repo SHARE memory; `system_global` tier for cross-cutting. Hooks set project_id
  via the in-process `Memory` SDK (bun→Postgres) because REST `/memory/{add,query}`
  lack project_id (only the SDK/MCP layer has it).
- Part B is now DESIGN-COMPLETE (see "Part B" section). Residual empirical Q9
  (live kiro↔openmemory /mcp connect + per-subagent RSS) gates the transport flip.

Earlier (end of session 3, still valid):
Part A (v3 trusted-TUI hook probe, Q5–Q8) DONE — self-serve reads of a user-run
TUI session against kiro-cli 2.11.1. Results: Q5 v3 standalone `.kiro/hooks/*.json`
LOAD + FIRE + inject exit-0 stdout into context (no trust prompt; `/hooks` listed
all three; SessionStart fires on the FIRST turn, not at welcome). Q6 `Stop` is
PER-TURN (2 prompts → 2 Stops, quit adds none — v3 has NO session-end hook), which
SUPERSEDES D8: the WRITE distiller must DEBOUNCE (revert to F5). Q7 hook stdin is
metadata-only (`{session_id,hook_event_name,cwd}`; UPS `prompt` empty), so the
distiller reads the transcript from
`~/.kiro/sessions/<hash>/<session_id>/messages.jsonl` (typed-event JSONL incl.
kiro's own `promptTurnSummaries`), located by `session_id`. Q8 command hooks run
UNGATED (no prompt, no `~/.kiro/workspace-roots/`) → no trust pre-seed needed; the
real gate is TUI-vs-classic. Read-side (D14): steering persists every turn, UPS
stdout injects per-turn, SessionStart stdout is one-shot (turn 1 only). Earlier
state stands: READ Tier-1 (steering) is the load-bearing, hook-independent
channel on both engines; v2 answered Q1/Q2; two hook systems (v2 embedded
camelCase, v3 standalone PascalCase = the mkKiro.nix target).

── NEXT TASK ──
Part B is DESIGN-COMPLETE in the doc (see the "Part B — implementation plan"
section). NEXT is IMPLEMENTATION, in checkpoints (HITL on the nixos-config side):
(0) **Residual empirical Q9 — ✅ DONE (Session 5).** Native `opm serve` `/mcp` works
with a real MCP client ON OUR PINNED REV (9af0f95); npm `latest` 1.3.3 is broken
(shared-transport). RAM win ~1.1 GB confirmed. See STATE + D21. Consequence for the
flip: it is ALSO a version bump (daemon = our nix pkg, NOT npx) and carries the
`project_id` tooling + a DB schema change (Q11). → proceed to Checkpoint 1.
(1) **nix-agentic-tools — ✅ DONE (Session 6, D22).** The `services.mcp-servers`
fleet ALREADY wired openmemory as native-HTTP (serverNames + `meta.modes.http =
"openmemory-mcp-serve"` + generic systemd-unit / `mkHttpEntry` machinery emitting
`{type=http; url=…:19758/mcp}`); the ONLY missing piece was the D18 no-auth env, now
added as a typed `devAllowNoAuth` → http-gated `OM_DEV_ALLOW_NO_AUTH` (+ 2 module-eval
tests). Our built `openmemory-mcp-serve` empirically drives a real MCP client (D22).
The `openmemory-mem` SDK helper binary is DEFERRED to Checkpoint 2 (it is for the
hooks). → proceed to Checkpoint 2.
(2) **The v3 hook set + distiller:** SessionStart rotate/banner, DEBOUNCED Stop
distiller (dirty-flag + cooldown + line-delta; reads `messages.jsonl` by
session_id; reuses kiro's `promptTurnSummaries`), UserPromptSubmit archive-RAG,
Manual `/remember`. Distiller = a bun SDK script keyed on the worktree-shared repo
root (D19). Emit via `ai.kiro.hooks.<name>` (raw JSON built structurally in-module).
(3) **Steering anchor** via `ai.kiro.rules.<KEY>` (`paths=null` → `inclusion:
always`) + the external `~/.kiro-memory/<repo-slug>/` file buffer (hook-independent
Tier-1, survives daemon-down).
(4) **nixos-config consumer flip (HITL):** openmemory stdio→http, systemd daemon
enable, one-time Postgres re-key `anonymous`→`dev-no-auth`.
Consider a small workflow to adversarially verify the emitted nix wiring against
the real option surface before landing each checkpoint.
```

---

## Backlog — next rolling plan (deferred; do NOT self-start)

> Captured across sessions from user direction; these roll into a NEW rolling
> plan when this workstream is retired. Do not start any of these without an
> explicit go. Mirror of memory `automemory-rolling-plan`.

**Consumer/backend follow-ups (from the S17 consumer flip):**

- **Module ergonomics (DRY).** The consumer currently hand-wires the `omEnv`
  derivation (`loadServer` + `settingsToEnv`) + the `kiroAutoMemory` call + the
  hooks/rules splice. Fold this into a declarative **`ai.autoMemory`** option
  (cross-CLI — NOT kiro-scoped, since Claude joins later) with sane defaults you
  just turn on; HM↔devenv parity + module-eval tests + fragment required.
- **Retire legacy openmemory + give the model the new DB.** Bring openmemory
  back as an MCP server pointed at the fresh `automemory` DB so the MODEL
  reads/writes it too, then drop the legacy `openmemory` stdio entry + old DB.
  Ends the parallel phase.

**Memory-behaviour / integration direction (user, S17):**

- **Encourage the LLM to USE memory** (not only the deterministic hooks): tune
  the system prompt / inject reminder instructions so the model retrieves +
  drafts/updates memory via the hooks, mimicking Claude. Non-deterministic; tune
  as we go.
- **Louder / observable:** surface in-session when the hooks store/retrieve, or
  when the LLM opts to invoke memory ops (like Claude's "retrieving memory" /
  "drafting/update memory" affordances).
- **Swap backend openmemory → Graphiti + neo4j.**
- **Drop the `remember` plugin** (`.remember` only used in this repo; user
  prefers Claude's auto-memory model, which this workstream ports).
- **Hijack Claude's auto-memory to use our harness.**
- **Mimic Claude's `/dream` consolidation cycle.**
- **Session isolation** — [seed, user] isolate memory per session, not only per
  worktree-shared `project_id`; exact semantics (opt-in scope, a session
  sub-namespace under the project scope, or a hard wall vs the shared buffer)
  are for the next plan to define.
- **Per-workspace hook delivery for non-nix repos** — v3 hooks are
  workspace-local real files (D35), and the devenv fix (D36) only covers
  nix/devenv projects; a direnv/manual symlink→copy into each non-nix repo's
  `.kiro/hooks/` is still open.

**Process guardrail reinforced (S17):** never mask a broken declarative
activation with a manual runtime/DB fix — fix it in nix (reusable module), then
re-activate from the fresh/broken state to prove reproducibility. (Memory
`no-manual-masking-activation`.)

**Final (S17):** this plan is DONE after this session and is not rerun. The next
memory living plan is drafted FRESH from the _tuned_ living workflow — i.e.
after the `living-workflow-backlog` (`B01…B24`, including this session's
captures) is groomed and its adopted tunings fold into
`docs/plans/living-workflow/` — pulling in the items above (session isolation,
non-nix hook delivery, module ergonomics, retire legacy, louder/observable,
Graphiti, `/dream`). Do NOT reopen this doc.

## Status

- **Phase:** empirical validation **complete for both engines** — v2 single-turn
  self-serve (S2) + v3 trusted-TUI user-assisted (S3, Q5–Q8). **No blocking
  unknowns remain for the MVP.** Session 4 (2026-07-11) resolved the openmemory
  transport + isolation questions (D15–D20) and made Part B design-complete;
  next is checkpointed implementation. **Session 5 (2026-07-11) resolved Q9:**
  native `opm serve` `/mcp` works with a real client on our pinned rev 9af0f95
  (npm `latest` 1.3.3 is broken — shared-transport); RAM win ~1.1 GB confirmed;
  the transport flip is also a version bump. **Session 6 (2026-07-11) landed
  Checkpoint 1:** the native-HTTP wiring already existed in the
  `services.mcp-servers` fleet; added the typed `devAllowNoAuth` no-auth knob (+
  module-eval tests) and confirmed our built `openmemory-mcp-serve` drives a
  real MCP client (D22). **Session 7 (2026-07-11) built Checkpoint 2 part 1 —
  the distiller core** (bun/TS, 47 TDD tests, committed d50fae0) and CORRECTED
  the messages.jsonl schema (`payload.type` discriminator; `promptTurnSummaries`
  = billing, so the B3/D12 reuse shortcut is dead — D23). **Session 8
  (2026-07-12)** landed D24 — the deferred tail-loss fix (shouldDistill AND→OR
  gate + a SessionStart `flushSessionTails` scan + `--flush` CLI; 58 TDD tests).
  **Session 9 (2026-07-12)** landed STAGE 2 (D25) — nix-packaged the distiller
  as `overlays/kiro-memory-distiller.nix` (dependency-free bun-wrapper, two role
  bins, cache-hit-parity allowlisted). **Session 10 (2026-07-12)** landed STAGE
  3 (D27) — the first end-to-end wiring (`packages/kiro-cli/lib/autoMemory.nix`
  → the v3 Stop/SessionStart/Manual hooks + steering anchor). **Session 11
  (2026-07-13)** landed STAGE 4 (D28) — the D23b per-project buffer lockfile
  (`withBufferLock`), making the distiller loop concurrency-safe across sibling
  worktrees. **Session 12 (2026-07-13)** landed STAGE 5a (D29) — the
  `openmemory-mem` SDK helper binary (`add`/`query` scoped by `project_id`,
  packaged as the 3rd bin of openmemory-mcp; 30 TDD tests; 4-lens review
  0-confirmed/1-refuted/3-partial-fixed), the last backend-code piece. STAGE 5
  was split into 5a (helper, done) / 5b (hook wiring, gated on the HITL).
  **Session 13 (2026-07-13)** ran the HITL live-TUI test (D30) — **all three
  checks PASSED on kiro-cli 2.12.0** (3 hooks from one file, Stop fires +
  delivers stdin + the write loop runs end-to-end, steering `inclusion: always`
  injects); the D23 parser schema did not drift on 2.12.0. This satisfies D27's
  LIVE-TEST CHECKPOINT, so STAGE 5b needs no one-file-per-hook split. **Session
  14 (2026-07-13)** landed STAGE 5b (D31) — the READ side (a
  `--read`/`kiro-memory-recall` hybrid recall hook: live `now.md` tier +
  best-effort openmemory archive query seeded by the buffer, since the UPS
  prompt is empty) + the backend wiring in `autoMemory.nix` (openmemory-mem onto
  every wrapper PATH; `OM_*` via a baked `omEnv`; the PG password runtime-cat
  from `omPgPasswordFile`, never baked; a `bakedEnv` password-guard assert). 11
  new bun tests (80 total, TDD) + 2 module-eval checks; 4-lens review (0
  confirmed / 9 partial — 8 fixed, 1 tuning-path deferred / 3 refuted). This was
  the FINAL code stage. **Session 15 (2026-07-13)** landed STAGE 6 (D32) — the
  D26 comprehensive implementation doc
  (`packages/kiro-cli/docs/kiro-auto-memory.md`, a package-scoped fragment
  registered in `dev/generate.nix` + cross-linked + fanned out to all 3
  ecosystems); 4-lens review 5-confirmed/5-refuted, all fixed; surfaced the
  Manual-`/remember`-does-not-force wiring gap (then documented + deferred to
  the user). **Session 16 (2026-07-13)** landed option B (D33) — Manual
  `/remember` now FORCES (`mkWrapper` `force` flag → `KIRO_MEMORY_FORCE=1` baked
  into the Manual wrapper only; new `manual-forces` module-eval test; the
  fragment's Known-gap note dropped in the same commit; 4-lens review
  1-confirmed [the D33 SSOT registration, fixed here] / 3-refuted). **The
  workstream's in-repo code + docs are now complete;** only the HITL
  nixos-config consumer flip (A, Q10/Q11) remains — user-gated.
- **Branch:** `refactor/ai-factory-architecture`.
- **Installed binary:** `kiro-cli 2.12.0` (S13; was 2.11.1 through S12). On
  2.12.0 BOTH `kiro-cli chat --tui --v3` (the `chat` subcommand, verified live)
  and the launcher form `kiro-cli --v3 --tui` work; `chat` additionally exposes
  `--agent-engine {v1,v2,v3}`, `--mode {default,spec}`, `-a/--trust-all-tools`.
  CLI 3.0/v3 is no longer bannered as Early Access (the welcome screen reads
  "Welcome to Kiro CLI V3!").
- **Blocking unknowns:** none for the MVP. Q1–Q4 (v2) and Q5–Q8 (v3) are all
  answered. The WRITE side is unblocked but **requires a debounced per-turn
  `Stop`** (Q6) whose distiller reads `messages.jsonl` off disk (Q7) — an
  implementation detail, not a blocker. READ Tier-1 (steering) confirmed on both
  engines, hook-independent.

## Goal

Persistent, cross-session memory for `kiro-cli` that works **without relying on
the model choosing to call a tool** — i.e. deterministic, harness-driven, the
way Claude Code's `.remember/` plugin and native project memory already work for
this user. The user has `openmemory` MCP available (already shared into the kiro
tool pool) but reports that system-prompt instructions + openmem alone "never
worked well." The plan explains why and designs around it.

---

## Key findings (session 1 research)

### F0 — Frame it as two problems

Every approach splits into **auto-READ** (memory into context) and
**auto-WRITE** (persisting memory). READ is easy on kiro; **WRITE is the hard
half** (no on-exit hook — see F3).

### F1 — Why sys-prompt + openmem alone fails (and is not tunable)

- MCP **tools are model-controlled by spec**: nothing injects memory unless the
  model _chooses_ to emit a `query`/`store` call.
- A "remember to recall" system-prompt line is a **probabilistic nudge that
  decays as the session grows** — it drifts out of attention exactly when the
  session is long enough to matter, and competes with every other instruction.
- Universal failure pattern: **storage gets solved, injection doesn't** (the
  well-documented "thousands of memories that never surface" problem).
  openmemory's tool descriptions say _what_ each tool does, never _when_.
- **Therefore better prompt tuning cannot fix this.** The fix in every working
  implementation is to move memory onto **deterministic harness injection points
  (hooks/steering)**, "no LLM on the hot path."

### F2 — The Claude blueprint we are porting

Three independent systems run on this user's Claude setup:

| System                     | READ                                                                                | WRITE                                                                                                                                                                                             |
| -------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `remember` plugin (v0.8.3) | `SessionStart` hook cats tiered `.remember/` files (`now→recent→archive`) to stdout | `PostToolUse` hook fires a **background Haiku summarizer** past a ~50-line transcript delta → appends to `now.md`; hourly compaction rolls `now→today→recent→archive`; manual `/remember` handoff |
| Native project memory      | Claude auto-injects `MEMORY.md` _index_; model reads linked fact-files on demand    | model writes fact-files with ordinary tools                                                                                                                                                       |
| `openmemory` MCP           | nothing auto-invokes it                                                             | nothing auto-invokes it                                                                                                                                                                           |

Porting consequences: **`openmemory` is already shared with kiro** (in the
`ai.mcpServers` pool; `mkKiro.nix` references it), so only Systems 1 & 2 need
recreating. The **`PostToolUse`-background-summarizer** pattern is the
write-side template (never touches main-loop latency).

### F3 — The linchpin: kiro's hook surface (verified from the repo)

`packages/kiro-cli/lib/mkKiro.nix` defines the kiro v3 hook triggers:

```
SessionStart · Stop · PreToolUse · PostToolUse · PreTaskExec · PostTaskExec
UserPromptSubmit · PostFileCreate/Save/Delete · Manual
```

- **No `SessionEnd` / on-exit event.** READ ports cleanly (`SessionStart`,
  `UserPromptSubmit`); WRITE has no "summarize once on exit" hook → must use a
  debounced `Stop` or explicit `/remember`.
  - **[S2 correction — this premise was wrong for v3].** The v2 embedded-hook
    enum genuinely has no exit trigger
    (`agentSpawn userPromptSubmit preToolUse postToolUse stop` — see F7). But
    the **kiro.dev v3 hook docs define `Stop` as _"Fires when session ends"_**,
    with a `timeout` (default 60s) the CLI waits on and hook context delivered
    **as JSON on stdin**. So under v3 the session-end hook the plan wanted
    _does_ exist — it is `Stop`. This makes the WRITE side simpler than F5
    assumed (a synchronous distiller in the `Stop` hook, no background/debounce
    needed) **provided v3 `Stop` fires once per session rather than once per
    turn** — the open question is Q6.
- **kiro hooks in the factory are UNTYPED passthrough (greenfield)** —
  `ai.kiro.hooks` writes whatever raw JSON you author (`mkKiro.nix:316-327`); no
  typed `SessionStart` option yet.
- **Whether a `SessionStart` hook's stdout injects into context is NOT
  verifiable from the repo** (the factory just writes the JSON; runtime behavior
  lives in the closed binary). → **Q1**. Do not bet the read side on
  hook-stdout.

### F4 — Read-side design: anchor on steering, bulk-load recent, RAG only the archive

- **Anchor READ on the steering `inclusion: always` channel, not hook-stdout.**
  `ai.rules.<name>` (`paths = null` → `inclusion: always`) / `ai.kiro.context`
  emit `.kiro/steering/*.md` and that injection path **is implemented and
  verifiable in the repo**. A `SessionStart` hook does deterministic
  rotation/refresh of the file _before_ steering loads.
- **Two-tier** (this is the answer to the user's "query surface" concern):
  - **Tier 1 — recent working buffer, bulk-loaded, NO query.** Keep it small
    (~500–2k tokens) so it always fits; inject wholesale via the always-loaded
    steering file. Deterministic, zero retrieval misses, and it **dissolves the
    coreference/follow-up problem** ("do the same for the other file") — the
    referent is already in context, so there is no muddy query to craft. ~80–90%
    of the value.
  - **Tier 2 — deep archive, RAG.** Only here does retrieval earn its cost.
    Query `openmemory` with the **raw prompt** + rely on its internal blend
    (semantic + BM25 + entity + recency/salience) + a **metadata filter on
    repo/recency/type**. `openmemory`/`mem0` already LLM-extract on write and
    blend signals on read — **do not rebuild that.**
  - **LLM query-rewriting (the ollama / `q --no-interactive` idea): defer.**
    Worth it only if the archive gets large _and_ raw-prompt misses are
    _observed_. Even then use the cheapest transform (conversational coreference
    rewrite) via a warm-kept `qwen2.5:1.5b`, gated so procedural prompts skip
    it. **Never** HyDE/multi-query/step-back here (they solve
    open-domain/multi-hop QA we don't have; HyDE adds 25–60% latency for no gain
    on a corpus you wrote yourself).

### F5 — Write-side design (no SessionEnd): don't classify in the shell

Ranked options:

1. **Debounced `Stop` hook → background summarizer** (autonomous auto-write; the
   direct port of Claude's `PostToolUse`+Haiku). `Stop` fires per turn; gate
   with dirty-flag + cooldown + line-delta so it writes at most every N turns,
   and run the distiller in the background off the hot path.
2. **Explicit `/remember` (Manual hook / skill)** — deterministic, user-gated;
   the reliable fallback that needs no exit hook. Pair with #1.
3. **One-turn-delayed capture on `UserPromptSubmit`** — extract durable facts
   from the _previous_ exchange. Works but hacky; only if `Stop` is unreliable.

**Classification ("what to save") is NOT solved in the shell hook.** Either let
`openmemory_store` do it (`mem0`-style `infer=True` LLM fact-extraction on
write) or have a cheap summarizer model emit structured fields (like the
`remember` plugin's `request/investigated/learned/next`). The dumb hook just
ships raw turns to something that distills. Do **not** rely on a steering line
telling the model to store — that is the probabilistic mechanism that already
failed the user.

### F6 — Repo implementation surface + the real blocker

From the config-parity remap (`packages/kiro-cli/…`):

- kiro's HM + devenv modules are **co-located under the package** (not a
  top-level `modules/`). One `mkAiApp` record in `mkKiro.nix` is projected into
  both backends by `lib/ai/app/{hmTransform,devenvTransform}.nix`; options in
  its `options` block appear in both automatically → **parity is largely
  structural-by-construction**. `hm.config` vs `devenv.config` do the
  per-backend on-disk emission (the only hand-written parity risk).
- **HOOKS, STEERING, MCP each already have full HM + devenv + lib emission — no
  new wiring needed on those three axes.**
- **The blocker: no `outOfStoreSymlink` anywhere in the modules.** Every file
  the factory writes is an immutable store symlink (clobbered each rebuild),
  except one HM `jq`-merged `settings/cli.json`. **devenv has no activation
  mechanism at all** (static writes only). So a declaratively-located,
  runtime-writable `~/.kiro/steering/MEMORY.md` that survives
  `home-manager switch` has **no existing mechanism**.
  - **Sidestep (recommended):** keep the actual store **outside nix's immutable
    tree** — `openmemory`'s Postgres for the archive; a plain
    `~/.kiro-memory/{slug}/` dir (or reuse `.remember/` external mode) for the
    tiered buffer. The module emits only (a) the always-loaded steering
    read-file, which the `SessionStart` hook _refreshes from_ the external
    buffer, and (b) the `Stop`/`Manual` write hooks. Dodges the
    `outOfStoreSymlink` gap; keeps HM/devenv parity trivial.
- Secondary parity gaps (only bite if scope grows): trust surfaces
  (`trustedMcpTools`, `permissions.yaml`) are **HM-only**; `cli.json` merge is
  HM-only; hooks/agents are untyped passthrough.
- **kiro-cli 2.0 remote-MCP has an OAuth/PRM auth gap** → keep `openmemory` on
  **stdio**, not HTTP.

### F7 — the empirical binary results (Session 2): TWO hook systems, engine-split

The installed `kiro-cli 2.11.1` ships **both** hook systems, and they behave
differently by engine. Tested in a throwaway scratch repo via
`kiro-cli chat --no-interactive` (self-serve, single-turn) plus the pasted
kiro.dev v3 docs. **Evidence matrix (✓ = fired/injected, ✗ = silent):**

| Mechanism (where it lives)                              | v2 engine (default) | v3 engine (`--v3`, "Kas") |
| ------------------------------------------------------- | :-----------------: | :-----------------------: |
| Steering `inclusion: always` (`.kiro/steering/*.md`)    |          ✓          |             ✓             |
| **Agent-embedded** hooks (`agent.hooks.{agentSpawn,…}`) |     ✓ all fire      |        ✗ none fire        |
| **Standalone** hooks (`.kiro/hooks/*.json`, PascalCase) |     ✗ not read      |       ✗ (see gates)       |

Key facts established:

- **Two hook schemas, and the repo factory targets the _v3_ one (correctly).**
  - **v2 = embedded, camelCase**, enum forced out of the binary's own validator
    (`agent validate` on a bogus trigger): exactly
    `agentSpawn · userPromptSubmit · preToolUse · postToolUse · stop`. Lives in
    the agent JSON under `"hooks": { <trigger>: [ { "command": … } ] }`.
  - **v3 = standalone, PascalCase**, per kiro.dev docs:
    `SessionStart Stop PreToolUse PostToolUse PreTaskExec PostTaskExec UserPromptSubmit PostFileCreate PostFileSave PostFileDelete Manual`
    in `.kiro/hooks/<name>.json`
    (`{version, hooks:[{name, trigger, matcher?, action:{type:"command"|"agent", …}, timeout?, enabled?}]}`).
    This **matches the `mkKiro.nix` schema comment exactly** — the factory's
    kiro-hook emission is aimed at the right v3 target. The docs give the
    2.x→3.0 mapping: `agentSpawn→SessionStart`, `stop→Stop`,
    `userPromptSubmit→UserPromptSubmit`, `pre/postToolUse→Pre/PostToolUse`,
    `fileEdited→PostFileSave`, `fileCreated→PostFileCreate`; **new in v3:**
    `PreTaskExec PostTaskExec PostFileDelete Manual`.
- **v2 answers Q1/Q2 affirmatively.** With an agent carrying embedded
  `agentSpawn`/`userPromptSubmit`/`stop` hooks (run via `--agent memtest`): all
  three fired; `agentSpawn` and `userPromptSubmit` **stdout was injected into
  model context** (sentinels echoed back) → **Q1 = yes**; the `stop` run
  finished in ~8s without hanging and a `nohup … &` child **survived process
  exit** → **Q2 = yes** (non-blocking, background survives). Reproduced across
  repeat runs; `--agent-engine v2` and the no-flag default both fire, proving
  the **engine is the discriminator**.
- **v3 fired NO hooks in the self-serve harness** — neither embedded nor
  standalone. This is explained by **two documented v3 gates**, not by a design
  flaw:
  1. **Classic mode is unsupported for v3.** kiro.dev "Known gaps": _"The legacy
     non-TUI mode (`kiro-cli chat` without the TUI) does not support the v3
     engine. Use the TUI."_ Our `--no-interactive` path spawns an ACP subprocess
     (`spawning ACP server subprocess for non-interactive session agent_engine=Kas`
     in `-vvv` logs) — i.e. exactly the unsupported non-TUI path.
  2. **Workspace trust gating.** v3 loads workspace `.kiro/agents/**` and
     `.kiro/hooks/**` **only if the workspace is trusted** (agent-config docs:
     "loaded only if workspace is trusted"). A fresh scratch dir is untrusted;
     `~/.kiro/workspace-roots/` did not even exist. Trust is granted by an
     interactive first-run TUI prompt (no non-interactive trust subcommand
     exists). Steering still loaded because it is not execution-gated. →
     Therefore **v3 hook firing can only be validated in a trusted TUI**
     (Q5–Q8), which is inherently interactive/multi-turn = user-assisted.
- **`--trust-all-tools` is removed in v3** (→ `permissions.yaml`), so the flag
  is a v2-only no-op under `--v3`. Aligns with the existing
  `[[project_kiro_v3_permissions]]` memory (typed `permissions` →
  `~/.kiro/settings/permissions.yaml`). Hook _command_ subprocesses are
  user-authored and run unconditionally; permissions gate the **agent's** tool
  calls, not hook execution — so a `Stop` hook writing to `~/.kiro-memory/` is
  not permission-gated.
- **READ Tier-1 is the load-bearing, engine-agnostic channel.** Project-local
  `.kiro/steering/mem.md` with `inclusion: always` injected its sentinel on
  **both** v2 and v3, with **no hook involvement**. The plan's D1 anchor holds
  regardless of how the v3 hook question resolves; hooks only _enhance_ READ
  (live-refresh the steering file) and _enable_ WRITE.

---

## Target architecture (MVP)

**Engine assumption:** the user runs **v3** (Kas, TUI). Emit hooks in the **v3
standalone PascalCase** format (`.kiro/hooks/*.json`) — the factory already
targets this. The design degrades gracefully to READ-only if v3 `Stop` turns out
not to fire the way we need (Q6).

1. **READ Tier-1 (confirmed, engine-agnostic — do this first, it is ~80–90% of
   the value):** an always-loaded `steering/MEMORY.md` (via `ai.kiro.context` or
   an `ai.rules` entry with `paths = null` → `inclusion: always`) holding the
   small recent-tier buffer. **Verified injecting on both v2 and v3, every turn,
   with no hook dependency — the durable anchor.** Live-refresh options, now
   with S3-known persistence (D14): a v3 `SessionStart` **command** hook
   rewrites the steering file from `~/.kiro-memory/{slug}/now.md` before load
   (its own exit-0 **stdout injects only into turn 1** — one-shot, so use it to
   rotate the file, not to carry durable content); a `UserPromptSubmit` command
   hook's stdout **injects every turn** (the right channel for per-prompt
   refresh). The `SessionStart` **agent** action type (appends a prompt string,
   no subprocess) is an alternative lightweight one-shot inject.
2. **WRITE (v3-native — S3-CORRECTED; reverts to F5's debounce, supersedes the
   session-end simplification of D8):** a v3 `Stop` **command** hook.
   **Empirically (S3) `Stop` fires PER TURN, not at session end, and its stdin
   is metadata-only** (`{session_id, hook_event_name, cwd}` — NO transcript; the
   UPS `prompt` field is empty in 2.11.1). So the hook must (a) **debounce** —
   dirty-flag + cooldown + line-delta so it distills at most every N turns, not
   every turn — and (b) **read the transcript itself** from
   `~/.kiro/sessions/<workspace-hash>/<session_id>/messages.jsonl` (locate by
   the `session_id` on stdin via a path glob; it is typed-event JSONL — filter
   `type:"user"` / `type:"assistant"` between `turn_start`/`turn_end`). Distill
   to `~/.kiro-memory/{slug}/` + `openmemory_store` (`infer=True`). **Candidate
   shortcut:** kiro already writes `promptTurnSummaries` into `messages.jsonl` —
   evaluate reusing those instead of a bespoke summarizer (Part B). **[S7:
   FALSIFIED — `promptTurnSummaries` is billing data (`usage_summary`), NOT a
   summary; distill from `user.content` + assistant `Say` instead; records are
   `{id,payload,timestamp}` keyed on `payload.type`. See D23.]** Run the
   distiller **in the background** off the turn's hot path (v2 proved a
   `nohup … &` child survives exit, Q2). Keep a `Manual`-trigger `/remember`
   hook as the deterministic override + fallback.
3. **ARCHIVE RECALL:** `openmemory` on **stdio**, queried by a
   `UserPromptSubmit` hook (v3: `UserPromptSubmit` command hook, exit-0 stdout →
   context) with a metadata filter — raw prompt, no rewrite.
4. **Skip** the ollama query-rewriter until a need is measured.
5. **Classification** stays out of the shell hook (F5): the `Stop`/`Manual`
   command ships raw turns to `openmemory_store` (`infer=True`) or a cheap
   summarizer; never a steering line asking the model to store.

Store lives outside the nix-managed tree (F6 sidestep). Parity: rides existing
HOOKS/STEERING/MCP emission; no new module axes required for MVP. **v3 caveat
(S3-corrected):** the real gate is **TUI-vs-classic** — v3 hooks fire only in
the TUI (classic / `--no-interactive` is unsupported for v3), but **workspace
trust did NOT gate hook-command execution** (S3: no trust prompt,
`workspace-roots` never created, hooks ran) — so no trust pre-seed is needed for
the memory hooks. `--trust-all-tools` is gone under v3 (use `permissions.yaml`),
which gates the **agent's own tool calls** — a separate axis from hook-command
execution.

**Session-4 update (supersedes the "openmemory stdio" assumption in §2/§3
above).** openmemory moves to ONE no-auth HTTP `serve` daemon (D15–D18) sharing
the ai-pg Postgres — the MODEL connects via `type=http` `/mcp` (kiro 2.11.1
accepts no-auth HTTP MCP), killing the per-subagent stdio RAM bomb. The
WRITE/READ hooks reach the SAME Postgres via the in-process `Memory` SDK (D20),
scoped by `project_id` = the worktree-shared canonical repo root (D19), with a
`system_global` tier for cross-cutting. See "Part B — implementation plan" for
the full wiring.

---

## End-goal architecture (direction, Session 5 — after the technical limits are mapped)

The MVP/Part B above wires openmemory + hooks + steering directly. The INTENDED
end state (user direction, S5) sits one level up:

- **A custom typed factory setting** (e.g. `ai.kiro.autoMemory` /
  `ai.autoMemory`, fanning out like the rest of `ai.*`) that SYNTHESISES the
  whole auto-memory rig — the steering anchor (B1), the v3 hook set + debounced
  distiller (B3), the external file buffer (B2), and the backend wiring — from
  ONE declarative switch. It is a custom option that **does NOT map 1:1 to a
  file kiro reads**; it OWNS the abstraction and emits the B1–B5 pieces.
- **A pluggable memory backend, expressed as a lambda / small interface.** The
  harness layer (SessionStart rotate, debounced Stop distiller, UPS archive-RAG,
  Manual `/remember`) is backend-AGNOSTIC; only `store` / `query` / `roll`
  differ per backend. Backends are swappable implementations of that interface:
  - `openmemory` (the S4/S5 design: SDK add/query keyed on `project_id`, one
    HTTP daemon for the model) — the first/default backend.
  - a future `markdown` backend (Claude `.remember`-style tiered files only, no
    openmemory) — essentially B2 standalone, for parity with the user's Claude
    setup. This is the FP-composition the user prefers
    ([[feedback_fp_composition]]): parameterise the common hook/steering shape
    once, pass the backend as the lambda that differs. It also means the "which
    store" decisions (D16–D20) are contained to the openmemory backend, not
    baked into the harness.
- **Sequencing:** this synthesis layer comes AFTER the technical limits are
  fully mapped (Q1–Q11) and the openmemory backend + harness are proven
  end-to-end. The current checkpoints build those concrete pieces; the typed
  `autoMemory` option and the backend-interface extraction are the capstone once
  the pieces work.

---

## Open empirical questions (gate the wiring)

These are about the _installed kiro-cli binary's runtime behavior_, which the
repo source cannot answer. **Q1–Q4 were resolved in Session 2** and **Q5–Q8 in
Session 3** (the trusted-TUI probe) — all answered inline below.

- **Q1 — SessionStart stdout injection (READ). ✅ ANSWERED: yes.** On **v2**, an
  `agentSpawn` (=v3 `SessionStart`) **command** hook's stdout was injected into
  model context (sentinel echoed back). v3 docs confirm the same by design
  (`SessionStart` exit-0 STDOUT "added to context"). So hook-stdout _is_ a
  viable live-refresh channel — but see Q5 (does it fire in a v3 TUI at all).
  Steering remains the mandatory, hook-independent base channel either way.
- **Q2 — Stop firing semantics (WRITE). ✅ ANSWERED for v2: yes.** v2 `stop`
  fired, run did not hang (~8s), and a `nohup … &` child survived process exit.
  v3 reframes this: docs say `Stop` fires at **session end**, is **non-blocking
  to the model** but the CLI **waits up to `timeout`**, and delivers context as
  JSON on stdin → prefer a synchronous distiller over a background one. Live v3
  behavior = Q6.
- **Q3 — hook config location & pickup. ✅ ANSWERED.** Steering
  `.kiro/steering/*.md` (`inclusion: always`) loads on **both** engines
  (project-local, scratch repo). Hooks: **v2** picks up the agent-embedded hooks
  of the selected `--agent`; **standalone `.kiro/hooks/*.json` is NOT read by
  v2**; **v3** gates workspace `.kiro/hooks` + `.kiro/agents` behind **workspace
  trust** (Q5).
- **Q4 — trigger inventory. ✅ ANSWERED.** v2 embedded enum (from the binary's
  own validator) =
  `agentSpawn · userPromptSubmit · preToolUse · postToolUse · stop` — no exit
  trigger. v3 standalone set (docs) = 11 triggers incl. **`Stop` = session-end**
  (the exit hook the plan thought was missing) and new
  `PreTaskExec/PostTaskExec/PostFileDelete/Manual`. The `mkKiro.nix` comment's
  PascalCase list matches the v3 docs exactly.

**v3-specific deferrals — ✅ ALL ANSWERED in Session 3 (trusted-TUI probe):**

- **Q5 — Do v3 standalone hooks fire in a trusted TUI? ✅ YES.** All three
  (`SessionStart`, `UserPromptSubmit`, `Stop`) loaded (`/hooks` listed them) and
  fired with **no trust prompt**; each hook's exit-0 **stdout injected into
  context** (the model echoed all three sentinels on turn 1). `SessionStart`
  fires on the **first turn**, not at the welcome screen (loaded ≠ fired). The
  S2 non-interactive silence was the **classic-mode-unsupported** gate, not
  trust.
- **Q6 — v3 `Stop` cardinality. ✅ PER-TURN.** Two prompts produced **two**
  `Stop` fires (end of each turn); quitting added **none**. **v3 has no
  session-end hook** — independently corroborated by the transcript's
  `ContextualHookInvoked` count (5 = 1 SS + 2 UPS + 2 Stop). → the WRITE
  distiller **must debounce** (supersedes D8; see D11).
- **Q7 — hook stdin contract. ✅ METADATA-ONLY.**
  `{session_id, hook_event_name, cwd}`; `UserPromptSubmit` adds an **empty**
  `prompt` field in 2.11.1; **no transcript on stdin**. The transcript is on
  disk at `~/.kiro/sessions/<workspace-hash>/<session_id>/messages.jsonl`
  (typed-event JSONL:
  `user`/`assistant`/`turn_start`/`turn_end`/`steering_inclusion`/
  `ContextualHookInvoked`/`usage_summary`, plus `promptTurnSummaries`). The
  distiller locates it by the `session_id` from stdin (a path glob avoids
  needing the workspace-hash algorithm).
- **Q8 — Trust mechanics. ✅ NOT REQUIRED for hook commands.** No trust prompt
  appeared, `~/.kiro/workspace-roots/` was never created, and every hook ran →
  command-hook execution is **not** workspace-trust-gated in 2.11.1; the real
  gate is TUI-vs-classic. No trust pre-seed is needed for the memory hooks. (The
  agent's own tool calls remain permission-gated via `permissions.yaml` — a
  separate axis from hook-command execution.)

**Session-4 residual (gates the openmemory transport flip, not the MVP):**

- **Q9 — Does kiro 2.11.1 connect to openmemory `serve`'s native `/mcp`, and how
  much RAM does the daemon save? ✅ ANSWERED (Session 5) — with a version
  caveat.** The transport/auth handshake is version-specific:
  - **Auth/mount CONFIRMED live:** `opm serve` mounts `POST /mcp`; no-auth
    `initialize` → 200 under `OM_DEV_ALLOW_NO_AUTH=true`; both OAuth well-knowns
    404 (matches the 4 kiro-working http servers). D16/D18 hold.
  - **Installed npx 1.3.3 (= npm `latest`) `/mcp` is BROKEN for real clients:**
    one shared `StreamableHTTPServerTransport` (`sessionIdGenerator: undefined`)
    reused across requests → `initialize` 200, then
    `notifications/initialized` + `tools/list` both 500. Reproduced by the real
    SDK client AND raw curl. A spec client can't get past `initialize`.
  - **Upstream `main` (rev 9af0f95 — the rev our overlay pins) FIXES it** with a
    fresh transport+server PER REQUEST (+ adds
    `openmemory_store_project`/`project_id`). A/B with the real SDK
    client+server: shared→FAIL, per-request→PASS. So our nix daemon works;
    `npx openmemory-js serve` does not.
  - **RAM win:** live 15 procs / 1,190 MB → 1 daemon / 86 MB (~93% / ~1.1 GB).
  - **Net:** native daemon VIABLE; flip = ALSO a version bump (our pkg, not
    npx). **Deferred confirm — ✅ DONE (Session 6, D22):** realised the
    openmemory-mcp `.drv` directly (`nix build <drv>^out`, skips the flake-eval
    OOM), substituting the cachix CI output
    `nnd6fka…-openmemory-mcp-1.3.3+9af0f95`; a real MCP SDK client + curl drove
    its `openmemory-mcp-serve` under `OM_DEV_ALLOW_NO_AUTH=true` → 200 no-auth
    `initialize`, well-knowns 404, `tools/list` with `openmemory_store_project`,
    no 500s.
- **Q10 — tenant vs `user_id` under HTTP no-auth (9af0f95). ⏳ OPEN (Part B).**
  In 9af0f95, HTTP MCP calls carry a `tenant` from `authenticate_api_request`;
  under `OM_DEV_ALLOW_NO_AUTH=true` that tenant is `dev-no-auth`, and
  `resolve_user_id` THROWS `tenant_mismatch` if the MODEL passes a `user_id` ≠
  tenant. The hooks use the in-process SDK (no tenant → fine, D20), but the
  model's own `openmemory_store`/`_query` calls must OMIT `user_id` (or pass
  `dev-no-auth`) and scope by `project_id` only. Confirm and constrain the
  steering/banner guidance.
- **Q11 — DB migration 1.3.3→9af0f95. ⏳ OPEN (Ckpt 4).** 9af0f95 adds a
  `project_id` column + the `openmemory_store_project` model; the live ai-pg
  store was written by 1.3.3 (no `project_id`). Verify whether `serve`
  auto-migrates the schema on startup or a manual `ALTER TABLE` is needed,
  alongside the D18 `anonymous`→`dev-no-auth` user_id re-key.

---

## Next task: implementation plan (Part B) — Part A ✅ DONE (Session 3)

The self-serve non-interactive probes (S2) and the user-assisted **v3
trusted-TUI hook probe (Part A, Q5–Q8) are both COMPLETE** (see Session 3 +
Decisions D10–D14). The remaining Next task is **Part B: the implementation
plan** (below). Part A's procedure is retained (marked DONE) for provenance.

### Part A — v3 trusted-TUI hook probe ✅ DONE (Session 3) — user ran; agent read results

A ready-to-run **v3 standalone-hook fixture** was staged in Session 2 at the
session scratch repo:

```
<scratchpad>/kiro-hooktest/
  .kiro/steering/mem.md          # inclusion: always, sentinel KIRO_STEER_SENTINEL_a17c
  .kiro/hooks/mem.json           # v3 PascalCase: SessionStart, UserPromptSubmit, Stop
  .kiro/agents/memtest.json      # v2 embedded-hook agent (ignore under v3 default agent)
```

Each hook (a) echoes a distinctive sentinel to stdout
(`KIRO_V3_SS_SENTINEL_11aa` for SessionStart, `KIRO_V3_UPS_SENTINEL_22bb` for
UserPromptSubmit), (b) appends a timestamped line to `v3-fired-<Trigger>.log`,
and (c) captures its **stdin** to `v3-<Trigger>-stdin.json` (`timeout 10 cat`).
If a future session lost the scratch, regenerate it with the Session-2 python
snippet (see Session log for the exact command; the fixture is trivial to
rebuild).

**User steps (interactive TUI — ~2 min):**

1. `cd <scratchpad>/kiro-hooktest`
2. `kiro-cli chat --v3` (TUI). **Accept the workspace-trust prompt** when it
   appears (this is the gate that was blocking the non-interactive runs).
3. Send **two** prompts in the same session, e.g. `first turn` then
   `second turn` — this distinguishes Q6 (per-turn vs per-session).
4. Quit the TUI (this should trigger `Stop` if it is a session-end hook).

**Then the agent reads the side-effect files** (all self-serve, no auth):

- `v3-fired-SessionStart.log` present? → **Q5** (v3 hooks fire in trusted TUI).
- Did `KIRO_V3_SS_SENTINEL_11aa` / `KIRO_V3_UPS_SENTINEL_22bb` appear in the TUI
  transcript? (ask the user, or check session logs) → v3 stdout-injection.
- **Line count of `v3-fired-Stop.log`** (1 = once-per-session; 2 =
  once-per-turn) and of `v3-fired-UserPromptSubmit.log` (expect 2) → **Q6**.
- `cat v3-Stop-stdin.json` / `v3-SessionStart-stdin.json` → **Q7** (the stdin
  JSON contract: does it carry the transcript the distiller needs?).
- `ls ~/.kiro/workspace-roots/` after trust → **Q8** recon (how trust persists;
  read-only, do not write there).

If v3 hooks fire and `Stop` gives a usable session-end + transcript-on-stdin →
the WRITE design in Target architecture §2 is validated as-is. If `Stop` is
per-turn → add debounce. If v3 hooks do **not** fire even trusted → fall back to
READ-only auto-memory (steering, confirmed) + a `Manual` `/remember` hook, and
escalate the v3 Early-Access gap.

**Guardrails (unchanged):** everything stays in the scratch repo; never write to
the real repo tree or `~/.kiro/` config; if a run hits an auth wall, STOP and
report; do not authenticate.

### Part B — implementation plan (DESIGN-COMPLETE, Session 4)

Transport + isolation are resolved (D15–D20). Below is the concrete wiring
against the real `mkKiro.nix` / `ai.kiro.*` surface. Target the v3 standalone
hook format.

#### B0 — openmemory deployment (foundational; fixes the RAM bomb)

- **Daemon.** `pkgs.ai.mcpServers.openmemory-mcp` exposes `openmemory-mcp-serve`
  (`opm serve`). **[S5/D21] Use THIS package (pins rev 9af0f95 — the fixed
  per-request `/mcp` transport + `project_id` tooling). Do NOT use
  `npx openmemory-js serve`: npm `latest` 1.3.3 ships a BROKEN shared-transport
  `/mcp` (initialize 200, then every subsequent request 500s → no real MCP
  client can connect).** Run it as a systemd user service on `127.0.0.1:<PORT>`
  with: `OM_DEV_ALLOW_NO_AUTH=true` (and NODE*ENV unset, no `OM_REQUIRE_AUTH` →
  single `dev-no-auth` tenant, no key — auth.ts), `OM_PORT=<PORT>`, plus the
  SAME
  `OM_PG*_`/`OM*EMBEDDINGS=ollama`/`OM_OLLAMA*_`/`OM_TIER=deep`/`OM_VECTOR_BACKEND=postgres`/`OM_METADATA_BACKEND=postgres`/`OM_VEC_DIM=768`
  the current stdio entry already uses → same ai-pg Postgres store.
- **nix-agentic-tools change (small, DRY).** Add a native-HTTP `openmemory`
  server module to the `services.mcp-servers` fleet (mirrors nixos-mcp's native
  mode; effect/fetch/gitlab are mcp-proxy `bridge` mode — openmemory does NOT
  need the bridge because `serve` is natively HTTP with `POST /mcp`). It emits
  `mcpConfig.mcpServers.openmemory = { type = "http"; url = "http://127.0.0.1:<PORT>/mcp"; }`
  for the consumer to `inherit`, exactly how effect/fetch/gitlab/nixos are
  wired.
- **Consumer flip (nixos-config, HITL).** Replace the raw
  `openmemory = { command = "npx"; args = ["-y" "openmemory-js" "mcp"]; … }`
  stdio entry in `ai.mcpServers` with the inherited http entry. One-time
  Postgres re-key so existing stdio-written rows stay visible under the new
  tenant: `UPDATE memories SET user_id='dev-no-auth' WHERE user_id='anonymous';`
  (repeat for `openmemory_vectors` and `temporal_facts`).
- **RAM result.** kiro (and Claude/Copilot) connect to ONE daemon over HTTP;
  subagent fan-outs no longer spawn per-instance openmemory processes.
- **Guardrail.** Bind `127.0.0.1` only; no-auth is safe because it's localhost
  single-user (the stdio setup had no auth either). Ignore openmemory's "dev
  only" warning — it concerns multi-tenant fail-open, irrelevant at one user.

#### B1 — READ Tier-1: steering anchor (engine-agnostic, hook-independent)

- `ai.kiro.rules.<KEY> = { paths = null; text = <anchor>; }` →
  `<configDir>/steering/<KEY>.md` with `inclusion: always` via `kiroTransformer`
  (verified: mkKiro.nix HM 504–516 / devenv 680–692; transformer
  `paths==null → "always"`). Use a dedicated `ai.kiro.rules` entry, NOT
  `ai.kiro.context` (which writes the flat frontmatter-less AGENTS.md the user
  already fills via `rulesDir`).
- This file is an IMMUTABLE store symlink → it holds a STATIC anchor (frames how
  to use memory, states the current `project_id` convention), NOT live content.
  Live content comes from the hooks (B3), never from mutating this file (F6: no
  `outOfStoreSymlink`; store files are immutable — this is why the SessionStart
  hook cannot "refresh" the steering file, only the buffer it reads).

#### B2 — External file buffer (Tier-1 live, hook-independent)

- `~/.kiro-memory/<repo-slug>/` (now.md → recent.md → archive.md), created at
  runtime by the hooks (`mkdir -p`) → sidesteps the missing `outOfStoreSymlink`
  (F6/D4). Faithful port of Claude's file-only `.remember` tiers; works even if
  the openmemory daemon is down. Keyed by the SAME canonical-repo-root slug as
  `project_id` (B4).

#### B3 — Hooks (v3 standalone `.kiro/hooks/*.json`, raw passthrough)

- Emit via `ai.kiro.hooks.<name>` (`attrsOf (either lines path)` →
  `<configDir>/hooks/<name>.json`; both backends: mkKiro.nix 469–479 / 644–650).
  **DECISION (typed-vs-raw): keep RAW passthrough** for the memory hooks — build
  the JSON structurally in-module with `builtins.toJSON` (type-safe authoring
  without a public typed schema). A typed `ai.kiro.hooks` schema is a separate
  future refactor (the mkKiro.nix greenfield note, 275–298), NOT a blocker.
- `action.command` = ABSOLUTE store path (nix-standards) to a distiller shipped
  from `packages/kiro-cli/` (content-separation: kiro-scoped, not shared lib).
- **Stop hook (WRITE, debounced).** Stop fires per-turn (D11), stdin
  metadata-only (D12). The distiller: (a) debounce via a state file
  (dirty-flag + cooldown + line-delta) → distill at most every N turns; (b)
  locate the transcript by `session_id` glob at
  `~/.kiro/sessions/<hash>/<session_id>/messages.jsonl`; (c) distill — **REUSE
  kiro's own `promptTurnSummaries`** _[S7: FALSIFIED — billing data, not a
  summary; see D23]_ (jq) as the primary distillation (Q7/D12 shortcut), cheap
  summarizer only as fallback; (d) append to the file buffer + roll tiers; (e)
  write to openmemory via the SDK (B4). Run in the BACKGROUND (`nohup … &`;
  survives exit per Q2) off the hot path. _[S10/D27: the BACKGROUND note is
  SUPERSEDED for STAGE 3 — the distiller ships synchronous (debounced +
  file-IO-only + sub-second). Revisit when STAGE 5 adds the network SDK write.
  See D27.]_
- **UserPromptSubmit hook (READ archive-RAG).** Per-turn; exit-0 stdout injects
  (D14). Query openmemory for the raw prompt scoped to `project_id=<repo-slug>`
  (+ `system_global`), echo top hits; also cat the recent file-buffer tier.
  Interface tradeoff (B4): SDK for exact project scoping (slower, per-turn bun
  spawn) vs daemon REST for speed (no project filter → broader results) —
  MEASURE and pick; a keyword/synthetic-mode SDK query may be fast enough.
- **SessionStart hook.** stdout is one-shot (turn-1 only, D14) → rotate/refresh
  the buffer + emit a one-time banner naming the current `project_id` so the
  model can pass it to `openmemory_store_project`/`_query`. Not for durable
  content.
- **Manual `/remember` hook.** Deterministic user-triggered distill+store; the
  reliable fallback.

#### B4 — openmemory access from hooks: the `Memory` SDK, keyed on the worktree-shared repo root

- **project_id derivation (D19).**
  `root="$(dirname "$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)")"`;
  `project_id="$(basename "$root")"` (or a fuller slug to avoid same-basename
  collisions). `--git-common-dir` returns the MAIN repo's `.git` for every
  linked worktree → all worktrees of a repo share one `project_id` (the user's
  requirement). Non-git cwd → a fallback bucket. Same slug keys
  `~/.kiro-memory/<slug>/` (B2).
- **Why the SDK, not REST (D20).** REST `/memory/add` + `/memory/query` have NO
  `project_id` (routes/memory.ts — only tenant/user*id scoping). Only the
  in-process `Memory` SDK (and the MCP tool layer) accept
  `{user_id, project_id}`. So hook writes/reads use a tiny bun script
  `import { Memory }` with
  `OM_PG*\*`env (→ same Postgres):`add(content,{project_id})`/`search(query,{project_id})`. The daemon is the MODEL's frontend; hooks go straight to Postgres via the SDK (same store). Ship an `openmemory-mem`helper binary (SDK add/query) from the openmemory package, or invoke bun with`NODE_PATH`into its`node_modules`.
- **Model-side scoping.** The daemon can't see the client cwd, so the model's
  own `openmemory_store_project`/`_query` calls are best-effort — inject the
  current `project_id` via the SessionStart banner/steering so the model echoes
  it. The DETERMINISTIC loop is the hooks.
- **Scope split.** repo-specific → `project_id=<repo-slug>`; cross-cutting
  (prefs, coding standards) → `openmemory_store` (`system_global`). A project
  query returns its project + `system_global`, never a sibling project
  (test_project_isolation.ts).

#### B5 — HM↔devenv parity

- All factory-emitted parts ride existing fanout: steering (`ai.kiro.rules` —
  both backends), hooks (`ai.kiro.hooks` — both), MCP http entry
  (`ai.mcpServers` — both). No new module axis (F6); parity is
  structural-by-construction. The distiller + `openmemory-mem` helper are
  backend-agnostic packages. The systemd daemon + Postgres re-key are
  HM/nixos-config consumer concerns (a devenv project points at the same daemon
  URL, or degrades to file-buffer-only Tier-1).

#### Residual empirical (Q9) — do FIRST; gates the flip

1. Live-confirm kiro 2.11.1 connects to openmemory `serve`'s native `/mcp`
   (near-certain from the 4 analogues, unconfirmed for openmemory). 2. Measure
   per-subagent openmemory RSS (stdio vs zero-with-daemon) to quantify the
   win. 3. Confirm stateless `/mcp` + `dev-no-auth` end-to-end (`tools/list`
   over http, no auth header).

---

## Decisions log (append-only)

- **D1 (S1):** Read channel anchors on steering `inclusion: always`, **not**
  hook-stdout — the only in-repo-verifiable injection path. (Revisit if Q1=yes.)
- **D2 (S1):** Two-tier read — bulk-load small recent tier (no query) + RAG the
  archive with raw prompt + hybrid + metadata. No LLM query-rewrite in v1.
- **D3 (S1):** Write via debounced `Stop` + explicit `/remember`; classification
  delegated to `openmemory_store` `infer=True` or a cheap summarizer, never to a
  steering instruction.
- **D4 (S1):** Memory store lives **outside** the nix-managed tree to sidestep
  the missing `outOfStoreSymlink`; module emits only the steering read-file +
  the read/write hooks.
- **D5 (S1):** `openmemory` stays on **stdio** (kiro-cli 2.0 remote-MCP OAuth
  gap).

- **D6 (S2):** Installed binary = `kiro-cli 2.11.1`; v3/CLI 3.0 = Early Access.
  **Two hook systems coexist:** v2 embedded camelCase (5 triggers, in the agent
  JSON) and v3 standalone PascalCase (11 triggers, `.kiro/hooks/*.json`). The
  `mkKiro.nix` factory hook schema matches the **v3** target exactly → keep
  emitting v3 standalone hooks; treat v2 embedded as legacy-only.
- **D7 (S2):** READ Tier-1 (steering `inclusion: always`) **confirmed injecting
  on BOTH engines, hook-independent.** It is the load-bearing channel — ship it
  first, standalone of any hook question. Strengthens D1.
- **D8 (S2):** WRITE reframed to a **v3 `Stop` session-end command hook** (hook
  context as JSON on stdin, CLI waits up to `timeout`) — supersedes F5's v2
  debounced-Stop-with-background. Synchronous distiller, no background/debounce,
  **provided `Stop` is once-per-session (Q6)**. `Manual` `/remember` stays as
  override + fallback.
- **D9 (S2):** v3 hook firing is **untestable via non-interactive/headless
  kiro** (classic non-TUI mode unsupported for v3 + workspace-trust gating), so
  it needs a trusted TUI. Packaging consequence: the memory setup must
  handle/document **workspace trust** (Q8); `--trust-all-tools` is gone under v3
  (→ `permissions.yaml`, per `[[project_kiro_v3_permissions]]`).

- **D10 (S3):** v3 standalone `.kiro/hooks/*.json` **load, fire, and inject
  exit-0 stdout into model context** in a trusted TUI — `SessionStart`,
  `UserPromptSubmit`, and `Stop` all fired, the model echoed their sentinels,
  and `/hooks` listed all three. The Session-2 non-interactive silence was the
  **classic-mode-unsupported** gate, not workspace trust. Answers **Q5 = yes**.
- **D11 (S3):** **v3 `Stop` is PER-TURN, not session-end.** Two prompts → two
  `Stop` fires (end of each turn); quitting added none; v3 has **no session-end
  hook at all** (corroborated by the transcript's `ContextualHookInvoked` count
  = 5 = 1 SS + 2 UPS + 2 Stop). This **supersedes D8** — the WRITE distiller
  **must debounce** (dirty-flag + cooldown + line-delta, per F5); it cannot be a
  one-shot synchronous session-end distiller. Answers **Q6 = per-turn**.
- **D12 (S3):** **Hook stdin is metadata-only**
  (`{session_id, hook_event_name, cwd}`; `UserPromptSubmit` adds an empty
  `prompt` in 2.11.1) — no transcript. The distiller reads the transcript from
  `~/.kiro/sessions/<workspace-hash>/<session_id>/messages.jsonl`, located by
  the `session_id` on stdin (path glob — no need to reproduce the hash
  algorithm). `messages.jsonl` is structured typed-event JSONL
  (`user`/`assistant`/`turn_start`/`turn_end`/`steering_inclusion`/
  `ContextualHookInvoked`/`usage_summary`, plus `promptTurnSummaries`). Answers
  **Q7**.
- **D13 (S3):** **Command-hook execution is NOT workspace-trust-gated** in
  2.11.1: no trust prompt, `~/.kiro/workspace-roots/` never created, all hooks
  ran. The memory hooks "just work" with no trust pre-seed — the D9/Q8 packaging
  worry does not bite for hook execution (the agent's own tool calls stay
  permission-gated via `permissions.yaml`, a separate axis). Answers **Q8**.
- **D14 (S3):** Injection **persistence differs by channel** (model-reported,
  turn-2 self-report): steering `inclusion: always` persists **every turn**
  (durable anchor); `UserPromptSubmit` stdout injects **per-turn**;
  `SessionStart` stdout is **one-shot** (turn 1 only). Read-side roles follow:
  steering = durable buffer, UPS hook = per-turn archive-RAG injection,
  SessionStart hook = one-shot session-open rotation/banner. Reinforces D1/D7.

- **D15 (S4):** **kiro-cli 2.11.1 ACCEPTS no-auth, non-PRM streamable-HTTP MCP —
  SUPERSEDES D5.** Proven live: the user's effect/fetch/gitlab/nixos servers are
  all `type=http` in `~/.kiro/settings/mcp.json`; each 404s
  `/.well-known/oauth-protected-resource` +
  `/.well-known/oauth-authorization-server` and answers a no-auth `POST /mcp`
  initialize (200). The OAuth 2.1 / RFC 9728 PRM gap
  (`[[project_mcp_proxy_kiro2_auth_gap]]`, kiro issue #8151) was real on kiro
  2.0/2.2 but NOT 2.11.1. openmemory therefore does NOT need to stay stdio for
  the MODEL. Residual live-confirm = Q9.
- **D16 (S4):** openmemory `opm serve` NATIVELY mounts `POST /mcp`
  (streamable-HTTP, stateless, `enableJsonResponse`, same tool surface as stdio)
  PLUS the REST API (`/memory/add`, `/memory/query`, …). So the transport fix is
  a native HTTP daemon; NO shim / mcp-proxy needed (contra the research
  workflow's Option C, which was premised on the now-refuted D5).
- **D17 (S4):** Deploy ONE `openmemory-mcp-serve` systemd user daemon on
  `127.0.0.1:<PORT>` against the SHARED ai-pg Postgres; flip
  kiro/Claude/Copilot's openmemory entry stdio→`{type=http; url=…/mcp}`. Fixes
  the per-subagent stdio RAM bomb (one process for all fan-outs). The
  ~100MB/instance is Node + pg/ioredis/sqlite3 drivers + aws/google/openai
  SDKs + doc parsers (NOT an embedding engine — openmemory embeddings are
  ollama/remote), amortized once in the daemon. Store is Postgres → no SQLite
  file-contention. Add the daemon via a native-HTTP server module in the
  `services.mcp-servers` fleet (small nix-agentic-tools change).
- **D18 (S4):** Auth mode = **no-auth `dev-no-auth`**
  (`OM_DEV_ALLOW_NO_AUTH=true`, NODE_ENV unset). Single implicit tenant
  `dev-no-auth`; kiro's http entry needs no headers; localhost-only guard.
  One-time Postgres re-key `anonymous`→`dev-no-auth` so existing stdio memories
  stay visible. (Keyed mode with `OM_API_KEY`+SOPS is the alternative if a hard
  tenant wall is ever wanted — see D19/D20.)
- **D19 (S4):** Isolation = **SOFT per-project via `project_id`**, keyed on the
  **canonical repo root shared across worktrees**
  (`dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` → slug),
  so all worktrees of one repo SHARE memory (user requirement). `system_global`
  tier for cross-cutting. NOT a security wall (same DB/tenant); a HARD
  work/personal wall would need separate keyed daemons/DBs (deferred; not needed
  now).
- **D20 (S4):** Hooks reach openmemory via the **in-process `Memory` SDK (bun →
  Postgres)**, NOT REST — because REST `/memory/{add,query}` lack `project_id`
  (only the SDK/MCP layer accepts `{user_id, project_id}`). The daemon is the
  MODEL's frontend; the hooks write/read Postgres directly with
  `project_id=<repo-slug>`. Ship an `openmemory-mem` SDK helper binary (or bun +
  `NODE_PATH`). Typed-vs-raw for `ai.kiro.hooks`: keep RAW passthrough, build
  JSON in-module via `builtins.toJSON` (typed hook schema is a separate future
  refactor).
- **D21 (S5):** **Q9 RESOLVED — native `opm serve` `/mcp` is VIABLE, but
  version-gated.** Empirically (real MCP SDK client + curl, self-serve): (a)
  `opm serve` mounts `POST /mcp` and answers a no-auth `initialize` (200) under
  `OM_DEV_ALLOW_NO_AUTH=true` with both OAuth well-knowns 404 — confirms D16/D18
  live; (b) the INSTALLED npx `openmemory-js 1.3.3` (= npm `latest`, published
  2026-01-27) is **broken for real HTTP clients** — its `/mcp` reuses ONE shared
  `StreamableHTTPServerTransport`, so `initialize` 200 then
  `notifications/initialized`+`tools/list` 500 (a spec client can't proceed);
  (c) upstream `main` **rev 9af0f95 — which our overlay already pins — FIXES
  it** by creating a fresh transport+server per request (comment: "MCP SDK 1.27
  rejects re-initialization on a single transport instance") and adds
  `openmemory_store_project` + `project_id` (1.3.3 has neither). A/B repro:
  shared→FAIL, per-request→PASS. **Consequences:** the stdio→http flip is ALSO a
  version bump (daemon = our nix pkg `openmemory-mcp-serve`, NEVER
  `npx …@latest`); it carries the D19/D20 `project_id` tooling; and it implies a
  DB schema change (Q11). RAM win confirmed: 15 live procs / 1,190 MB → 1 daemon
  / 86 MB (~1.1 GB / ~93%). Deferred empirical confirm of OUR built serve
  (`nix build .#openmemory-mcp`
  - real-client drive) is Checkpoint 1's first step (local eval OOMs this host).
    **Lesson (again, per D-note S4): the version you RUN ≠ the source you READ —
    `main`/our-pin had the fix, the npm `latest` did not; the user's "one turn
    isn't enough evidence" pushback caught a premature "serve is broken"
    conclusion.**
- **D22 (S6):** **Checkpoint 1 landed — the native-HTTP openmemory wiring was
  ALREADY generic; only the D18 no-auth knob was missing.** Recon of the real
  option surface proved the `services.mcp-servers` fleet
  (packages/mcp-services/modules/homeManager/default.nix) already treats
  openmemory as native-HTTP: it is in `serverNames`; its module declares
  `meta.modes.http = "openmemory-mcp-serve"` (≠ "bridge"); the generic machinery
  already generates the `mcp-openmemory-mcp` systemd unit running
  `openmemory-mcp-serve` + all OM\_\* env, and emits
  `mcpConfig.mcpServers.openmemory-mcp = {type=http; url=http://127.0.0.1:PORT/mcp}`
  via `mkHttpEntry` (settings.path default `/mcp`). So B0's "add a native-HTTP
  module" was already done EXCEPT `OM_DEV_ALLOW_NO_AUTH`. Added a typed
  `devAllowNoAuth` (`nullOr bool`, default null) → http-gated
  `OM_DEV_ALLOW_NO_AUTH` in `settingsToEnv` (only meaningful for the http
  `serve` daemon; stdio has no auth layer) + 2 platform-independent module-eval
  tests (option discoverability + native-HTTP mcpConfig entry). Verified
  pre-land: a lib-only targeted `settingsToEnv` eval (`import <nixpkgs/lib>`, no
  flake) → OM_DEV_ALLOW_NO_AUTH="true" for {devAllowNoAuth=true} in http mode,
  absent by default, absent in stdio (gate holds); a 3-lens adversarial workflow
  (conventions PASS_WITH_NITS → fixed the description style outlier; correctness
  PASS, could not refute the systemd-env + url trace incl.
  escapeShellArg→systemd-EXTRACT_UNQUOTE; propagation flaked → answered its
  cspell / module-eval / README questions by hand: no doc staleness, cspell
  clean, tests added). **Empirical Q9 confirm now holds on OUR built artifact**
  (cachix output `nnd6fka…`, real SDK client, `openmemory_store_project`
  present, no 500s). **METHOD NOTE (reusable on this OOM-prone host):**
  `nix build <drv>^out` on the pre-existing on-disk `.drv` builds/substitutes
  WITHOUT re-evaluating the flake. Consumer flip against the real ai-pg store
  still gated on Q11 (DB schema migration) + Q10 (tenant/user_id).

- **D23 (S7):** **Checkpoint 2, part 1 — the distiller core landed (d50fae0), +
  a schema correction.** Built `overlays/kiro-memory-distiller/distiller.ts`
  (bun/TS, 47 TDD tests, real-transcript validated). It is the deterministic
  Stop-hook write path: parse → select undistilled complete turns (execId dedup)
  → roll the tiered file buffer (`~/.kiro-memory/<slug>/` now/recent/archive) →
  best-effort backend seam → persist per-session state. Debounce = line-delta +
  cooldown; Manual = `force`. project_id/slug = D19 (dirname of git-common-dir +
  path hash; worktrees share).
  - **SCHEMA CORRECTION (supersedes the schema in D12/Q7 + kills the B3/D12
    promptTurnSummaries shortcut):** real messages.jsonl records are
    `{id,payload,timestamp}` with discriminator **`payload.type`** (D12/Q7
    wrongly listed those values as top-level `.type`). **`promptTurnSummaries`
    is BILLING data** (`[{unit,unitPlural,usage,usedTools}]` inside
    `usage_summary`), NOT a per-turn summary — so distillation must derive from
    `user.content` + `assistant.content where operationType=="Say"` (Reasoning
    excluded); `usedTools` kept as cheap metadata. `user` payloads have no
    executionId (positional assoc).
  - **Design:** dedup by execId (not line offset) is robust to a turn straddling
    runs; line-count feeds ONLY the debounce gate. Backend is an injected
    best-effort seam; the file-buffer write is unconditional (survives
    daemon-down, D20).
  - **Adversarial review (4-lens workflow + adjudicator, 9 findings).** FIXED:
    persist state before the backend loop (dup-on-crash), unique atomic-write
    temp names, corrupt-buffer preservation (never silently wipe the warm
    buffer), backend timeout/killSignal, readFileSync + main try-catch,
    session_id path-traversal validation, git-ENOENT warn, turn_start
    prompt-leak, usedTools dedup. VERIFIED against real data that usage_summary
    DOES carry executionId (reviewer's "usedTools dropped" case cannot fire).
    **DEFERRED (next session):**
    - **(D23a) Tail-loss.** The gate is `enoughNew && cooledDown` (AND). Because
      v3 has NO SessionEnd hook and Stop is per-turn (D11), the LAST turn of a
      session, if it adds < minNewLines lines, is never flushed. FIX: flip to
      `enoughNew || cooledDown` (batch when busy, flush when quiet) AND add a
      SessionStart hook that flushes the PRIOR session's tail; Manual
      `/remember` is the interim catch. (Changing the gate requires rewriting
      the shouldDistill tests to the OR semantics.)
    - **(D23b) Concurrency.** Concurrent worktree distillers RMW the ONE shared
      buffer (D19) with no lock → last-writer lost-update / corruption. FIX: a
      per-project O_EXCL lockfile mutex (Atomics.wait backoff + stale-break)
      around the loadBuffer→rollTiers→write critical section. (unique-temp +
      corrupt-preservation already reduce the blast radius.)
  - DECLINED (with reason): capping `state.distilled` (unsafe without transcript
    windowing — would re-distill old turns); throttling the no-op re-parse (LOW;
    n is small, interacts with the tail-flush).
  - Language = bun/TS per the user directive; TS turns out to be treefmt-covered
    (prettier), voiding the earlier "TS untooled" concern. cspell terms:
    cooldown, sess.

- **D24 (S8):** **Checkpoint 2 — the deferred tail-loss fix (D23a) landed.** Two
  parts + a review-caught watermark fix.
  - **(a) OR gate.** shouldDistill flipped from `enoughNew && cooledDown` to
    `enoughNew || cooledDown`: distill on EITHER enough new lines (batch while
    busy) OR the cooldown elapsed (flush the tail while quiet); skip only when
    BOTH are false (few new lines AND a recent run). This is the actual
    tail-loss fix — under AND, a session's final sub-threshold turn was never
    distilled (v3 has no SessionEnd; Stop is per-turn). Note the pre-existing
    interaction: fresh state has lastRunMs=0, so cooledDown is trivially true on
    a session's FIRST Stop → every session now distills its opening turn
    immediately (intended — it also guarantees a .state file exists for the
    flush scan). Rewrote the shouldDistill tests to OR semantics + the one
    distill debounce test whose premise changed.
  - **(b) flushSessionTails (SessionStart).** The residual the OR gate can't
    catch (a sub-threshold tail ending WITHIN the cooldown) is flushed on the
    next SessionStart: scan the project's prior-session .state files and, for
    each session != the just- started one whose transcript grew past a recorded
    byte size, force-distill it (idempotent via execId dedup). New DistillState
    field lastTranscriptSize + a stat-only size gate keep a caught-up session at
    locate+stat, no read/parse. CLI: `--flush` argv dispatch + mainFlush();
    shared env/stdin plumbing DRY'd into resolveCliEnv/readMeta.
  - **Adversarial review (4-lens workflow + per-finding refute pass; 16 agents,
    12 findings, 6 CONFIRMED).** THREE lenses independently caught the flagship
    defect: distill's no-new-turns path returned BEFORE the state write, so a
    grown-but-no-new-complete-turn force run never advanced lastTranscriptSize →
    the stat gate never closed → EVERY legacy pre-D24 state file
    (lastTranscriptSize defaults 0) and every aborted/in-flight tail would
    re-locate+read+parse on EVERY SessionStart forever (efficiency, not
    correctness — distill is idempotent — but unbounded, and it defeats the
    feature's own optimization). FIXED before landing: advance ONLY the flush
    watermark on the no-new-turns path, guarded on growth, debounce baselines
    (lastLineCount/lastRunMs) untouched; legacy state self-heals after one
    flush. Also FIXED: mainFlush uses the `...env` spread like main (DRY); added
    3 tests — two pinning the watermark advance (incomplete-tail + legacy-zero)
    and one that truly pins the stat gate (inflated watermark + undistilled
    complete turn ⇒ NOT distilled).
  - REFUTED / not changed (with reason): the byte-size (Buffer.byteLength) vs
    statSync().size equality is exact for valid UTF-8 (messages.jsonl always is)
    → no false grow/caught-up; the live cross-worktree flush race is real but
    the SAME class as the deferred D23b lock and NOT new data-loss (idempotent);
    the empty/invalid currentSessionId tolerance in mainFlush is intended (it is
    only the exclusion key; each scanned entry is independently re-validated).
    first-Stop-always-distills is already pinned by two shouldDistill tests.

- **D25 (S9):** **STAGE 2 landed — the distiller is nix-packaged.**
  `overlays/kiro-memory-distiller.nix` packages
  `overlays/kiro-memory-distiller/distiller.ts` as an
  `ourPkgs.stdenvNoCC.mkDerivation`. The script is dependency-free (node:
  built-ins only) → NO `buildNpmPackage`/`npmDepsHash` (simpler than every MCP
  server). Build pattern = the repo's established bun-wrapper idiom
  (openmemory-mcp / effect-mcp / git-intel-mcp): `makeWrapper` over
  `${bun}/bin/bun --add-flags <entry>`, chosen over `bun build --compile` (no
  in-repo precedent; bun is already in the closure; a wrapper is smaller +
  transparent). TWO role bins from one derivation (`kiro-memory-distiller` +
  `kiro-memory-flush`, mirroring openmemory-mcp/-serve) so STAGE 3's Stop vs
  SessionStart hooks each reference a bare absolute path with no arg plumbing.
  git on the wrapper PATH via `--suffix` (ambient-first, ours as fallback —
  resolves even under an env-stripped hook). checkPhase runs the 58-test suite
  IN the sandbox (a real failure fails the build — no `|| true` masking);
  installCheck is an exit-0 `{}`-stdin smoke on both bins.
  - **Cache-hit parity:** every build input routes through `ourPkgs`
    (bun/git/lib/makeWrapper/ stdenvNoCC + the `lib.makeBinPath` git path baked
    into the wrapper); `src` is the in-repo path (this flake's content,
    consumer-stable) → byte-identical CI-vs-consumer. Added to the
    `checks/cache-hit-parity.nix` allowlist (aiCliPackages, the
    `consumerPkgs.ai.<name>` lookup).
  - **Registration:** `overlays/default.nix` flatDrvs (alphabetical) →
    auto-flattens to `.#kiro-memory-distiller` / `pkgs.ai.kiro-memory-distiller`
    (flake.nix comment confirms new flatDrvs entries need no flake.nix edit).
    `overlays/README.md` index row + an "In-repo source" bullet. version="0.1.0"
    (no upstream/rev — the first in-repo-source overlay pkg, so NOT in
    `config/update-matrix.nix`, mirroring the content pkgs);
    license=`lib.licenses.unlicense` (repo LICENSE = Unlicense; free → the
    `ensureUnfreeCheck` guard passes it unwrapped).
  - **Validated OOM-safely** (this host OOMs on flake eval; a live kiro TUI +
    opm procs were up): a TARGETED `nix-build --impure --expr` importing ONLY
    this overlay + `getFlake … .inputs.nixpkgs` (inputs, NOT outputs) → no
    packages/checks/modules eval. Built clean, 58 tests green in-sandbox, both
    wrappers exit 0. The full cache-hit-parity check runs in CI (can't run
    locally).
  - **Adversarial review (4-lens workflow + per-finding refute; 6 agents): 0
    CONFIRMED, 1 PARTIAL, 1 REFUTED.**
    - PARTIAL (dev/data.nix): the distiller is absent from the user-facing
      generated-docs SSOT (root README AI-CLI table / doc-site overlay table).
      **DECIDED intentional, no change:** it is internal hook plumbing invoked
      by kiro's hooks, never a user-run CLI — consistent with the curated lists
      already omitting claude-code (from `overlayPackages.ai-clis`) and agnix.
      No structural check enforces data.nix completeness; the generators iterate
      data.nix (not pkgs), so an absent package is silently dropped, not an
      error. (The repo does not annotate the analogous claude-code/agnix
      omissions inline, so neither does this.)
    - REFUTED (overlay header omits HOME): refuted FOR THE HEADER (HOME is a
      universal inherited var, unlike the wrapper-baked git/openmemory-mem
      decisions the header documents; the cited MCP env-replacement failure
      class is MCP-specific, and the PATH-strip case is already mitigated by
      absolute bun + suffixed git). BUT the underlying insight is a real STAGE-3
      requirement, recorded in the S9 STATE block: the hook `action` env MUST
      export HOME (the distiller derives sessionsDir/memoryDir from it; a
      stripped HOME → silent cwd-relative memory-loss), and MAY set the
      `KIRO_MEMORY_*` overrides. No correctness or parity defect survived the
      review.

- **D26 (interim, 2026-07-12):** **Backlog — a comprehensive implementation doc,
  scheduled LAST (FROZEN STAGE 6).** User directive: add a deliverable that
  "explains the whole implementation" for BOTH an LLM revising the code AND a
  human; placement at the END is the user's stated lean and the agent-owned
  ordering call (protocol bullet, S8).
  - **Form (recommended, not frozen):** a package-scoped architecture fragment —
    the repo's established mechanism for exactly this dual audience
    (`location=package`, `packages/kiro-cli/docs/<name>.md`, registered in
    `dev/generate.nix` `devFragmentNames.kiro-cli`, scope globs in
    `packagePaths`). ONE markdown source fans out to per-ecosystem scoped router
    files (`.claude/rules` `paths:`, Copilot `applyTo:`, Kiro `fileMatch`) for
    the LLM audience AND stays plain readable prose for the human audience — so
    it satisfies both with no duplication (see AGENTS.md "Architecture
    Fragments"). The user left the form open ("readme or fragment or steering…
    something"); a fragment is the DRY pick, optionally cross-linked from a
    top-level README / `overlays/README.md` for discoverability. Final call at
    implementation time.
  - **Why LAST:** the repo's own doctrine says an out-of-date fragment is worse
    than none ("a lie is worse than silence"). Stages 3–5 still reshape the
    abstraction (hook wiring, buffer lock, backend helper); documenting before
    they settle guarantees immediate staleness. End placement also matches the
    user's lean.
  - **Scope to cover:** the two-problem frame (auto-READ / auto-WRITE, F0); the
    read tiers (steering anchor + external file buffer + archive RAG, F4/D2);
    the write distiller pipeline
    (parse→select→distill→rollTiers→buffer→backend) + its corrected schema
    (D23); the v3 hook set + the mandatory HOME / `KIRO_MEMORY_*` env contract
    (S9 STATE); the two role bins + the bun-wrapper packaging idiom (D25); the
    module option surface (`ai.kiro.hooks`/`.rules` + B5 HM↔devenv parity); and
    the load-bearing invariants (worktree-shared project_id D19/D20, debounce
    OR-gate + tail-flush watermark D24, buffer O_EXCL lock D23b). Mark the
    fragment's `Last verified:` on landing.

- **D27 (S10, 2026-07-12):** **STAGE 3 landed — the v3 hook set + steering
  anchor as a reusable generator.** `packages/kiro-cli/lib/autoMemory.nix`
  (exported `lib.ai.apps.kiroAutoMemory`) produces VALUES for the EXISTING
  `ai.kiro.hooks` / `ai.kiro.rules` options — no new module axis (B5), riding
  the same HM↔devenv fanout. It emits ONE `.kiro/hooks/kiro-memory.json`
  `{version:"v1", hooks:[…]}` envelope with three v3 hooks + one steering rule.
  - **Sync, not background (refines B3 over D8):** D8 (S2) chose a synchronous
    distiller; D11 (S3) found Stop is per-turn → debounce (F5); B3 (S4) then
    said "Run in the BACKGROUND (nohup &)". D27 REAFFIRMS synchronous for STAGE
    3 — the distiller is already debounced (S7/S8) + file-IO-only (no network
    until the STAGE-5 SDK) + sub-second, so kiro's Stop `timeout` wait is
    negligible and a store-path `nohup &` fork only adds fragility
    (reap-on-exit, PATH/env). B3's background note is annotated SUPERSEDED in
    place; revisit at STAGE 5.
  - **HOME always-guarded (hardened by the S10 review):** each wrapper ALWAYS
    runs a fail-loud `: "${HOME:?…}"` guard (trips on unset AND empty) and
    additionally bakes a supplied NON-EMPTY absolute path. The 4-lens
    adversarial review (2 lenses CONFIRMED) caught that a naive `home != null`
    bake would emit `export HOME=''` for an empty-string input — a public-API
    footgun (`builtins.getEnv "HOME"` → "" under pure eval) that the distiller's
    `?? ""` keeps empty → silent cwd-relative memory-loss (the exact S9/D25
    failure the guard exists to stop). Empty is now treated exactly like null
    (guard-only, never baked); regression-locked by the module-eval
    `empty == unset` assertion + built-wrapper evidence for all three HOME
    branches.
  - **Scope:** Stop (distill) + SessionStart (`--flush`) + Manual (`/remember`,
    reuses the Stop bin, D3 fallback) + the B1 steering anchor. UserPromptSubmit
    archive-RAG stays deferred to STAGE 5 (needs the `openmemory-mem` SDK
    helper + the B3 interface measurement).
  - **Bins by absolute store path** via `getExe' pkgs.ai.kiro-memory-distiller`
    (D25): Stop/Manual → `kiro-memory-distiller`, SessionStart →
    `kiro-memory-flush`. Wrappers are `writeShellScript` (strict mode, absolute
    paths per nix-standards) — consumer-local config artifacts, NOT overlay
    packages, so no cache-hit-parity concern.
  - **Tests:** 4 module-eval tests (checks/module-eval.nix) — HM emits the
    hooks, HM emits the steering (`inclusion: always`), HM↔devenv BYTE-IDENTICAL
    parity (B5 proven empirically), and the HOME-baked / empty==null regression.
    All green via a bounded targeted `evalModules` (no flake eval — this host
    OOMs); the full checks run in CI.
  - **LIVE-TEST CHECKPOINT (HITL, gates the consumer flip):** confirm in a
    trusted TUI that kiro (a) fires all three hooks from ONE file (the
    documented schema supports it; if it wants one-per-file, splitting is a
    trivial 3-attr change), (b) the Stop hook's stdin still reaches the
    distiller through the wrapper `exec … "$@"`, and (c) the steering anchor
    injects. These are closed-binary behaviors the repo cannot assert.

- **D28 (S11, 2026-07-13):** **STAGE 4 landed — the D23b per-project buffer
  lockfile.** `withBufferLock` (exported) serialises the SHARED-buffer
  read-modify-write (loadBuffer→rollTiers→ write) across concurrent
  sibling-worktree distillers — D19 keys the buffer on the worktree-shared repo
  root, so concurrent kiro sessions in different worktrees RMW ONE buffer.
  Mechanism: `linkSync` of a written temp onto `<projDir>/.buffer.lock` (atomic
  EEXIST-on-collision, the canonical local-fs mutex — no empty-file window);
  ttl-based stale-break; `Atomics.wait` sync backoff (matches the sync file-IO
  distiller, D8/D27 — no event loop); release in `finally`. On lock-timeout
  `distill()` returns `skipped:"locked"`. The per-session `.state/<sid>.json`
  stays OUTSIDE the lock (per-session, no cross-process contention).
  - **Adversarial review (4-lens workflow + per-finding refute; 10 agents): 2
    CONFIRMED, 4 PARTIAL, 0 REFUTED.** Both CONFIRMED fixed before landing:
    - **(medium) data-loss regression** — the locked skip originally wrote
      nothing, but `flushSessionTails` finds recoverable sessions only by
      scanning `.state/*.json`. A session whose only/final Stop timed out on the
      lock left no `.state` → invisible to flush → turns permanently dropped.
      Pre-D23b every first Stop wrote `.state` (first Stop always distills:
      lastRunMs=0 ⇒ cooledDown), so the lock introduced a NEW gap. FIX: the
      locked skip writes `.state` with the LOADED values verbatim (fresh session
      ⇒ all zeros ⇒ flush's `size > lastTranscriptSize` gate re-fires; no
      baseline advanced ⇒ the next Stop still re-distills). End-to-end
      regression test: lock-skip → drop lock → SessionStart flush rediscovers +
      distills the tail.
    - **(low) test-fidelity** — no test fed withBufferLock's OWN written token
      back through the staleness reader, so a future drop of `ts` from the token
      (→ every contended lock reads as infinitely-old → both break-and-enter →
      total mutex defeat) would pass all tests. Added a self-contention
      round-trip test + a garbage-content-lock break test.
  - **PARTIAL (adjudicated, all low):** (i) the stale-break + release unlink by
    PATH with no holder-identity check → a live-but-slow/suspended holder past
    ttlMs can be broken and a resumed holder can free a successor's lock (a
    concurrent critical section) — bounded to a lost UPDATE (writeAtomic
    corruption-free; the turns survive in `.state` distilled[] + the backend,
    missing only from the rebuildable file-buffer tier), squarely inside D23b's
    best-effort scope; the overstated doc comment (was "only triggers when a
    holder has actually died") was CORRECTED. (ii) `lockAgeExceeded`'s
    garbage/vanished branches — the garbage precondition is not producible by
    this module (linkSync atomicity → only an orphan `.tmp`), added a cheap test
    anyway. (iii) a weak-named "happy path releases the lock" test (already
    covered by the unit acquire/release tests) — renamed to a "no stray
    .buffer.lock" smoke. DECLINED a subprocess real-race test (flaky,
    best-effort, bounded impact); kernel-flock / identity-checked break-release
    recorded as future hardening if the residual bites.
  - Validated OOM-safely (targeted single-overlay `nix-build --expr`, no flake
    outputs): built clean, all 67 tests green in the checkPhase sandbox, both
    wrappers exit 0. cspell terms added: serialised, serialising, toctou,
    unheld, unparseable, rebuildable.

- **D29 (S12, 2026-07-13):** **STAGE 5a landed — the `openmemory-mem` SDK helper
  binary; STAGE 5 split into 5a (helper) / 5b (wiring).** The deterministic
  backend seam the distiller shells out to (`defaultBackendWrite` →
  `openmemory-mem add --project-id <id>` + stdin) plus a symmetric `query`
  subcommand for the deferred read hook. Fills the `backendWrite` seam stubbed
  since D23.
  - **SDK verified against the pinned 9af0f95 source (not memory):**
    `new Memory(user_id?)`; `mem.add(content,{project_id})`;
    `mem.search(query,{project_id,limit})` → hsg_query rows
    {id,score,primary_sector,salience,content,…}. The in-process SDK
    writes/reads Postgres DIRECTLY (`add_hsg_memory`/`hsg_query`), BYPASSING the
    HTTP daemon's tenant middleware — so **Q10's `tenant_mismatch` cannot bite
    the helper** (D20 holds; it fires only on the model's HTTP calls). A write
    with user_id undefined stores "anonymous"; search applies no user filter
    when unset (the hook write→read loop is self-consistent); `OM_USER_ID`
    aligns the write to the daemon tenant (`dev-no-auth`) at the consumer flip
    (a 5b/flip knob, not a 5a decision).
  - **Design:** a pure exported core
    (`parseArgs`/`formatHits`/`normalizeRows`/`runMem`) with the SDK as an
    INJECTED `MemoryBackend` seam; the real backend is built LAZILY (dynamic
    import of the co-packaged `./dist/index.js`) only in the `import.meta.main`
    entry, so the bun suite never loads dist/PG (mirrors the distiller's seam
    injection). Exit codes: 0 ok / 1 backend-or-op failure (best-effort, the
    distiller swallows it) / 2 usage. Empty stdin short-circuits BEFORE
    constructing the backend (so the nix smoke never touches PG). `formatHits`
    mirrors openmemory's `fmt_matches`.
  - **Packaging = 3rd bin of openmemory-mcp** (D20 "from the openmemory
    package"), NOT a separate overlay — shares the exact `dist/` +
    `node_modules` the daemon runs → SDK/Postgres-schema lockstep (Q11). A
    `checkPhase` runs the 30-test bun suite in-sandbox (isolated temp dir →
    ignores the upstream vitest suite); `installPhase` cp's the helper beside
    `dist/` + adds the wrapper; the empty-stdin `openmemory-mem` smoke rides
    `mkMcpSmokeTest`'s `runHook postInstallCheck` (DRY, no double runHook).
    Verified OOM-safely (`nix build <drv>^out` — npmDeps substituted; the
    checkPhase tests + both smokes green; 3 bins present; dist/node_modules are
    siblings of the helper).
  - **Adversarial review (4 lenses — correctness / nix-packaging /
    contract-fidelity / test-adversarial — + per-finding refute; 8 agents): 0
    CONFIRMED, 1 REFUTED, 3 PARTIAL (all low).**
    - REFUTED (nix cache-parity): a claim that `${memHelper}`/`${memTest}`
      interpolation pulls the whole flake source into the drv context →
      per-commit churn. The verifier empirically proved (Nix 2.34.4) that
      file-literal interpolation yields an ISOLATED content-addressed
      single-file store path, byte-identical to `builtins.path` — so the drv
      re-hashes ONLY on a helper/test byte change (confirmed live: `wlkk…` →
      `c3h6…` only after the fix). The `toString ./file` sub-path behavior the
      author conflated is a different operation, not used here. No change.
    - PARTIAL → FIXED: (1) extracted+exported `normalizeRows(rows): Hit[]` (the
      drift-prone SDK row→Hit projection — `primary_sector`→sector +
      numeric/string coercion — that had ZERO coverage since the stub replaces
      the whole backend and the smoke short-circuits before the real path) + 2
      unit tests (canonical row → exact Hit; coercion + missing-field defaults).
      Catches an adapter typo as a red test instead of a silent blank read hook.
      (2) `trunc` made codepoint-aware (`Array.from`) — the UTF-16
      `slice(0,200)` split a surrogate pair on astral content, emitting a lone
      surrogate that renders U+FFFD and diverges from openmemory's codepoint
      `fmt_matches`; proven old→`isWellFormed()` false / new→true; added an
      astral test + a trimEnd-boundary characterization test. (3) `parseArgs`
      now rejects a flag-shaped `--project-id` value (`--project-id --limit`
      previously parsed a VALID `projectId="--limit"` silently — the opposite of
      the "typo'd flag is loud" intent) + 2 tests.
  - **5a/5b split (agent-owned ordering, protocol S8):** 5a is HITL-INDEPENDENT
    (the helper binary touches no hook wiring), so it shipped now — reconciling
    the user's "de-risk the HITL before sinking effort into STAGE 5" with "it
    gates the consumer flip, not STAGE 5 code." 5b (wire the bin onto the hook
    PATH + the UserPromptSubmit read hook + the `OM_PG*`/`OM_USER_ID` env in
    `autoMemory.nix`) is HITL-reshapeable (one-file-3-hooks) → deferred until
    after the HITL live-TUI test.
  - cspell: renamed a `memtest` shell var → `mem_test_dir` (dictionary-clean)
    rather than adding a term.

- **D30 (S13, 2026-07-13):** **HITL live-TUI test PASSED — all three checks
  green on kiro-cli 2.12.0; the one-file-3-hooks model holds, so STAGE 5b needs
  NO split.** This satisfies D27's LIVE-TEST CHECKPOINT — the last closed-binary
  unknown that has gated the consumer flip since S3.
  - **Version note:** the installed binary is now **kiro-cli 2.12.0** (was
    2.11.1 across S1–S12). The v3 hook set was last probed on 2.11.1, so this
    run doubles as re-validation on the newer binary. The `chat` subcommand
    accepts `--tui --v3` (`kiro-cli chat --tui --v3`; `chat` also accepts
    `--agent-engine {v1,v2,v3}` + `--mode {default,spec}` +
    `-a/--trust-all-tools`) — confirmed from the live TUI's own command line.
    The **top-level launcher ALSO still accepts `--v3`/`--tui`** on 2.12.0
    (verified via `--help-all` Options block + a parse-only
    `kiro-cli --v3 --tui --help` exiting 0), consistent with the 2.8.1
    [[project_kiro_v3_engine_mode]] launcher semantics — so the harness's
    original `kiro-cli --v3 --tui` hint was **NOT broken** (I initially
    mis-claimed it was and corrected that here). Switched the printed hint to
    the `chat` form actually exercised this session; both work.
  - **Pre-flight de-risk (agent, non-interactive, OOM-safe):** BEFORE the user's
    TUI time, verified the generated config end-to-end — the `kiro-memory.json`
    envelope carries all 3 hooks; each wrapper has the HOME `:?` guard +
    `KIRO_MEMORY_DIR` scratch redirect + execs a REALIZED distiller bin; and,
    crucially, drove the **stop wrapper** exactly as kiro would
    (`{session_id,cwd}` on stdin, `FORCE=1`) against a **real 2.12.0
    `messages.jsonl`** → `distilled:2, skipped:null`, buffer files written. So
    the **D23 parser schema did NOT drift on 2.12.0** and the whole write
    pipeline works on real data. This narrowed the live test to purely the
    closed-binary firing/stdin/injection behaviors.
  - **Live results (user-run trusted TUI, guided synchronously —
    [[feedback_hitl_walk_through_live]]):**
    - **(a) 3 hooks / 1 file** ✅ — `/hooks` listed `kiro-memory-distill`
      (Stop), `kiro-memory-flush` (SessionStart), `kiro-memory-remember`
      (Manual), all from the single envelope. **No one-file-per-hook split
      needed** — 5b adds its UserPromptSubmit read hook as a 4th entry in the
      same file.
    - **(b) Stop fires + delivers stdin + full write loop** ✅ — after quitting,
      the scratch `.state` file was keyed on the **live** session id
      (`sess_f3248b29…`), proving kiro delivered the stdin metadata; `now.md`
      grew 0→320 B with the correct distilled turn (Ask + answer +
      `_tools: read_file_`). Turn 2 was correctly cooldown-skipped (first Stop
      distilled at `lastRunMs=0` ⇒ `cooledDown`; turn 2 within 90 s and under
      the 12-line `enoughNew` threshold) — the D24 OR-gate + D8 debounce
      observed live, not a bug. Per Q6, quit added no Stop.
    - **(c) steering `inclusion: always` injects** ✅ — the model quoted "#
      Persistent project memory (auto-maintained)" verbatim and named the rule
      `kiro-auto-memory`.
  - **Consequence for 5b:** proceed as designed against the existing one-file
    envelope. The open design surface is the UserPromptSubmit archive-RAG
    **read** hook (what to query, how much to inject, the B3 interface
    measurement) + the `OM_PG*`/`OM_USER_ID` env contract (Q10 alignment at the
    flip). The consumer flip stays HITL (Q10/Q11 gate ONLY the flip, not 5b
    code).

- **D31 (S14, 2026-07-13):** **STAGE 5b landed — the READ side + openmemory
  backend wiring; the FINAL code stage.** Adds the `UserPromptSubmit`
  archive-RAG recall hook and binds the `openmemory-mem` helper onto the hook
  PATH + threads the `OM_*` env, completing the deterministic read/write loop.
  - **Read-hook design — Option C (hybrid), the resolved open question.** The
    `UserPromptSubmit` stdin `prompt` is EMPTY (D12), so the archive query is
    seeded from the distilled buffer, not the prompt; and `now.md` was never
    read back into context before (the steering anchor is a static store
    symlink). So recall injects, per turn: the live `now.md` tier
    (always-available base, works with the daemon down) PLUS a best-effort
    openmemory archive query seeded by `now.md` (lights up after the flip). It
    degrades to the recent tier alone when the backend is absent — faithful to
    the Claude `.remember` + openmemory blueprint. Rejected: archive-only (dark
    until the flip, untestable end-to-end in 5b) and buffer-only (skips the
    archive-RAG the stage is named for). The user delegated the call and asked
    for the best (not surgical) approach + logged tuning paths.
  - **Where the logic lives.** A `--read` mode (`mainRead`) in `distiller.ts`, a
    3rd role bin `kiro-memory-recall`, mirroring `--flush`. It REUSES
    `deriveProjectId`/`resolveCliEnv`/the buffer paths — reimplementing the
    git-common-dir→slug derivation in bash would be a DRY violation + drift risk
    (the read must see the same `project_id` the write produced, D19). New
    exports: `BackendQuery` (read seam symmetric with `BackendWrite`),
    `RecallConfig`, `formatRecall` (pure, bounded composer), `recall`;
    `defaultBackendQuery` shells
    `openmemory-mem query --project-id <id> --limit <n>` (seed on stdin,
    best-effort "" on any failure — symmetric with `defaultBackendWrite`).
    `--read` dispatch after `--flush`.
  - **Wiring (autoMemory.nix), secret-safe.** A 4th `UserPromptSubmit → recall`
    entry in the SAME one-file envelope (D30 — no split). `openmemory-mem` (a
    bin of `pkgs.ai.mcpServers.openmemory-mcp`) goes on EVERY wrapper's PATH —
    bound HERE, not in the distiller overlay, so that package stays
    backend-agnostic (the end-goal pluggable-backend direction). `OM_*`
    connection env rides a baked `omEnv` attrset EXCEPT the Postgres password,
    which is cat from `omPgPasswordFile` (a runtime STRING path) at wrapper
    start — NEVER baked into the world-readable store
    ([[feedback_mimic_sops_secrets]]). An assert rejects `OM_PG_PASSWORD` in the
    merged `bakedEnv` (`env // omEnv`). Consumers should feed `omEnv` from the
    SAME source as the daemon (openmemory-mcp `settingsToEnv`) so the hook and
    daemon stay schema-lockstep (Q11) — a consumer-flip concern; 5b provides the
    seam.
  - **TDD + 4-lens adversarial review + per-finding refute (16 agents): 0
    CONFIRMED, 9 PARTIAL, 3 REFUTED.** 11 new bun tests (80 total, red→green) +
    2 module-eval checks (build-and-grep of the recall AND a write-path wrapper;
    two-route `rejects-baked-password`). **8 partials FIXED before landing:**
    - (medium, flagged by nix-wiring AND test-adversarial) the password guard
      covered only `omEnv`, but `bakedEnv = env // omEnv` — a secret via `env`
      would still bake. Broadened the assert to `bakedEnv`
      - a module-eval test smuggling via `env`.
    - `formatRecall` violated its stated `length <= maxChars` bound when
      `maxChars < marker` (13); and it sliced by UTF-16 unit (a lone surrogate →
      U+FFFD, the exact class 5a's `fmt_matches` `trunc` fixed). Replaced with
      `boundedTruncate` (true bound for every `maxChars` + drop a trailing lone
      high surrogate) + tests at `maxChars < marker` and all-astral content.
    - `defaultBackendQuery` passed an un-coerced `--limit`; a fractional
      `KIRO_MEMORY_RECALL_LIMIT` made the helper exit-2 and silently drop the
      whole archive tier → `Math.max(1, Math.trunc(...))`.
    - test hardening: grep a write-path (Stop) wrapper too (P8); pin the fence +
      section ordering (P9).
    - **1 partial DEFERRED as a TUNING path (P3):** the recall hook spawns
      `openmemory-mem` synchronously per prompt (5 s timeout) — sub-perceptible,
      symmetric with the landed write path, and inert in the 5b default (no
      backend). Post-flip, if felt, add a debounce/short-TTL cache or async
      fork; MEASURE first (B4). Logged alongside seed-strategy /
      recent-tier-depth / injection-size / dedup knobs in the S14 STATE block
      for the tuning rounds.
  - **De-risk (OOM-safe):** built the distiller overlay (80 tests + 3-bin
    smoke) + 6 module-eval checks + drove the built `kiro-memory-recall` on real
    data (degraded recent-only AND the archive path with a fake
    `openmemory-mem`: `query --project-id <slug> --limit 3`, `now.md` seed on
    stdin, both tiers).
  - **Scope:** the consumer flip (openmemory stdio→http daemon, Postgres re-key,
    full `OM_*` from the daemon's `settingsToEnv`, Q10/Q11) stays HITL and is
    NOT part of 5b. cspell: British spellings avoided (American) rather than
    adding dictionary terms.

- **D32 (S15, 2026-07-13):** **STAGE 6 landed — the D26 comprehensive
  implementation doc; the workstream's FINAL stage.**
  `packages/kiro-cli/docs/kiro-auto-memory.md`, a package-scoped architecture
  fragment (location=package) registered in `dev/generate.nix`
  (`devFragmentNames.kiro-cli` + `packagePaths.kiro-cli`, scoped to
  `overlays/kiro-memory-distiller.nix` + `packages/kiro-cli/**` +
  `overlays/mcp-servers/openmemory-mem/**`). Fans out to
  `.claude/rules/kiro-cli.md`, the TRACKED
  `.github/instructions/kiro-cli.instructions.md`, and
  `.kiro/steering/kiro-cli.md`. Cross-linked from `overlays/README.md` (+ a
  stale 58→80 test-count fix) and this plan (the top-of-file implementation-map
  pointer). Covers everything D26 named (READ/WRITE frame; distiller pipeline +
  D23 schema; hybrid recall + `BackendQuery` seam D31; `project_id` D19/D20;
  hook set + env contract + secret-never-baked D31; 3 role bins + packaging
  D25/D29; module surface + B5 parity; the invariant checklist).
  `Last verified: 2026-07-13` + maintenance trigger. Doc-only stage: no
  production code changed; built OOM-safely (per-derivation instruction builds,
  not a full flake eval).
  - **Adversarial review (4-lens — write-path / read-path / nix-wiring /
    completeness — + per-finding refute; 14 agents): 5 CONFIRMED / 5 refuted;
    all 5 fixed.** Two medium: (i) the pipeline-order summary listed
    select-then-gate → corrected to gate-BEFORE-parse (distill() runs
    shouldDistill before selectUndistilledTurns — the cheap pre-parse gate).
    (ii) **the real find — the Manual `/remember` hook does NOT force:**
    `manualWrapper` is byte-identical to `stopWrapper` and sets no
    `KIRO_MEMORY_FORCE`, so `/remember` runs the same debounced path as `Stop`
    and can silently no-op — contradicting D3 + the steering anchor's "force an
    immediate distill" line. Three low, all fixed: "file-IO-only" (the sync path
    also forks git per Stop + openmemory-mem per turn at a 5 s SIGKILL cap);
    "every write is temp+rename atomic" (false for archive.md's appendFileSync);
    "three tiers, only one live read" (recall() does two). 5 refuted (all
    cosmetic/imprecise-only, refute-by-default): "injects every turn"
    (empty-buffer case already documented downstream); "fourth bin from a
    different package" (a running count, not a bin-count claim; the doc says
    "3rd bin of openmemory-mcp" correctly at its packaging section);
    "cache-hit-parity allowlisted" (accurate — aiCliPackages is the covered
    list, the repo's own term); the "80" test count (correct today, mitigated by
    the maintenance marker); the env-knob block (accurate + a genuine cross-file
    contract, not a restatement).
  - **Manual-force decision (deferred to user, per
    [[feedback_wait_for_review]] + [[feedback_run_decisions_by_user]]):** the
    fix is a 1-line `export KIRO_MEMORY_FORCE=1` in `manualWrapper` (the
    distiller already honors it) — but it is a code change to code the user
    explicitly froze after 5b, and it reshapes the abstraction the doc
    describes. So STAGE 6 stayed doc-only: the gap is documented as a KNOWN GAP
    in the fragment (honest, not masked — [[feedback_no_masking_fixes]]) and
    surfaced for the user's call, NOT landed. If approved → `feat(kiro-cli)` +
    drop the Known-gap note + the fragment's data-flow row; if declined → the
    note stays.

- **D33 (S16, 2026-07-13):** **Manual `/remember` now FORCES — option B landed**
  (closes the gap D32 surfaced). `mkWrapper` in `autoMemory.nix` gains a `force`
  flag; the Manual wrapper alone sets `force=true`, baking
  `export KIRO_MEMORY_FORCE=1` (placed AFTER the baked env so it wins over a
  consumer's `env`), which `distiller.main()` already honors
  (`KIRO_MEMORY_FORCE==="1"` → `force:true` → `shouldDistill` bypassed). Manual
  = the Stop wrapper `+ force`; Stop stays debounced. `/remember` is thus a
  deterministic immediate distill (the D3 intent), and the steering anchor's
  "force an immediate distill" line no longer over-promises. TDD: new
  module-eval check `module-kiro-auto-memory-manual-forces` (realizes both
  wrappers; manual has FORCE, stop has none), proven RED→GREEN OOM-safely. The
  fragment was maintained in the SAME commit (data-flow row, a "Manual forces"
  env-contract bullet, the FORCE knob note, invariant #10, Known-gap bullet
  removed, `manual-forces` added to the test enumeration); routers regenerated.
  Also aligned the Manual `mkHook` description with the header comment. 4-lens
  review + per-finding refute (8 agents): **1 CONFIRMED / 3 refuted.** CONFIRMED
  (doc-fidelity): the minted D33 was un-registered in this plan SSOT (the
  fragment header names it the D# source) and STATE(15) mislabeled the fix
  "(D32)" — both fixed here (this entry + the "(D32)"→"(D33)" correction). 3
  refuted: an ordering-test nice-to-have (guards a nonsensical
  `KIRO_MEMORY_FORCE=0` config; sibling tests are presence-only by convention);
  "plan-doc live status still says B un-landed" (out-of-scope for the feat
  commit — handled in the S16 docs(plans) update: Status + STATE
  - D33 + S16); the Manual `description` "fallback" wording (cosmetic — fixed
    anyway as self-introduced asymmetry). The user chose B over the HITL
    consumer flip (A), which stays the sole remaining item (user-gated).
- **D34 (S17, 2026-07-14):** **pgvector HNSW-dimension race fixed in the
  openmemory-mcp MODULE.** On a fresh Postgres DB the 9af0f95 daemon creates
  `openmemory_vectors(v vector)` (no dimension) then builds an HNSW index →
  pgvector rejects it; a persistent daemon races the ai-pg bootstrap and can win
  with the undimensioned table, breaking ALL openmemory writes. Added a
  `settingsToPreStart` service-schema hook wired as the fleet systemd
  `ExecStartPre` (`packages/mcp-services/modules/homeManager`); `openmemory-mcp`
  implements it (postgres+http): wait for PG, `createdb` if missing, pre-create
  the dimensioned `openmemory_vectors(v vector(<vecDim>), … project_id)` before
  ExecStart. Module-eval `module-openmemory-pgvector-prestart`. Committed+pushed
  `58536a4c`. Lesson (memory `no-manual-masking-activation`): first mis-fixed by
  a manual DROP+recreate that MASKED whether activation works — the right fix is
  declarative + re-activate from the FRESH/broken state.
- **D35 (S17, 2026-07-14):** **kiro v3 hooks are WORKSPACE-local + must be REAL
  files (docs-confirmed).** v3 discovers hooks ONLY under the launch cwd's
  `.kiro/hooks/`, never global `~/.kiro/hooks/` (kirodotdev/Kiro
  #5440/#7737/#9075; only steering + skills load globally), AND its `read_dir`
  scan SKIPS store symlinks. So the HM global `ai.kiro.hooks` install never
  loads under v3, and devenv `files.*` symlinks don't either. S13 "passed" only
  because its harness used PROJECT-LOCAL REAL files — the global HM path was
  never exercised. Memory `kiro-v3-hooks-workspace-local`. Consequence → D36.
- **D36 (S17, 2026-07-14):** **devenv writes kiro hooks as REAL files via
  enterShell (not `files.*`).** `packages/kiro-cli/lib/mkKiro.nix` devenv branch
  now emits inline hooks + hooksDir via `enterShell`
  (`install -m 0644 <writeText> .kiro/hooks/<name>.json`); steering/agents stay
  symlinks. module-eval: `enterShell` added to the devenv stub;
  HM↔devenv-parity + devenv-writes-hooks tests adapted (parity is now
  by-construction — HM emits the JSON verbatim, devenv installs the same content
  as a real file). Fragment + tracked router updated. Hooks LOAD live in-repo
  (user-confirmed). Committed local `e73972a5`. Delivery for NON-nix repos
  (per-workspace symlink→copy) → next memory living plan.

## Session log (append-only)

- **Session 1 — 2026-07-11.** Research via a 3-phase workflow (map local memory
  systems, research kiro caps / MCP-memory failures / memory patterns,
  adversarial verify, synthesize) + two standalone agents (RAG query-surface
  ROI; config-parity remap). The workflow itself later crashed
  (`StructuredOutput` retry-cap on the kiro-native-capabilities agent — an
  over-rigid schema on my part), so the **primary-docs verification of kiro's
  runtime hook behavior was not obtained** — this is precisely why Q1/Q2 are
  deferred to an empirical binary test rather than trusting docs. Four agents
  completed cleanly and fed the synthesis captured above (F0–F6). Wrote this
  plan. **Next:** empirical hook tests (Q1–Q4).

- **Session 2 — 2026-07-11.** Ran the empirical hook probes **self-serve**
  against `kiro-cli 2.11.1` in a throwaway scratch git repo via
  `kiro-cli chat --no-interactive [--v3] [--agent memtest] --trust-all-tools "<prompt>"`
  (auth already handled by user; no wall hit). Findings:
  - **Invocation:** `--no-interactive` + a positional prompt works; stdout = the
    model reply only, logs on stderr. `--v3` selects the "Kas" engine, which
    **spawns an ACP subprocess for non-interactive** sessions.
  - **Steering READ:** project-local `.kiro/steering/mem.md`
    (`inclusion: always`) injected its sentinel on **v2 AND v3** → Q3 confirmed.
  - **Standalone `.kiro/hooks/*.json` (PascalCase):** fired nothing on v2 or v3
    non-interactive.
  - **v2 embedded enum** (forced from the binary's own validator by feeding
    `kiro-cli agent validate` a bogus trigger):
    `agentSpawn, userPromptSubmit, preToolUse, postToolUse, stop`.
  - Built an agent via `kiro-cli agent create` with embedded
    `agentSpawn`/`userPromptSubmit`/`stop` hooks; ran with `--agent memtest`:
    **v2 (default / `--agent-engine v2`)** — all three fired; agentSpawn +
    userPromptSubmit **stdout injected** (Q1=yes); stop non-blocking,
    `nohup … &` child **survived exit** (Q2=yes); reproduced. **v3 (`--v3` /
    `--agent-engine v3`)** — none fired; only steering injected. → engine is the
    discriminator.
  - **User pasted the kiro.dev CLI 3.0 docs**, which resolved the v3 silence:
    (a) classic non-TUI mode is unsupported for v3; (b) workspace-trust gates
    `.kiro/hooks`+`.kiro/agents`; plus the v3 standalone hook schema (matches
    `mkKiro.nix`), the 2.x→3.0 trigger mapping, `Stop` = _session-end_, and
    `--trust-all-tools` removal.
  - Q1–Q4 answered (see Open questions). Staged a **v3 standalone-hook fixture**
    in the scratch repo for the user-assisted trusted-TUI probe. **Next:** Part
    A (v3 TUI hook confirmation, Q5–Q8), then Part B (impl plan).
  - **Fixture regen** (empty scratch git repo; `S` = abs scratch path): create
    `.kiro/steering/mem.md` (`---\ninclusion: always\nname: mem\n---`, body =
    `sentinel KIRO_STEER_SENTINEL_a17c`) and `.kiro/hooks/mem.json`
    (`{version:"v1", hooks:[…]}` with triggers `SessionStart` /
    `UserPromptSubmit` / `Stop`; each `action.type="command"` doing: `printf`
    its sentinel to stdout, append `$S/v3-fired-<Trigger>.log`, and
    `timeout 10 cat > $S/v3-<Trigger>-stdin.json`).

- **Session 3 — 2026-07-11.** **Part A** executed: user-assisted **v3
  trusted-TUI hook probe** in the staged scratch fixture (user launched bare
  `kiro-cli`; their wrapper injects `--v3 --tui`). No workspace-trust prompt
  appeared; `/hooks` listed all three standalone hooks (loaded). All results
  read **self-serve** from the side-effect logs, stdin captures, and the on-disk
  session store:
  - **Q5 = yes.** `SessionStart`/`UserPromptSubmit`/`Stop` all fired; each
    hook's stdout injected into context (model echoed
    `KIRO_V3_SS_SENTINEL_11aa`, `KIRO_V3_UPS_SENTINEL_22bb`,
    `KIRO_STEER_SENTINEL_a17c` on turn 1). `SessionStart` fired on the **first
    turn**, not at the welcome screen (loaded ≠ fired).
  - **Q6 = per-turn.** `UserPromptSubmit` 2 fires, `Stop` 2 fires (one per
    turn); quit added no `Stop`. No session-end hook exists. → debounce
    required; **supersedes D8** (see D11).
  - **Q7 = metadata only.** stdin = `{session_id, hook_event_name, cwd}`; UPS
    `prompt` empty. Transcript on disk at
    `~/.kiro/sessions/<hash>/<session_id>/messages.jsonl` (22-line typed-event
    JSONL; contains `promptTurnSummaries` — kiro's own per-turn summaries, a
    candidate distillation input for Part B).
  - **Q8 = no trust gate for hooks.** No prompt, no `~/.kiro/workspace-roots/`,
    hooks ran ungated.
  - **Turn-2 refinement (D14):** the model lost the `SessionStart` sentinel by
    turn 2 → SessionStart stdout is one-shot; UPS stdout per-turn; steering
    durable.
  - **Fixture note:** the Session-2 scratch fixture survived on disk (the
    "rebuild in a fresh session" caveat was over-cautious for this tmp path);
    reused as-is. Flag check: `chat` accepts `--v3` / `--agent-engine v3` /
    `--mode` / `--tui`; a bare wrapped `kiro-cli` already selects v3+TUI.
  - **Next:** Part B — implementation plan against real `mkKiro.nix` option
    paths.

- **Session 4 — 2026-07-11.** Resolved openmemory TRANSPORT + ISOLATION (the
  archive tier's real dependencies), triggered by the user's ask to move
  openmemory off per-subagent stdio (RAM bomb). Method: grounded reads of the
  openmemory-js source (CaviraOSS/OpenMemory @ 9af0f95) via github MCP + a
  4-grounder/adversarial research workflow + a LIVE probe of the user's running
  MCP fleet.
  - **The workflow's central conclusion was WRONG for 2.11.1 and I caught it
    empirically.** It concluded (from kiro issue #8151 + the stale
    `project_mcp_proxy_kiro2_auth_gap` memory, both kiro 2.0/2.2) that kiro
    rejects no-auth HTTP MCP → recommended a thin stdio shim (Option C). But the
    user's LIVE config has 4 working `type=http` servers; `curl` proved each
    404s the OAuth well-knowns and answers a no-auth `POST /mcp` initialize
    (200). So kiro 2.11.1 ACCEPTS no-auth HTTP MCP (D15) → the shim is
    unnecessary; a native `opm serve` daemon is the answer (Option B). Lesson:
    live config beats stale GitHub issues.
  - Read auth.ts/index.ts/mcp.ts/memory.ts/tenant.ts/cfg.ts to settle the auth +
    isolation model (D16–D20). Confirmed `serve` mounts native `POST /mcp`; auth
    is fail-closed 503 without a key BUT `OM_DEV_ALLOW_NO_AUTH=true` gives a
    single `dev-no-auth` tenant (stdio-equivalent); REST lacks `project_id`
    (SDK/MCP only); `project_id` gives soft per-project isolation with a
    `system_global` tier.
  - User decisions: no-auth localhost daemon (mode 1); SOFT per-project
    isolation keyed on the worktree-shared canonical repo root (share memory
    across worktrees of one repo). Part B written design-complete. **Next:**
    implementation, checkpointed, starting with the Q9 live test.
  - Corrected the stale `project_mcp_proxy_kiro2_auth_gap` memory (2.11.1
    change).

- **Session 5 — 2026-07-11.** Executed **Checkpoint 0 (Q9)** — the residual
  gate. Method, all self-serve (no real config touched; scratch daemon + probe
  scripts cleaned up afterward): a scratch `opm serve` daemon (the npx-cache
  `opm` binary, `OM_DEV_ALLOW_NO_AUTH=true`, synthetic embeddings, default
  sqlite, port 19911) + the REAL MCP SDK client
  (`StreamableHTTPClientTransport`) + raw curl + reading the installed
  `dist/src` and upstream `main` via github MCP.
  - **First result (misleading):** `initialize` 200 no-auth (well-knowns 404,
    matches the 4 kiro-working http servers), but `notifications/initialized`
    and `tools/list` both 500. Root-caused in `src/ai/mcp.ts`: ONE shared
    `StreamableHTTPServerTransport` (`sessionIdGenerator: undefined`) connected
    once and reused — breaks after the first request.
  - **User pushback** ("one turn isn't enough evidence; search
    docs/issues/flags?") → I checked: (a) NO serve flag toggles the transport
    (`serve` parses zero flags; port is `OM_PORT`-only; README's own mcp example
    is buggy — wires `serve` as a stdio `command`); (b) npm `latest` = 1.3.3
    (2026-01-27) = the broken code; (c) upstream `main` **rev 9af0f95 — which
    our overlay already pins — FIXES it** (fresh transport+server per request;
    also adds `openmemory_store_project` + `project_id`, absent in 1.3.3).
  - **A/B proof** (self-contained: real SDK client + real SDK server transport,
    no DB, no nix): `shared`→FAIL (reproduces the exact "Error POSTing to
    endpoint" 500), `per-request`→PASS (lists tools). Confirms the diagnosis AND
    the fix empirically.
  - **RAM:** 15 live openmemory procs / 1,190 MB (~90 MB per `opm mcp` child,
    from subagent fan-out) → 1 daemon / 86 MB (~93% / ~1.1 GB saved).
  - **Corrected conclusion:** native `opm serve` `/mcp` is VIABLE (D16/D17
    stand), but the stdio→http flip is ALSO a version bump — the daemon MUST be
    our nix pkg (rev 9af0f95), never `npx openmemory-js serve` (1.3.3, broken).
    Recorded as D21; opened Q10 (tenant vs `user_id` under http no-auth) + Q11
    (1.3.3→9af0f95 DB migration). Empirical confirm of OUR built serve deferred
    to Ckpt 1 (local eval OOMs this host).
  - **User direction (end goal, recorded in "End-goal architecture"):** a custom
    typed `autoMemory` setting that synthesises the whole rig, with a PLUGGABLE
    backend as a lambda (openmemory now; a Claude-`.remember`-style markdown
    backend later) — sequenced AFTER the technical limits are mapped.
  - **Next:** Checkpoint 1 — the native-HTTP openmemory server module in
    `services.mcp-servers`, starting with the deferred
    `nix build .#openmemory-mcp`
    - real-client handshake confirmation.

- **Session 6 — 2026-07-11.** Executed **Checkpoint 1** (native-HTTP openmemory
  module) + closed the deferred Q9 confirm on our actual nix artifact. All
  self-serve (scratch daemon + probe scripts, cleaned up; no nixos-config /
  ~/.kiro touched):
  - **Recon first.** Read the real option surface
    (packages/openmemory-mcp/modules/mcp-server.nix, the `services.mcp-servers`
    fleet, lib/mcp.nix `mkHttpEntry`/`effectiveEnv`, lib/ai/mcpServer/\*, the
    nixos-mcp native-HTTP reference). Finding: the fleet ALREADY wires
    openmemory as native-HTTP; the only gap for D18 was the missing
    `OM_DEV_ALLOW_NO_AUTH` knob (grep across the repo returned zero hits). B0's
    framing overstated the work.
  - **Empirical confirm (deferred Q9) — PASS on OUR built package.** The built
    output wasn't in the store but the `.drv` was (from a prior eval), so
    realised it via
    `nix build /nix/store/…-openmemory-mcp-1.3.3+9af0f95.drv^out` — NO flake
    eval (this host OOMs on flake eval, and a live kiro TUI + ~7 `opm mcp` procs
    were eating RAM). It substituted the exact CI/cachix output
    `nnd6fka…-openmemory-mcp-1.3.3+9af0f95`. Drove its `openmemory-mcp-serve`
    under `OM_DEV_ALLOW_NO_AUTH=true` (synthetic embeddings + scratch sqlite, no
    ollama/postgres) with a REAL MCP SDK client
    (`StreamableHTTPClientTransport`) + curl: OAuth well-knowns 404/404, no-auth
    `initialize`→200, `tools/list`→7 tools INCL. `openmemory_store_project`
    (absent in 1.3.3); serve.log confirms
    initialize→notifications/initialized→tools/list with NO 500s.
  - **Change (nix-agentic-tools):** typed `devAllowNoAuth` (`nullOr bool`) →
    http-gated `OM_DEV_ALLOW_NO_AUTH`; + 2 module-eval tests
    (`mcp-services-openmemory-devallownoauth`,
    `mcp-services-openmemory-http-entry`). Fixed the description to plain-prose
    house style (conventions nit).
  - **Verify before land:** lib-only targeted `settingsToEnv` eval (proved the
    emission + the stdio/default gates) + a 3-agent adversarial workflow. The
    propagation agent flaked (stub summary "test"); I answered its questions by
    hand (no README/doc staleness, cspell clean, tests added). treefmt clean,
    both files parse.
  - **Next:** Checkpoint 2 (v3 hook set + debounced distiller + optional
    `openmemory-mem` SDK helper). User may do a SAFE live daemon smoke on
    nixos-config (throwaway store); the FULL flip against real ai-pg stays gated
    on Q11 + Q10.

- **Session 7 — 2026-07-11.** Built **Checkpoint 2, part 1 — the distiller
  core** (`overlays/kiro-memory-distiller/distiller.ts` + tests, bun/TS, 47 TDD
  tests, treefmt + cspell clean, committed d50fae0). FIRST introspected the REAL
  `messages.jsonl` (3 live sessions) and CORRECTED the plan's schema:
  discriminator is `payload.type`, and `promptTurnSummaries` is billing data
  (not a summary) → the B3/D12 reuse shortcut is dead; distillation now derives
  from user + assistant-Say content. TDD'd
  parse/select/deriveProjectId/shouldDistill/format/rollTiers/distill + fs/git
  wrappers
  - a CLI `main()`; validated end-to-end via a subprocess smoke test and against
    a real transcript. Ran a 4-lens adversarial review workflow (correctness /
    schema-fidelity / safety / spec-fidelity) + an adjudicator (9 findings);
    applied 9 fixes, deferred 2 (OR-gate tail-flush; per-project buffer
    lockfile) and declined 2 with reasons. See D23. **Next:** the deferred
    review fixes, the `openmemory-mem` SDK helper, nix packaging of the
    distiller, and the v3 hook + steering nix emission.

- **Session 8 — 2026-07-12.** Landed D24 (the deferred D23a tail-loss fix)
  self-serve on refactor/ai-factory-architecture; the distiller is still
  unwired, so the change is isolated to overlays/kiro-memory-distiller/. TDD
  throughout (watched each test fail first): shouldDistill gate AND→OR +
  flushSessionTails SessionStart scan + `--flush` CLI + lastTranscriptSize state
  field + DRY helpers (58 bun tests, treefmt + cspell clean). Ran a 4-lens
  adversarial review workflow (correctness / concurrency / design / tests) with
  a per-finding refute pass (16 agents, 12 findings, 6 confirmed); fixed the
  3-lens-confirmed watermark re-parse defect + a DRY nit + 2 test gaps before
  landing. User delegated implementation order to the agent (agile working
  increments; most load-bearing otherwise) → encoded a frozen stage order + a
  new protocol bullet into the bootstrap. **Next:** STAGE 2 — nix-package the
  distiller as a derivation.

- **Session 9 — 2026-07-12.** Landed **STAGE 2 — nix-packaged the distiller**
  (D25), self-serve on refactor/ai-factory-architecture; the distiller is now a
  buildable/cachix-able flake package but still unwired (no hook/module consumer
  — that is STAGE 3), so the change is contained to `overlays/` + `checks/`.
  First mapped the repo's bun/TS packaging precedent (openmemory-mcp et al. =
  `makeWrapper ${bun}/bin/bun --add-flags <entry>`, all inputs via `ourPkgs` for
  cache-hit parity), then wrote `overlays/kiro-memory-distiller.nix`
  (stdenvNoCC, dep-free, two role bins, checkPhase = 58 in-sandbox bun tests,
  installCheck smoke) + registered it (flatDrvs auto-flatten, parity allowlist,
  README index). Validated OOM-safely via a targeted single-overlay
  `nix-build --expr` (getFlake inputs only, no flake-output eval) — built clean,
  tests green in-sandbox, both wrappers exit 0. Ran a 4-lens adversarial review
  workflow (build-fidelity / cache-hit-parity / conventions-propagation /
  stage3-readiness) + a per-finding refute pass (6 agents): **0 CONFIRMED, 1
  PARTIAL, 1 REFUTED** — no correctness/parity defect. Adjudicated the PARTIAL
  (dev/data.nix omission) as intentional (internal plumbing, matches the
  claude-code/agnix curation) and folded the refuted-but-real HOME point into
  the S9 STATE block as a STAGE-3 wiring requirement. Also corrected the
  `overlays/default.nix` header comment (now notes the in-repo source pattern).
  **Next:** STAGE 3 — emit the v3 Stop + `--flush` SessionStart hooks + steering
  anchor via `ai.kiro.hooks` / `ai.kiro.rules`, referencing the packaged bins by
  absolute store path (HOME must be exported in the hook action env).

- **Session 10 — 2026-07-12.** Landed STAGE 3 (D27) self-serve on
  refactor/ai-factory-architecture — the first end-to-end auto-memory wiring,
  turning the packaged-but-unwired distiller into referenced-and-emitted hooks +
  steering. First mapped the real option surface (mkKiro.nix hooks/rules
  emission, ai-common ruleModule, the kiro transformer's `inclusion: always`,
  the distiller's HOME/`KIRO_MEMORY_*`/`--flush` contract, the flake's
  `lib.ai.apps` merge), then wrote `packages/kiro-cli/lib/autoMemory.nix` +
  exported it + added 4 module-eval parity tests. Verified OOM-safely (targeted
  `evalModules` + built wrappers for all HOME branches — no flake eval). Ran a
  4-lens adversarial review workflow (schema-fidelity / option-surface /
  distiller-contract / plan-and-nix) + a per-finding refute pass (8 agents): **2
  CONFIRMED, 1 PARTIAL, 1 REFUTED, 1 clean.** The CONFIRMED finding (a
  `home != null` bake would emit `export HOME=''` for an empty-string input →
  silent cwd-relative loss) was FIXED before presenting — always-guard +
  bake-only-non-empty, regression-locked by `empty == unset`. The PARTIAL
  (dangling D27 label) is resolved by recording D27 + annotating B3 in the same
  change. **Next:** STAGE 4 (D23b buffer lockfile) or STAGE 5 (openmemory-mem
  SDK helper) — agent's call; the consumer flip + live-TUI test stay HITL.

- **Interim — 2026-07-12 (post-S9).** Recorded a user backlog item without
  touching code: a comprehensive implementation doc (README/fragment/steering)
  that explains the whole auto-memory system for BOTH an LLM revising it and a
  human, scheduled LAST. Added as FROZEN STAGE 6 + D26 (recommended form = a
  package-scoped architecture fragment; final form + timing owned by the agent
  per the protocol, deferred to after stages 3–5 per the repo's stale-fragment
  doctrine). Plan-only (docs(plans)); no source/module change. **Next
  unchanged:** STAGE 3.

- **Session 11 — 2026-07-13.** Landed **STAGE 4 — the D23b per-project buffer
  lockfile** (D28), self-serve on refactor/ai-factory-architecture; isolated to
  overlays/kiro-memory-distiller/ (distiller.ts
  - tests) + a cspell bump. TDD throughout (watched RED first): `withBufferLock`
    (linkSync O_EXCL mutex + ttl stale-break + `Atomics.wait` backoff,
    injectable clock/sleep) around the shared-buffer RMW; `distill()` returns
    `skipped:"locked"` on timeout. Ran a 4-lens adversarial review workflow
    (concurrency / data-loss / test-fidelity / nix-repo-plan) + a per-finding
    refute pass (10 agents; 2 CONFIRMED, 4 PARTIAL, 0 REFUTED). Fixed both
    CONFIRMED before landing — the medium data-loss regression (locked skip now
    writes a discoverable `.state` stub so `flushSessionTails` rediscovers the
    tail) and the low token round-trip test gap — and adjudicated the 4 PARTIALs
    (corrected the overstated stale-break comment; added garbage-lock +
    round-trip tests; renamed a weak-named test; declined a flaky real-race
    test). 67 bun tests, treefmt + cspell clean, built OOM-safely (67 tests
    in-sandbox). ALSO prepared a turnkey USER-run HITL live-TUI harness (real
    autoMemory hooks JSON built OOM-safely + a shellcheck-clean scratch-config
    setup script). **Next:** STAGE 5 — the `openmemory-mem` SDK helper (agent's
    call next session; run the HITL live-TUI test first per D27).

- **Session 12 — 2026-07-13.** Landed **STAGE 5a — the `openmemory-mem` SDK
  helper binary** (D29), self-serve on refactor/ai-factory-architecture. First
  VERIFIED the real `Memory` SDK API against the pinned 9af0f95 GitHub source
  (via the github MCP) rather than trusting D19/D20 from memory — confirmed
  `add`/`search` accept `project_id` and the SDK path bypasses the HTTP tenant
  layer (so Q10 doesn't bite the helper). TDD (watched RED): a pure
  `parseArgs`/`formatHits`/`normalizeRows`/`runMem` core with the SDK as an
  injected `MemoryBackend` seam (real backend built lazily in the entry, so the
  bun suite never loads dist/PG); CLI matches the distiller's
  `defaultBackendWrite` byte-for-byte. Packaged as the 3rd bin of openmemory-mcp
  (shares dist/ + node_modules → schema lockstep). Verified OOM-safely
  (`nix build <drv>^out`, npmDeps substituted; the checkPhase ran the suite
  in-sandbox + smokes green). Ran a 4-lens adversarial review + per-finding
  refute (8 agents; 0 CONFIRMED, 1 REFUTED — the nix cache-parity claim,
  empirically disproven on Nix 2.34.4 — 3 PARTIAL, all low, all fixed:
  extracted+tested `normalizeRows`, made `trunc` codepoint-aware, and rejected
  flag-shaped `--project-id` values). 30 bun tests, treefmt + cspell clean.
  STAGE 5 split into 5a (done) / 5b (hook wiring, gated on the HITL). Mid-turn,
  the user twice flagged the error-path stderr in the test output as looking
  broken → refactored the error sink to be injected so error-path tests
  CAPTURE + assert the diagnostics (clean output, stronger tests), and recorded
  the guided-HITL preference ([[feedback_hitl_walk_through_live]]). Follow-ups
  (user directives): (a) fixed a repo-wide treefmt footgun the commit surfaced —
  biome AND prettier both formatted every `.ts` (treefmt-nix `includes` APPEND,
  they don't replace) and fought over a `new(...)=>` ctor type →
  `--fail-on-change` looped with an empty git diff; per the user's "prefer
  biome" directive, scoped prettier off JS/TS/JSON/CSS so biome owns them
  (`a49fb03`, zero reformat — all tracked files were already biome fixed points;
  [[feedback_prefer_biome]]); (b) baked "push without asking" into the OPERATING
  PROTOCOL. **Next:** the HITL live-TUI test (USER-run, guided synchronously),
  then STAGE 5b.

- **Session 13 — 2026-07-13.** Ran **the HITL live-TUI test** (D30) — the
  user-run trusted-TUI checkpoint deferred since S3, guided synchronously
  step-by-step ([[feedback_hitl_walk_through_live]]). **All three checks PASSED
  on kiro-cli 2.12.0** (a version bump from the 2.11.1 of S1–S12, so the run
  doubles as re-validation). Agent-side pre-flight (non-interactive, OOM-safe):
  verified the generated `kiro-memory.json` envelope + all three wrappers (HOME
  guard + `KIRO_MEMORY_DIR` redirect + realized distiller bins), then drove the
  stop wrapper as kiro would against a REAL 2.12.0 `messages.jsonl`
  (`distilled:2`) — proving the **D23 parser schema did not drift** and the
  whole write pipeline works on real data, narrowing the live test to the
  closed-binary behaviors alone. Live (user-run): (a) `/hooks` listed **all
  three hooks from the one file** → no split needed; (b) the scratch `.state`
  was keyed on the **live** session id and `now.md` grew with the correct
  distilled turn → Stop fires + delivers stdin
  - the write loop runs end-to-end (turn 2 correctly cooldown-skipped); (c) the
    model quoted the steering anchor's title line → `inclusion: always` injects.
    Switched the harness's printed launch hint to the `kiro-cli chat --tui --v3`
    form actually exercised this session; VERIFIED both that form and the
    launcher form `kiro-cli --v3 --tui` work on 2.12.0 (the launcher still
    exposes `--v3`/`--tui` per `--help-all`), so the original hint was NOT
    broken — [[project_kiro_v3_engine_mode]]'s 2.8.1 launcher semantics still
    hold. (I first mis-claimed the launcher form was stale and corrected it
    fix-forward the same session — verify-before-asserting.) No production code
    changed; the plan + harness-hint updates are self-contained. **Next:** STAGE
    5b — wire `openmemory-mem` onto the hook PATH, add the UserPromptSubmit
    archive-RAG read hook (as a 4th entry in the existing envelope) + the
    `OM_PG*`/`OM_USER_ID` env contract, all in `autoMemory.nix`; the consumer
    flip stays HITL.

- **Session 14 — 2026-07-13.** Landed **STAGE 5b — the READ side + openmemory
  backend wiring** (D31), the FINAL code stage. Brainstormed the one open design
  question ([[superpowers:brainstorming]]) and resolved it to **Option C (hybrid
  recall)**: because the `UserPromptSubmit` stdin `prompt` is empty (D12) and
  `now.md` was never read back into context, the recall hook injects the live
  `now.md` tier (works with the daemon down) PLUS a best-effort openmemory
  archive query seeded by the buffer (lights up post-flip) — the user delegated
  the call ("pick the best, not surgical; log tuning paths"). Built, TDD-first:
  a `--read`/`mainRead` mode + `kiro-memory-recall` bin (mirroring `--flush`),
  `formatRecall` (pure bounded composer) + `recall` + a `BackendQuery` seam
  symmetric with `BackendWrite` (`defaultBackendQuery` shells
  `openmemory-mem query`); the overlay's 3rd bin; and `autoMemory.nix`'s 4th
  hook entry + openmemory-mem-on-PATH + `omEnv`/`omPgPasswordFile` (secret
  runtime-cat, never baked) + a `bakedEnv` password-guard assert. 11 new bun
  tests (80 total) + 2 module-eval checks. **4-lens adversarial review +
  per-finding refute (16 agents, read-only over the captured diff): 0 CONFIRMED,
  9 PARTIAL, 3 REFUTED.** Fixed 8 partials before landing — the standout being a
  medium two-lens catch that my `OM_PG_PASSWORD` guard covered only `omEnv`
  while `bakedEnv = env // omEnv` also bakes `env` (→ guard the merged set);
  plus `formatRecall`'s true char bound + codepoint-safe truncation (the 5a
  surrogate fix), an `archiveLimit` integer-coercion, and test hardening.
  Deferred 1 partial as a post-flip TUNING path (per-turn synchronous
  `openmemory-mem` spawn — inert in the 5b default). De-risked OOM-safely: built
  the overlay (80 tests + 3-bin smoke) + all 6 module-eval checks + drove the
  built recall bin on real data (degraded recent-only AND the archive path with
  a fake helper). **Next:** STAGE 6 — the D26 comprehensive implementation doc;
  the consumer flip stays HITL.

- **Session 15 — 2026-07-13.** Landed **STAGE 6 — the D26 comprehensive
  implementation doc** (D32), the workstream's FINAL stage. Read the whole
  plan + all four code files (`distiller.ts`, `autoMemory.nix`,
  `kiro-memory-distiller.nix`, `openmemory-mem.ts`) + the generator-registration
  mechanics + a template package fragment, then wrote
  `packages/kiro-cli/docs/kiro-auto-memory.md` (~320 lines, end-to-end),
  registered it in `dev/generate.nix` (`devFragmentNames`/`packagePaths`
  `kiro-cli` category), cross-linked `overlays/README.md` (+ fixed a stale test
  count 58→80), and regenerated the router files — verifying the TRACKED Copilot
  output + the gitignored Claude/Kiro mirrors, all OOM-safe via per-derivation
  `instructions-*` builds (no full flake eval; RAM held ~15 GB free). Ran a
  4-lens adversarial review workflow (write-path / read-path / nix-wiring /
  completeness) + a per-finding refute pass (14 agents, 10 raw findings → 5
  CONFIRMED / 5 refuted); fixed all 5, the headline being the
  Manual-`/remember`-does-not-force wiring gap (surfaced, documented as a KNOWN
  GAP, and deferred to the user rather than fixed in this frozen-code doc-only
  session). Pushed. **Next:** the workstream is CODE- + DOC-complete; only the
  HITL consumer flip and the optional Manual-force 1-liner remain, both gated on
  a user decision.

- **Session 16 — 2026-07-13.** Landed **option B — Manual `/remember` forces**
  (D33), closing the one correctness gap the STAGE-6 review surfaced. Resumed
  the (complete) workstream, reconciled the doc's STATE(15) against the live
  repo (branch clean at `b3e9c653`; the S15 commits + 7 merged update PRs
  present; fragment + routers on disk), and confirmed the gap was still real
  (`manualWrapper == stopWrapper`, no `KIRO_MEMORY_FORCE`). Per the user's pick
  of B over the HITL flip (A), fixed it TDD-style: a failing `manual-forces`
  module-eval test first (RED), then parameterized `mkWrapper` with a `force`
  flag so the Manual wrapper bakes `KIRO_MEMORY_FORCE=1` after the baked env
  (GREEN); cat'd the realized wrapper to confirm placement. Closed the gap
  everywhere the fragment documented it + regenerated routers (only
  `.github/instructions/kiro-cli.instructions.md` is tracked; `.claude`/`.kiro`
  mirrors gitignored) + aligned the Manual `mkHook` description. 4-lens
  adversarial review + per-finding refute (8 agents): **1 CONFIRMED** (the
  minted D33 dangled in this plan SSOT + STATE(15) mislabeled it "(D32)" — both
  fixed here) **/ 3 refuted.** De-risked OOM-safely (getFlake-inputs-only
  targeted `nix-build` of the single module-eval check, RED→GREEN; no full flake
  eval). Commits: `feat(kiro-cli)` (code + fragment + tracked router) +
  `docs(plans)` (this doc). Pushed. **Next:** only the HITL nixos-config
  consumer flip (A, Q10/Q11) remains — user-gated; the in-repo code + docs are
  complete.
- **Session 17 — 2026-07-13/14. PLAN CLOSED.** Executed the consumer flip (A) in
  nixos-config: fresh `automemory` Postgres DB in PARALLEL with the legacy
  `openmemory` (model keeps legacy); native-HTTP `openmemory-mcp` daemon →
  automemory; kiro hooks/rules spliced; `omEnv` derived from the daemon's
  `settingsToEnv` (Q11 lockstep). No re-key/migration — the 9af0f95 base schema
  has `project_id` natively on a fresh DB (user chose "fresh parallel DB, retire
  legacy later" over re-keying real data; empirical ai-pg inspection showed the
  dominant existing user_id was `caubut`, not `anonymous`, which the fresh-DB
  path made moot). Hit + fixed a pgvector HNSW-dimension create-race in the
  openmemory-mcp MODULE (D34, `58536a4c`) — after first mis-fixing it by hand
  (recorded the no-manual-masking lesson); proven reproducibly by dropping
  automemory + re-activating (zero manual steps) + a backend add→query
  round-trip. THEN the delivery reality: `/hooks` showed 0 — kiro v3 hooks are
  WORKSPACE-local + REAL-file only (D35; kirodotdev/Kiro #5440/#7737/#9075).
  Fixed the devenv path to write real files via `enterShell` (D36, `e73972a5`);
  hooks now load live in-repo (test-wired via a gitignored `devenv.local.nix`).
  Fragment + router updated; module-eval GREEN. See STATE(17) for the full
  close-out + next steps (a NEW memory living plan the user drafts via the
  living workflow). **Plan CLOSED.**

## Sources

- HyDE — https://arxiv.org/abs/2212.10496 · Step-back —
  https://arxiv.org/abs/2310.06117 · LangChain query transforms —
  https://www.langchain.com/blog/query-transformations
- Conversational query rewriting — https://arxiv.org/abs/2406.18960
- Hybrid + metadata —
  https://www.digitalapplied.com/blog/hybrid-search-bm25-vector-reranking-reference-2026
- mem0 internals — https://docs.mem0.ai/core-concepts/memory-operations ·
  https://github.com/mem0ai/mem0 · https://arxiv.org/abs/2504.19413
- OpenMemory (CaviraOSS) — https://github.com/CaviraOSS/OpenMemory
- Local small-model rewriting —
  https://developers.cloudflare.com/ai-search/configuration/query-rewriting ·
  https://ollama.com/library/qwen2.5
- RAG vs long-context threshold —
  https://www.sitepoint.com/long-context-vs-rag-1m-token-windows/
- MCP tools spec (model-controlled) —
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Reference memory MCP server —
  https://github.com/modelcontextprotocol/servers/tree/main/src/memory
- In-repo — `packages/kiro-cli/lib/mkKiro.nix` (hook schema, options),
  `lib/ai/transformers/kiro.nix` (steering inclusion),
  `lib/ai/app/*Transform.nix`
- kiro.dev CLI 3.0 (Early Access) docs (pasted by user, S2) —
  https://kiro.dev/docs/cli/v3/hooks.md ·
  https://kiro.dev/docs/cli/v3/permissions.md ·
  https://kiro.dev/docs/cli/v3/agent-config.md ·
  https://kiro.dev/docs/cli/v3/feature-overview.md ·
  https://kiro.dev/docs/cli/v3/specs.md · index https://kiro.dev/llms.txt
