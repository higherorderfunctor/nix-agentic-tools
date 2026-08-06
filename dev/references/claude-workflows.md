# Claude Code Workflow Tool — Mechanics and Wiring Patterns

Reference for the multi-agent `Workflow` tool in Claude Code, written for a
reader who was not present for the extraction. Sibling of `kiro-workflows.md`
and using its provenance convention.

**Provenance labels.** Every heading that makes a behavioral claim carries one:

- **(Contract)** — transcribed from the `Workflow` / `Agent` tool schemas as
  exposed to a live session of `claude-code 2.1.222`. Not tested unless stated.
- **(Measured)** — established empirically on 2026-08-05 against the
  Nix-packaged `claude-code 2.1.222` binary (x86_64-linux, Bun single-executable
  build), either by byte-offset extraction from that binary or by live probes
  run inside a workflow. Evidence inline.
- **(Inferred)** — a conclusion beyond what was directly observed. Weakest
  class.

## 1. Execution model (Contract)

A workflow is a **plain JavaScript script** (not TypeScript, not JSON — see
§5.1) that the root agent submits inline. The script is the orchestrator:
deterministic control flow (loops, conditionals, fan-out) lives in JS; only the
leaf work is model-driven. The script body runs in an async context with these
globals: `agent()`, `parallel()`, `pipeline()`, `phase()`, `log()`, `args`,
`budget`, `workflow()`.

Runs are **background by default**: the tool call returns immediately with a
`runId` (`wf_…`) and a script path; a task notification fires on completion. The
user watches live progress in the `/workflows` TUI.

Key properties that shape everything else:

- **Agents are one-shot.** Each `agent(prompt, opts?)` call spawns a fresh
  subagent with no memory of any other agent. Its **final text is its return
  value** — the subagent is told it is returning data to a program, not chatting
  with a human. With `opts.schema` (JSON Schema), the runtime forces a
  `StructuredOutput` tool call and `agent()` resolves to the validated object,
  retrying on mismatch.
- **The script is the only bus.** There is no agent-to-agent channel (§3).
- **Determinism is enforced for resume.** `Date.now()`, `Math.random()`, and
  `new Date()` called with no arguments **throw** inside scripts — replay would
  diverge. Timestamps come in via `args`; randomness is faked by varying prompts
  per index. No filesystem or Node API access from the script itself (agents
  have tools; the orchestrating script does not).
- **Every invocation persists its script** under the session directory; the tool
  result names the file. Iteration = edit that file, relaunch with
  `{scriptPath}` (§4.4).

## 2. Primitives (Contract)

| Primitive                    | Shape                                        | Semantics                                                                                                                                                                                                                                  |
| ---------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `agent(prompt, opts?)`       | `Promise<any>`                               | Spawn one subagent. Returns final text, or schema-validated object. Returns `null` if the user skips it mid-run or it dies on a terminal API error after retries — always `.filter(Boolean)` fan-out results.                              |
| `parallel(thunks)`           | `Array<() => Promise<any>> → Promise<any[]>` | Concurrent execution with a **barrier**: awaits all before returning. A throwing thunk resolves to `null`; the call itself never rejects.                                                                                                  |
| `pipeline(items, ...stages)` | `Promise<any[]>`                             | Each item flows through all stages **independently, no barrier between stages** — item A can be in stage 3 while B is in stage 1. Stage callbacks receive `(prevResult, originalItem, index)`. A throwing stage drops that item to `null`. |
| `phase(title)`               | `void`                                       | Groups subsequent `agent()` calls in the progress display. Global state — inside `pipeline`/`parallel` stages use `opts.phase` per agent instead to avoid races.                                                                           |
| `log(msg)`                   | `void`                                       | Narrator line above the progress tree. Use it to surface anything you silently bounded (top-N, sampling).                                                                                                                                  |
| `args`                       | any                                          | The Workflow call's `args` input, verbatim. Pass real JSON values, not stringified JSON.                                                                                                                                                   |
| `budget`                     | `{total, spent(), remaining()}`              | Token target from a user "+500k"-style directive. Hard ceiling: at `spent() >= total`, further `agent()` calls **throw**. Pool is shared across the main loop and all workflows.                                                           |
| `workflow(nameOrRef, args?)` | `Promise<any>`                               | Run another workflow inline as a sub-step (§5.3).                                                                                                                                                                                          |

