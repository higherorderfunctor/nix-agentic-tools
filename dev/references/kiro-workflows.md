# Kiro Workflow Engine — Mechanics and Measured Behavior

Reference for adopting the workflow engine in another repository. Written for a
reader who was not present for the experiments.

**Provenance labels.** Every heading that makes a behavioral claim carries one:

- **(Contract)** — transcribed from the `run_workflow` / `validate_workflow` /
  `update_workflow` tool schemas. Not tested unless stated. §12 lists exactly
  which contract claims were never exercised.
- **(Measured)** — established empirically on 2026-07-31/08-01 against
  `kiro-cli 2.16.0`. The evidence is given inline.
- **(Inferred)** — a conclusion drawn from contract text, not observed. Treated
  as the weakest class.

Four container sections (§3, §4, §7, §8) carry no label of their own, because
they deliberately mix classes — read the label on each subsection instead.
Vocabulary (§2), adoption guidance (§11), the untested-claims list (§12) and
methodology (§13) make no behavioral claims and so carry none.

## 1. What this is, and what it is not (Measured)

There is **no `/workflow` slash command**, and no workflow feature in the
official Kiro CLI documentation — not in the slash-command reference, the CLI
command reference, or the built-in tools reference. The workflow system is
**harness-provided**: it exists as tools exposed to the agent, not as a
`kiro-cli` feature.

Consequences for adoption:

- Users cannot invoke it directly. There is no user-facing entry point to teach.
  A user describes work in natural language and the agent decides to use a
  workflow.
- Nothing in `~/.kiro/` configures it, and Kiro does not create a
  `.kiro/workflows/` directory. The agent will run recipes placed there, but you
  must create it yourself.
- Document it to **agents**, via steering, not to users. See §11.

The agent-facing tools are `run_workflow`, `inspect_workflow`,
`update_workflow`, and `validate_workflow`.

## 2. Vocabulary

Terms used throughout, several of which are specific to this document:

| term                 | meaning                                                                         |
| -------------------- | ------------------------------------------------------------------------------- |
| **orchestrator**     | the chat session that calls `run_workflow`. Also "root session", "parent".      |
| **step agent**       | the agent running one `step` node, in its own isolated session                  |
| **recipe**           | a stored workflow definition, referenced by `bundled://` or `generated://`      |
| **worker**           | in the §9 pool pattern, one `repeat` loop containing one `step`                 |
| **task**             | a unit of queued work, represented as a file. Not a workflow node.              |
| **child**            | a task created at runtime by another task ("runtime-discovered work")           |
| **claim**            | a worker taking exclusive ownership of a task, by atomic `mv`                   |
| **drain marker**     | the JSON file a worker writes to signal it found no work left (§9)              |
| **claim ramp**       | elapsed time between the first and last worker claiming its first task          |
| **peak concurrency** | maximum number of simultaneously-open claim→done intervals, by sweep (§13)      |
| **wave barrier**     | a synchronization point where all parallel work must finish before any restarts |
| **no-op iteration**  | a `repeat` iteration the engine ran but whose agent did no work (§7)            |

## 3. Node types and validation

### 3.1 Node types (Contract)

A workflow is
`{ name, description?, inputs?, modelId?, effortLevel?, steps[] }`.

| type       | required fields                                                                               | notes                                                                         |
| ---------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `step`     | `id`, `agent`, and at least one of `prompt` / `input`                                         | optional `artifacts`, `captureOutput`, `completion`, `modelId`, `effortLevel` |
| `repeat`   | `id`, `steps`, `maxIterations` (1–1000), `onMaxIterations`, plus a stop condition (see below) | `onMaxIterations`: `abort` \| `continue` \| `pause`                           |
| `sequence` | `id`, `steps`                                                                                 | ordered                                                                       |
| `parallel` | `id`, `branches`, `joinPolicy`                                                                | `all` \| `allSettled` \| `any`                                                |
| `watch`    | `id`, `handler`, `config`                                                                     | non-LLM polling, e.g. `github-pr`                                             |

**The two tool schemas disagree about whether a `repeat` stop condition is
mandatory.** `run_workflow` says exactly one of `stopCondition` / `stopWhen`,
"not both, not neither". `validate_workflow` says a repeat "may define neither
and rely on `maxIterations`". Both were transcribed here before the conflict was
noticed, and it was not tested. **Safe rule: always supply exactly one** — that
form satisfies both readings.

`stopWhen` is sugar for common `stopCondition` shapes: `"<watchId>.terminal"`,
or `"{{expr}} contains <text>"`.

**Nested workflows are forbidden**: a workflow step cannot start a workflow.

### 3.2 The node cap counts `step` nodes only (Measured)

The limit is **20 `step` nodes per workflow**. `repeat`, `parallel` and
`sequence` wrappers are **free** — they do not count.

Established by validating three shapes without running them:

| shape                                          | step nodes | total nodes | result                                                                  |
| ---------------------------------------------- | ---------- | ----------- | ----------------------------------------------------------------------- |
| 12 workers (`parallel` + 12×(`repeat`+`step`)) | 12         | 25          | valid                                                                   |
| flat `parallel` of 20 plain steps              | 20         | 21          | valid                                                                   |
| flat `parallel` of 21 plain steps              | 21         | 22          | **invalid**: "Workflow has 21 step nodes, exceeding the maximum of 20." |

So a queue-pull pool (§9) can host **up to 20 workers in a single run**, or 19
workers plus an in-workflow verification step. That 19+1 shape was not merely
validated but **run** (§6, §9.4): 19 workers executed concurrently and the
verify step ran after the join. An earlier draft of this document claimed 9
workers per run by wrongly counting `repeat` and `parallel` nodes against the
cap; if you see that figure anywhere, it is wrong.

