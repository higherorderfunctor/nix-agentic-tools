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

── STATE (end of session 2) ──
Empirical hook probes done self-serve against installed kiro-cli 2.11.1: (a) READ
Tier-1 via steering `inclusion: always` WORKS on both v2 and v3, hook-independent
— the load-bearing channel; (b) TWO hook systems — v2 embedded camelCase
(agentSpawn/userPromptSubmit/preToolUse/postToolUse/stop) and v3 standalone
PascalCase `.kiro/hooks/*.json` (the mkKiro.nix target); (c) on v2 all embedded
hooks fire, session-start stdout injects (Q1=yes), stop is non-blocking and
backgrounds survive (Q2=yes); (d) on v3 NO hooks fired non-interactively because
v3 needs a TUI (classic mode unsupported) AND a trusted workspace. Docs correct
the plan: v3 `Stop` fires at session-end with JSON context on stdin.

── NEXT TASK ──
Part A: v3 trusted-TUI hook confirmation (Q5–Q8), USER-ASSISTED (the
non-interactive harness structurally cannot test v3 hooks). A ready fixture is
staged at <scratchpad>/kiro-hooktest (`.kiro/hooks/mem.json` etc.). Ask the user
to run `kiro-cli chat --v3` there, accept the workspace-trust prompt, send two
prompts, and quit; then YOU read the `v3-fired-*.log` / `v3-*-stdin.json`
side-effect files (self-serve) to answer Q5 (hooks fire when trusted), Q6 (Stop
once-per-session vs per-turn), Q7 (Stop stdin transcript contract), Q8 (trust
persistence). See the "Next task" section for exact steps. If scratch is gone,
rebuild from the Session-2 recipe. Then Part B: implementation plan against real
mkKiro.nix option paths.
```

---

## Status

- **Phase:** empirical validation done for the **v2 engine** (single-turn,
  self-serve). The **v3 engine** hook path is gated behind an interactive
  TUI + trusted-workspace run (Q5–Q8) that the self-serve non-interactive
  harness structurally cannot exercise. Implementation plan is next after v3
  confirmation.
- **Branch:** `refactor/ai-factory-architecture`.
- **Installed binary:** `kiro-cli 2.11.1` (store path
  `…4mandd5ra27ggndwk4mqww35g7kzx43z-kiro-cli-2.11.1`). CLI 3.0/v3 is **Early
  Access** in this build (`--v3` / `--agent-engine v3` opt-in).
- **Blocking unknowns:** Q1/Q2 are **answered for v2** (see Q&A below). The
  live-behavior unknown that now gates the WRITE side is **Q6** (does the v3
  `Stop` hook fire, once-per-session or once-per-turn, in a trusted TUI) —
  deferred to a user-assisted interactive run. READ Tier-1 (steering) is
  confirmed working on **both** engines and does not depend on any of this.

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
   small recent-tier buffer. **Verified injecting on both v2 and v3 with no hook
   dependency.** Optional live-refresh: a v3 `SessionStart` **command** hook
   whose exit-0 **stdout is appended to context** (docs) and/or which rewrites
   the steering file from `~/.kiro-memory/{slug}/now.md` before load. The
   `SessionStart` **agent** action type (appends a prompt string, no subprocess)
   is an alternative lightweight inject.
2. **WRITE (v3-native, revised from F5):** a v3 `Stop` **command** hook. Per
   docs `Stop` fires at **session end**, the CLI **waits up to `timeout`
   (default 60s)**, and **hook context arrives as JSON on stdin** — so the hook
   can distill the just-ended session synchronously (no background/debounce
   needed) and write to `~/.kiro-memory/{slug}/` + `openmemory_store` for the
   archive. **Gated on Q6** (once-per-session vs once-per-turn; and confirming
   what the stdin JSON actually contains — does it include the transcript?).
   Keep a `Manual`-trigger `/remember` hook as the deterministic override and
   the fallback if `Stop` is unusable.
3. **ARCHIVE RECALL:** `openmemory` on **stdio**, queried by a
   `UserPromptSubmit` hook (v3: `UserPromptSubmit` command hook, exit-0 stdout →
   context) with a metadata filter — raw prompt, no rewrite.
4. **Skip** the ollama query-rewriter until a need is measured.
5. **Classification** stays out of the shell hook (F5): the `Stop`/`Manual`
   command ships raw turns to `openmemory_store` (`infer=True`) or a cheap
   summarizer; never a steering line asking the model to store.

Store lives outside the nix-managed tree (F6 sidestep). Parity: rides existing
HOOKS/STEERING/MCP emission; no new module axes required for MVP. **v3 caveat:**
workspace `.kiro/hooks` + `.kiro/agents` load only in a **trusted** TUI
workspace, and `--trust-all-tools` is gone under v3 (use `permissions.yaml`).

---

## Open empirical questions (gate the wiring)

These are about the _installed kiro-cli binary's runtime behavior_, which the
repo source cannot answer. **Q1–Q4 were resolved in Session 2** (see answers
inline); **Q5–Q8 are the v3-specific deferrals** that need a trusted-TUI run.

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

**v3-specific deferrals (need a trusted TUI — user-assisted, multi-turn):**

- **Q5 — Do v3 standalone hooks fire at all, in a trusted TUI?** After
  accepting the workspace-trust prompt, does a `SessionStart`/`UserPromptSubmit`
  command hook fire and inject stdout? This separates the "classic-mode
  unsupported" and "untrusted-workspace" gates from any deeper problem.
- **Q6 — v3 `Stop` cardinality (THE write-side linchpin).** Does `Stop` fire
  **once per session** (at quit) or **once per assistant turn**? Determines
  whether the WRITE distiller needs debouncing. Multi-turn by nature.
- **Q7 — v3 `Stop` (and `SessionStart`) stdin contract.** What JSON does the
  hook actually receive on stdin? Does it include the transcript / last turns
  (the distiller's input), or just metadata? Capture with a `cat > file` hook.
- **Q8 — Trust mechanics for automation.** How is workspace trust granted, and
  can it be pre-seeded (e.g. a `~/.kiro/workspace-roots/<hash>/` entry) so a
  packaged setup "just works" without a manual prompt? (Read-only recon only;
  do not write into the user's real `~/.kiro`.)

---

## Next task: v3 trusted-TUI hook confirmation (user-assisted), then impl plan

The self-serve non-interactive probes are done (Session 2). What remains is the
one thing the non-interactive harness **structurally cannot** test — v3 hook
firing in a trusted TUI (Q5–Q8) — followed by writing the implementation plan.
Do these in order.

### Part A — v3 trusted-TUI hook probe (user runs; agent prepares + reads results)

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

### Part B — implementation plan against real `mkKiro.nix` option paths

Once Q5–Q8 are known, write the concrete wiring plan: which `ai.kiro.*` /
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