`agent()` opts: `label` (display), `phase`, `schema`, `model` (default: inherit
the session model — omit unless confident), `effort` (`low`…`max`; `low` for
mechanical stages), `isolation: 'worktree'` (own git worktree, ~200-500ms +
disk, only for parallel file mutation), `agentType` (any registered subagent
type, e.g. `'general-purpose'`, instead of the default workflow subagent;
composes with `schema`).

Every script must open with
`export const meta = {name, description, phases?, whenToUse?}` as a **pure
literal** — no interpolation, no computed values. `phases` titles are
string-matched against `phase()` calls.

## 3. State flow — how "message passing" actually works (Contract)

There is **no peer-to-peer messaging between workflow agents**. All coordination
is value flow through the script:

1. an `agent()` call resolves to a value (text or structured object);
2. the script binds it to a variable;
3. a later prompt is a template literal that **embeds that value**.

That is the entire mechanism. "Writer output reaches the reviewer" means: the
writer's return value is interpolated into the reviewer's prompt string.
"Reviewer feedback reaches the next loop iteration" means: the loop carries a
`feedback` variable and the writer's prompt template includes it. A planner →
loop(writer → reviewer) topology is nothing but:

```js
const plan = await agent(
  `Plan the implementation of: ${args.task}. Return a numbered step list.`,
);

let feedback = null;
let approved = false;
let round = 0;
while (!approved && round < 5) {
  round++;
  const diff = await agent(
    `Implement per this plan:\n${plan}\n` +
      (feedback
        ? `A reviewer rejected the previous attempt. Address every point:\n${feedback}`
        : ""),
    { label: `write:r${round}`, phase: "Loop" },
  );
  const review = await agent(`Review this change for correctness:\n${diff}`, {
    label: `review:r${round}`,
    phase: "Loop",
    schema: {
      type: "object",
      properties: {
        approved: { type: "boolean" },
        comments: { type: "string" },
      },
      required: ["approved", "comments"],
    },
  });
  approved = review.approved;
  feedback = review.comments;
}
```

Consequences worth internalizing:

- **Bandwidth is prompt-sized.** Whatever the writer returns is what the
  reviewer sees. If agents need to exchange large artifacts, have them write
  files (agents have tools) and pass **paths** through the script instead of
  contents.
- **Schemas are the typed edges.** `opts.schema` turns the wire format between
  two agents into a validated contract, with retry-on-mismatch at the tool-call
  layer — use it anywhere a downstream stage consumes fields rather than prose.
- **Loops are the feedback channel.** Iteration count, convergence criteria, and
  what carries over are all ordinary JS. The "graph" the TUI renders is just the
  trace of `agent()` calls the script happened to make.
- **Root-level `SendMessage` is a different mechanism** (Contract): the _root_
  agent can continue a previously spawned `Agent`-tool subagent with its context
  intact. It targets root-spawned agents, not the one-shot agents inside a
  workflow run.

<!-- RECON-SLOT: probe results on whether workflow agents can address each other or the root -->

## 4. Steering and lifecycle

### 4.1 Observation and control (Contract)

- `/workflows` — live progress TUI: phase groups, per-agent lines, narrator
  `log()` output.
- **User skip**: the user can skip an individual agent mid-run; the script sees
  `null` from that `agent()` call and keeps going. Defensive `.filter(Boolean)`
  is what makes fan-outs survive this.
- **Stop**: `TaskStop` with the run's task ID halts the run. Stopping first is
  required before resuming.

<!-- RECON-SLOT: TUI steering mechanics extracted from binary (steer/message individual agents) -->

### 4.2 Failure containment (Contract)