Other validated limits: 8 levels of nesting, and unique node ids across the
whole tree.

### 3.3 Template variables and artifacts (Contract)

Workflow `inputs` interpolate into prompts as `{{name}}`. Step output is
addressable three ways:

| reference              | meaning                                              |
| ---------------------- | ---------------------------------------------------- |
| `{{previous.output}}`  | the immediately prior **sibling** step               |
| `{{<id>.output}}`      | a named earlier step (also `{{steps.<id>.output}}`)  |
| `{{artifacts.<name>}}` | a path declared in an earlier step's `artifacts` map |

Ordering is enforced at validation: a reference must name a producer that runs
**earlier**. A later sibling, or a concurrent parallel branch, is rejected.
`{{previous.output}}` is rejected inside a stop-condition context, since a stop
condition has no preceding sibling — though a `repeat`'s stop condition may
reference producers inside its own loop body, and a step's `completion` may
reference its own output and artifacts.

`artifacts` map **values** are re-interpolated on every path, fresh runs and
continuations alike, which makes them the correct way to pass an absolute path
between steps. Interpolate a workflow input so the value stays absolute — here
`workdir`, the same input the §11 example declares:

```json
"artifacts": { "plan": "{{workdir}}/.agents/tasks/plan.md" }
```

A downstream step reads `{{artifacts.plan}}` and receives the resolved path. Any
declared input works; if the workflow targets a worktree, pass that worktree's
absolute path as the input and interpolate it here (§8.5).

### 3.4 What validation does and does not check (Contract)

`validate_workflow` **does** check schema conformance, the caps in §3.2, that
every step has at least one of `prompt` / `input`, that a `repeat` does not
define both stop forms, that `stopWhen` watch references resolve to real watch
ids, the ordering rules in §3.3, and that `fileCheck` paths are not provably
outside the workspace roots (§7.1).

It does **not** check agent names, watch handler configs, `modelId`,
`effortLevel`, or bare `{{identifier}}` references — those pass through as
literal text, with at most an advisory server-log warning on a likely typo.
**Passing validation does not mean the run works**: unknown agents and unknown
models both fail at session-creation time.

### 3.5 Step agent roster (Measured, this environment)

The `agent` field names a registered agent mode. **Names must match exactly and
are not validated at authoring time**, so a typo surfaces only when the step's
session is created.

| agent                  | role                                                       |
| ---------------------- | ---------------------------------------------------------- |
| `wf-planner`           | investigation and planning; first step of non-trivial work |
| `wf-design`            | requirements and technical design documents                |
| `wf-design-reviewer`   | reviews a design for gaps; mechanical blocking verdict     |
| `wf-coder`             | implementation — edits, tests, commits                     |
| `semantic_reviewer`    | code review of a diff                                      |
| `wf-review-aggregator` | merges multiple reviews into one verdict                   |
| `wf-pr-submitter`      | opens a pull request from a branch                         |
| `wf-pr-responder`      | responds to PR review comments and CI feedback             |
| `wf-auto-researcher`   | autonomous experiment/benchmark loop                       |
| `wf-workflow-creator`  | builds and saves workflow definitions (see §4.1)           |

Note `semantic_reviewer` uses an **underscore** while every `wf-*` agent uses
hyphens. Since the field is not validated, that inconsistency is a live trap.

`general-task-execution` and `context-gatherer` are **orchestrator-side subagent
modes** for `orchestrate_subagent` (§8), not workflow step agents.

### 3.6 What tools a step agent has (Measured)

Enumerated by a probe whose workflow was a **single top-level `step`** (id
`inventory`, the sole entry in `steps[]`), instructed to list its own tool set.
A `wf-coder` step agent has exactly **ten** tools:

```
disclose_context   execute_bash    file_search   fs_write      grep_search
read_file          report_progress  send_message  str_replace   subagent_response
```

**A step agent cannot delegate.** There is no `orchestrate_subagent`,
`delegate`, `subagent`, `spawn`, or `Task`. Corroborated three ways: the step's
own report, the enumerated list, and the absence of any artifact from the
delegated work (so it also did not quietly perform that work itself).

Combined with the ban on nested workflows (§3.1), a workflow is exactly **two
tiers deep**: the orchestrator, and its step agents. No third fanout tier is
reachable from inside a workflow. Total parallelism is therefore:

```
step nodes per run (≤20)  ×  number of concurrent workflow runs
```

and never multiplied by fanout from within a step.

Two tool names invite confusion and grant nothing: `subagent_response` returns
the step's own result to its parent, and `disclose_context` only loads
skill/steering text — a skill whose text _describes_ spawning reviewers does not
confer any ability to spawn them.

**A `wf-coder` step also has no `update_workflow`**, nor any other workflow
tool. The probed step satisfied the contract's "top-level step agent"
precondition (it was the sole entry in `steps[]`), so this **contradicts** the
contract's claim that such a step may call `update_workflow` with either action.
Do not design a workflow expecting a `wf-coder` step to change its own status or
rewrite the remaining plan.

Note also the absence of any web, knowledge, or todo tooling: a step needing
external fetch or search must run under a different agent. This roster was
measured for `wf-coder` only — verify before relying on another agent's
capabilities.

## 4. Launching and monitoring

### 4.1 Reference forms (Contract, list Measured)

`workflowPath` takes three forms:

- `bundled://<name>` — a recipe shipped with the harness.
- `generated://<id>` — a definition saved by the `wf-workflow-creator` agent.
  **Single-use**: the stored definition is consumed when the run starts, so
  launching the same shape again requires a fresh save. This matters for the
  multi-run pool in §6 — three concurrent runs need three separate saves.
