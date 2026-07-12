# Kiro-CLI auto-memory

> **What this document is.** A _living_ design + execution plan for giving
> `kiro-cli` persistent cross-session "auto memory" comparable to Claude
> Code's `.remember/` tiered buffer + native `MEMORY.md` systems. Unlike the
> one-shot autonomous plans in this directory, this doc is **maintained across
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
> 5. Rewrite the **Bootstrap prompt** to describe the _new_ Next task, and
>    keep its **Operating protocol** section current with any
>    how-to-function change (the Bootstrap is the single source of truth
>    for how to run a session).
> 6. Commit with a Conventional Commit (`docs(plans): …`). Run
>    `treefmt docs/plans/kiro-cli-auto-memory.md` before committing.

---

## Bootstrap prompt (read first)

```
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
- Session END: (1) update the plan — Session log, Decisions log, Target
  architecture, Open questions, and THIS bootstrap (state + next task + any
  how-to-function change) — treefmt, then commit (docs(plans): …). (2) ALSO emit
  a paste-able handoff prompt in chat for the next round.
- Handoff prompt = convenience pointer to resume + a catch for LATE tuning that
  arrives after you have committed; the doc/bootstrap stays the single source of
  truth and the handoff must not contradict it.
- Logs are append-only (mark done, never delete). Keep experiments in scratch;
  never touch the real repo tree or ~/.kiro global config; on an auth wall STOP
  and report (do not authenticate). `--trust-all-tools` is gone under v3 →
  permissions.yaml.

── STATE (end of session 7) ──
Session 7 (2026-07-11) built CHECKPOINT 2, PART 1: the deterministic Stop-hook
DISTILLER CORE, and CORRECTED the messages.jsonl schema the plan had wrong. All
self-serve; committed to nix-agentic-tools (d50fae0), nixos-config untouched.
- **Landed:** `packages/kiro-cli/memory/{distiller.ts,distiller.test.ts}` (bun/TS,
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

## Status

- **Phase:** empirical validation **complete for both engines** — v2 single-turn
  self-serve (S2) + v3 trusted-TUI user-assisted (S3, Q5–Q8). **No blocking
  unknowns remain for the MVP.** Session 4 (2026-07-11) resolved the openmemory
  transport + isolation questions (D15–D20) and made Part B design-complete; next
  is checkpointed implementation. **Session 5 (2026-07-11) resolved Q9:** native
  `opm serve` `/mcp` works with a real client on our pinned rev 9af0f95 (npm `latest`
  1.3.3 is broken — shared-transport); RAM win ~1.1 GB confirmed; the transport flip
  is also a version bump. **Session 6 (2026-07-11) landed Checkpoint 1:** the
  native-HTTP wiring already existed in the `services.mcp-servers` fleet; added the
  typed `devAllowNoAuth` no-auth knob (+ module-eval tests) and confirmed our built
  `openmemory-mcp-serve` drives a real MCP client (D22). **Session 7 (2026-07-11)
  built Checkpoint 2 part 1 — the distiller core** (bun/TS, 47 TDD tests, committed
  d50fae0) and CORRECTED the messages.jsonl schema (`payload.type` discriminator;
  `promptTurnSummaries` = billing, so the B3/D12 reuse shortcut is dead — D23). Next
  = the deferred review fixes (OR-gate tail-flush + buffer lockfile), the
  `openmemory-mem` SDK helper, nix packaging, and the v3 hook + steering emission.
- **Branch:** `refactor/ai-factory-architecture`.
- **Installed binary:** `kiro-cli 2.11.1` (store path
  `…4mandd5ra27ggndwk4mqww35g7kzx43z-kiro-cli-2.11.1`). CLI 3.0/v3 is **Early
  Access** in this build (`--v3` / `--agent-engine v3` / `--tui` opt-in; a bare
  wrapped `kiro-cli` may already inject these).
- **Blocking unknowns:** none for the MVP. Q1–Q4 (v2) and Q5–Q8 (v3) are all
  answered. The WRITE side is unblocked but **requires a debounced per-turn
  `Stop`** (Q6) whose distiller reads `messages.jsonl` off disk (Q7) — an
  implementation detail, not a blocker. READ Tier-1 (steering) confirmed on both
  engines, hook-independent.

## Goal

Persistent, cross-session memory for `kiro-cli` that works **without relying on
the model choosing to call a tool** — i.e. deterministic, harness-driven, the
way Claude Code's `.remember/` plugin and native project memory already work
for this user. The user has `openmemory` MCP available (already shared into the
kiro tool pool) but reports that system-prompt instructions + openmem alone
"never worked well." The plan explains why and designs around it.

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
  implementation is to move memory onto **deterministic harness injection
  points (hooks/steering)**, "no LLM on the hot path."

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
    enum genuinely has no exit trigger (`agentSpawn userPromptSubmit preToolUse
postToolUse stop` — see F7). But the **kiro.dev v3 hook docs define `Stop`
    as _"Fires when session ends"_**, with a `timeout` (default 60s) the CLI
    waits on and hook context delivered **as JSON on stdin**. So under v3 the
    session-end hook the plan wanted _does_ exist — it is `Stop`. This makes the
    WRITE side simpler than F5 assumed (a synchronous distiller in the `Stop`
    hook, no background/debounce needed) **provided v3 `Stop` fires once per
    session rather than once per turn** — the open question is Q6.
- **kiro hooks in the factory are UNTYPED passthrough (greenfield)** —
  `ai.kiro.hooks` writes whatever raw JSON you author (`mkKiro.nix:316-327`);
  no typed `SessionStart` option yet.
- **Whether a `SessionStart` hook's stdout injects into context is NOT
  verifiable from the repo** (the factory just writes the JSON; runtime
  behavior lives in the closed binary). → **Q1**. Do not bet the read side on
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
    _observed_. Even then use the cheapest transform (conversational
    coreference rewrite) via a warm-kept `qwen2.5:1.5b`, gated so procedural
    prompts skip it. **Never** HyDE/multi-query/step-back here (they solve
    open-domain/multi-hop QA we don't have; HyDE adds 25–60% latency for no
    gain on a corpus you wrote yourself).

### F5 — Write-side design (no SessionEnd): don't classify in the shell

Ranked options:

1. **Debounced `Stop` hook → background summarizer** (autonomous auto-write;
   the direct port of Claude's `PostToolUse`+Haiku). `Stop` fires per turn; gate
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
  structural-by-construction**. `hm.config` vs `devenv.config` do the per-backend
  on-disk emission (the only hand-written parity risk).
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
  - **v3 = standalone, PascalCase**, per kiro.dev docs: `SessionStart Stop
PreToolUse PostToolUse PreTaskExec PostTaskExec UserPromptSubmit
PostFileCreate PostFileSave PostFileDelete Manual` in
    `.kiro/hooks/<name>.json` (`{version, hooks:[{name, trigger, matcher?,
action:{type:"command"|"agent", …}, timeout?, enabled?}]}`). This **matches
    the `mkKiro.nix` schema comment exactly** — the factory's kiro-hook emission
    is aimed at the right v3 target. The docs give the 2.x→3.0 mapping:
    `agentSpawn→SessionStart`, `stop→Stop`, `userPromptSubmit→UserPromptSubmit`,
    `pre/postToolUse→Pre/PostToolUse`, `fileEdited→PostFileSave`,
    `fileCreated→PostFileCreate`; **new in v3:** `PreTaskExec PostTaskExec