`parallel()` never rejects — a failed thunk is a `null` slot. A throwing
`pipeline` stage nulls that item and skips its remaining stages. A terminal API
failure after retries returns `null` rather than exploding the run. The design
pushes partial failure into data (`null`s you filter) instead of control flow.

### 4.3 Resume — the replay cache (Contract)

Relaunch with `Workflow({scriptPath, resumeFromRunId})`:

- the **longest unchanged prefix** of `agent()` calls (same prompt + opts)
  returns cached results instantly;
- the first edited/new call and everything after runs live;
- same script + same args → 100% cache hit.

`<transcriptDir>/journal.jsonl` records each agent's actual return value — read
it before diagnosing an empty result, and to hand-author a continuation script
when no journal survives (per-agent `agent-<id>.jsonl` files are the fallback).

### 4.4 Edit-and-resume IS dynamic graph surgery (Contract)

The "synthesize nodes incrementally, not all upfront" capability does not need a
special mechanism — it falls out of resume:

1. run a workflow that does the part you know how to plan;
2. read its result;
3. **edit the persisted script file** — append new phases/agents, or rewrite the
   tail;
4. relaunch with `{scriptPath, resumeFromRunId}` — the finished prefix replays
   from cache, the new tail runs live.

Combined with ordinary JS control flow (a `while` loop whose iteration count is
decided by agent output), the node set is dynamic even within a single run: a
loop-until-dry workflow does not know its own node count when it starts.

## 5. Composition and reuse

### 5.1 Saved workflows are `.js` files, not JSON (Measured)