- An absolute path to a `.workflow.json` inside the workspace roots. Unlike
  `generated://`, a path is reusable.

The seven bundled recipes are `autoresearch`, `feature-pipeline`, `goal`,
`investigate`, `publish-pr`, `ralph`, and `semantic-review-multi-model`.

**Verified** against the harness itself: `acp-server.js` — under
`~/.local/share/kiro-cli/kas/*/node_modules/@kiro/agent/dist/server/`, where the
`kas` directory is named `<version>-<64-hex-digest>`, so do not substitute a
bare version number — references exactly these seven `<name>.workflow.json`
files. To re-derive the list on a new version, grep that file for
`[a-z-]+\.workflow\.json`. Beware partial tables elsewhere in the same file:
per-recipe default pairs of the form `["ralph", ralph_workflow_default]`
enumerate a subset and will understate the set.

A name that does not exist fails **immediately and cleanly**, before anything
runs: `no bundled recipe named '<name>'`. Existence is therefore cheap to probe
— but the converse is not safe, because probing a name that _does_ exist starts
it. Do not probe blind in a live repository: `autoresearch` and `ralph` are
autonomous loops that commit.

### 4.2 Keeping the orchestrator conversational (Measured)

`run_workflow` **returns immediately**. It does not block, so the orchestrator
stays responsive for free. The failure mode is self-inflicted: **do not `sleep`
in a shell call waiting for the run.** That is what blocks the session, not the
engine.

The correct pattern is **launch → end the turn → act on the completion
notification.** Completion notifications arrived unsolicited for every run in
this series, and they reach _subagent_ contexts as well as the orchestrator's,
so there is nothing to poll for. While waiting, do other useful work; never
idle.

**A completion notification means finished, not succeeded.** Verified the hard
way (§9.4): a run reported `completed` with every node green while most of its
work sat unprocessed. Always follow the notification with a result check —
`inspect_workflow` for engine state, plus a domain assertion for actual
outcomes.

### 4.3 Step lifecycle is controlled by `send_message` severity (Contract)

When a **workflow step** calls `send_message`, the severity is not cosmetic — it
drives the step's lifecycle:

| severity  | effect on the step                               |
| --------- | ------------------------------------------------ |
| `success` | marks the step completed; the workflow advances  |
| `warning` | **pauses the workflow** and waits for user input |
| `error`   | marks the step failed                            |
| `info`    | informational only, no lifecycle effect          |

`warning` is a load-bearing hazard: a step reaching for it to flag something
non-fatal will halt the entire run pending human input.

**(Measured)** Steps routinely ignore an instruction not to call `send_message`
at all. Every probe here told its worker "Do not call send_message" and dozens
of `[notification/success]` messages arrived regardless. Treat step
notifications as something to tolerate, not something you can switch off by
asking.

### 4.4 Reading engine state (Measured)

`inspect_workflow` returns a status, a captured-output map keyed by step id, and
a node tree. Two shape details matter:

- The engine wraps your definition in an **implicit top-level
  `sequence:wf_<id>`**, even when you declared exactly one node.
- Each `repeat` iteration that ran appears as a wrapper node
  `sequence:<repeatId>#<n>`, zero-indexed. Counting those gives the
  **engine-side iteration count**.

That second point is what makes the silent-skip defect (§7.2) detectable.
Compare the engine-side count against independent evidence the work happened:

```
engine iterations = number of `sequence:<repeatId>#<n>` nodes
real invocations  = number of side-effect records your step actually wrote
no-op iterations  = engine iterations − real invocations
```

A no-op step still reports `[completed]`, so the node tree alone will never
reveal it. **Have every step leave a durable trace if you need to audit this** —
a step that writes nothing cannot be audited this way at all.

## 5. Runtime DAG mutation (Inferred — see §12)

**The conclusion in this section was not tested.** `update_workflow` was never
invoked in this series, and §3.6 shows a `wf-coder` step does not even have the
tool. What follows is read off the contract.

`update_workflow` has two actions:

- `update_status` — set the current step's status (`completed`, `failed`,
  `paused`, `running`). Documented as callable only by a top-level step agent.
- `replace_remaining` — replace **all steps after the currently-running step**.
  Documented as callable by a top-level step agent, or by the orchestrator
  (which can only use this action, having no current step).

The critical semantics: already-executed steps are immutable, and **if a step is
running, the update is queued and applied at the next step boundary.**

It follows — by inference, not observation — that you **cannot add a branch to
an in-flight `parallel` node**: the mutation point is the join. If your goal is
to eliminate wave barriers so freed slots backfill immediately,
`replace_remaining` does not help, because its application point _is_ a barrier.
Every concurrency primitive the engine has (`parallel` plus a join) is a
barrier; `joinPolicy: any` abandons the losers rather than backfilling.

The engine is a **static DAG with future-rewrite**, not a work-stealing
scheduler. §9 is the way to get scheduler-like behavior without fighting it.

## 6. Concurrency (Measured)

Each worker is one `repeat` loop containing one `step`. Multiple workflow runs
launched simultaneously share one filesystem queue.

| workers | runs | model              | tasks (each) | wall   | peak        | claim ramp                         |
| ------- | ---- | ------------------ | ------------ | ------ | ----------- | ---------------------------------- |
| 6       | 1    | `claude-opus-5`    | n/a (25 s)   | 49.7 s | **6 / 6**   | 26 ms                              |
| 9       | 1    | `claude-opus-5`    | 15 (3 s)     | 27.2 s | **9 / 9**   | 540 ms                             |
| 18      | 2    | `claude-opus-5`    | 23 (15 s)    | 54.5 s | **18 / 18** | 130 ms for 17, 4.84 s for the last |
| 19      | 1    | `claude-haiku-4.5` | 43 (2 s)     | 71.6 s | **19 / 19** | 340 ms for all 19                  |
| 27      | 3    | `claude-haiku-4.5` | 57 (15 s)    | 98.0 s | **27 / 27** | 310 ms for all 27                  |

"tasks (each)" is the number of queued tasks and the simulated duration of one.
The 6-worker probe had no queue — each branch simply slept 25 s. Task totals
include runtime-injected children, so they exceed the seeded count.

The **19-worker row is a single run** and is the one to copy: it needs no
cross-run coordination, and it carried an in-workflow verification step as its
20th step node (§9.4). Multi-run composition is only necessary beyond 20
workers.

Findings:

1. **Step sessions do not draw from Kiro's documented pool of 4 concurrent
   subagents.** That cap — asserted in Kiro's subagent documentation, which is
   separate from this undocumented workflow surface — does not apply here. 27
   concurrent was reached with no sign of an engine-imposed ceiling.
2. **Concurrency composes across runs.** Filesystem coordination means the
   engine never needs to know the pools cooperate. Given §3.2, a single run can
   host up to 20 workers, so multi-run composition is only needed beyond that.

**Fan-out startup latency is erratic**: 24.6 s for a 6-branch fan-out, 5.0 s for
9 branches, ~0.3 s for 27 across three runs. Unexplained; possibly session
warmth or prompt length. Do not rely on any of these figures.

### 6.1 Overhead grows with worker count (Measured)

Per-iteration session overhead, measured as the gap between a worker's `done`
event and its next `iter-start`:

| workers | model              | overhead per iteration        | implied per-worker |
| ------- | ------------------ | ----------------------------- | ------------------ |
| 9       | `claude-opus-5`    | 6.3 – 7.0 s                   | 0.74 s             |
| 18      | `claude-opus-5`    | 9.2 – 11.4 s                  | 0.57 s             |
| 19      | `claude-haiku-4.5` | 12.8 – 35.8 s (median 14.6 s) | 0.77 s             |
| 27      | `claude-haiku-4.5` | 16.3 – 24.5 s (median 18.2 s) | 0.68 s             |

Overhead clearly grows with worker count, at roughly **0.57–0.77 s per worker**,
but this is a four-point fit and the coefficient is noisy — no single value
reproduces every row. Note that 19 workers on the _faster_ model cost more per
iteration than 18 on the slower one, which says the dominant term is concurrency
rather than model latency. **Use the measured overhead for a given size, not the
coefficient.**

Wall time is roughly predicted by:

```
wall ≈ iterations_per_worker × (task_duration + measured_overhead(workers))
```

- 18 workers: 2 × (15 + 10.3) = 50.6 s predicted vs **54.5 s** actual
- 27 workers: 3 × (15 + 18.2) = 99.7 s predicted vs **98.0 s** actual
- 19 workers: 3.6 × (2 + 14.6) = 60.3 s predicted vs **71.6 s** actual

The formula **predicts low**, and the 19-worker row shows why estimating
`iterations_per_worker` as `ceil(tasks / workers)` is too optimistic. Every
worker spends one extra iteration discovering the queue is empty, some spend
further iterations waiting on in-flight work (§9.3), and the ragged final round
leaves most workers idle. Measured there: 69 iterations across 19 workers to
serve 43 claims, so 26 of 69 iterations did no task work at all. Treat the
formula as a lower bound.

Note the 27-worker row changed model as well as size, so it is a lower bound on
the concurrency penalty rather than a like-for-like comparison.

Effective parallelism (work-seconds ÷ wall) was 6.3× at 18 workers and 8.7× at
27 — far below peak, because trailing rounds leave most workers idle. **Keep
tasks per worker at 5 or more** so drain and trailing-round costs amortize.

## 7. Gotchas — the engine

### 7.1 `fileCheck` paths outside the workspace are silently false forever (Measured)

A `repeat` `stopCondition` or step `completion` whose path lies outside the
workspace roots evaluates to `false` permanently — no error. The loop then runs
to `maxIterations` and does whatever `onMaxIterations` says: fails under
`abort`, halts under `pause`, and continues **silently** under `continue`.

Keep all stop-condition state inside the repository. Never `/tmp`. Interpolate
an absolute path (`{{workdir}}/...`); a bare relative path resolves against the
workflow's `workspacePath`, which is the session's first workspace folder and
may not be where agents actually write.

### 7.2 Step agents silently skip execution (Measured once)

A step agent can complete a `repeat` iteration **without doing anything**, and
the node tree still shows `[completed]`.

Measured once, at 18 workers on `claude-opus-5`: **67 engine iterations against
61 actual script invocations — 6 silent no-ops (~9%)**. One captured output read
verbatim: _"The command already ran and exited 0; I'm not re-running it."_ The
prompt had said "Do not run it a second time", intended to prevent
double-execution within a session; the agent applied it across iterations. Those
no-ops also explain why only 16 of 18 workers wrote drain markers in that run —
the two that did not (`w1`, `w12`) each no-op'd their final iteration, so they
never reached the drain branch.

**Mechanism is hypothesized, not established.** The natural explanation is that
`repeat` iterations are not context-isolated and prior-iteration output leaks
forward. But the observation is equally consistent with the agent noticing its
own side effects on disk, which this pattern deliberately makes visible.
Distinguishing them would need a step that leaves no filesystem trace.

The fix, and the wording that worked:

```
IMPORTANT: you may have run this exact command before, in an earlier iteration
of a loop. That is expected and completely irrelevant. Run it AGAIN now
regardless. Each invocation is a separate and necessary unit of work. Never skip
it. Never conclude that it has already been done.
```

After this change, at 27 workers: **zero no-ops across all three runs.** Engine
iteration counts (31 + 33 + 31 = 95, read from the `sequence:<repeatId>#<n>`
wrappers) matched script invocations exactly, worker by worker, for all 27
workers, and all 27 drained cleanly.

