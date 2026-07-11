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
> 5. Rewrite the **Bootstrap prompt** to describe the _new_ Next task.
> 6. Commit with a Conventional Commit (`docs(plans): …`). Run
>    `treefmt docs/plans/kiro-cli-auto-memory.md` before committing.

---

## Bootstrap prompt (read first)

```
Resume the kiro-cli auto-memory work. Read docs/plans/kiro-cli-auto-memory.md
in full first — it holds the complete design, decisions, and session history;
you should not need to re-run research.

Current state (end of session 1): research + synthesis complete. Design is
settled pending TWO empirical unknowns about the installed kiro-cli binary
that gate all module wiring (see "Open empirical questions"):
  Q1. Does a kiro `SessionStart` hook's stdout get injected into model context?
  Q2. Does the `Stop` hook fire once per assistant turn, without blocking, and
      can it spawn a surviving background process?

Next task = run the empirical hook tests in "Next task" below. Method (agreed
with the user): a throwaway SCRATCH repo, driven with the shell tool using
kiro-cli NON-INTERACTIVE single-prompt invocations. Discover the exact
non-interactive flag first (`kiro-cli --help`, `kiro-cli chat --help`). The
user has handled kiro-cli auth; if a run still hits an auth/login wall, STOP
and report — do not try to authenticate.

When done: record results in the Decisions log + Session log, update Target
architecture if the results change it, rewrite this Bootstrap prompt to point
at the next task (which will be: turn the §MVP into an implementation plan
against real mkKiro.nix option paths), then commit (docs(plans): …). Keep the
plan additive — mark items done, never delete.
```

---

## Status

- **Phase:** research complete → empirical validation pending.
- **Branch:** `refactor/ai-factory-architecture`.
- **Blocking unknowns:** Q1 (SessionStart stdout injection), Q2 (Stop firing
  semantics). Everything downstream is designed to route around them, but the
  test results will simplify or harden the wiring.

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

---

## Target architecture (MVP)

1. **READ:** an always-loaded `steering/MEMORY.md` (via `ai.kiro.context` or an
   `ai.rules` entry with `paths = null`) holding the small recent-tier buffer,
   refreshed by a `SessionStart` hook that reads `~/.kiro-memory/{slug}/now.md`.
2. **WRITE:** a debounced `Stop` hook running the background-summarizer pattern
   into that buffer + `openmemory_store` for the archive, **plus** a `/remember`
   Manual hook as deterministic override.
3. **ARCHIVE RECALL:** `openmemory` on **stdio**, queried by a
   `UserPromptSubmit` hook with a metadata filter — raw prompt, no rewrite.
4. **Skip** the ollama query-rewriter until a need is measured.

Store lives outside the nix-managed tree (F6 sidestep). Parity: rides existing
HOOKS/STEERING/MCP emission; no new module axes required for MVP.

---

## Open empirical questions (gate the wiring)

These are about the _installed kiro-cli binary's runtime behavior_, which the
repo source cannot answer. They are resolved by the **Next task** tests.