PostFileDelete Manual`.
- **v2 answers Q1/Q2 affirmatively.** With an agent carrying embedded
  `agentSpawn`/`userPromptSubmit`/`stop` hooks (run via `--agent memtest`):
  all three fired; `agentSpawn` and `userPromptSubmit` **stdout was injected
  into model context** (sentinels echoed back) → **Q1 = yes**; the `stop` run
  finished in ~8s without hanging and a `nohup … &` child **survived process
  exit** → **Q2 = yes** (non-blocking, background survives). Reproduced across
  repeat runs; `--agent-engine v2` and the no-flag default both fire, proving
  the **engine is the discriminator**.
- **v3 fired NO hooks in the self-serve harness** — neither embedded nor
  standalone. This is explained by **two documented v3 gates**, not by a design
  flaw:
  1. **Classic mode is unsupported for v3.** kiro.dev "Known gaps": _"The
     legacy non-TUI mode (`kiro-cli chat` without the TUI) does not support the
     v3 engine. Use the TUI."_ Our `--no-interactive` path spawns an ACP
     subprocess (`spawning ACP server subprocess for non-interactive session
agent_engine=Kas` in `-vvv` logs) — i.e. exactly the unsupported non-TUI
     path.
  2. **Workspace trust gating.** v3 loads workspace `.kiro/agents/**` and
     `.kiro/hooks/**` **only if the workspace is trusted** (agent-config docs:
     "loaded only if workspace is trusted"). A fresh scratch dir is untrusted;
     `~/.kiro/workspace-roots/` did not even exist. Trust is granted by an
     interactive first-run TUI prompt (no non-interactive trust subcommand
     exists). Steering still loaded because it is not execution-gated.
     → Therefore **v3 hook firing can only be validated in a trusted TUI**
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
targets this. The design degrades gracefully to READ-only if v3 `Stop` turns
out not to fire the way we need (Q6).

1. **READ Tier-1 (confirmed, engine-agnostic — do this first, it is ~80–90% of
   the value):** an always-loaded `steering/MEMORY.md` (via `ai.kiro.context`
   or an `ai.rules` entry with `paths = null` → `inclusion: always`) holding the
   small recent-tier buffer. **Verified injecting on both v2 and v3, every turn,
   with no hook dependency — the durable anchor.** Live-refresh options, now with
   S3-known persistence (D14): a v3 `SessionStart` **command** hook rewrites the
   steering file from `~/.kiro-memory/{slug}/now.md` before load (its own exit-0
   **stdout injects only into turn 1** — one-shot, so use it to rotate the file,
   not to carry durable content); a `UserPromptSubmit` command hook's stdout
   **injects every turn** (the right channel for per-prompt refresh). The
   `SessionStart` **agent** action type (appends a prompt string, no subprocess)
   is an alternative lightweight one-shot inject.
2. **WRITE (v3-native — S3-CORRECTED; reverts to F5's debounce, supersedes the
   session-end simplification of D8):** a v3 `Stop` **command** hook.
   **Empirically (S3) `Stop` fires PER TURN, not at session end, and its stdin is
   metadata-only** (`{session_id, hook_event_name, cwd}` — NO transcript; the UPS
   `prompt` field is empty in 2.11.1). So the hook must (a) **debounce** —
   dirty-flag + cooldown + line-delta so it distills at most every N turns, not
   every turn — and (b) **read the transcript itself** from
   `~/.kiro/sessions/<workspace-hash>/<session_id>/messages.jsonl` (locate by the
   `session_id` on stdin via a path glob; it is typed-event JSONL — filter
   `type:"user"` / `type:"assistant"` between `turn_start`/`turn_end`). Distill to
   `~/.kiro-memory/{slug}/` + `openmemory_store` (`infer=True`). **Candidate
   shortcut:** kiro already writes `promptTurnSummaries` into `messages.jsonl` —
   evaluate reusing those instead of a bespoke summarizer (Part B). **[S7: FALSIFIED — `promptTurnSummaries` is billing data (`usage_summary`), NOT a summary; distill from `user.content` + assistant `Say` instead; records are `{id,payload,timestamp}` keyed on `payload.type`. See D23.]** Run the
   distiller **in the background** off the turn's hot path (v2 proved a
   `nohup … &` child survives exit, Q2). Keep a `Manual`-trigger `/remember` hook
   as the deterministic override + fallback.
3. **ARCHIVE RECALL:** `openmemory` on **stdio**, queried by a
   `UserPromptSubmit` hook (v3: `UserPromptSubmit` command hook, exit-0 stdout →
   context) with a metadata filter — raw prompt, no rewrite.
4. **Skip** the ollama query-rewriter until a need is measured.
5. **Classification** stays out of the shell hook (F5): the `Stop`/`Manual`
   command ships raw turns to `openmemory_store` (`infer=True`) or a cheap
   summarizer; never a steering line asking the model to store.

Store lives outside the nix-managed tree (F6 sidestep). Parity: rides existing
HOOKS/STEERING/MCP emission; no new module axes required for MVP. **v3 caveat
(S3-corrected):** the real gate is **TUI-vs-classic** — v3 hooks fire only in the
TUI (classic / `--no-interactive` is unsupported for v3), but **workspace trust
did NOT gate hook-command execution** (S3: no trust prompt, `workspace-roots`
never created, hooks ran) — so no trust pre-seed is needed for the memory hooks.
`--trust-all-tools` is gone under v3 (use `permissions.yaml`), which gates the
**agent's own tool calls** — a separate axis from hook-command execution.

**Session-4 update (supersedes the "openmemory stdio" assumption in §2/§3
above).** openmemory moves to ONE no-auth HTTP `serve` daemon (D15–D18) sharing
the ai-pg Postgres — the MODEL connects via `type=http` `/mcp` (kiro 2.11.1
accepts no-auth HTTP MCP), killing the per-subagent stdio RAM bomb. The WRITE/READ
hooks reach the SAME Postgres via the in-process `Memory` SDK (D20), scoped by
`project_id` = the worktree-shared canonical repo root (D19), with a `system_global`
tier for cross-cutting. See "Part B — implementation plan" for the full wiring.

---

## End-goal architecture (direction, Session 5 — after the technical limits are mapped)

The MVP/Part B above wires openmemory + hooks + steering directly. The INTENDED end
state (user direction, S5) sits one level up:

- **A custom typed factory setting** (e.g. `ai.kiro.autoMemory` / `ai.autoMemory`,
  fanning out like the rest of `ai.*`) that SYNTHESISES the whole auto-memory rig —
  the steering anchor (B1), the v3 hook set + debounced distiller (B3), the external
  file buffer (B2), and the backend wiring — from ONE declarative switch. It is a
  custom option that **does NOT map 1:1 to a file kiro reads**; it OWNS the
  abstraction and emits the B1–B5 pieces.
- **A pluggable memory backend, expressed as a lambda / small interface.** The
  harness layer (SessionStart rotate, debounced Stop distiller, UPS archive-RAG,
  Manual `/remember`) is backend-AGNOSTIC; only `store` / `query` / `roll` differ per
  backend. Backends are swappable implementations of that interface:
  - `openmemory` (the S4/S5 design: SDK add/query keyed on `project_id`, one HTTP
    daemon for the model) — the first/default backend.
  - a future `markdown` backend (Claude `.remember`-style tiered files only, no
    openmemory) — essentially B2 standalone, for parity with the user's Claude setup.
    This is the FP-composition the user prefers ([[feedback_fp_composition]]):
    parameterise the common hook/steering shape once, pass the backend as the lambda
    that differs. It also means the "which store" decisions (D16–D20) are contained to
    the openmemory backend, not baked into the harness.
- **Sequencing:** this synthesis layer comes AFTER the technical limits are fully
  mapped (Q1–Q11) and the openmemory backend + harness are proven end-to-end. The
  current checkpoints build those concrete pieces; the typed `autoMemory` option and
  the backend-interface extraction are the capstone once the pieces work.

---

## Open empirical questions (gate the wiring)

These are about the _installed kiro-cli binary's runtime behavior_, which the
repo source cannot answer. **Q1–Q4 were resolved in Session 2** and **Q5–Q8 in
Session 3** (the trusted-TUI probe) — all answered inline below.

- **Q1 — SessionStart stdout injection (READ). ✅ ANSWERED: yes.** On **v2**,
  an `agentSpawn` (=v3 `SessionStart`) **command** hook's stdout was injected
  into model context (sentinel echoed back). v3 docs confirm the same by design
  (`SessionStart` exit-0 STDOUT "added to context"). So hook-stdout _is_ a viable
  live-refresh channel — but see Q5 (does it fire in a v3 TUI at all). Steering
  remains the mandatory, hook-independent base channel either way.
- **Q2 — Stop firing semantics (WRITE). ✅ ANSWERED for v2: yes.** v2 `stop`
  fired, run did not hang (~8s), and a `nohup … &` child survived process exit.
  v3 reframes this: docs say `Stop` fires at **session end**, is **non-blocking
  to the model** but the CLI **waits up to `timeout`**, and delivers context as
  JSON on stdin → prefer a synchronous distiller over a background one. Live v3
  behavior = Q6.
- **Q3 — hook config location & pickup. ✅ ANSWERED.** Steering
  `.kiro/steering/*.md` (`inclusion: always`) loads on **both** engines
  (project-local, scratch repo). Hooks: **v2** picks up the agent-embedded
  hooks of the selected `--agent`; **standalone `.kiro/hooks/*.json` is NOT read
  by v2**; **v3** gates workspace `.kiro/hooks` + `.kiro/agents` behind
  **workspace trust** (Q5).
- **Q4 — trigger inventory. ✅ ANSWERED.** v2 embedded enum (from the binary's
  own validator) = `agentSpawn · userPromptSubmit · preToolUse · postToolUse ·
stop` — no exit trigger. v3 standalone set (docs) = 11 triggers incl.
  **`Stop` = session-end** (the exit hook the plan thought was missing) and new
  `PreTaskExec/PostTaskExec/PostFileDelete/Manual`. The `mkKiro.nix` comment's
  PascalCase list matches the v3 docs exactly.

**v3-specific deferrals — ✅ ALL ANSWERED in Session 3 (trusted-TUI probe):**

- **Q5 — Do v3 standalone hooks fire in a trusted TUI? ✅ YES.** All three
  (`SessionStart`, `UserPromptSubmit`, `Stop`) loaded (`/hooks` listed them) and
  fired with **no trust prompt**; each hook's exit-0 **stdout injected into
  context** (the model echoed all three sentinels on turn 1). `SessionStart` fires
  on the **first turn**, not at the welcome screen (loaded ≠ fired). The S2
  non-interactive silence was the **classic-mode-unsupported** gate, not trust.
- **Q6 — v3 `Stop` cardinality. ✅ PER-TURN.** Two prompts produced **two**
  `Stop` fires (end of each turn); quitting added **none**. **v3 has no
  session-end hook** — independently corroborated by the transcript's
  `ContextualHookInvoked` count (5 = 1 SS + 2 UPS + 2 Stop). → the WRITE distiller
  **must debounce** (supersedes D8; see D11).
- **Q7 — hook stdin contract. ✅ METADATA-ONLY.**
  `{session_id, hook_event_name, cwd}`; `UserPromptSubmit` adds an **empty**
  `prompt` field in 2.11.1; **no transcript on stdin**. The transcript is on disk
  at `~/.kiro/sessions/<workspace-hash>/<session_id>/messages.jsonl` (typed-event
  JSONL: `user`/`assistant`/`turn_start`/`turn_end`/`steering_inclusion`/
  `ContextualHookInvoked`/`usage_summary`, plus `promptTurnSummaries`). The
  distiller locates it by the `session_id` from stdin (a path glob avoids needing
  the workspace-hash algorithm).
- **Q8 — Trust mechanics. ✅ NOT REQUIRED for hook commands.** No trust prompt
  appeared, `~/.kiro/workspace-roots/` was never created, and every hook ran →
  command-hook execution is **not** workspace-trust-gated in 2.11.1; the real gate
  is TUI-vs-classic. No trust pre-seed is needed for the memory hooks. (The
  agent's own tool calls remain permission-gated via `permissions.yaml` — a
  separate axis from hook-command execution.)

**Session-4 residual (gates the openmemory transport flip, not the MVP):**

- **Q9 — Does kiro 2.11.1 connect to openmemory `serve`'s native `/mcp`, and how
  much RAM does the daemon save? ✅ ANSWERED (Session 5) — with a version caveat.**
  The transport/auth handshake is version-specific:
  - **Auth/mount CONFIRMED live:** `opm serve` mounts `POST /mcp`; no-auth
    `initialize` → 200 under `OM_DEV_ALLOW_NO_AUTH=true`; both OAuth well-knowns 404
    (matches the 4 kiro-working http servers). D16/D18 hold.
  - **Installed npx 1.3.3 (= npm `latest`) `/mcp` is BROKEN for real clients:** one
    shared `StreamableHTTPServerTransport` (`sessionIdGenerator: undefined`) reused
    across requests → `initialize` 200, then `notifications/initialized` + `tools/list`
    both 500. Reproduced by the real SDK client AND raw curl. A spec client can't get
    past `initialize`.
  - **Upstream `main` (rev 9af0f95 — the rev our overlay pins) FIXES it** with a
    fresh transport+server PER REQUEST (+ adds `openmemory_store_project`/`project_id`).
    A/B with the real SDK client+server: shared→FAIL, per-request→PASS. So our nix
    daemon works; `npx openmemory-js serve` does not.
  - **RAM win:** live 15 procs / 1,190 MB → 1 daemon / 86 MB (~93% / ~1.1 GB).
  - **Net:** native daemon VIABLE; flip = ALSO a version bump (our pkg, not npx).
    **Deferred confirm — ✅ DONE (Session 6, D22):** realised the openmemory-mcp
    `.drv` directly (`nix build <drv>^out`, skips the flake-eval OOM), substituting
    the cachix CI output `nnd6fka…-openmemory-mcp-1.3.3+9af0f95`; a real MCP SDK
    client + curl drove its `openmemory-mcp-serve` under `OM_DEV_ALLOW_NO_AUTH=true`
    → 200 no-auth `initialize`, well-knowns 404, `tools/list` with
    `openmemory_store_project`, no 500s.
- **Q10 — tenant vs `user_id` under HTTP no-auth (9af0f95). ⏳ OPEN (Part B).** In
  9af0f95, HTTP MCP calls carry a `tenant` from `authenticate_api_request`; under
  `OM_DEV_ALLOW_NO_AUTH=true` that tenant is `dev-no-auth`, and `resolve_user_id`
  THROWS `tenant_mismatch` if the MODEL passes a `user_id` ≠ tenant. The hooks use
  the in-process SDK (no tenant → fine, D20), but the model's own
  `openmemory_store`/`_query` calls must OMIT `user_id` (or pass `dev-no-auth`) and
  scope by `project_id` only. Confirm and constrain the steering/banner guidance.
- **Q11 — DB migration 1.3.3→9af0f95. ⏳ OPEN (Ckpt 4).** 9af0f95 adds a
  `project_id` column + the `openmemory_store_project` model; the live ai-pg store
  was written by 1.3.3 (no `project_id`). Verify whether `serve` auto-migrates the
  schema on startup or a manual `ALTER TABLE` is needed, alongside the D18
  `anonymous`→`dev-no-auth` user_id re-key.

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

Each hook (a) echoes a distinctive sentinel to stdout (`KIRO_V3_SS_SENTINEL_11aa`
for SessionStart, `KIRO_V3_UPS_SENTINEL_22bb` for UserPromptSubmit), (b) appends
a timestamped line to `v3-fired-<Trigger>.log`, and (c) captures its **stdin** to
`v3-<Trigger>-stdin.json` (`timeout 10 cat`). If a future session lost the
scratch, regenerate it with the Session-2 python snippet (see Session log for the
exact command; the fixture is trivial to rebuild).

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
- **Line count of `v3-fired-Stop.log`** (1 = once-per-session; 2 = once-per-turn)
  and of `v3-fired-UserPromptSubmit.log` (expect 2) → **Q6**.
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

Transport + isolation are resolved (D15–D20). Below is the concrete wiring against
the real `mkKiro.nix` / `ai.kiro.*` surface. Target the v3 standalone hook format.

#### B0 — openmemory deployment (foundational; fixes the RAM bomb)

- **Daemon.** `pkgs.ai.mcpServers.openmemory-mcp` exposes `openmemory-mcp-serve`
  (`opm serve`). **[S5/D21] Use THIS package (pins rev 9af0f95 — the fixed
  per-request `/mcp` transport + `project_id` tooling). Do NOT use
  `npx openmemory-js serve`: npm `latest` 1.3.3 ships a BROKEN shared-transport
  `/mcp` (initialize 200, then every subsequent request 500s → no real MCP client
  can connect).** Run it as a systemd user service on `127.0.0.1:<PORT>` with:
  `OM_DEV_ALLOW_NO_AUTH=true` (and NODE*ENV unset, no `OM_REQUIRE_AUTH` → single
  `dev-no-auth` tenant, no key — auth.ts), `OM_PORT=<PORT>`, plus the SAME
  `OM_PG*_`/`OM*EMBEDDINGS=ollama`/`OM_OLLAMA*_`/`OM_TIER=deep`/`OM_VECTOR_BACKEND=postgres`/`OM_METADATA_BACKEND=postgres`/`OM_VEC_DIM=768`
  the current stdio entry already uses → same ai-pg Postgres store.
- **nix-agentic-tools change (small, DRY).** Add a native-HTTP `openmemory` server
  module to the `services.mcp-servers` fleet (mirrors nixos-mcp's native mode;
  effect/fetch/gitlab are mcp-proxy `bridge` mode — openmemory does NOT need the
  bridge because `serve` is natively HTTP with `POST /mcp`). It emits
  `mcpConfig.mcpServers.openmemory = { type = "http"; url = "http://127.0.0.1:<PORT>/mcp"; }`
  for the consumer to `inherit`, exactly how effect/fetch/gitlab/nixos are wired.
- **Consumer flip (nixos-config, HITL).** Replace the raw
  `openmemory = { command = "npx"; args = ["-y" "openmemory-js" "mcp"]; … }`
  stdio entry in `ai.mcpServers` with the inherited http entry. One-time Postgres
  re-key so existing stdio-written rows stay visible under the new tenant:
  `UPDATE memories SET user_id='dev-no-auth' WHERE user_id='anonymous';` (repeat
  for `openmemory_vectors` and `temporal_facts`).
- **RAM result.** kiro (and Claude/Copilot) connect to ONE daemon over HTTP;
  subagent fan-outs no longer spawn per-instance openmemory processes.
- **Guardrail.** Bind `127.0.0.1` only; no-auth is safe because it's localhost
  single-user (the stdio setup had no auth either). Ignore openmemory's "dev only"
  warning — it concerns multi-tenant fail-open, irrelevant at one user.

#### B1 — READ Tier-1: steering anchor (engine-agnostic, hook-independent)

- `ai.kiro.rules.<KEY> = { paths = null; text = <anchor>; }` →
  `<configDir>/steering/<KEY>.md` with `inclusion: always` via `kiroTransformer`
  (verified: mkKiro.nix HM 504–516 / devenv 680–692; transformer `paths==null →
"always"`). Use a dedicated `ai.kiro.rules` entry, NOT `ai.kiro.context` (which
  writes the flat frontmatter-less AGENTS.md the user already fills via `rulesDir`).
- This file is an IMMUTABLE store symlink → it holds a STATIC anchor (frames how
  to use memory, states the current `project_id` convention), NOT live content.
  Live content comes from the hooks (B3), never from mutating this file (F6: no
  `outOfStoreSymlink`; store files are immutable — this is why the SessionStart
  hook cannot "refresh" the steering file, only the buffer it reads).

#### B2 — External file buffer (Tier-1 live, hook-independent)

- `~/.kiro-memory/<repo-slug>/` (now.md → recent.md → archive.md), created at
  runtime by the hooks (`mkdir -p`) → sidesteps the missing `outOfStoreSymlink`
  (F6/D4). Faithful port of Claude's file-only `.remember` tiers; works even if the
  openmemory daemon is down. Keyed by the SAME canonical-repo-root slug as
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
- **Stop hook (WRITE, debounced).** Stop fires per-turn (D11), stdin metadata-only
  (D12). The distiller: (a) debounce via a state file (dirty-flag + cooldown +
  line-delta) → distill at most every N turns; (b) locate the transcript by
  `session_id` glob at `~/.kiro/sessions/<hash>/<session_id>/messages.jsonl`;
  (c) distill — **REUSE kiro's own `promptTurnSummaries`** _[S7: FALSIFIED — billing data, not a summary; see D23]_ (jq) as the primary
  distillation (Q7/D12 shortcut), cheap summarizer only as fallback; (d) append to
  the file buffer + roll tiers; (e) write to openmemory via the SDK (B4). Run in
  the BACKGROUND (`nohup … &`; survives exit per Q2) off the hot path.
- **UserPromptSubmit hook (READ archive-RAG).** Per-turn; exit-0 stdout injects
  (D14). Query openmemory for the raw prompt scoped to `project_id=<repo-slug>`
  (+ `system_global`), echo top hits; also cat the recent file-buffer tier.
  Interface tradeoff (B4): SDK for exact project scoping (slower, per-turn bun
  spawn) vs daemon REST for speed (no project filter → broader results) — MEASURE
  and pick; a keyword/synthetic-mode SDK query may be fast enough.
- **SessionStart hook.** stdout is one-shot (turn-1 only, D14) → rotate/refresh the
  buffer + emit a one-time banner naming the current `project_id` so the model can
  pass it to `openmemory_store_project`/`_query`. Not for durable content.
- **Manual `/remember` hook.** Deterministic user-triggered distill+store; the
  reliable fallback.

#### B4 — openmemory access from hooks: the `Memory` SDK, keyed on the worktree-shared repo root

- **project_id derivation (D19).**
  `root="$(dirname "$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir)")"`;
  `project_id="$(basename "$root")"` (or a fuller slug to avoid same-basename
  collisions). `--git-common-dir` returns the MAIN repo's `.git` for every linked
  worktree → all worktrees of a repo share one `project_id` (the user's
  requirement). Non-git cwd → a fallback bucket. Same slug keys
  `~/.kiro-memory/<slug>/` (B2).
- **Why the SDK, not REST (D20).** REST `/memory/add` + `/memory/query` have NO
  `project_id` (routes/memory.ts — only tenant/user*id scoping). Only the
  in-process `Memory` SDK (and the MCP tool layer) accept `{user_id, project_id}`.
  So hook writes/reads use a tiny bun script `import { Memory }` with `OM_PG*\*`env
(→ same Postgres):`add(content,{project_id})`/`search(query,{project_id})`.
The daemon is the MODEL's frontend; hooks go straight to Postgres via the SDK
(same store). Ship an `openmemory-mem`helper binary (SDK add/query) from the
openmemory package, or invoke bun with`NODE_PATH`into its`node_modules`.
- **Model-side scoping.** The daemon can't see the client cwd, so the model's own
  `openmemory_store_project`/`_query` calls are best-effort — inject the current
  `project_id` via the SessionStart banner/steering so the model echoes it. The
  DETERMINISTIC loop is the hooks.
- **Scope split.** repo-specific → `project_id=<repo-slug>`; cross-cutting (prefs,
  coding standards) → `openmemory_store` (`system_global`). A project query returns
  its project + `system_global`, never a sibling project (test_project_isolation.ts).

#### B5 — HM↔devenv parity

- All factory-emitted parts ride existing fanout: steering (`ai.kiro.rules` — both
  backends), hooks (`ai.kiro.hooks` — both), MCP http entry (`ai.mcpServers` — both).
  No new module axis (F6); parity is structural-by-construction. The distiller +
  `openmemory-mem` helper are backend-agnostic packages. The systemd daemon +
  Postgres re-key are HM/nixos-config consumer concerns (a devenv project points at
  the same daemon URL, or degrades to file-buffer-only Tier-1).

#### Residual empirical (Q9) — do FIRST; gates the flip

1. Live-confirm kiro 2.11.1 connects to openmemory `serve`'s native `/mcp`
   (near-certain from the 4 analogues, unconfirmed for openmemory). 2. Measure
   per-subagent openmemory RSS (stdio vs zero-with-daemon) to quantify the win. 3. Confirm stateless `/mcp` + `dev-no-auth` end-to-end (`tools/list` over http,
   no auth header).

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
  `UserPromptSubmit`, and `Stop` all fired, the model echoed their sentinels, and
  `/hooks` listed all three. The Session-2 non-interactive silence was the
  **classic-mode-unsupported** gate, not workspace trust. Answers **Q5 = yes**.
- **D11 (S3):** **v3 `Stop` is PER-TURN, not session-end.** Two prompts → two
  `Stop` fires (end of each turn); quitting added none; v3 has **no session-end
  hook at all** (corroborated by the transcript's `ContextualHookInvoked` count =
  5 = 1 SS + 2 UPS + 2 Stop). This **supersedes D8** — the WRITE distiller **must
  debounce** (dirty-flag + cooldown + line-delta, per F5); it cannot be a
  one-shot synchronous session-end distiller. Answers **Q6 = per-turn**.
- **D12 (S3):** **Hook stdin is metadata-only** (`{session_id, hook_event_name,
cwd}`; `UserPromptSubmit` adds an empty `prompt` in 2.11.1) — no transcript. The
  distiller reads the transcript from
  `~/.kiro/sessions/<workspace-hash>/<session_id>/messages.jsonl`, located by the
  `session_id` on stdin (path glob — no need to reproduce the hash algorithm).
  `messages.jsonl` is structured typed-event JSONL
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
  (durable anchor); `UserPromptSubmit` stdout injects **per-turn**; `SessionStart`
  stdout is **one-shot** (turn 1 only). Read-side roles follow: steering = durable
  buffer, UPS hook = per-turn archive-RAG injection, SessionStart hook = one-shot
  session-open rotation/banner. Reinforces D1/D7.

- **D15 (S4):** **kiro-cli 2.11.1 ACCEPTS no-auth, non-PRM streamable-HTTP MCP —
  SUPERSEDES D5.** Proven live: the user's effect/fetch/gitlab/nixos servers are all
  `type=http` in `~/.kiro/settings/mcp.json`; each 404s
  `/.well-known/oauth-protected-resource` + `/.well-known/oauth-authorization-server`
  and answers a no-auth `POST /mcp` initialize (200). The OAuth 2.1 / RFC 9728 PRM
  gap (`[[project_mcp_proxy_kiro2_auth_gap]]`, kiro issue #8151) was real on kiro
  2.0/2.2 but NOT 2.11.1. openmemory therefore does NOT need to stay stdio for the
  MODEL. Residual live-confirm = Q9.
- **D16 (S4):** openmemory `opm serve` NATIVELY mounts `POST /mcp` (streamable-HTTP,
  stateless, `enableJsonResponse`, same tool surface as stdio) PLUS the REST API
  (`/memory/add`, `/memory/query`, …). So the transport fix is a native HTTP
  daemon; NO shim / mcp-proxy needed (contra the research workflow's Option C,
  which was premised on the now-refuted D5).
- **D17 (S4):** Deploy ONE `openmemory-mcp-serve` systemd user daemon on
  `127.0.0.1:<PORT>` against the SHARED ai-pg Postgres; flip kiro/Claude/Copilot's
  openmemory entry stdio→`{type=http; url=…/mcp}`. Fixes the per-subagent stdio RAM
  bomb (one process for all fan-outs). The ~100MB/instance is Node + pg/ioredis/
  sqlite3 drivers + aws/google/openai SDKs + doc parsers (NOT an embedding engine —
  openmemory embeddings are ollama/remote), amortized once in the daemon. Store is
  Postgres → no SQLite file-contention. Add the daemon via a native-HTTP server
  module in the `services.mcp-servers` fleet (small nix-agentic-tools change).
- **D18 (S4):** Auth mode = **no-auth `dev-no-auth`** (`OM_DEV_ALLOW_NO_AUTH=true`,
  NODE_ENV unset). Single implicit tenant `dev-no-auth`; kiro's http entry needs no
  headers; localhost-only guard. One-time Postgres re-key `anonymous`→`dev-no-auth`
  so existing stdio memories stay visible. (Keyed mode with `OM_API_KEY`+SOPS is the
  alternative if a hard tenant wall is ever wanted — see D19/D20.)
- **D19 (S4):** Isolation = **SOFT per-project via `project_id`**, keyed on the
  **canonical repo root shared across worktrees**
  (`dirname "$(git rev-parse --path-format=absolute --git-common-dir)"` → slug), so
  all worktrees of one repo SHARE memory (user requirement). `system_global` tier
  for cross-cutting. NOT a security wall (same DB/tenant); a HARD work/personal wall
  would need separate keyed daemons/DBs (deferred; not needed now).
- **D20 (S4):** Hooks reach openmemory via the **in-process `Memory` SDK (bun →
  Postgres)**, NOT REST — because REST `/memory/{add,query}` lack `project_id`
  (only the SDK/MCP layer accepts `{user_id, project_id}`). The daemon is the
  MODEL's frontend; the hooks write/read Postgres directly with
  `project_id=<repo-slug>`. Ship an `openmemory-mem` SDK helper binary (or bun +
  `NODE_PATH`). Typed-vs-raw for `ai.kiro.hooks`: keep RAW passthrough, build JSON
  in-module via `builtins.toJSON` (typed hook schema is a separate future refactor).
- **D21 (S5):** **Q9 RESOLVED — native `opm serve` `/mcp` is VIABLE, but version-gated.**
  Empirically (real MCP SDK client + curl, self-serve): (a) `opm serve` mounts
  `POST /mcp` and answers a no-auth `initialize` (200) under `OM_DEV_ALLOW_NO_AUTH=true`
  with both OAuth well-knowns 404 — confirms D16/D18 live; (b) the INSTALLED npx
  `openmemory-js 1.3.3` (= npm `latest`, published 2026-01-27) is **broken for real
  HTTP clients** — its `/mcp` reuses ONE shared `StreamableHTTPServerTransport`, so
  `initialize` 200 then `notifications/initialized`+`tools/list` 500 (a spec client
  can't proceed); (c) upstream `main` **rev 9af0f95 — which our overlay already
  pins — FIXES it** by creating a fresh transport+server per request (comment: "MCP
  SDK 1.27 rejects re-initialization on a single transport instance") and adds
  `openmemory_store_project` + `project_id` (1.3.3 has neither). A/B repro:
  shared→FAIL, per-request→PASS. **Consequences:** the stdio→http flip is ALSO a
  version bump (daemon = our nix pkg `openmemory-mcp-serve`, NEVER `npx …@latest`);
  it carries the D19/D20 `project_id` tooling; and it implies a DB schema change
  (Q11). RAM win confirmed: 15 live procs / 1,190 MB → 1 daemon / 86 MB (~1.1 GB /
  ~93%). Deferred empirical confirm of OUR built serve (`nix build .#openmemory-mcp`
  - real-client drive) is Checkpoint 1's first step (local eval OOMs this host).
    **Lesson (again, per D-note S4): the version you RUN ≠ the source you READ —
    `main`/our-pin had the fix, the npm `latest` did not; the user's "one turn isn't
    enough evidence" pushback caught a premature "serve is broken" conclusion.**
- **D22 (S6):** **Checkpoint 1 landed — the native-HTTP openmemory wiring was
  ALREADY generic; only the D18 no-auth knob was missing.** Recon of the real option
  surface proved the `services.mcp-servers` fleet
  (packages/mcp-services/modules/homeManager/default.nix) already treats openmemory
  as native-HTTP: it is in `serverNames`; its module declares `meta.modes.http =
"openmemory-mcp-serve"` (≠ "bridge"); the generic machinery already generates the
  `mcp-openmemory-mcp` systemd unit running `openmemory-mcp-serve` + all OM\_\* env, and
  emits `mcpConfig.mcpServers.openmemory-mcp = {type=http; url=http://127.0.0.1:PORT/mcp}`
  via `mkHttpEntry` (settings.path default `/mcp`). So B0's "add a native-HTTP module"
  was already done EXCEPT `OM_DEV_ALLOW_NO_AUTH`. Added a typed `devAllowNoAuth`
  (`nullOr bool`, default null) → http-gated `OM_DEV_ALLOW_NO_AUTH` in `settingsToEnv`
  (only meaningful for the http `serve` daemon; stdio has no auth layer) + 2
  platform-independent module-eval tests (option discoverability + native-HTTP
  mcpConfig entry). Verified pre-land: a lib-only targeted `settingsToEnv` eval
  (`import <nixpkgs/lib>`, no flake) → OM_DEV_ALLOW_NO_AUTH="true" for
  {devAllowNoAuth=true} in http mode, absent by default, absent in stdio (gate holds);
  a 3-lens adversarial workflow (conventions PASS_WITH_NITS → fixed the description
  style outlier; correctness PASS, could not refute the systemd-env + url trace incl.
  escapeShellArg→systemd-EXTRACT_UNQUOTE; propagation flaked → answered its cspell /
  module-eval / README questions by hand: no doc staleness, cspell clean, tests added).
  **Empirical Q9 confirm now holds on OUR built artifact** (cachix output `nnd6fka…`,
  real SDK client, `openmemory_store_project` present, no 500s). **METHOD NOTE
  (reusable on this OOM-prone host):** `nix build <drv>^out` on the pre-existing
  on-disk `.drv` builds/substitutes WITHOUT re-evaluating the flake. Consumer flip
  against the real ai-pg store still gated on Q11 (DB schema migration) + Q10
  (tenant/user_id).

- **D23 (S7):** **Checkpoint 2, part 1 — the distiller core landed (d50fae0), + a
  schema correction.** Built `packages/kiro-cli/memory/distiller.ts` (bun/TS, 47 TDD
  tests, real-transcript validated). It is the deterministic Stop-hook write path:
  parse → select undistilled complete turns (execId dedup) → roll the tiered file
  buffer (`~/.kiro-memory/<slug>/` now/recent/archive) → best-effort backend seam →
  persist per-session state. Debounce = line-delta + cooldown; Manual = `force`.
  project_id/slug = D19 (dirname of git-common-dir + path hash; worktrees share).
  - **SCHEMA CORRECTION (supersedes the schema in D12/Q7 + kills the B3/D12
    promptTurnSummaries shortcut):** real messages.jsonl records are
    `{id,payload,timestamp}` with discriminator **`payload.type`** (D12/Q7 wrongly
    listed those values as top-level `.type`). **`promptTurnSummaries` is BILLING
    data** (`[{unit,unitPlural,usage,usedTools}]` inside `usage_summary`), NOT a
    per-turn summary — so distillation must derive from `user.content` +
    `assistant.content where operationType=="Say"` (Reasoning excluded); `usedTools`
    kept as cheap metadata. `user` payloads have no executionId (positional assoc).
  - **Design:** dedup by execId (not line offset) is robust to a turn straddling
    runs; line-count feeds ONLY the debounce gate. Backend is an injected best-effort
    seam; the file-buffer write is unconditional (survives daemon-down, D20).
  - **Adversarial review (4-lens workflow + adjudicator, 9 findings).** FIXED:
    persist state before the backend loop (dup-on-crash), unique atomic-write temp
    names, corrupt-buffer preservation (never silently wipe the warm buffer), backend
    timeout/killSignal, readFileSync + main try-catch, session_id path-traversal
    validation, git-ENOENT warn, turn_start prompt-leak, usedTools dedup. VERIFIED
    against real data that usage_summary DOES carry executionId (reviewer's "usedTools
    dropped" case cannot fire). **DEFERRED (next session):**
    - **(D23a) Tail-loss.** The gate is `enoughNew && cooledDown` (AND). Because v3 has
      NO SessionEnd hook and Stop is per-turn (D11), the LAST turn of a session, if it
      adds < minNewLines lines, is never flushed. FIX: flip to `enoughNew || cooledDown`
      (batch when busy, flush when quiet) AND add a SessionStart hook that flushes the
      PRIOR session's tail; Manual `/remember` is the interim catch. (Changing the gate
      requires rewriting the shouldDistill tests to the OR semantics.)
    - **(D23b) Concurrency.** Concurrent worktree distillers RMW the ONE shared buffer
      (D19) with no lock → last-writer lost-update / corruption. FIX: a per-project
      O_EXCL lockfile mutex (Atomics.wait backoff + stale-break) around the
      loadBuffer→rollTiers→write critical section. (unique-temp + corrupt-preservation
      already reduce the blast radius.)
  - DECLINED (with reason): capping `state.distilled` (unsafe without transcript
    windowing — would re-distill old turns); throttling the no-op re-parse (LOW; n is
    small, interacts with the tail-flush).
  - Language = bun/TS per the user directive; TS turns out to be treefmt-covered
    (prettier), voiding the earlier "TS untooled" concern. cspell terms: cooldown, sess.

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
  `kiro-cli chat --no-interactive [--v3] [--agent memtest] --trust-all-tools
"<prompt>"` (auth already handled by user; no wall hit). Findings:
  - **Invocation:** `--no-interactive` + a positional prompt works; stdout = the
    model reply only, logs on stderr. `--v3` selects the "Kas" engine, which
    **spawns an ACP subprocess for non-interactive** sessions.
  - **Steering READ:** project-local `.kiro/steering/mem.md` (`inclusion:
always`) injected its sentinel on **v2 AND v3** → Q3 confirmed.
  - **Standalone `.kiro/hooks/*.json` (PascalCase):** fired nothing on v2 or v3
    non-interactive.
  - **v2 embedded enum** (forced from the binary's own validator by feeding
    `kiro-cli agent validate` a bogus trigger): `agentSpawn, userPromptSubmit,
preToolUse, postToolUse, stop`.
  - Built an agent via `kiro-cli agent create` with embedded
    `agentSpawn`/`userPromptSubmit`/`stop` hooks; ran with `--agent memtest`:
    **v2 (default / `--agent-engine v2`)** — all three fired; agentSpawn +
    userPromptSubmit **stdout injected** (Q1=yes); stop non-blocking, `nohup … &`
    child **survived exit** (Q2=yes); reproduced. **v3 (`--v3` /
    `--agent-engine v3`)** — none fired; only steering injected. → engine is the
    discriminator.
  - **User pasted the kiro.dev CLI 3.0 docs**, which resolved the v3 silence:
    (a) classic non-TUI mode is unsupported for v3; (b) workspace-trust gates
    `.kiro/hooks`+`.kiro/agents`; plus the v3 standalone hook schema (matches
    `mkKiro.nix`), the 2.x→3.0 trigger mapping, `Stop` = _session-end_, and
    `--trust-all-tools` removal.
  - Q1–Q4 answered (see Open questions). Staged a **v3 standalone-hook fixture**
    in the scratch repo for the user-assisted trusted-TUI probe. **Next:** Part A
    (v3 TUI hook confirmation, Q5–Q8), then Part B (impl plan).
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
  appeared; `/hooks` listed all three standalone hooks (loaded). All results read
  **self-serve** from the side-effect logs, stdin captures, and the on-disk
  session store:
  - **Q5 = yes.** `SessionStart`/`UserPromptSubmit`/`Stop` all fired; each hook's
    stdout injected into context (model echoed `KIRO_V3_SS_SENTINEL_11aa`,
    `KIRO_V3_UPS_SENTINEL_22bb`, `KIRO_STEER_SENTINEL_a17c` on turn 1).
    `SessionStart` fired on the **first turn**, not at the welcome screen
    (loaded ≠ fired).
  - **Q6 = per-turn.** `UserPromptSubmit` 2 fires, `Stop` 2 fires (one per turn);
    quit added no `Stop`. No session-end hook exists. → debounce required;
    **supersedes D8** (see D11).
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
  - **Next:** Part B — implementation plan against real `mkKiro.nix` option paths.

- **Session 4 — 2026-07-11.** Resolved openmemory TRANSPORT + ISOLATION (the
  archive tier's real dependencies), triggered by the user's ask to move openmemory
  off per-subagent stdio (RAM bomb). Method: grounded reads of the openmemory-js
  source (CaviraOSS/OpenMemory @ 9af0f95) via github MCP + a 4-grounder/adversarial
  research workflow + a LIVE probe of the user's running MCP fleet.
  - **The workflow's central conclusion was WRONG for 2.11.1 and I caught it
    empirically.** It concluded (from kiro issue #8151 + the stale
    `project_mcp_proxy_kiro2_auth_gap` memory, both kiro 2.0/2.2) that kiro rejects
    no-auth HTTP MCP → recommended a thin stdio shim (Option C). But the user's LIVE
    config has 4 working `type=http` servers; `curl` proved each 404s the OAuth
    well-knowns and answers a no-auth `POST /mcp` initialize (200). So kiro 2.11.1
    ACCEPTS no-auth HTTP MCP (D15) → the shim is unnecessary; a native `opm serve`
    daemon is the answer (Option B). Lesson: live config beats stale GitHub issues.
  - Read auth.ts/index.ts/mcp.ts/memory.ts/tenant.ts/cfg.ts to settle the auth +
    isolation model (D16–D20). Confirmed `serve` mounts native `POST /mcp`; auth is
    fail-closed 503 without a key BUT `OM_DEV_ALLOW_NO_AUTH=true` gives a single
    `dev-no-auth` tenant (stdio-equivalent); REST lacks `project_id` (SDK/MCP only);
    `project_id` gives soft per-project isolation with a `system_global` tier.
  - User decisions: no-auth localhost daemon (mode 1); SOFT per-project isolation
    keyed on the worktree-shared canonical repo root (share memory across worktrees
    of one repo). Part B written design-complete. **Next:** implementation,
    checkpointed, starting with the Q9 live test.
  - Corrected the stale `project_mcp_proxy_kiro2_auth_gap` memory (2.11.1 change).

- **Session 5 — 2026-07-11.** Executed **Checkpoint 0 (Q9)** — the residual gate.
  Method, all self-serve (no real config touched; scratch daemon + probe scripts
  cleaned up afterward): a scratch `opm serve` daemon (the npx-cache `opm` binary,
  `OM_DEV_ALLOW_NO_AUTH=true`, synthetic embeddings, default sqlite, port 19911) +
  the REAL MCP SDK client (`StreamableHTTPClientTransport`) + raw curl + reading the
  installed `dist/src` and upstream `main` via github MCP.
  - **First result (misleading):** `initialize` 200 no-auth (well-knowns 404, matches
    the 4 kiro-working http servers), but `notifications/initialized` and `tools/list`
    both 500. Root-caused in `src/ai/mcp.ts`: ONE shared
    `StreamableHTTPServerTransport` (`sessionIdGenerator: undefined`) connected once
    and reused — breaks after the first request.
  - **User pushback** ("one turn isn't enough evidence; search docs/issues/flags?")
    → I checked: (a) NO serve flag toggles the transport (`serve` parses zero flags;
    port is `OM_PORT`-only; README's own mcp example is buggy — wires `serve` as a
    stdio `command`); (b) npm `latest` = 1.3.3 (2026-01-27) = the broken code;
    (c) upstream `main` **rev 9af0f95 — which our overlay already pins — FIXES it**
    (fresh transport+server per request; also adds `openmemory_store_project` +
    `project_id`, absent in 1.3.3).
  - **A/B proof** (self-contained: real SDK client + real SDK server transport, no DB,
    no nix): `shared`→FAIL (reproduces the exact "Error POSTing to endpoint" 500),
    `per-request`→PASS (lists tools). Confirms the diagnosis AND the fix empirically.
  - **RAM:** 15 live openmemory procs / 1,190 MB (~90 MB per `opm mcp` child, from
    subagent fan-out) → 1 daemon / 86 MB (~93% / ~1.1 GB saved).
  - **Corrected conclusion:** native `opm serve` `/mcp` is VIABLE (D16/D17 stand),
    but the stdio→http flip is ALSO a version bump — the daemon MUST be our nix pkg
    (rev 9af0f95), never `npx openmemory-js serve` (1.3.3, broken). Recorded as D21;
    opened Q10 (tenant vs `user_id` under http no-auth) + Q11 (1.3.3→9af0f95 DB
    migration). Empirical confirm of OUR built serve deferred to Ckpt 1 (local eval
    OOMs this host).
  - **User direction (end goal, recorded in "End-goal architecture"):** a custom typed
    `autoMemory` setting that synthesises the whole rig, with a PLUGGABLE backend as a
    lambda (openmemory now; a Claude-`.remember`-style markdown backend later) —
    sequenced AFTER the technical limits are mapped.
  - **Next:** Checkpoint 1 — the native-HTTP openmemory server module in
    `services.mcp-servers`, starting with the deferred `nix build .#openmemory-mcp`
    - real-client handshake confirmation.

- **Session 6 — 2026-07-11.** Executed **Checkpoint 1** (native-HTTP openmemory
  module) + closed the deferred Q9 confirm on our actual nix artifact. All self-serve
  (scratch daemon + probe scripts, cleaned up; no nixos-config / ~/.kiro touched):
  - **Recon first.** Read the real option surface
    (packages/openmemory-mcp/modules/mcp-server.nix, the
    `services.mcp-servers` fleet, lib/mcp.nix `mkHttpEntry`/`effectiveEnv`,
    lib/ai/mcpServer/\*, the nixos-mcp native-HTTP reference). Finding: the fleet
    ALREADY wires openmemory as native-HTTP; the only gap for D18 was the missing
    `OM_DEV_ALLOW_NO_AUTH` knob (grep across the repo returned zero hits). B0's
    framing overstated the work.
  - **Empirical confirm (deferred Q9) — PASS on OUR built package.** The built output
    wasn't in the store but the `.drv` was (from a prior eval), so realised it via
    `nix build /nix/store/…-openmemory-mcp-1.3.3+9af0f95.drv^out` — NO flake eval
    (this host OOMs on flake eval, and a live kiro TUI + ~7 `opm mcp` procs were
    eating RAM). It substituted the exact CI/cachix output
    `nnd6fka…-openmemory-mcp-1.3.3+9af0f95`. Drove its `openmemory-mcp-serve` under
    `OM_DEV_ALLOW_NO_AUTH=true` (synthetic embeddings + scratch sqlite, no
    ollama/postgres) with a REAL MCP SDK client (`StreamableHTTPClientTransport`) +
    curl: OAuth well-knowns 404/404, no-auth `initialize`→200, `tools/list`→7 tools
    INCL. `openmemory_store_project` (absent in 1.3.3); serve.log confirms
    initialize→notifications/initialized→tools/list with NO 500s.
  - **Change (nix-agentic-tools):** typed `devAllowNoAuth` (`nullOr bool`) →
    http-gated `OM_DEV_ALLOW_NO_AUTH`; + 2 module-eval tests
    (`mcp-services-openmemory-devallownoauth`, `mcp-services-openmemory-http-entry`).
    Fixed the description to plain-prose house style (conventions nit).
  - **Verify before land:** lib-only targeted `settingsToEnv` eval (proved the
    emission + the stdio/default gates) + a 3-agent adversarial workflow. The
    propagation agent flaked (stub summary "test"); I answered its questions by hand
    (no README/doc staleness, cspell clean, tests added). treefmt clean, both files
    parse.
  - **Next:** Checkpoint 2 (v3 hook set + debounced distiller + optional
    `openmemory-mem` SDK helper). User may do a SAFE live daemon smoke on nixos-config
    (throwaway store); the FULL flip against real ai-pg stays gated on Q11 + Q10.

- **Session 7 — 2026-07-11.** Built **Checkpoint 2, part 1 — the distiller core**
  (`packages/kiro-cli/memory/distiller.ts` + tests, bun/TS, 47 TDD tests, treefmt +
  cspell clean, committed d50fae0). FIRST introspected the REAL `messages.jsonl`
  (3 live sessions) and CORRECTED the plan's schema: discriminator is `payload.type`,
  and `promptTurnSummaries` is billing data (not a summary) → the B3/D12 reuse shortcut
  is dead; distillation now derives from user + assistant-Say content. TDD'd
  parse/select/deriveProjectId/shouldDistill/format/rollTiers/distill + fs/git wrappers
  - a CLI `main()`; validated end-to-end via a subprocess smoke test and against a real
    transcript. Ran a 4-lens adversarial review workflow (correctness / schema-fidelity /
    safety / spec-fidelity) + an adjudicator (9 findings); applied 9 fixes, deferred 2
    (OR-gate tail-flush; per-project buffer lockfile) and declined 2 with reasons. See
    D23. **Next:** the deferred review fixes, the `openmemory-mem` SDK helper, nix
    packaging of the distiller, and the v3 hook + steering nix emission.

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
  `lib/ai/transformers/kiro.nix` (steering inclusion), `lib/ai/app/*Transform.nix`
- kiro.dev CLI 3.0 (Early Access) docs (pasted by user, S2) —
  https://kiro.dev/docs/cli/v3/hooks.md ·
  https://kiro.dev/docs/cli/v3/permissions.md ·
  https://kiro.dev/docs/cli/v3/agent-config.md ·
  https://kiro.dev/docs/cli/v3/feature-overview.md ·
  https://kiro.dev/docs/cli/v3/specs.md · index https://kiro.dev/llms.txt