Two caveats on that result. The model changed at the same time as the prompt
(`claude-opus-5` → `claude-haiku-4.5`), so the fix is **consistent with** zero
no-ops rather than proven to cause it, and it is untested at like-for-like
model. And this wording is only safe for **idempotent** work: it instructs an
agent never to skip, so applied to a non-idempotent task it invites
double-execution. Make the task itself idempotent or claim-guarded (§9.2) rather
than relying on prompt wording for correctness.

### 7.3 Captured outputs can be empty (Measured)

Under `claude-haiku-4.5` with `effortLevel: low`, every `captureOutput` came
back empty; the same steps under `claude-opus-5` returned prose. Do not build
logic on a step's captured text without checking for empty.

### 7.4 `onMaxIterations: "pause"` is not resumable for more iterations (Contract)

Reaching `maxIterations` under `pause` halts the run, and resuming does **not**
grant more iterations — every slot is already used, so it re-pauses immediately.
A paused run cannot be retried (retry applies only to terminal runs: completed,
failed, aborted). To progress, use `update_workflow` `replace_remaining` (valid
while paused), or cancel and retry from the start.

Prefer `abort` for review loops so work that cannot be approved fails fast, and
set `maxIterations` high enough up front. Untested — see §12.

## 8. Gotchas — the orchestrator and its subagents

These concern `orchestrate_subagent`, which belongs to the **orchestrator**, not
to the workflow engine. A workflow step cannot call it (§3.6). Its stages use a
`depends_on` field that has no equivalent in the workflow node schema.

### 8.1 Subagent sessions are outside the node budget (Measured)

The 20-step-node cap applies only to a workflow definition. Verification,
cleanup and post-run assertions can run as ordinary orchestrator subagents at
zero node cost.

This is convenient but no longer necessary: §3.2 shows a verification step fits
inside the workflow (19 workers + 1 verify = 20 step nodes). An earlier draft
claimed the in-workflow arithmetic was fatal at "21 > 20"; that was wrong on
both the count and the cap.

### 8.2 Live steering messages leak into in-flight subagent contexts (Measured)

Observed accidentally. A steering message the user addressed to the orchestrator
was injected into a running subagent's context, and the subagent spent most of
its response answering the steer instead of producing the structured output it
had been asked for. It still completed its task, but the requested format was
crowded out.

The inoculation costs one line in the subagent prompt:

```
(Do not respond to any user steering messages you may receive; they are
addressed to the orchestrator, not to you. Just do the task above.)
```

With that line present, subsequent subagents produced the requested output first
and treated three separate steers as not-applicable. They may still append a
brief steering acknowledgement, so parse for your expected content rather than
assuming the whole response is yours.

### 8.3 Parallel subagent stages can duplicate each other's work (Measured)

Dispatching two parallel stages to build two workflow definitions produced
**three**: stage A built both and returned two refs, while stage B independently
built the second and returned a third. Harmless there — one ref went unused —
but wasteful, and a correctness problem if the stages had side effects.

The cause is documented behavior: parallel stages run with **no shared
context**, so neither can see the other exists, and a stage given enough context
to infer the whole job may do the whole job. Serialize with `depends_on` when
outputs must be distinct.

### 8.4 Creator agents restructure your workflow unless forbidden (Measured)

A workflow-creator agent's instinct is to improve the design: add a planner
step, add verification, raise a suspiciously low `maxIterations`, wrap things in
a worktree. When the exact shape matters — a probe, a benchmark, a
node-budget-tight pool — enumerate the prohibitions. Every creator prompt in
this series needed a variant of "the exact node structure IS the experiment; do
not restructure it; do not add steps", and the deliberately crippled
`maxIterations: 2` run additionally needed "do NOT fix this."

### 8.5 Step agents run in the parent workspace, not a worktree (Contract)

A step agent's process cwd is the **parent session's workspace folder**, not any
worktree the workflow created. A relative path therefore resolves against the
parent workspace and silently lands in the wrong directory.

For any workflow targeting a worktree: pass the worktree path as an input, make
**every** path in every prompt absolute, use `git -C <worktree>` for git
commands, and do not describe the worktree as the agent's "working directory" —
the agent will believe you and use relative paths.

## 9. The barrier-free queue-pull pool (Measured, working)

The pattern that makes this static-DAG engine behave like a scheduler. **Do not
express tasks as DAG nodes. Express workers as nodes, and put tasks in a queue
directory.**

### 9.1 Shape (Measured)

```
sequence
├─ parallel (joinPolicy: all)
│   ├─ repeat w1 … stopCondition fileCheck {{workdir}}/w1-done.json → drained: true
│   │   └─ step w1   → claims ONE task per iteration, then exits
│   ├─ repeat w2 … stopCondition fileCheck {{workdir}}/w2-done.json → drained: true
│   │   └─ step w2
│   └─ … up to 19 workers (20th step node is the verify below)
└─ step verify   → asserts the queue actually drained (§9.4)
```

Each `repeat` needs `onMaxIterations`. Use `continue` if you want the run to
finish and let the verify step judge the outcome; use `abort` if an
iteration-exhausted worker should fail the run. The stranding scenario in §9.4
turns on this being `continue`.