The binary resolves named workflows by joining `.claude/workflows/` + name +
`.js` (adjacent constant strings at ~byte 272.8M; the tool schema's `name` field
reads "built-in or from .claude/workflows/ — resolves to a self-contained
script").

<!-- RECON-SLOT: confirm extension handling from limits-composition agent -->

So "little workflows in JSON, combined by reference" is half right in spirit and
wrong in format: the unit of reuse is a **self-contained JS script** with a
`meta` literal, saved under `.claude/workflows/<name>.js`, parameterized via
`args`.

### 5.2 Three composition mechanisms (Contract)

1. **Registry by name**: `Workflow({name: 'my-saved-flow', args: {...}})` — the
   root agent invokes a saved workflow like a function.
2. **Inline sub-workflow — the actual ref-pointer**: inside a script,
   `workflow('other-flow', childArgs)` (or `workflow({scriptPath}, childArgs)`)
   runs another workflow as a sub-step and returns its return value. The child
   shares the parent's concurrency cap, agent counter, abort signal, and token
   budget; its agents appear as a `▸ name` group in `/workflows`. **Nesting is
   one level only** — `workflow()` inside a child throws.
3. **LLM synthesis**: the root agent authors a fresh script per task. Saved
   workflows are the stable, parameterized building blocks; the synthesized
   outer script is the glue. This is the intended division: templates as
   `.claude/workflows/*.js` + a bespoke orchestration layer written at
   invocation time.

Multi-phase composition across turns is the fourth, degenerate form: run one
workflow, read its output, author the next — the root agent stays in the loop
between phases.

### 5.3 What sharing means for the child (Contract)

Because a `workflow()` child shares the parent's agent counter and budget,
composition does not multiply capacity: a parent near its lifetime cap or token
ceiling starves its children. Plan totals across the whole tree, not per script.

## 6. Limits and scale

### 6.1 The real numbers (Contract; binary confirmation pending)

| Limit                                | Value                                     | Nature                                                           |
| ------------------------------------ | ----------------------------------------- | ---------------------------------------------------------------- |
| Concurrent agents per run            | `min(16, cpu cores − 2)`                  | Scheduling cap — excess calls queue; all still complete          |
| Lifetime agents per run              | 1000                                      | Runaway-loop backstop, far above real workflows                  |
| Items per `pipeline`/`parallel` call | 4096                                      | Explicit error, not silent truncation                            |
| Token budget                         | user-set (`+500k` style), else none       | **Hard ceiling** — `agent()` throws once spent                   |
| Size guideline                       | session-configurable (default ~15 agents) | Guideline, not enforcement; "Dynamic workflow size" in `/config` |

There is **no 18-node graph maximum**. The "node count" a TUI shows is the trace
of agent calls made so far, not a declared graph with a slot limit.

### 6.2 The 6×3 fan-out is one call (Contract)

Six parallel lanes of three sequential agents — 18 agent-runs — needs no
ref-stitching, no synthetic plan, no node surgery:

```js
const lanes = await pipeline(
  args.targets, // 6 items
  (t) =>
    agent(`Analyze ${t}. Return findings as terse markdown.`, {
      phase: "Analyze",
    }),
  (findings, t) =>
    agent(`Deepen the highest-risk finding for ${t}:\n${findings}`, {
      phase: "Deepen",
    }),
  (deep, t) =>
    agent(`Adversarially verify, try to refute:\n${deep}`, {
      phase: "Verify",
      schema: VERDICT,
    }),
);
```

`pipeline` is the default for exactly this shape: lane 1 can be verifying while
lane 5 is still analyzing. Reach for `parallel` between stages only when stage N
genuinely needs _all_ of stage N−1 (dedup across the full set, early-exit on
zero findings, prompts that reference "the other findings").

### 6.3 Budget-scaled fleets (Contract)

```js
const FLEET = budget.total ? Math.floor(budget.total / 100_000) : 5 // static scaling
while (budget.total && budget.remaining() > 50_000) { ... }         // dynamic loop
```

Guard on `budget.total`: with no target set, `remaining()` is `Infinity` and an
unguarded loop runs at the 1000-agent backstop.

## 7. Ad-hoc orchestration from inside a workflow agent

<!-- RECON-SLOT: probe results — Agent/Workflow tool availability inside default and general-purpose workflow agents; blocking vs background; tool-pool deny lists from binary -->

## 8. Bundled workflows

<!-- RECON-SLOT: bundled workflow inventory + deep-research anatomy + coder workflow existence verdict -->

## 9. Pattern cookbook (Contract)

Composable shapes, mix per task. All assume `.filter(Boolean)` hygiene on
fan-out results.

- **Fan-out / fan-in**: `parallel(items.map((i) => () => agent(...)))` then
  reduce in plain JS. The reduce step is code, not an agent — dedup, count, and
  rank without spending tokens.
- **Dedup barrier before expensive verify**: collect all finders with
  `parallel`, dedup by key in JS, then fan out verification only over the
  survivors. The one legitimate barrier.
- **Adversarial verify**: N independent skeptics per finding, each prompted to
  REFUTE, majority vote kills. Prevents plausible-but-wrong findings surviving.
- **Perspective-diverse verify**: same, but each verifier gets a distinct lens
  (correctness / security / repro) instead of N identical refuters — diversity
  catches failure modes redundancy cannot.
- **Judge panel**: N attempts from different angles, parallel judges score,
  synthesize from the winner grafting runner-up ideas. Beats
  one-attempt-iterated when the solution space is wide.
- **Loop-until-dry**: for unknown-size discovery, keep spawning finder rounds
  until K consecutive rounds surface nothing new. Dedup against everything
  **seen**, not everything **confirmed** — else judge-rejected findings reappear
  each round and the loop never converges.
- **Completeness critic**: a final agent asks "what's missing — modality not
  run, claim unverified, source unread?" Its answer seeds the next round.
- **Writer ↔ reviewer loop**: §3's worked example — state threads through loop
  variables.
- **Incremental synthesis**: §4.4 — plan the prefix, run, read, append, resume.

## 10. Not exercised

Claims in this doc labeled (Contract) were transcribed, not tested, except where
a (Measured) note says otherwise. Specifically never exercised while writing
this: `isolation: 'worktree'` agents, `budget` under a real token directive,
`workflow()` nesting-depth enforcement, resume-cache invalidation granularity
(prompt-identity vs opts-identity).
