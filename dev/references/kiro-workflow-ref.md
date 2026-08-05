# Kiro Workflow Engine — Working Reference

A human-readable guide to what the Kiro workflow engine actually does, and how
to wire its pieces into useful shapes. Sibling of `claude-workflows.md`.

This document **synthesizes**; it does not measure. Everything here comes from
research already in this repository, and each claim names its source so you can
go read the evidence:

| Source                                           | What it is                                                                                  |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `kiro-workflows.md` §N                           | the evidence ledger — live runs against **kiro-cli 2.16.0**, 2026-07-31/08-01               |
| `fixtures/kiro-primitives/records/` R-name-N     | static reads of the **KAS 2.15.1** engine bundle, 2026-07-29 (byte offsets moved in 2.15.2) |
| `fixtures/kiro-primitives/workflows/contract.jq` | the definition contract re-implemented from those reads, as a runnable checker              |
| `docs/plans/kiro-v3-research-raw/`               | raw working notes, including live ACP protocol probes                                       |

Where a live measurement and a code read agree, the claim is strong and said so
plainly. Where they disagree, or where only one exists, §8 records it.

**The feature is dark-shipped and off by default.** Upstream describes
`workflows` as "Dark-shipped at 0% until release certification is complete", and
it appears in no official Kiro documentation. Everything below can move without
notice.

## 1. Execution model

### Unlocking it

Nothing here runs until the `workflows` rollout feature is force-unlocked. In
this repository that is two options in `packages/kiro-cli/lib/mkKiro.nix`:

```nix
ai.kiro.unlockedRolloutFeatures = ["workflows"];
ai.kiro.v3 = true;                  # required — the commands need the kas engine
```

`KIRO_ENABLED_FEATURES` **does not work**, despite the rollout manifest's own
description saying it does. The Rust chat binary recomputes and overwrites the
variable before spawning bun: the parent held `["workflows"]` and the child
received `["tangent"]`. Patching the manifest is the only client-side seam
(ledger §1.1).

Registration is **all-or-nothing on one boolean**. When `workflowsEnabled`
resolves true a session gains six tools — `run_workflow`, `inspect_workflow`,
`update_workflow`, `validate_workflow`, `send_message`, plus
`save_workflow_definition` in the custom-agent pool — along with a bundled
steering document and the slash-command source. When false, every pool array is
`void 0` and nothing registers. There is no partial mode, and the gate is
checked once at session-connection time (R-workflow-4).

Confirm it took before trusting anything: call `validate_workflow` on a trivial
definition. If the workflow tools are absent, the feature is not unlocked.

### Three client surfaces, not one

This is the single most useful thing to hold in your head, because the surfaces
have **different capabilities** and most confusion about the engine comes from
generalizing one to another.

| Surface                   | What it is                                                          | Run control                                           |
| ------------------------- | ------------------------------------------------------------------- | ----------------------------------------------------- |
| **TUI slash commands**    | 7 feature-gated commands, 2 visible + 5 hidden (ledger §1)          | full: run, cancel, resume, status, browse             |
| **Agent-facing tools**    | the 6 above; how the agent itself drives a workflow                 | **launch and mutate only** — no resume, no cancel     |
| **ACP extension methods** | `_kiro/workflow/*`, registered **unconditionally** (raw ACP probes) | full: pause, resume, resumeAll, cancel, retry, delete |

The ledger's measurements were all taken through the **agent-facing tools** in
an ACP session, which is why it reports "the agent-facing tools cannot resume a
run at all" (§7.4). That is true of those tools and is not true of the engine.
§2 has the details.

### The shape of a run

A workflow is one JSON object:

```
{ name, description?, inputs?, modelId?, effortLevel?, steps[] }
```