Each worker is an independent loop with its own stop condition, so workers are
never synchronized. Measured proof from the 18-worker run: `w1` began iteration
2 at t=14.74 s while `w9` was still on its first iteration until t=19.56 s.
Under a wave barrier, `w1` would have been blocked until `w9` finished.

Properties measured across all runs:

- **Task count is unbounded** and decoupled from the node cap.
- **Runtime-discovered work needs zero DAG mutation.** Children injected at t≈8
  s by `w1`/`w5`/`w7` were claimed at t≈15 s by _different_ workers.
- **Self-healing.** A no-op or dead worker simply fails to claim; the others
  absorb the queue. Attrition costs throughput, not correctness.

### 9.2 The worker (Measured)

One invocation equals one loop iteration: claim at most one task, do it, exit.
State lives in four sibling directories plus one drain marker per worker.

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

n="${1:?worker number required}"          # worker id, used for its drain marker
root="${2:?queue root directory}"         # must be INSIDE the workspace (§7.1)
queue="$root/queue"                       # *.task files awaiting a claim
claimed="$root/claimed"                   # *.task files currently in flight
finished="$root/done"                     # *.task files completed
events="$root/events"                     # per-worker append-only audit log
mkdir -p "$queue" "$claimed" "$finished" "$events"

# Portable epoch timestamp. `date +%N` is GNU-only — BSD/macOS date emits a
# literal "N", which would silently break the `sort -n` analysis in §13.
now() {
  local t
  if [ -n "${EPOCHREALTIME:-}" ]; then    # bash >= 5; locale may use a comma
    printf '%s\n' "${EPOCHREALTIME/,/.}"
    return 0
  fi
  t="$(date +%s.%N)"
  case "$t" in *.N) t="${t%.N}" ;; esac   # no sub-second resolution available
  printf '%s\n' "$t"
}

ev() { printf '%s w%s %s\n' "$(now)" "$n" "$*" >>"$events/w$n.log"; }

ev iter-start   # durable trace: without this, no-ops are undetectable (§4.4)

