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

── STATE (end of session 3) ──
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
Part B: write the implementation plan against the real `mkKiro.nix` / `ai.kiro.*`
option paths (Part A is DONE; no trusted-TUI blocker remains — this is a
desk/design chunk). Cover: (1) the always-loaded steering `MEMORY.md` read-anchor
(`ai.kiro.context` or an `ai.rules` entry with `paths=null`); (2) the v3
`.kiro/hooks/*.json` WRITE — a DEBOUNCED `Stop` command hook (dirty-flag +
cooldown + line-delta, since Stop fires per-turn) that reads `messages.jsonl` by
`session_id` and distills to the external store + `openmemory_store` in the
background, plus a `Manual` `/remember` override; decide typed-vs-raw for
`ai.kiro.hooks` (untyped passthrough today); (3) a `UserPromptSubmit` command hook
for per-turn archive-RAG injection (openmemory stdio, raw prompt); (4) the
external `~/.kiro-memory/{slug}/` store (F6 sidestep — no outOfStoreSymlink);
(5) HM↔devenv parity checks. Evaluate reusing kiro's own `promptTurnSummaries`
instead of a bespoke summarizer. Optionally use a small workflow to draft +
adversarially verify the wiring against the actual option surface.
```

---

## Status

- **Phase:** empirical validation **complete for both engines** — v2 single-turn
  self-serve (S2) + v3 trusted-TUI user-assisted (S3, Q5–Q8). **No blocking
  unknowns remain for the MVP.** Next is the Part B implementation plan.
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
   evaluate reusing those instead of a bespoke summarizer (Part B). Run the
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

### Part B — implementation plan against real `mkKiro.nix` option paths (ACTIVE — the Next task)

Q5–Q8 are now known (Session 3); write the concrete wiring plan: which `ai.kiro.*` /
`mkKiro.nix` options emit the steering `MEMORY.md`, the v3 `.kiro/hooks/*.json`
(`ai.kiro.hooks` untyped passthrough today — decide typed vs raw), the external
`~/.kiro-memory/{slug}/` store (F6 sidestep), and the `openmemory` stdio MCP;
plus HM↔devenv parity checks and the workspace-trust bootstrap (Q8). Target the
v3 standalone format; keep v2 embedded-hook emission only if the user still runs
v2 anywhere.

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