with five node types, and that is the entire scheduling vocabulary
(R-workflow-5, quoting the engine's own enums):

| type       | required                                                   | notes                                              |
| ---------- | ---------------------------------------------------------- | -------------------------------------------------- |
| `step`     | `id`, `agent`, and at least one of `prompt` / `input`      | the only node that runs an agent                   |
| `sequence` | `id`, `steps`                                              | ordered                                            |
| `parallel` | `id`, `branches`, `joinPolicy`                             | `all` \| `allSettled` \| `any`                     |
| `repeat`   | `id`, `steps`, `maxIterations` (1–1000), `onMaxIterations` | `abort` \| `continue` \| `pause`; plus a stop form |
| `watch`    | `id`, `handler`, `config`                                  | non-LLM polling: `github-pr`, `crux-cr`            |

Launch is by `workflowPath` in one of three forms (ledger §4.1):

- `bundled://<name>` — one of seven shipped recipes: `autoresearch`,
  `feature-pipeline`, `goal`, `investigate`, `publish-pr`, `ralph`,
  `semantic-review-multi-model`. A workspace `.kiro/workflows/` entry shadows a
  bundled name.
- `generated://<id>` — saved by `wf-workflow-creator`. **Single-use**: the
  stored definition is consumed when the run starts.
- an absolute path to a `.workflow.json` inside the workspace roots —
  **reusable**.

Three properties shape everything downstream:

- **`run_workflow` returns immediately.** It does not block, so the orchestrator
  stays conversational for free. Launch, end the turn, act on the completion
  notification — never `sleep` in a shell call waiting for it (ledger §4.2).
- **A completion notification means finished, not succeeded.** A run reported
  `completed` with every node green while 58% of its work sat unprocessed
  (ledger §9.4). Always follow it with a domain assertion.
- **The engine is a static DAG with future-rewrite, not a work-stealing
  scheduler** (ledger §5.3). Every concurrency primitive it has is a barrier. §7
  is how you get scheduler-like behavior without fighting that.

`inspect_workflow` returns a status, a captured-output map keyed by step id, and
a node tree. Two shape details you need for auditing: the engine wraps your
definition in an implicit top-level `sequence:wf_<id>` even if you declared one
node, and each executed `repeat` iteration appears as `sequence:<repeatId>#<n>`,
zero-indexed. Counting those wrappers gives the engine-side iteration count
(ledger §4.4) — which is the only way to detect the silent-skip defect in §7.

## 2. Steering and run control

### Can you steer an individual agent from the TUI?

**No — there is no per-agent steering channel.** Nothing in any of the three
surfaces addresses one step agent inside a running workflow. Every control verb
takes a **run** id; the one mutation verb takes the run's top-level step list.
That is a clean negative across all three surfaces, and it is the answer to plan
around.

What you get instead, in decreasing order of usefulness:

**1. Rewriting the future (`update_workflow`, action `replace_remaining`).**
Replaces all steps after the currently-running step. Two things about it are not
what the contract's wording suggests, both measured (ledger §5):

- It operates **only on the top-level `steps[]` array**. It cannot reach inside
  a `sequence` or a `parallel`. Where a workflow is one top-level `sequence` —
  as the §7 pool is, and as most useful shapes are — "all steps after the
  current one" is the _empty set_, so a "replacement" silently **appends** a
  sibling instead. Measured both ways: nested, the original steps all ran and
  the new one was appended; flat, the originals never ran at all.
- The response string tells you which path was taken:
  `Queued: …will be replaced after the current step completes` while a step
  runs, `Applied: …` when paused or idle.

It **cannot unstick a paused run**. Applied to a run halted by a
`warning`-severity step, the new step appeared `[pending]` and stayed there
(ledger §5.2).

**2. Step lifecycle via `send_message` severity.** When a step calls
`send_message` the severity is not cosmetic — it drives the step (ledger §4.3):

| severity  | effect                                            |
| --------- | ------------------------------------------------- |
| `success` | marks the step completed; the workflow advances   |
| `warning` | **pauses the whole run** and waits for user input |
| `error`   | marks the step failed                             |
| `info`    | informational only                                |

`warning` is a load-bearing hazard: a step reaching for it to flag something
non-fatal halts the entire run, and the agent-facing tools cannot resume. Also
note steps **routinely ignore** an instruction not to call `send_message` at all
— treat their notifications as something to tolerate, not something you can
switch off by asking.

**3. Steering a running sub-agent resets its work budget.** A dispatched
sub-execution is bounded by `agentIterationLimit = 300` model-invoke entries
(one per agent turn, not per tool call), under a 6000 graph-transition safety
net. But a queued steering message **short-circuits the limit check and resets
the counter to zero** (R-limits-1). So the real invariant is _300 consecutive
turns with no queued message_ — steering a long-running worker extends it rather
than merely nudging it. Termination has to come from the domain, not from this
cap.

### Why a run is paused

A run can be `paused` for four distinct reasons and the string is diagnostic
(ledger §4.3):

| reason string                                                          | cause                            | resumes itself                 |
| ---------------------------------------------------------------------- | -------------------------------- | ------------------------------ |
| `Step requested user input via send_message.`                          | a step used `warning` severity   | no                             |
| `Step '<id>' is waiting for the next user message.`                    | an unmet step `completion` block | yes, once the condition is met |
| `Transient model service error (service 5xx/throttling); will resume.` | upstream model error             | claims to; once did not        |
| `Step interrupted (agent shutdown or connection reset); will resume.`  | a step agent's session died      | observed once of three         |

"Will resume" is not a guarantee. One run sat in the transient-error state
indefinitely, stalled on iteration 5 of 12 with four clean iterations behind it;
relaunching the identical workflow completed it. Treat a long-lived
transient-error pause as a stall to relaunch, not a wait to sit out.

**A resume can re-run an earlier step in the same loop iteration.** In one
implement-and-review run the interrupt hit the reviewer; the run returned to
`running` with the _coder_ step running again inside the same
`sequence:build-loop#0` wrapper (node-id continuity excludes "the loop
advanced"). So design against double execution: anything non-idempotent in that
step happens twice — creating a worktree, appending to a queue, opening a PR
(ledger §7.4).

### The ACP surface — full run control, ungated

The raw protocol probes record a `_kiro/workflow/*` extension surface of **14
request methods, registered unconditionally** (not gated on `workflowsEnabled`).
It carries the verbs the agent-facing tools lack:

| method                              | notes                                                          |
| ----------------------------------- | -------------------------------------------------------------- |
| `new`                               | creates but **does not start** — `root` stays `pending`        |
| `invoke`                            | starts it; fire-and-forget; restarts terminal runs             |
| `pause` / `resume` / `resumeAll`    | by id; `resumeAll` sweeps all base dirs                        |
| `cancel`                            | `{workflowId, targetStatus?}`, default `aborted`               |
| `retry`                             | terminal runs only; `nodeId` must be failed or aborted         |
| `delete`                            | refuses a running run owned by a live process                  |
| `load` / `inspect` / `list`         | `load` also rewires the notification bridge to this connection |
| `update`                            | `replace_remaining`, or a status update                        |
| `listRecipes` / `listWatchHandlers` | the 7 recipes and 2 watch handlers with input schemas          |

Notifications flow agent→client — `run_start`, `run_complete`, `node_start`,
`node_complete`, `node_paused`, `loop_iteration`, `watch_poll`, `paused`,
`steps_queued` — but **only after a bridge is wired** by `new`+`invoke`, `load`,
`resume` or `resumeAll` on that connection. A second connection's `load`
_steals_ the stream. The bridge self-unsubscribes on terminal `run_complete`.

This is the surface to reach for when you need to drive runs programmatically.
Two caveats before you build on it: it is a protocol surface rather than a
supported API, and the ledger's own measurements never used it, so the live
behavior of these verbs against a real run is thinner evidence than the rest of
this document. §8 records that.

### One orchestrator-side hazard

Live steering messages **leak into in-flight sub-agent contexts**. A steer
addressed to the orchestrator was injected into a running subagent, which spent
most of its response answering the steer instead of producing its structured
output. One line of inoculation in the subagent prompt fixes it (ledger §8.2):

```
(Do not respond to any user steering messages you may receive; they are
addressed to the orchestrator, not to you. Just do the task above.)
```

## 3. How data moves between agents

### There is no message passing

**Agents in a workflow never talk to each other.** There is no peer channel, no
mailbox, no `depends_on` payload. Everything moves through one of three places,
and choosing between them is most of workflow design:

| Channel                | Shape                             | Good for                                     |
| ---------------------- | --------------------------------- | -------------------------------------------- |
| **Template variables** | `{{<id>.output}}` in a prompt     | short verdicts, small structured text        |
| **Artifacts**          | `{{artifacts.<name>}}` → a path   | anything large; passing an absolute location |
| **The filesystem**     | the agents just read and write it | loops, queues, accumulating state            |

The third is not a workaround — it is the **shipped idiom**, and the bundled
recipes use it (§3.3 below).

### Template variables, and the envelope

Workflow `inputs` interpolate as `{{name}}`. Step output is addressable three
ways, and all three resolve to byte-identical text (ledger §3.3):

| reference                                        | meaning                                       |
| ------------------------------------------------ | --------------------------------------------- |
| `{{previous.output}}`                            | the immediately prior **sibling** step        |
| `{{<id>.output}}` (also `{{steps.<id>.output}}`) | a named earlier step                          |
| `{{artifacts.<name>}}`                           | a path from an earlier step's `artifacts` map |

Ordering is enforced at validation, and each rejection names the offending pair:
a reference must name a producer that runs earlier, `{{previous.output}}` is
rejected on a first step, and a reference **across concurrent `parallel`
branches** is rejected as "does not run before it". So sibling branches cannot
read each other by construction — that is a validator rule, not a convention.

**Captured output is never raw.** What a prompt receives is wrapped in a
delimiter carrying a per-run random nonce:

```
<prior_step_output_e94daa17f05467d6 id="producer">
TOKEN-PC-7731
</prior_step_output_e94daa17f05467d6>
```

The payload above was 13 characters; the envelope accounts for the other 89. The
nonce differs per run — the signature of a prompt-injection guard, since content
cannot forge a closing tag it cannot predict. Two consequences:

- `{{<id>.output}}` is **a channel for an agent to read, not a value to compute
  on**. Anything parsing it must strip the envelope and must not assume a stable
  tag.
- `inspect_workflow`'s captured-output map is the exception — it shows the raw
  payload unwrapped, so that is where to read output programmatically.

**Capture can be empty.** `captureOutput` defaults to `true`, but under
`claude-haiku-4.5` with `effortLevel: low` both steps' captured outputs were
empty strings while the work demonstrably happened — the envelope was still
there with nothing inside it. Do not pin a cheap model to a step whose output
something downstream consumes, and test for empty rather than expecting to
notice (ledger §7.3).

### Artifacts are the right way to pass a path

`artifacts` map values are re-interpolated on every path, fresh runs and
continuations alike:

```json
"artifacts": { "plan": "{{workdir}}/.agents/tasks/plan.md" }
```

A downstream step reads `{{artifacts.plan}}` and gets the resolved path.
Interpolate a declared input so the value stays **absolute** — a relative
artifact path resolves against the workspace root, and an _undefined_ input is
not an error: it stays literal and becomes part of the path. That is how a real
run produced a directory literally named `{{report_path}}` (ledger §3.3, §4.1).

### The writer → reviewer question, and a correction

The brief asks about "the built-in coder workflow (planner → looper(writer →
reviewer))". **No such recipe ships, and no recipe of that shape exists anywhere
in this repository's research.** The seven bundled recipes are listed in §1. The
one that is a loop, `ralph`, has been reproduced verbatim from the bundle
(R-workflow-7) and is a **single-agent sequential drain** — one `repeat`
wrapping one `step` on `wf-coder`, 200 iterations, terminated by a file check:

```json
{
  "name": "ralph",
  "inputs": { "goal": "prompt", "prd_path": "file" },
  "steps": [
    {
      "type": "repeat",
      "id": "ralph-loop",
      "maxIterations": 200,
      "onMaxIterations": "pause",
      "stopCondition": {
        "fileCheck": {
          "path": "{{prd_path}}",
          "jsonPath": "complete",
          "value": true
        }
      },
      "steps": [
        {
          "type": "step",
          "id": "iterate",
          "agent": "wf-coder",
          "prompt": "Goal: {{goal}}\n\nRead {{prd_path}}. If the file does not exist, create it as a JSON checklist … If it already exists, pick the first unchecked item, implement it, run tests, commit. Update {{prd_path}} to mark it done. Set complete: true when nothing remains."
        }
      ]
    }
  ]
}
```

**That is the answer to "what mechanic carries state across iterations", and it
is not output threading — it is a JSON file on disk.** The agent reads
`{{prd_path}}`, does one item, rewrites the file. The engine tracks nothing; the
model owns progress. The record calls this "the clearest existing statement of
the shipped loop idiom: durable state in a file the human can inspect, one item
per iteration, the model updating the file rather than the engine tracking
progress."

`feature-pipeline` and `semantic-review-multi-model` are the two bundled recipes
whose _names_ suggest the operator's multi-stage shape. Only their input schemas
are recorded — `feature-pipeline{task:prompt, workdir:string}` and
`semantic-review-multi-model{target:prompt, workdir:string}`. **Their node
structure is nowhere in this repository.** Six of the seven recipes were never
run; only `investigate` was, and only far enough to establish input handling
(ledger §12). That is register item R-1.

So for a writer → reviewer loop you build yourself, the mechanic is your choice
of the three channels, and the trade is:

- **Template output** (`{{code.output}}` into the reviewer's prompt) is the
  smallest wiring, but it inherits the envelope and the empty-capture hazard,
  and it cannot cross `parallel` branches.
- **A verdict file** written by the reviewer and read by the next iteration's
  writer is what the shipped idiom does, survives an interrupted step, and is
  human-inspectable mid-run.

One hazard specific to the second, and it is sharp: **a loop artifact's presence
is not a first-pass test.** After an interrupted-step resume, the reviewer's
verdict file is still absent — the reviewer is the step that died before writing
it — so a re-running writer concludes "first pass" and may redo committed work.
Derive idempotence from inspecting the repository, never from whether a loop
artifact happens to be there (ledger §7.4).

## 4. Composition and reuse

### Workflows do not compose

**There is no ref, include, import, or pointer from one workflow definition into
another.** The five node types in §1 are the complete vocabulary; none of them
references an external definition, and `bundled://` / `generated://` / a file
path are _launch_ forms, not node forms. Reuse is by **inlining** — you generate
the JSON, you do not link it.

A step also cannot start a workflow, so composition-by-nesting is closed too at
the contract level (§6 has the nuance, which is a live open question).

What you get instead:

| Mechanism                              | Reusable? | Notes                                           |
| -------------------------------------- | --------- | ----------------------------------------------- |
| `.kiro/workflows/<name>.workflow.json` | yes       | launch by absolute path; shadows a bundled name |
| `generated://<id>`                     | **no**    | consumed when the run starts; re-save each time |
| `bundled://<name>`                     | yes       | the seven shipped recipes                       |
| a generator script emitting JSON       | yes       | what the fixtures do — see §7                   |

That last row is the practical answer to "how do I get six of these". The
fixtures' `workflows/generate.sh` is the only place the branch count `K` lives,
and it emits the whole definition; the shape is a template in a script, not a
composition primitive in the engine.

### Can an LLM synthesize a workflow from saved ones?

Yes, and there is a dedicated agent for it — but read the constraints first.

`wf-workflow-creator` builds and saves definitions, and it is the only agent
holding `save_workflow_definition`. It has **five tools, no file tools and no
`execute_bash`** (ledger §3.6). It cannot read the repository at all. It
composes JSON purely from the prompt you hand it, which means:

- **Every path, agent name and constraint must be in the prompt.** It cannot
  verify that anything it references exists.
- **It will restructure your design unless forbidden.** Its instinct is to
  improve: add a planner step, add verification, raise a suspiciously low
  `maxIterations`, wrap things in a worktree. Every creator prompt in the
  ledger's series needed a variant of _"the exact node structure IS the
  experiment; do not restructure it; do not add steps"_ (ledger §8.4).

Feeding it saved definitions as templates works because the authoring spec it
follows is itself prose in the bundled steering — the model is being taught the
schema in text, so more examples in the prompt is exactly the right lever.

### What validation catches, and what it does not

`validate_workflow` **does** check schema conformance, the caps in §5, that
every step has `prompt` or `input`, that a `repeat` does not define both stop
forms, that `stopWhen` watch references resolve, the ordering rules in §3, and
that `fileCheck` paths are not provably outside the workspace roots.

It does **not** check agent names, watch handler configs, `modelId`,
`effortLevel`, or bare `{{identifier}}` references. A `watch` node with a
completely empty `config` validates clean (ledger §3.4).

The failure timing is what matters in practice:

| mistake                 | caught when                                                               |
| ----------------------- | ------------------------------------------------------------------------- |
| bad schema / over a cap | validation                                                                |
| unregistered `agent`    | **launch**, cleanly, before any step runs — and checked live against disk |
| unknown `modelId`       | **mid-run**, at that step's session creation, with no fallback            |
| missing `inputs`        | never — the placeholder stays literal in the prompt and the path          |

The agent-name check is live rather than snapshotted: a profile deleted
mid-session stopped working immediately, even though its name still sat in the
orchestrator's own delegation list. Note also that the TUI may display
`agent "<name>" not found, using "default"` alongside a launch refusal — that
message announces a fallback which **did not happen**; the refusal is
authoritative (ledger §3.5).

Do not use `kiro-cli agent validate` as a pre-flight. It exits 0 unconditionally
— five inputs including a nonexistent path all returned 0, with only stderr
separating them — it is JSON-only so it cannot read a Markdown profile at all,
and it does not check tool-group names (ledger §3.8).

### Validating without a session

There is a bootstrapping problem worth knowing about: `validate_workflow` only
exists in a session where `workflowsEnabled` is true, and enabling that requires
pre-seeding a persisted session — so the tool that would vet your definition
only exists in a session you can only create by already having a definition
worth seeding.

`fixtures/kiro-primitives/workflows/contract.jq` breaks that circle. It
re-implements the definition contract from the bundle read, runs on nothing but
`jq`, and each diagnostic carries a `basis` saying whose rule it is: `engine`
(the engine performs an equivalent check), `policy` (the engine **accepts**
this; the rule exists because acceptance is silent and the consequence
expensive), or `mechanical`. Run it with `validate-workflow.sh --strict`. It is
a model of the engine, not the engine — but every rule traces to a quoted schema
or function.

## 5. Limits and fan-out

### The node cap is 20, not 18 — and it counts `step` nodes only

Two independent methods agree, which makes this the best-established number in
the document:

- **Static read:** `DEFAULT_MAX_STEP_NODES = 20`, alongside
  `DEFAULT_MAX_NESTING_DEPTH = 8` and `MAX_REPEAT_ITERATIONS = 1000`
  (R-workflow-5, from the engine's validator module).
- **Live validation:** a flat `parallel` of 20 plain steps is valid; 21 is
  rejected with `Workflow has 21 step nodes, exceeding the maximum of 20.`
  (ledger §3.2).

**`repeat`, `parallel` and `sequence` wrappers are free.** A 12-worker pool with
25 total nodes validated fine because only 12 of them were `step` nodes. An
earlier draft of the ledger claimed 9 workers per run by wrongly counting
wrappers; if you see that figure anywhere, it is wrong.

There is no bundled recipe named "coder", so the "coder uses 3" figure has no
referent in the research. For calibration: `ralph` and `investigate` are **one**
step node each.

### Does 6 parallel × 3-agent chains fit?

**Yes, comfortably.** Six branches, each a `sequence` of three `step` nodes:

```
6 branches × 3 step nodes            = 18 step nodes   (cap 20 → 2 spare)
wrappers: 1 parallel + 6 sequences   =  0 counted
nesting: parallel → sequence → step  =  3 levels        (cap 8)
```

Two spare step nodes is exactly enough for the pattern §7 recommends: one
top-level verification step after the join. If each of the three per-branch
stages is instead a `repeat` (a self-draining worker), that costs nothing extra
— still 18 `step` nodes, with the `repeat` wrappers free.

The real limits on that shape are not node count:

| Limit                              | Value                                     | Source          |
| ---------------------------------- | ----------------------------------------- | --------------- |
| concurrent step sessions           | no ceiling found; **27** reached          | ledger §6       |
| subagents dispatched _by_ one step | **5**, and it **queues** past that        | R-concurrency-1 |
| sub-agent nesting depth            | **5** (`MAX_SUB_EXECUTION_DEPTH`)         | R-nesting-1     |
| model turns per sub-execution      | **300**, resettable by a steering message | R-limits-1      |
| context before compaction          | **80%** — and see the hazard below        | R-limits-3      |

### Concurrency: step sessions are not capped; delegated subagents are

Kiro's documented pool of 4 concurrent subagents **does not describe either
population here**. Step sessions showed no ceiling at 27 concurrent across three
runs (ledger §6, finding 1). Subagents spawned _by_ a step are a different
population with a ceiling of **5** — and the two methods agree beautifully:

- **Measured:** peak overlap was exactly 5 at both N=8 and N=12, never 6, while
  every leaf eventually ran. A third run put two dispatchers in one `parallel`,
  five leaves each, and reached a peak of **10** — so the 5 is _per delegating
  step_, not a shared pool (ledger §6, finding 3).
- **Read from source:** `MAX_CONCURRENT_SUBAGENTS = 5`, and the semaphore is
  minted per parent execution via a `WeakMap` keyed on the execution object, so
  "every parent — including a subagent that itself dispatches — gets its own 5
  permits" (R-concurrency-2).

The ledger lists "what imposes the fan-out ceiling of 5" as an open question;
the static read answers it, and the per-execution scoping predicts exactly the
peak of 10 that was measured. **Tiers multiply rather than share**: root's 5
permits hold 5 dispatchers, each holding 5 workers, for 25 concurrent leaves.

One mechanism difference matters more than the number. The widely-quoted 4 comes
from the **v2 Rust** binary, where it is a _rejection of an oversized batch_
(`You can only spawn 4 or fewer subagents at a time`). Under v3 the sixth
dispatch **queues** on the semaphore and proceeds when a permit frees; the only
errors on that path are abort races. Code written against v2's semantics treats
over-fanout as an error path that under v3 never fires.

### The hazard that should shape your design

**A sub-execution crossing 80% context tombstones its _parent_ session's stored
history** (R-limits-3). Compaction fires at `SUMMARIZATION_THRESHOLD = 80`; the
detection guard contains no sub-execution, depth, or session-identity test; and
a dispatched sub-agent's `chatSessionId` **is its parent's**, carried verbatim
through the dispatch context. When the summarization cycle completes it persists
against that id, appending a tombstone whose `truncatedMessageCount` covers
_all_ the target session's messages.

So a long-lived worker can declare its parent's entire stored conversation
truncated and replace it with a summary of the worker's private task. The damage
is invisible at the time — the parent's live context is untouched — and lands on
the next session load.

**Keep workers short by construction, not by convention.** That is the strongest
argument for the one-task-per-iteration shape in §7: a fresh session per task
never accumulates enough context to compact.

### Dynamic node editing

You can rewrite a running workflow's future, with three hard edges (ledger §5):

- **Top-level only.** `replace_remaining` cannot reach inside a `sequence` or
  `parallel`. If your whole workflow is one `sequence` — as most good shapes are
  — it is effectively immutable, and a "replacement" appends instead.
- **Applied at the next step boundary** while a step runs; immediately when
  paused or idle. A queued replacement is visible in `inspect_workflow` as
  `Pending replacement (queued, …)`.
- **You cannot add a branch to an in-flight `parallel`.** Not because of join
  semantics but because **no API addresses a running node** —
  `replace_remaining` replaces a suffix of the top-level list, and a running
  `parallel` is the current node, not in that suffix.

So _incremental synthesis_ — deciding node N+1 after seeing node N's result —
works only if you author the workflow as a **flat top-level list** and accept
that you rewrite the tail rather than editing in place. If you want freed slots
to backfill immediately, this is the wrong tool; use §7's queue instead.

### Overhead

Per-iteration session overhead grows with worker count at roughly **0.57–0.77 s
per worker** (a noisy four-point fit; use the measured value for your size, not
the coefficient). At 19 workers the median was 14.6 s per iteration; at 27, 18.2
s.

Effective parallelism was 6.3× at 18 workers and 8.7× at 27 — far below peak,
because trailing rounds leave most workers idle. **Keep tasks per worker at 5 or
more** so drain and trailing-round costs amortize (ledger §6.1).

Fan-out startup latency is erratic and unexplained: 24.6 s for a 6-branch
fan-out, 5.0 s for 9, ~0.3 s for 27 across three runs. Do not rely on any of
those figures.

## 6. Ad-hoc agents and nested workflows

### Can a step spawn agents outside the graph?

**Yes — but not with any bundled agent.** This is a property of the agent
_profile_, not of the step surface, and the distinction is the whole answer.

**None of the ten bundled agents can delegate.** There is no
`orchestrate_subagent`, `delegate`, `subagent`, `spawn` or `Task` in any of
them. For `wf-coder` this was corroborated three ways: the step's own report,
the enumerated tool list, and the absence of any artifact from the delegated
work (ledger §3.6). Two names invite confusion and grant nothing —
`subagent_response` returns the step's own result to its parent, and
`disclose_context` only loads skill/steering text.

**A custom `.kiro/agents/` profile declaring the `subagent` group does delegate,
and the dispatch genuinely works.** This was proved by construction rather than
by asking: a parent profile was given `subagent` **and nothing else** — no
write, no shell, no way to create a file by any means — and told to dispatch a
leaf that writes a token to an absolute path. The file exists and holds the
token, so the leaf ran (ledger §3.7). Withholding the capability, rather than
forbidding its use, is what makes that airtight.

The tool shape is **one tool per callable target**, not one tool taking a role:

```
subagent_probe-echo-leaf   subagent_wf-coder   subagent_semantic_reviewer   …
```

The target set is every registered custom profile plus all ten bundled agents —
15 in the measured environment — and it is **self-inclusive**, so a dispatcher
can name itself. Bundled agents appear as targets without existing on disk.
Orchestrator-side modes (`context-gatherer`, `custom-agent-creator`,
`general-task-execution`, `introspect`) are a _fourth_ population and are
**not** step targets.

Custom profiles are picked up **mid-session** without a restart. One caveat: a
delegation inventory taken right after a registry change is unreliable — one run
saw only 2 targets and no bundled agents at all, while an identical later run
saw the full 15. A deliberate reproduction attempt failed, so this is not
timing-triggered and not reliably reproducible; the advice is simply to re-run
the inventory before believing it (ledger §3.5).

**How deep, and how wide:**

- Depth is capped at **5** (`MAX_SUB_EXECUTION_DEPTH`), gated as
  `if (currentDepth >= MAX_SUB_EXECUTION_DEPTH)` _before_ dispatching — so the
  deepest reachable execution is depth 5 with root at 0: six levels of
  execution, five of nesting. A root/dispatcher/worker arrangement spends 2,
  leaving 3 (R-nesting-1).
- Width is **5 per delegating step**, queueing past that (§5).
- **Subagent sessions are outside the node budget.** Verification, cleanup and
  post-run assertions can run as ordinary subagents at zero node cost (ledger
  §8.1) — though since the cap is 20 and not 21, an in-workflow verify step now
  fits too, and is preferable.

**One thing to know before you rely on the rejection.** A depth-limit refusal is
**not thrown**. It is emitted as an `Error`-state action and returned as a
_synthetic tool message with an empty response_, so the parent model sees a
failed tool call and keeps going. Code that expects an exception, or that reads
an empty response as "no work found", will misread it (R-nesting-1).

Whether a dispatch **blocks** the calling step is register item R-2.

### Can a step create a second workflow?

**The contract says no; the evidence is not unanimous, and this is the most
consequential open question in the brief.**

- The workflow contract states plainly that a workflow step cannot start a
  workflow (ledger §3.1).
- The ledger's own drift ledger lists this as **open**, because later static
  surface analysis found that workflow-step sessions may expose `run_workflow`
  when enabled. Its working rule: _do not depend on nested workflows without a
  targeted live probe._
- The mechanism that makes the conflict plausible is visible in the engine
  source: the registration comment notes that "**Workflow step sessions always
  pass this gate**: `createWorkflowStepSession` sets
  `settings.workflows.enabled` explicitly, so the step completion protocol keeps
  its `send_message` signal" (R-workflow-4). Since registration is
  all-or-nothing on that one boolean (§1), a step session passing the gate would
  receive `run_workflow` **along with** `send_message` — the tool it actually
  needs.

So the two claims are reconcilable: the _engine_ may well register the tool in a
step session while the _scheduler_ refuses a nested run. Nobody has run it. That
is register item R-3, and it is the one worth spending a probe on, because it
decides whether the 20-node cap is a per-run budget or a per-tree one.

Separately: **parallel workflow runs are not in doubt.** Concurrency composes
across runs through the filesystem, and three simultaneous runs were measured
(ledger §6, finding 2). Multi-run composition is only _necessary_ beyond 20
workers.

Note also that no bundled agent has `update_workflow` — all nine non-`wf-coder`
agents reported `NO_UPDATE_WORKFLOW` in one parallel probe, and `wf-coder` was
measured separately. This **contradicts** the contract's claim that a top-level
step agent may call it, and makes `update_status` unreachable dead surface for
every bundled agent. Only the orchestrator's `replace_remaining` is real (ledger
§3.6).

## 7. Wiring patterns

### Pattern A — the queue-pull pool (the one that actually scales)

The engine is a static DAG, so **do not express tasks as nodes. Express workers
as nodes, and put tasks in a queue directory.**

```
sequence
├─ parallel (joinPolicy: allSettled)
│   ├─ repeat w1 … stopCondition fileCheck {{workdir}}/w1-done.json → drained: true
│   │   └─ step w1   → claims ONE task per iteration, then exits
│   ├─ repeat w2 … (same shape)
│   └─ … up to 19 workers
└─ step verify   → asserts the queue actually drained
```

Why this shape wins (ledger §9):

- **No wave barrier.** Each worker is an independent loop with its own stop
  condition, so workers are never synchronized — `w1` began iteration 2 at
  t=14.7 s while `w9` was still on its first until t=19.6 s.
- **Task count is unbounded** and decoupled from the node cap.
- **Runtime-discovered work needs zero DAG mutation.** Children injected at t≈8
  s were claimed at t≈15 s by _different_ workers.
- **Self-healing.** A dead worker simply fails to claim; the others absorb the
  queue. Attrition costs throughput, not correctness.

Three details are load-bearing:

1. **Claim by atomic `mv`.** `rename(2)` is atomic within a filesystem, so a
   losing worker's `mv` fails and it tries the next file. **Zero duplicate
   claims** at 9, 18 and 27 workers, including across three independent runs. No
   lock needed.
2. **The premature-drain guard is mandatory.** A worker finding an empty queue
   must not drain while any task is still in flight, because an in-flight task
   may still inject work. Observed live: two workers hit `wait-inflight=6` and
   correctly drained later — without the guard the pool would have dropped 2 of
   18 workers just before three children landed.
3. **A drain assertion is mandatory.** With `onMaxIterations: continue` a run
   can complete with work stranded and no error raised: 40 seeded + 3 injected −
   18 processed = **25 stranded**, and `inspect_workflow` reported
   `Status: completed` with every node green. Nothing in engine state hints at
   it.

The two scripts are in ledger §9.2 and §9.4 and have no repository coupling —
they take the queue root as an argument. Put the queue root **inside the
workspace** (§7 traps below).

### Pattern B — the 6 × 3 fan-out

For six independent chains of three stages, the shape is a `parallel` of six
`sequence` branches. It costs 18 of 20 step nodes (§5), leaving room for a
verify step. Two settings are worth arguing about, and the fixtures argue both:

- **`joinPolicy: "allSettled"`, not `"all"`.** `all` aborts every sibling on the
  first branch _failure_, so one poisoned item cancels every other branch. Under
  `allSettled` a failing branch is contained, the other five run to completion,
  and the run **still reports `failed`** — nothing is swallowed. (`allSettled`
  changes _cancellation_, not the verdict: the step after the join never ran in
  either case — ledger §7.7.)
- **`onMaxIterations: "abort"`** for any `repeat` inside. Not `pause` — resuming
  grants no further iterations and a paused run cannot be retried, so it is a
  state you cannot leave. Not `continue` — it marks the repeat COMPLETED on
  exhaustion, indistinguishable from a genuine drain, so an unfinished branch
  scores as success.

Note the vendor's own long-loop recipes (`ralph`, `goal`) ship
`onMaxIterations: "pause"`. Do not copy that field from them.

`fixtures/kiro-primitives/workflows/drain.workflow.json` is a working
five-branch instance of this shape; `generate.sh` beside it is the only place
the branch count lives, and is the practical answer to "how do I get six of
these" (§4).

### Pattern C — a writer → reviewer loop

Build it as a `repeat` containing a `sequence` of two steps, and thread state
through a **verdict file**, not through captured output (§3). Then:

- Set `maxIterations` high enough up front and prefer
  `onMaxIterations: "abort"`, so work that cannot be approved fails fast.
- Make the writer derive "is this a first pass?" from **the repository**, not
  from whether the verdict file exists — an interrupted-step resume re-runs the
  writer with that file still absent (§2).
- Do not use a step `completion` block as the gate. It looks like one and is
  actually an **unbounded retry loop**: a step whose completion file it was
  forbidden to create was re-nudged at ~8 s intervals for at least 7
  invocations, with no `maxIterations` equivalent and no escalation to failure.
  Writing the expected `{"done": true}` ended it immediately (ledger §7.5). If
  you do use one, make the step itself write the completion file, and only on
  idempotent work.

### The traps that fail silently

Ranked by how quietly they fail, which is the ranking that matters.

**1. A step agent can skip its work entirely and still report `[completed]`.**
Measured at 18 workers: 67 engine iterations against 61 actual invocations — 6
silent no-ops (~9%). One captured output read _"The command already ran and
exited 0; I'm not re-running it."_ The prompt had said "Do not run it a second
time", meaning within a session; the agent applied it across iterations. The
wording that fixed it, verbatim (ledger §7.2):

```
IMPORTANT: you may have run this exact command before, in an earlier iteration
of a loop. That is expected and completely irrelevant. Run it AGAIN now
regardless. Each invocation is a separate and necessary unit of work. Never skip
it. Never conclude that it has already been done.
```

After that change: zero no-ops across 27 workers, and the prompt-vs-model
confound was later retired by holding the model fixed. **But this wording is
only safe for idempotent work** — it instructs an agent never to skip, so on a
non-idempotent task it invites double execution.

To detect it at all, **have every step leave a durable trace**, then compare:

```
engine iterations = number of `sequence:<repeatId>#<n>` nodes in inspect_workflow
real invocations  = side-effect records your step actually wrote
no-op iterations  = engine iterations − real invocations
```

**2. A pre-satisfied stop condition caps a `repeat` at one iteration — and the
run reports success.** `stopCondition` is evaluated only _after_ an iteration
runs, never before the first, so a `repeat` is a do-while and can never serve as
an idempotence guard. A target file left behind by an _earlier run_ is enough to
do this. The stop target must be created by the run that consumes it: write into
a per-run directory, or delete the target before the `repeat` starts (ledger
§7.1).

A `repeat` that finished suspiciously fast has these two causes and the
iteration count separates them — a no-op leaves engine iterations exceeding
invocations; a pre-satisfied stop leaves one iteration and one matching
invocation.

**3. Four authoring traps the engine accepts silently** (`contract.jq`, each
quoting the engine function it derives from):

| Trap                                  | What actually happens                                                                                                                                              |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `jsonPath` is **not** JSONPath        | the engine does `split(".")` then property access. `"$.drained"` reads a property literally named `$`, resolves undefined, loop never stops                        |
| an **array**-valued `fileCheck.value` | means "any of these candidates" — `value.some(c => deepEqual(resolved, c))` — not "match this array"                                                               |
| a **templated** `fileCheck.path`      | the load-time containment check does `if (indexOf("{{") === 0) continue;` — a path _starting_ with a template skips validation entirely and can only fail mid-loop |
| a `repeat` with **neither** stop form | accepted. The only stop-form rule concerns defining _both_. Such a loop runs to `maxIterations` with nothing reporting why                                         |

That third row resolves something the ledger could only infer. From five probe
rows it deduced "prefix resolution" and flagged one untried case —
`dev/../../../tmp/x.json`, a literal in-root prefix followed by a literal
escape. The engine source settles it: `firstRef === 0` is the _only_ skip, so
that path is containment-checked and rejected. The escape is specifically a
**parameterized root**, not interpolation in general.

**4. Stop-condition state must live inside the repository.** A `fileCheck` path
outside the workspace roots evaluates to `false` **permanently**, with no error,
so the loop burns every iteration it has. Never `/tmp`. And `stopWhen`'s
`"{{id.output}} contains <text>"` form matches against _captured output_, so it
inherits the empty-capture hazard wholesale — under a cheap model the condition
can never match and the loop silently runs to `maxIterations` (ledger §7.6).

### Small things that save a run

- **Model/effort cascade is step > workflow > parent session.** Omitting both is
  the correct default. Never guess a `modelId` — discover them with
  `kiro-cli chat --list-models -f json`; an unknown id is the one field that
  passes validation and then fails mid-run with no fallback (ledger §10).
- **Pinning a cheap model to mechanical steps is worth it** — 27 workers on
  `claude-haiku-4.5` (0.4×) instead of `claude-opus-5` (2.2×) is a 5.5× cost
  reduction on work that runs one shell command. Just not on a step whose output
  something downstream reads.
- **Step agents run in the parent workspace, not a worktree.** Pass the worktree
  path as an input, make every path in every prompt absolute, use
  `git -C <worktree>`, and do not describe the worktree as the agent's "working
  directory" — the agent will believe you and use relative paths (ledger §8.5).
- **`wf-review-aggregator` cannot execute anything** (no `execute_bash`), and
  `semantic_reviewer` alone lacks `str_replace` so it rewrites whole files
  rather than patching (ledger §3.6). Pick step agents by tool set, not by name.

## 8. Open-item register

Questions this repository's research cannot answer, each with the single
measurement that would settle it. **Nothing here is a backlog** — probe a row
only when the answer would change a concrete design.

| #    | Question                                                                                                                                                                                  | The one measurement                                                                                                                                                                                                                                                    |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R-1  | What is the node structure of `feature-pipeline` and `semantic-review-multi-model`? Only their input schemas are recorded, and six of seven recipes were never run.                       | `run_workflow` is not needed — call the ACP `listRecipes` method, which returns each recipe's precomputed node `plan` alongside its inputs.                                                                                                                            |
| R-2  | Does a `subagent_<role>` dispatch **block** the calling step, or is there an async/background mode?                                                                                       | One step on a `subagent`-only profile dispatches one leaf that sleeps 30 s and writes an end marker; the step writes its own marker on return. Compare timestamps: step-marker after leaf-marker means blocking.                                                       |
| R-3  | Can a step create or launch a **second workflow**? The contract forbids it; the step session appears to register `run_workflow` anyway.                                                   | One step on a profile with the workflow tool group, prompted to call `run_workflow` on a trivial one-step definition and report the exact response. Three outcomes: it runs; it is refused with an engine message; the tool is absent.                                 |
| R-4  | Do the ACP run-control verbs (`pause`, `resume`, `cancel`, `retry`) actually work against a live run? They were probed for reachability and param shape, never driven through a real run. | Launch the §7 pool, `pause` it mid-drain, `inspect` to confirm the transition, `resume`, and confirm workers resume claiming. One session, one run.                                                                                                                    |
| R-5  | Can `update_workflow` / `update_status` be **granted** to a custom step agent? No bundled agent has it, contradicting the contract.                                                       | Write a `.kiro/agents/` profile declaring whatever group carries `update_workflow`, run it as a single top-level step, and have it report its own tool inventory.                                                                                                      |
| R-6  | Does a permission `match` rule on a `subagent_<role>` tool name **bind** inside a step?                                                                                                   | Give one step agent two delegation targets, write a rule matching one name and not the other, run a step that calls both. Three distinguishable outcomes: both go through (no bind), one refused (binds), or the step stalls (consulted but unanswerable from a step). |
| R-7  | Can a profile sit in `.kiro/agents/` and never become a delegation target? Presence on disk has not been shown to suffice.                                                                | Write a profile, then read the agent roster and one step's target list. Likeliest outcome is the null one, which retires the premise.                                                                                                                                  |
| R-8  | What triggers the resume of a run paused by an interrupted step, and how long is the paused window?                                                                                       | A deliberate mid-step interruption followed by an open-ended wait with **nothing** else touching the run or the host, timing the transition if it comes. Cheap in setup, expensive only in patience.                                                                   |
| R-9  | Where does step-session concurrency actually break? 27 was reached with no engine complaint.                                                                                              | The overhead law suggests the economics fail before the engine does, so the useful version is a cost question, not a limit question — measure wall-clock per task at 20 / 30 / 40 workers and find where it stops improving.                                           |
| R-10 | Is `stopCondition.completionSignal` real? It was discovered in a runtime schema error and validates, but is absent from every upstream document and has never been run.                   | A two-iteration `repeat` whose step signals `success` via `send_message`, with `"stopCondition": {"completionSignal": "success"}` and `maxIterations: 3`. Count the iteration wrappers.                                                                                |
| R-11 | Does the fan-out ceiling of 5 hold across profiles and leaf types? All three runs used the same capability-starved parent and the same shell leaf.                                        | Repeat the N=8 dispatch probe with a parent holding a full tool set and a leaf that is not a shell one-shot.                                                                                                                                                           |
| R-12 | Which component emits `agent "<name>" not found, using "default"`, and does a silent fallback to `default` ever actually happen?                                                          | The second half is what matters — a measurement taken on a silently-downgraded surface would look plausible and mean nothing. Run one step naming a deleted profile and check whether _any_ artifact appears.                                                          |

Two standing caveats that are not open questions but should travel with every
figure above:

- **Version skew.** The live measurements are `kiro-cli 2.16.0`; the code reads
  are KAS 2.15.1 with byte offsets known to have moved in 2.15.2. Where both
  exist they agree, which is the main reason to trust either. The constants are
  the durable part; the offsets are not.
- **Pre-release.** `workflows` is dark-shipped at 0% pending certification.
  Every behavior here can change without notice, and none of it is documented
  upstream.