# --- claim exactly one task; losing the mv race just means someone else won ---
mine=""
for t in "$queue"/*.task; do
  [ -e "$t" ] || break                    # empty dir: glob stayed literal
  base="$(basename "$t")"
  if mv "$t" "$claimed/$base" 2>/dev/null; then
    mine="$base"
    break
  fi
done

if [ -z "$mine" ]; then
  # Nothing claimable. Only drain if nothing is in flight, otherwise a running
  # task could still inject new work after we quit. See §9.3.
  inflight="$(find "$claimed" -name '*.task' -type f | wc -l | tr -d ' ')"
  if [ "$inflight" -eq 0 ]; then
    ev drain
    printf '{"drained": true}\n' >"$root/w$n-done.json"   # the stop condition
  else
    ev "wait-inflight=$inflight"
    sleep 2
  fi
  exit 0
fi

ev "claim $mine"

# ------------------------------------------------------------------
# REAL WORK GOES HERE. The task file's name and contents identify the
# unit of work. To inject runtime-discovered work, write a new
# "$queue/<name>.task" — any worker will pick it up, no DAG edit.
# ------------------------------------------------------------------

mv "$claimed/$mine" "$finished/$mine"
ev "done $mine"
```

The **drain marker** is the contract between worker and engine. Its shape must
match the `repeat`'s `stopCondition` exactly:

```json
{ "drained": true }
```

read by
`{"fileCheck": {"path": "<root>/w<N>-done.json", "jsonPath": "drained", "value": true}}`.

Note the work is done by the **agent**, not necessarily by this script: for
agent-native work (reviewing a file, say), have the step prompt run a claim
script, do the work in the agent's own context, then run a completion script.
One agent session per task is desirable — it gives each task a fresh,
uncontaminated context, which is why the per-iteration session overhead in §6.1
is a price worth paying rather than pure waste.

### 9.3 Atomic claim, and the premature-drain guard (Measured)

`mv queue/<task> claimed/<task>` — `rename(2)` is atomic within one filesystem,
so a losing worker's `mv` simply fails and it tries the next file. **Zero
duplicate claims** were observed at 9, 18 and 27 workers, including across three
independent workflow runs, because the kernel arbitrates rather than the engine.
No lock needed.

**The premature-drain guard is mandatory.** A worker finding an empty queue must
not drain while any task is still in flight, because an in-flight task may still
inject work. Observed live at 18 workers: `w5` and `w2` hit `wait-inflight=6` at
t≈16 s and correctly drained later at t≈24–27 s. Without the guard the pool
would have silently dropped 2 of 18 workers just before three children landed.

### 9.4 A drain assertion is mandatory (Measured)

With `onMaxIterations: continue`, a run can **complete with work stranded and no
error raised.** Verified deliberately: a pool capped at `maxIterations: 2` was
pointed at 40 seeded tasks, giving 9 workers × 2 iterations = 18 processable.

Reconciling that run: 40 seeded, 3 children injected at runtime, 18 processed,
leaving **25 stranded** (40 + 3 − 18). `inspect_workflow` reported
`Status: completed` with every node `[completed]` and all 9 `repeat` loops
green, zero drain markers written, and 58% of the work never done. Nothing in
engine state hints at it.

So always assert the queue and in-flight directories are empty after the join.
The assertion can be an in-workflow step (§3.2, §8.1) or an orchestrator
subagent.

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

root="${1:?queue root directory}"

count() { # tolerate a missing dir so this can run before the pool ever started
  [ -d "$1" ] || { printf '0\n'; return 0; }
  find "$1" -name '*.task' -type f | wc -l | tr -d ' '
}

nq="$(count "$root/queue")"
nc="$(count "$root/claimed")"
nd="$(count "$root/done")"
stranded=$((nq + nc))

printf '{"queue":%s,"claimed":%s,"done":%s,"stranded":%s,"drained":%s}\n' \
  "$nq" "$nc" "$nd" "$stranded" \
  "$([ "$stranded" -eq 0 ] && printf true || printf false)" \
  >"$root/drain-report.json"

if [ "$stranded" -eq 0 ]; then
  printf 'PASS — queue empty, nothing in flight, %s task(s) done.\n' "$nd"
  exit 0
fi
printf 'FAIL — %s stranded (%s queued, %s in flight); only %s done.\n' \
  "$stranded" "$nq" "$nc" "$nd" >&2
exit 1
```

Count with `find -name '*.task' -type f`, not a glob: a glob over an empty
directory misbehaves under `set -u` and across shells.

Both exit paths were tested against staged states, then end-to-end from a real
subagent session: exit **1** with 25 stranded against the crippled run above,
and exit **0** with `"done": 43` after a follow-up pool drained it. 43 = 40
seeded + 3 children, so nothing was lost across the two runs.

It was then run a third way — as an **in-workflow `verify` step**, the 20th step
node after a 19-worker pool, ordered by wrapping both in a `sequence`. It fired
after the `parallel` joined and reported exit 0 with 43 tasks done. So all three
placements work: staged unit test, orchestrator subagent, and in-workflow step.
Prefer the in-workflow step — it keeps the assertion inside the artifact that
needs it, and it costs one step node you were probably not using.

## 10. Model and effort selection (Contract, table Measured)

Set `modelId` / `effortLevel` per step, or once at workflow level as a default.
Resolution cascades **step > workflow > parent session**; omit a field (or set
`auto`) to inherit. Omitting both is the correct default.

Discover valid ids; never guess, since an unknown id passes validation and then
fails at session creation with no fallback:

```bash
kiro-cli chat --list-models -f json
```

Credit multipliers (the `rate_multiplier` field, `rate_unit: "Credit"`) as of
`kiro-cli 2.16.0`:

| model               | credit multiplier |
| ------------------- | ----------------- |
| `gpt-5.6-luna`      | 0.1×              |
| `claude-haiku-4.5`  | 0.4×              |
| `gpt-5.6-terra`     | 1.0×              |
| `claude-sonnet-4.6` | 1.3×              |
| `claude-opus-5`     | 2.2×              |
| `gpt-5.6-sol`       | 2.4×              |

Effort levels are model-dependent (`low`, `medium`, `high`, `xhigh`, `max`); an
unsupported level falls back to the model's default rather than failing.

Pinning a cheap model to mechanical steps is worthwhile — 27 workers at ~3.5
iterations each on `claude-haiku-4.5` (0.4×) instead of `claude-opus-5` (2.2×)
is a 5.5× cost reduction on work that runs one shell command. Watch for the
empty captured outputs in §7.3, and note that changing model mid-experiment
confounds timing comparisons (§6.1).

## 11. Adopting this in another repository

1. **Add agent-facing steering.** Users have no entry point (§1), so the
   orchestrator must know when to reach for a workflow. A minimal steering rule:

   ```
   Delegate multi-step implementation work to a workflow rather than doing it
   inline. Use `wf-workflow-creator` to build and validate the definition, then
   `run_workflow` with the returned `generated://` ref. Do not hand-author
   workflow JSON. After launching, end your turn — `run_workflow` does not block,
   and a completion notification will arrive. Treat that notification as
   "finished", not "succeeded": always check the result.
   ```

2. **Decide where recipes live.** Reusable shapes belong in
   `.kiro/workflows/<name>.workflow.json` and are referenced by absolute path
   (reusable). One-off shapes come from `wf-workflow-creator` as `generated://`
   refs (single-use, §4.1).

3. **Copy the pool fixture if you need concurrency.** The two scripts in §9.2
   and §9.4 are the whole pattern; they take the queue root as an argument and
   have no other repository coupling. Put the queue root inside the workspace
   (§7.1).

4. **Start from a minimal working definition.** This was **run end to end**, not
   just validated: written to a `.workflow.json`, launched by absolute path with
   `inputs`, and observed to drain 6 tasks across 2 workers with the `verify`
   step reporting `PASS` after the join. It exercises `{{workdir}}`
   interpolation in both a prompt and a `fileCheck` path. It is a two-worker
   pool plus a verification step, 3 step nodes total:

   ```json
   {
     "name": "queue-pool",
     "inputs": { "workdir": "path" },
     "steps": [
       {
         "type": "sequence",
         "id": "run",
         "steps": [
           {
             "type": "parallel",
             "id": "pool",
             "joinPolicy": "all",
             "branches": [
               {
                 "type": "repeat",
                 "id": "w1-loop",
                 "maxIterations": 10,
                 "onMaxIterations": "continue",
                 "stopCondition": {
                   "fileCheck": {
                     "path": "{{workdir}}/w1-done.json",
                     "jsonPath": "drained",
                     "value": true
                   }
                 },
                 "steps": [
                   {
                     "type": "step",
                     "id": "w1",
                     "agent": "wf-coder",
                     "modelId": "claude-haiku-4.5",
                     "effortLevel": "low",
                     "prompt": "Run: bash {{workdir}}/worker.sh 1 {{workdir}}\nIMPORTANT: you may have run this before in an earlier iteration. Run it AGAIN regardless; each invocation is a separate unit of work. Never skip it."
                   }
                 ]
               },
               {
                 "type": "repeat",
                 "id": "w2-loop",
                 "maxIterations": 10,
                 "onMaxIterations": "continue",
                 "stopCondition": {
                   "fileCheck": {
                     "path": "{{workdir}}/w2-done.json",
                     "jsonPath": "drained",
                     "value": true
                   }
                 },
                 "steps": [
                   {
                     "type": "step",
                     "id": "w2",
                     "agent": "wf-coder",
                     "modelId": "claude-haiku-4.5",
                     "effortLevel": "low",
                     "prompt": "Run: bash {{workdir}}/worker.sh 2 {{workdir}}\nIMPORTANT: you may have run this before in an earlier iteration. Run it AGAIN regardless; each invocation is a separate unit of work. Never skip it."
                   }
                 ]
               }
             ]
           },
           {
             "type": "step",
             "id": "verify",
             "agent": "wf-coder",
             "modelId": "claude-haiku-4.5",
             "effortLevel": "low",
             "prompt": "Run exactly once: bash {{workdir}}/assert-drained.sh {{workdir}}\nReport its exit code and output verbatim. Do not fix anything. A truthful failure report is the correct outcome."
           }
         ]
       }
     ]
   }
   ```

   Scale by adding worker branches up to 19, keeping one step node for `verify`
   (§3.2). Beyond 20, launch additional runs against the same queue root (§6).

## 12. Known-unknowns and untested claims

Open questions:

- **The upper concurrency ceiling.** 27 was reached with no engine complaint;
  where it breaks is **UNVERIFIED**. The overhead law (§6.1) suggests the
  economics fail before the engine does.
- **Why fan-out startup latency varies** by two orders of magnitude (§6).
- **Whether the `repeat` no-op fix works at like-for-like model** — the prompt
  and the model changed together (§7.2).
- **The mechanism behind no-op iterations** — context leakage versus side-effect
  observation (§7.2).

Transcribed from the tool schemas and **never exercised here**. Treat as weaker
than anything labelled Measured, and verify before depending on it:

- **`update_workflow`** — neither action was ever invoked. §5's barrier
  conclusion rests entirely on documented semantics. A `wf-coder` step does not
  even have the tool (§3.6), so the step-agent path is unavailable for that
  agent; only the orchestrator's `replace_remaining` remains plausible, and it
  too is untested.
- **`onMaxIterations: "pause"` semantics** (§7.4).
- **`watch` nodes** and their handlers, e.g. `github-pr`.
- **`joinPolicy`** — only `all` was used; `allSettled` and `any` are untested.
- **`artifacts` maps and reference ordering** (§3.3) — `{{...}}` interpolation
  itself **is** tested (see below), but no probe declared an `artifacts` map or
  cross-referenced another step's output, so those rules were never exercised.
- **`stopWhen`**, step `completion` blocks, and `captureOutput` as a data
  channel — only `stopCondition` with `fileCheck` was used, and captured output
  was read only for diagnostics.
- **Whether a `repeat` may legally omit a stop condition** (§3.1).
- **Bundled recipes** — none were run. The `generated://` and absolute-path
  forms were both exercised; `bundled://` was only ever probed with a
  nonexistent name (§4.1).
- **`maxIterations` above 6**; the documented range is 1–1000. A `repeat` with
  `maxIterations: 10` was run but stopped at 4 on its stop condition.

## 13. Reproducing the measurements

The probes coordinated through a queue directory and per-worker append-only
event logs of the form `<timestamp> w<N> <event> <task>` (§9.2), which is what
made after-the-fact analysis possible.

Sub-second resolution needs either bash 5 (`EPOCHREALTIME`) or GNU `date`. On a
system with neither, §9.2's `now()` degrades to whole seconds — the logs still
sort numerically and the sweep below still works, but the overhead figures in
§6.1 would be too coarse to reproduce, since the gaps being measured are
single-digit seconds.

**Peak concurrency**, by sweep over claim/done intervals — the source of every
"peak" figure in §6:

```bash
cat events/*.log \
  | awk '$3=="claim"{print $1,1} $3=="done"{print $1,-1}' \
  | sort -n \
  | awk '{s+=$2; if(s>m){m=s;mt=$1}} END{printf "PEAK=%d at t=%.2f\n", m, mt}'
```

**Per-iteration overhead**, as the gap between a worker's `done` and its next
`iter-start`. Use only the _first_ such gap per worker: a later gap may span a
silent no-op iteration (§7.2) and read as inflated overhead.

```bash
awk '$3=="done"{d=$1; next}
     $3=="iter-start" && d!=""{printf "%.2f\n", $1-d; exit}' events/w1.log
```

**No-op audit** (§7.2): count `sequence:<repeatId>#<n>` wrapper nodes per worker
in each run's `inspect_workflow` tree, and compare against
`grep -c iter-start events/w<N>.log`. Do this per worker, not in aggregate — two
workers with offsetting errors would cancel out in a total.

**The node cap** (§3.2): build candidate shapes and call `validate_workflow`. It
never executes anything, so boundary-probing is free. The error message names
the count and the limit.

**Step agent tool roster** (§3.6): a single top-level `step` instructed to write
its own tool list to a file. Design such a probe so a false claim is detectable
— forbid the agent from doing the delegated work itself, and require a durable
artifact from each delegate, so that absent artifacts plus a self-report of
unavailability is a three-way corroboration rather than a bare assertion.

Two methodology cautions. **Validate the measurement before trusting the
measurement**: the first overhead figures were contaminated by no-op iterations
spanning two engine iterations, which inflated the apparent gap until the
first-gap-only rule above was adopted. And **do not change two variables at
once** — the model changed between the 18- and 27-worker runs, which is why
§6.1's overhead comparison and §7.2's no-op fix both carry confound caveats.