- **Q1 — SessionStart stdout injection (READ).** Does a `SessionStart` hook of
  `action.type = "command"` have its **stdout injected into model context**?
  - If **yes** → hook-stdout is a viable live-refresh channel (can inject
    fresher memory than a frozen steering file).
  - If **no** → the steering `inclusion: always` file is _mandatory_ as the read
    channel (already the plan's default); the hook can only _rewrite that file_,
    not inject directly.
- **Q2 — Stop firing semantics (WRITE).** Does `Stop` fire **once per assistant
  turn**, **without blocking** the UI, and can its command **spawn a background
  process that survives** the turn (for the async summarizer)?
- **Q3 — hook config location & pickup.** Are project-local `.kiro/hooks/*.json`
  picked up in a scratch repo (vs only `~/.kiro/hooks/`)? Does the always-loaded
  `.kiro/steering/*.md` (`inclusion: always`) actually load? (Confirms the F4
  read channel independently of Q1.)
- **Q4 — trigger inventory.** Confirm empirically there is no `SessionEnd`/exit
  trigger, and note any triggers the repo schema comment missed.

---

## Next task: empirical hook tests

**Method (agreed with user):** throwaway **scratch repo**, driven via the shell
tool using **kiro-cli non-interactive single-prompt** invocations. The user has
handled kiro-cli auth. Single non-interactive prompt = one conversation → fires
`SessionStart` once and `Stop` once, which is exactly enough to probe Q1/Q2.

**Step 0 — discover invocation.** Run `kiro-cli --help` and
`kiro-cli chat --help` (the repo wraps the launcher as `kiro-cli-chat`; the raw
binary is `kiro-cli`). Find the non-interactive/headless single-prompt form.
Candidates to check (do NOT assume): `kiro-cli chat --no-interactive "<prompt>"`,
`echo "<prompt>" | kiro-cli chat`, a `--trust-all-tools`/`--no-interactive`
combo. Record the exact working invocation in the Session log.

**Step 1 — Test Q3 + READ channel (steering).** In `scratch/` create
`.kiro/steering/mem.md` with `inclusion: always` frontmatter containing a
distinctive sentinel, e.g. `KIRO_STEER_SENTINEL_a17c`. Run a non-interactive
prompt: _"Reply with only the unusual all-caps sentinel tokens visible in your
current context, comma-separated; if none, say NONE."_ Observe whether
`KIRO_STEER_SENTINEL_a17c` appears. This validates the channel the plan anchors
on, independent of hooks.

**Step 2 — Test Q1 (SessionStart stdout injection).** Add
`.kiro/hooks/mem-read.json` — a `SessionStart` `command` hook that
`echo`s a _different_ sentinel `KIRO_HOOK_SENTINEL_9f3e` to stdout. Re-run the
same echo-the-sentinels prompt. If `KIRO_HOOK_SENTINEL_9f3e` appears →
Q1 = yes; if only the steering sentinel appears → Q1 = no.

- Candidate hook JSON shape (VERIFY against `kiro-cli` schema/docs first — the
  factory comment gives `{version:"v1", hooks:[{name, trigger,
action:{type:"command"|"agent", command|prompt}}]}`):
  ```json
  {
    "version": "v1",
    "hooks": [
      {
        "name": "mem-read",
        "trigger": "SessionStart",
        "action": {
          "type": "command",
          "command": "echo KIRO_HOOK_SENTINEL_9f3e"
        }
      }
    ]
  }
  ```

**Step 3 — Test Q2 (Stop fires, non-blocking, background survives).** Add
`.kiro/hooks/mem-write.json` — a `Stop` `command` hook that appends a timestamp
to `./stop-fired.log` **and** launches a `nohup … &` background process that
sleeps briefly then writes `./bg-survived.log`. Run one non-interactive prompt,
time it (confirm it did not hang), then after exit check: `stop-fired.log`
exists with exactly one line (fired once/turn), and `bg-survived.log` appears
shortly after (background survived the turn). Use strict-mode bash in any hook
script (`set -euETo pipefail; shopt -s inherit_errexit`).

**Step 4 — Test Q4.** From `--help`/any schema output, inventory the accepted
triggers; confirm no `SessionEnd`/exit trigger. Optionally try registering a
bogus `SessionEnd` hook and see if it is rejected/ignored.

**Guardrails.**

- Keep everything in a scratch dir under the session scratchpad or a temp git
  repo; do **not** touch the real repo tree or `~/.kiro/` global config.
- If any run hits an auth/login wall, **STOP and report** — do not attempt to
  authenticate.
- For READ tests, the model may paraphrase; make sentinels highly distinctive
  and ask for verbatim echo. Prefer the file-side-effect signal (Step 3) where
  possible since it does not depend on model cooperation.

**Deliverable:** Q1–Q4 answered with evidence, recorded in Decisions + Session
logs; Target architecture updated (e.g. if Q1 = yes, add hook-stdout live
refresh; if Q2 background does not survive, switch the summarizer to a
fire-and-record-then-next-session-flush design). Then set the next task =
"implementation plan against real `mkKiro.nix` option paths."

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
