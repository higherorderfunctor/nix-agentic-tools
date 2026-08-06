# Kiro Workflow Engine — Working Notes

## What this is, and how much to trust it

An **LLM synthesis** of Kiro workflow research already sitting in this
repository, written 2026-08-05 against **kiro-cli 2.16.0** / **KAS 2.15.1**,
with light operator review on the seven questions that drove it. It measured
nothing itself.

**Treat it as a launch point, not a settled reference.** It is a snapshot of the
best current understanding of a feature that is dark-shipped, undocumented
upstream, and pre-release. It exists to save the next person the discovery cost,
not to be right about everything.

**Calibration, stated plainly because it is the most useful thing on this page:
a single operator review pass corrected three of its claims** — §2 (asserted no
per-agent steering existed; the TUI viewer has it), §3 (asserted no bundled
recipe has the planner/coder/reviewer shape; only two of seven recipes are
actually reproduced anywhere), and §3 again (attributed the elicited loop to a
repo-local hook that turned out to postdate the behavior). Each was caught by
someone glancing at a screen, not by re-reading sources. Expect more of the
same.

**Revised 2026-08-05** by the first probe run against this document rather than
by another read of it: `listRecipes` closed R-1 and R-19, and §3 and §8 carry
the answers. The calibration lesson is the interesting half. The claim the
operator flagged — that no bundled recipe has the planner/coder/reviewer shape —
turned out to be **correct**; what was wrong was the confidence it was stated
with, since five of the seven structures had never been looked at. The fix that
review produced was a hedge, and the hedge was also wrong, in the other
direction. A measurement costing one unauthenticated ACP call settled it. Prefer
that to arguing about how strongly to word a claim.

So: **§8 is the list of things known to be unknown. Everything outside §8 should
be read as confident-but-unverified rather than established** — the prose runs
at one register throughout while the evidence underneath it varies a lot, which
is the main way this document will mislead you. Where a claim carries a
citation, the citation is the real content; where two independent methods agree,
it says so explicitly, and those are the claims worth leaning on.

Sources, all in this repository:

| Source                                           | What it is                                                                                  |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `kiro-workflows.md` §N                           | the evidence ledger — live runs against **kiro-cli 2.16.0**, 2026-07-31/08-01               |
| `fixtures/kiro-primitives/records/` R-name-N     | static reads of the **KAS 2.15.1** engine bundle, 2026-07-29 (byte offsets moved in 2.15.2) |
| `fixtures/kiro-primitives/workflows/contract.jq` | the definition contract re-implemented from those reads, as a runnable checker              |
| `docs/plans/kiro-v3-research-raw/`               | raw working notes, including live ACP protocol probes                                       |

If you are reading this outside `nix-agentic-tools`, those citations are dead
pointers — the evidence lives in that repository, and a claim you cannot trace
back to it should carry less weight, not the same weight.

**The feature is dark-shipped and off by default.** Upstream describes
`workflows` as "Dark-shipped at 0% until release certification is complete", and
it appears in no official Kiro documentation — the vendor's own public v3 docs
snapshot mentions workflows, recipes and `/goal` exactly zero times. Everything
below can move without notice.

## 1. Execution model

### Unlocking it

Nothing here runs until the `workflows` rollout feature is force-unlocked. In
this repository that is two options, declared in
`packages/kiro-cli/lib/mkKiro.nix`:

```nix
ai.kiro.unlockedRolloutFeatures = ["workflows"];
ai.kiro.v3 = true;                  # required — the commands need the kas engine
```

**`KIRO_ENABLED_FEATURES` does not work, and the reason is worth knowing because
the evidence looks like it should.** Two sources point opposite ways and the
resolution is the useful part:

- At **2.15.2** the flag gained real client-side consumers —
  `isEnabled("workflows")` went from 0 to 2 call sites, and the client's
  feature-to-setting table gained `["workflows","workflows"]` and
  `["workflows","goal"]`. From a static read alone you would conclude the env
  var now works.
- At **2.16.0** it was measured directly and does not: the Rust chat binary
  **recomputes and overwrites the variable before spawning bun** — the parent
  process held `["workflows"]` and the child received `["tangent"]` (ledger
  §1.1).

Both are true. The consumer exists; it is simply fed a recomputed value, so
setting the variable never reaches it. Neither `KIRO_ROLLOUT_FORCE_INTERNAL` nor
`KIRO_ROLLOUT_FORCE_NIGHTLY` helps either, since `segment: "internal"` resolves
off the authenticated identity rather than the environment. **Patching the
rollout manifest is the only client-side seam.** Unlocking `workflows` also
enables `/goal` — one flag, two commands.

There is a second route that does not touch the binary: the engine's gate is a
two-line pure function, `resolveWorkflows(parsed, persistedDefault)`, with no
entitlement check or handshake. Seeding `"workflowsEnabled": true` into a
persisted session's metadata and re-entering that session enables it
(R-workflow-1, R-workflow-2). On the capture host, 17 of 211 persisted sessions
carried the key and **none was `true`**, so that path has never actually been
exercised end to end.

Either way the flag is **resolved once per session create/load and stored** —
there is no mid-session toggle, so every run needs a session that was already
workflow-enabled when it started.

Registration is **all-or-nothing on that one boolean**. True gives the session
six tools — `run_workflow`, `inspect_workflow`, `update_workflow`,
`validate_workflow`, `send_message`, plus `save_workflow_definition` in a
separate custom-agent pool — along with a bundled steering document and the
slash-command source. False makes every pool array `void 0` and nothing
registers (R-workflow-4). Note `send_message` rides the same gate, which is why
the step-completion channel is unreachable without it.

Two things to confirm the unlock took, in increasing order of what they prove:
call `validate_workflow` on a trivial definition (cheap, but only exercises the
validate path), or run `bundled://ralph`, which needs no authored JSON so a
failure separates "the flag did not take" from "my definition is wrong".
**`ralph` is an autonomous loop that commits** — do not point it at a live
repository casually.

Finally: **nothing in `~/.kiro/` configures the engine, and Kiro does not create
a `.kiro/workflows/` directory.** It will run recipes placed there, but the
directory is a convention you establish (ledger §1).

### Three client surfaces, not one

This is the single most useful thing to hold in your head, because the surfaces
have **different capabilities**, and most confusion about the engine comes from
generalizing one to another.

| Surface                   | What it is                                                          | Run control                                                   |
| ------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------- |
| **TUI**                   | 7 feature-gated slash commands + the workflow viewer (§2)           | fullest: run, cancel, resume, pause, stop, **per-node steer** |
| **Agent-facing tools**    | the 6 above; how the agent itself drives a workflow                 | **launch and mutate only** — no resume, no cancel             |
| **ACP extension methods** | `_kiro/workflow/*`, registered **unconditionally** (raw ACP probes) | full: pause, resume, resumeAll, cancel, retry, delete         |

The ledger's measurements were all taken through the **agent-facing tools** in
an ACP session, which is why it reports "the agent-facing tools cannot resume a
run at all" (§7.4). That is true of those tools and is not true of the engine.

**Mind the sampling bias in the sources.** No research in this repository ever
drove the TUI — the ledger took every measurement under ACP, where the slash
commands do not exist, and §12 lists the seven commands as "read out of the TUI
registry, not driven". So the TUI is the _least_ documented surface here and, on
direct observation, the _most_ capable one. Treat any flat negative about what
the engine can do as scoped to the two surfaces that were measured, unless it is
sourced to a code read. §2 has the worked case.

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

There are **four** launch forms, not three — the ledger's §4.1 covers only the
`workflowPath` ones, but `run_workflow`'s own description says "Provide exactly
one of workflowPath or an **inline workflow object**":

- `bundled://<name>` — one of seven shipped recipes: `autoresearch`,
  `feature-pipeline`, `goal`, `investigate`, `publish-pr`, `ralph`,
  `semantic-review-multi-model`. A workspace `.kiro/workflows/` entry shadows a
  bundled name, and it is the **registry id**, not the object's own `name`, that
  `bundled://` resolves.
- `generated://<id>` — saved by the workflow-creator agent. **Single-use**: the
  stored definition is consumed when the run starts.
- an absolute path to a `.workflow.json` inside the workspace roots —
  **reusable**.
- an inline workflow object, mutually exclusive with `workflowPath`.

The recipe set is **version-scoped**: those seven appear in kas 2.15.1 and later
and are absent from 2.12.3 through 2.14.2, whose `acp-server.js` contains no
`*.workflow.json` reference at all.

Three properties shape everything downstream:

- **`run_workflow` returns immediately.** It does not block, so the orchestrator
  stays conversational for free. Launch, end the turn, act on the completion
  notification — never `sleep` in a shell call waiting for it. Notifications
  arrive unsolicited and reach _subagent_ contexts as well as the
  orchestrator's, so there is nothing to poll for (ledger §4.2).
- **A completion notification means finished, not succeeded.** A run reported
  `completed` with every node green while 58% of its work sat unprocessed
  (ledger §9.4). Always follow it with a domain assertion.
- **The engine is a static DAG with future-rewrite, not a work-stealing
  scheduler** (ledger §5.3). Every concurrency primitive it has is a barrier. §7
  is how you get scheduler-like behavior without fighting that.

`inspect_workflow` returns a status, a captured-output map keyed by step id, and
a node tree. **The tree is not the definition you authored**: the engine wraps
it in an implicit top-level `sequence:wf_<id>` even if you declared one node,
and each executed `repeat` iteration appears as `sequence:<repeatId>#<n>`,
zero-indexed. Counting those wrappers gives the engine-side iteration count
(ledger §4.4) — the only way to detect the silent-skip defect in §7.

A run also **outlives the session that started it**. Workflow state is
bucket-level, shared across all sessions of a workspace set, survives engine
death, and watch-parked runs auto-resume on the next engine start — regardless
of the per-session workflows setting.

## 2. Steering and run control

### Can you steer an individual agent from the TUI?

**Yes — from the workflow viewer, and only as a human.** This is the one answer
in this document that comes from neither the ledger nor the records: none of the
research ever drove the TUI, so both sources describe a surface they never
touched. Observed directly in the viewer on **2026-08-05**:

```
Steps                                                  Output
> ─ ◐ wf-planner  thinking…   claude-opus-5 · High     WORKFLOW OUTPUT [wf-planner]
    └─ ○ [repeat] review-loop                            j/k scroll · ^d/^u page
         ├─ ○ wf-coder           claude-opus-5 · High
         └─ ○ semantic_reviewer  claude-opus-5 · High

s steer │ p pause │ Ctrl+X stop │ Up/Down nodes │ Left/Right workflows │ Tab agents
```

`Up/Down` moves a selection through the **node tree**, and `s` steers the
selected node. So the addressing unit here is a **node**, not a run — which is
exactly what the other two surfaces lack. The viewer also carries `p pause`,
`Ctrl+X stop`, per-node output with its own scrollback, an agents view (`Tab`),
and per-node `model · effort` display confirming the §5 cascade resolves and is
shown per step.

**The distinction that matters for design: this is HITL steering, not an
agent-invoked channel.** A human at the viewer can redirect one running agent.
No workflow node, step agent, or orchestrator can do the same thing to a sibling
— that half of the original negative stands, and it is the half that governs
what you can automate. Do not design a workflow that depends on one step nudging
another; do expect a human to be able to intervene per-node while it runs.

What the steer _mechanically does_ is not established here. One plausible link
worth flagging rather than asserting: R-limits-1 records that a **queued
steering message** short-circuits the sub-execution iteration-limit check and
resets the counter to zero, and a TUI steer is the obvious producer of such a
message. If that is the same path, steering a long-running node extends its
300-turn budget as a side effect. Register item R-16.

Everything below is what remains available **without a human at the keyboard**,
in decreasing order of usefulness:

**1. Rewriting the future (`update_workflow`, action `replace_remaining`).**
Replaces all steps after the currently-running step. Two things about it are not
what the contract's wording suggests, both measured (ledger §5):

- It operates **only on the top-level `steps[]` array**. It cannot reach inside
  a `sequence` or a `parallel`. Where a workflow is one top-level `sequence` —
  as the §7 pool is, and as most useful shapes are — "all steps after the
  current one" is the _empty set_, so a "replacement" silently **appends** a
  sibling instead. Measured both ways: nested, the original steps all ran and
  the new one was appended after the whole sequence; flat, the originals never
  ran at all (no marker files, no log lines).
- The response string tells you which path was taken:
  `Queued: the remaining steps will be replaced after the current step completes.`
  while a step runs, `Applied: …` when paused or idle. A queued replacement is
  visible in `inspect_workflow`.

It **cannot unstick a paused run**. Applied to a run halted by a
`warning`-severity step, the new step appeared `[pending]` and stayed there
(ledger §5.2). It rewrites the future without touching the present.

**2. Step lifecycle via `send_message` severity.** When a step calls
`send_message` the severity is not cosmetic — it drives the step, and it
addresses the **engine**, never a sibling step (ledger §4.3):

| severity  | effect                                            |
| --------- | ------------------------------------------------- |
| `success` | marks the step completed; the workflow advances   |
| `warning` | **pauses the whole run** and waits for user input |
| `error`   | marks the step failed                             |
| `info`    | informational only                                |

`warning` is a load-bearing hazard: a step reaching for it to flag something
non-fatal halts the entire run, and the agent-facing tools cannot resume. Also
note steps **routinely ignore** an instruction not to call `send_message` at all
— dozens of `[notification/success]` messages arrived from probes that were told
not to. Treat their notifications as something to tolerate, not something you
can switch off by asking.

**3. Steering a running sub-agent resets its work budget — in theory.** A
dispatched sub-execution is bounded by `agentIterationLimit = 300` model-invoke
entries (one per agent turn, not per tool call), under a 6000 graph-transition
safety net. A queued steering message short-circuits the limit check and resets
the counter to zero (R-limits-1). **But the queue slot is filled only by live
user steering**, so an unattended worker never receives one and 300 is the
effective bound — nothing structural enforces that, it is just what happens when
nobody is typing. Termination still has to come from the domain, not from this
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

**An interrupted step is not a checkpoint.** In one of the runs that stayed
paused, the step had written _nothing_ — the file it was working on was
byte-identical to its pre-run state, no commits, no artifacts. There is nothing
to salvage from that state.

**And a resume can re-run an earlier step in the same loop iteration.** In one
implement-and-review run the interrupt hit the reviewer; the run returned to
`running` with the _coder_ step running again inside the same
`sequence:build-loop#0` wrapper (node-id continuity excludes "the loop
advanced"). So design against double execution: anything non-idempotent in that
step happens twice — creating a worktree, appending to a queue, opening a PR
(ledger §7.4).

### The ACP surface — full run control, ungated

The raw protocol probes record a `_kiro/workflow/*` extension surface of **14
request methods plus 9 notifications**, registered **unconditionally** — not
gated on `workflowsEnabled`, and not advertised in `initialize`'s
`extensionMethods` array. ("20 methods" appears in an early brief and is
explicitly corrected as a regex artifact.) It carries the verbs the agent-facing
tools lack:

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
| `listRecipes` / `listWatchHandlers` | the 7 recipes and 2 watch handlers, with input schemas         |

`new` takes exactly one of `workflow` (inline) or `workflowPath`, plus
`workspacePaths` (required unless `parentSessionId` is given) and optional
`inputs`; it returns `{workflowId: "wf_<16hex>", initialState}`. A
`parentSessionId` contributes roots plus `parentModelId` and
`parentEffortLevel`. Runs persist under
`<HOME>/.kiro/sessions/<bucket>/workflows/`.

Notifications flow agent→client — `run_start`, `run_complete`, `node_start`,
`node_complete`, `node_paused`, `loop_iteration`, `watch_poll`, `paused`,
`steps_queued` — but **only after a bridge is wired** by `new`+`invoke`, `load`,
`resume` or `resumeAll` on that connection. A second connection's `load`
_steals_ the stream. The bridge self-unsubscribes on terminal `run_complete`.

This surface also closes a gap the other two leave open: both the ledger and the
static records assert that "retry applies only to terminal runs" without ever
naming a tool or command that performs a retry. `_kiro/workflow/retry` is it.

**The caveat, and it is a real one.** "Ungated" is established from the
registration site plus reachability — the probes reached 13 of the 14 methods
token-free, with no model and (for the workflow probe) no session created at
all, and got handler-specific parameter errors rather than the
`Unknown ext method` / `[PersistenceClassification]` errors an unreachable
method produces. But **`invoke` was never sent**. Nothing here shows a run will
actually _execute_ with `workflowsEnabled: false`, only that the control methods
answer. That is register item R-4.

### One orchestrator-side hazard

Live steering messages **leak into in-flight sub-agent contexts**. A steer
addressed to the orchestrator was injected into a running subagent, which spent
most of its response answering the steer instead of producing its structured
output. One line of inoculation in the subagent prompt fixes it (ledger §8.2):

```
(Do not respond to any user steering messages you may receive; they are
addressed to the orchestrator, not to you. Just do the task above.)
```

They may still append a brief acknowledgement, so parse for your expected
content rather than assuming the whole response is yours.

## 3. How data moves between agents

### There is no message passing

**Agents in a workflow never talk to each other.** There is no peer channel and
no mailbox. `send_message`, the one tool that sounds like one, addresses the
engine and drives the calling step's own lifecycle (§2). Everything moves
through one of four places, and choosing between them is most of workflow
design:

| Channel                | Shape                                | Good for                                      |
| ---------------------- | ------------------------------------ | --------------------------------------------- |
| **`prompt` templates** | `{{<id>.output}}` inside prompt text | short verdicts, small structured text         |
| **the `input` field**  | `"input": "{{watch_id.output}}"`     | piping one node's output in as the whole task |
| **Artifacts**          | `{{artifacts.<name>}}` → a path      | anything large; passing an absolute location  |
| **The filesystem**     | the agents just read and write it    | loops, queues, accumulating state             |

`input` is easy to miss and is a distinct field, not a prompt convention: **it
takes precedence over `prompt`** when both are set, and its documented purpose
is piping a `watch` payload into the following step (ledger §3.1). A `step`
needs at least one of the two.

The fourth row is not a workaround — it is the **shipped idiom**, and the
bundled recipes use it.

### Template variables, and the envelope

Workflow `inputs` interpolate as `{{name}}`. Step output is addressable three
ways, and all three resolve to byte-identical text (ledger §3.3):

| reference                                        | meaning                                       |
| ------------------------------------------------ | --------------------------------------------- |
| `{{previous.output}}`                            | the immediately prior **sibling** step        |
| `{{<id>.output}}` (also `{{steps.<id>.output}}`) | a named earlier step                          |
| `{{artifacts.<name>}}`                           | a path from an earlier step's `artifacts` map |

Ordering is enforced at validation and each rejection names the offending pair:
a reference must name a producer that runs earlier, `{{previous.output}}` is
rejected on a first step, and a reference **across concurrent `parallel`
branches** is rejected with "does not run before it". So sibling branches cannot
read each other by construction — a validator rule, not a convention. Two
relaxations exist: a `repeat`'s stop condition may reference producers inside
its own loop body, and a step's `completion` may reference its own output and
artifacts.

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
- `inspect_workflow`'s captured-output map, keyed by step id, is the exception —
  it shows the raw payload unwrapped, so that is where to read output
  programmatically.

**Capture can be empty.** `captureOutput` defaults to `true`, but under
`claude-haiku-4.5` with `effortLevel: low` both steps' captured outputs were
empty strings while the work demonstrably happened — the envelope was still
there with nothing inside it, so the interpolated text is 89 characters either
way. Do not pin a cheap model to a step whose output something downstream
consumes, and test for empty rather than expecting to notice (ledger §7.3).

### Artifacts, and where a bare relative path lands

`artifacts` map values are re-interpolated on every path, fresh runs and
continuations alike:

```json
"artifacts": { "plan": "{{workdir}}/.agents/tasks/plan.md" }
```

A downstream step reads `{{artifacts.plan}}` and gets the resolved path.
Interpolate a declared input so the value stays **absolute**. A relative
artifact path resolves against the workspace root, and an _undefined_ input is
not an error — it stays literal and becomes part of the path, which is how a
real run produced a directory literally named `{{report_path}}` (ledger §3.3,
§4.1).

A bare relative **stop-condition** path is different again: it resolves against
the workflow's `workspacePath`, which is the session's first workspace folder
and may not be where agents actually write (ledger §7.1).

### The writer → reviewer question, and two corrections

The brief asks about "the built-in coder workflow (planner → looper(writer →
reviewer))". Two things need separating.

**First: none of the seven bundled recipes has that shape.** This was a hedge
until 2026-08-05 — only two of seven had been reproduced, and the two whose
names most suggest a multi-stage pipeline were not among them. `listRecipes`
returns a per-recipe `plan`, so all seven structures are now on this page (R-1,
closed below), and the claim is a flat negative rather than a narrow one.

Of the two that were already reproduced: `ralph` (R-workflow-7, verbatim from
the bundle) is a **single-agent sequential drain** — one `repeat` wrapping one
`step` on `wf-coder`, 200 iterations, terminated by a file check:

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

`goal` is the same single-agent shape, and no `wf-writer` or `wf-reviewer` agent
id appears anywhere in the corpus.

#### All seven, structurally — R-1 closed

`_kiro/workflow/listRecipes` returns a `plan` array per recipe. Captured
2026-08-05 by replaying the in-repo ACP driver
(`docs/plans/kiro-v3-research-raw/phase2/probes/acp-drive.py` with
`steps-6-recipes.json`), which is **token-free and model-free**: the driver
refuses the engine's one `_kiro/auth/getAccessToken` request, so no credits are
spent and no model runs. The seven plans came back **byte-identical on kiro-cli
2.15.1 and 2.16.1** — descriptions, inputs and plans all — which is worth more
than either reading alone given the version-skew caveat in §8.

**`plan` is a structural projection, not the definition.** It carries `nodeId` /
`type` / `agentName` plus the loop controls, and it omits every `prompt`: you
can read a recipe's graph from it, you cannot reconstruct the recipe. It also
renames as it projects — definitions use `id` / `agent` / `handler` (§1), and a
`watch` node's handler comes back as `agentName`, which is why `publish-pr`'s
`wait` node reports `agentName: "github-pr"`. The projection reproduces `ralph`
exactly as R-workflow-7 transcribed it, which is the cross-check that makes the
other six trustworthy.

```
autoresearch                 experiments[repeat] → experiment            (wf-auto-researcher)
goal                         goal-loop[repeat]   → work                  (wf-coder)
investigate                  investigate                                 (wf-planner)
ralph                        ralph-loop[repeat]  → iterate               (wf-coder)
publish-pr                   submit                                      (wf-pr-submitter)
                             pr-loop[repeat]     → wait                  (watch: github-pr)
                                                 → respond               (wf-pr-responder)
semantic-review-multi-model  setup                                       (wf-coder)
                             reviews[parallel]   → review-fable          (semantic_reviewer)
                                                 → review-gpt            (semantic_reviewer)
                             aggregate                                   (wf-coder)
feature-pipeline             setup                                       (wf-coder)
                             requirements                                (wf-design)
                             design-loop[repeat] → design-draft          (wf-design)
                                                 → design-review         (wf-design-reviewer)
                             plan                                        (wf-planner)
                             code-loop[repeat]   → implement             (wf-coder)
                                                 → code-reviews[parallel]
                                                      → review-fable     (semantic_reviewer)
                                                      → review-gpt       (semantic_reviewer)
                                                 → code-aggregate        (wf-review-aggregator)
                             validate-gate[repeat] → validate            (wf-coder)
```

Four things fall out of that block that no amount of re-reading the old sources
would have given:

- **The vendor's own multi-model review idiom.** `review-fable` and `review-gpt`
  are the same `semantic_reviewer` agent pinned to **different `modelId`s** —
  `claude-fable-5` and `gpt-5.6-sol`, both at `effortLevel: "xhigh"` — run as
  `parallel` branches so neither sees the other's output, then merged. `modelId`
  and `effortLevel` are per-node, and this is what they are for.
- **`stopCondition.completionSignal` is vendor-used, not invented.** `goal`
  carries `"stopCondition": {"completionSignal": "success"}` verbatim. That does
  not prove the runtime honors it — R-10's iteration-count measurement is still
  the thing that would — but it retires the "absent from every upstream
  document, possibly a schema artifact" half of that doubt.
- **`stopWhen` is a sibling of `stopCondition`, not a spelling of it.**
  `publish-pr`'s loop uses `"stopWhen": "wait.terminal"` — a bare `<nodeId>.`
  reference to a watch node's terminal state, with no `stopCondition` key at
  all.
- **`onMaxIterations: "abort"` is the bundle's default posture for review
  loops** (`feature-pipeline`, all three loops), while the two autonomous drains
  — `goal` and `ralph` — use `"pause"` at 200. Pause when a human should look;
  abort when the gate genuinely failed.

The two recipes R-1 named, in full, because their stop conditions are the
canonical form §7's pattern C is trying to reproduce:

```json
[
  {
    "nodeId": "setup",
    "type": "step",
    "agentName": "wf-coder",
    "effortLevel": "low"
  },
  { "nodeId": "requirements", "type": "step", "agentName": "wf-design" },
  {
    "nodeId": "design-loop",
    "type": "repeat",
    "steps": [
      { "nodeId": "design-draft", "type": "step", "agentName": "wf-design" },
      {
        "nodeId": "design-review",
        "type": "step",
        "agentName": "wf-design-reviewer"
      }
    ],
    "maxIterations": 3,
    "onMaxIterations": "abort",
    "stopCondition": {
      "fileCheck": {
        "path": "{{setup.output}}/design-review.json",
        "jsonPath": "verdict",
        "value": "APPROVED"
      }
    }
  },
  { "nodeId": "plan", "type": "step", "agentName": "wf-planner" },
  {
    "nodeId": "code-loop",
    "type": "repeat",
    "steps": [
      { "nodeId": "implement", "type": "step", "agentName": "wf-coder" },
      {
        "nodeId": "code-reviews",
        "type": "parallel",
        "branches": [
          {
            "nodeId": "review-fable",
            "type": "step",
            "agentName": "semantic_reviewer",
            "modelId": "claude-fable-5",
            "effortLevel": "xhigh"
          },
          {
            "nodeId": "review-gpt",
            "type": "step",
            "agentName": "semantic_reviewer",
            "modelId": "gpt-5.6-sol",
            "effortLevel": "xhigh"
          }
        ]
      },
      {
        "nodeId": "code-aggregate",
        "type": "step",
        "agentName": "wf-review-aggregator"
      }
    ],
    "maxIterations": 3,
    "onMaxIterations": "abort",
    "stopCondition": {
      "fileCheck": {
        "path": "{{setup.output}}/code-review.json",
        "jsonPath": "verdict",
        "value": "APPROVED"
      }
    }
  },
  {
    "nodeId": "validate-gate",
    "type": "repeat",
    "steps": [
      { "nodeId": "validate", "type": "step", "agentName": "wf-coder" }
    ],
    "maxIterations": 1,
    "onMaxIterations": "abort",
    "stopCondition": {
      "fileCheck": {
        "path": "{{setup.output}}/validation.json",
        "jsonPath": "verdict",
        "value": "PASS"
      }
    }
  }
]
```

```json
[
  {
    "nodeId": "setup",
    "type": "step",
    "agentName": "wf-coder",
    "effortLevel": "low"
  },
  {
    "nodeId": "reviews",
    "type": "parallel",
    "branches": [
      {
        "nodeId": "review-fable",
        "type": "step",
        "agentName": "semantic_reviewer",
        "modelId": "claude-fable-5",
        "effortLevel": "xhigh"
      },
      {
        "nodeId": "review-gpt",
        "type": "step",
        "agentName": "semantic_reviewer",
        "modelId": "gpt-5.6-sol",
        "effortLevel": "xhigh"
      }
    ]
  },
  {
    "nodeId": "aggregate",
    "type": "step",
    "agentName": "wf-coder",
    "modelId": "claude-fable-5",
    "effortLevel": "xhigh"
  }
]
```

Note `feature-pipeline`'s `{{setup.output}}` — a leading cheap step exists
purely to mint one timestamped run directory that every later node interpolates,
so re-runs cannot overwrite each other or leave a stale verdict file for the
next iteration's stop check to read. That is the vendor's answer to the
first-pass hazard at the end of this section, and it is worth copying.

**Second, and more useful: the shape you are describing does exist — as a tool,
not a recipe.** `orchestrate_subagent` is a model-elected staged DAG, and under
the stock TUI chat surface it is registered _instead of_ `invoke_sub_agent`
(mutually exclusive; `subagentOrchestration` defaults true and no user config
key maps to it). Its input schema is:

```
task:     string
stages[]: { name, role, prompt_template ({task} substitution), depends_on?: string[] }
repeat?:  { maxIterations: int 1–20, stopCondition: { containsText }, onMaxIterations?: "continue" | "abort" }
```

A `repeat` wrapping stages with `depends_on` is _precisely_ planner →
looper(writer → reviewer), and roles including `planner`, `coder` and
`semantic_reviewer` exist as subagents. Three stages would also account for the
"coder uses 3" recollection. Note this is **not** the workflow engine — it is
the orchestrator's own tool, its `repeat` is capped at **20** iterations rather
than the engine's 1000, and a workflow step cannot call it (§6).

**How data moves in that shape:** dependency outputs are **inlined into the
dependent stage's prompt as markdown**. That is the writer → reviewer mechanic,
and it is the orchestrator doing the threading, not the engine. Three sharp
edges come with it:

- **Fold-back is unbounded.** `formatResults` concatenates _every_ stage's full
  response into one tool message on the parent.
- **A stage's `files[]` never reaches the parent transcript** — `result.state`
  is discarded. (Direct `invoke_sub_agent` dispatch is the opposite: a child's
  returned files are re-read _in full_ by the parent as synthetic `read_file`
  pairs, which quietly undoes the isolation you delegated for. Know which path
  you are on.)
- **Stage success is scored as `response !== ""`.** A child that legally returns
  an empty response plus files is recorded as a **failed** stage. Every worker
  must return a non-empty receipt string.

**Third: this repo already ships prescriptive guidance for the loop.**
`packages/kiro-cli/lib/workflowReminder.nix` is a `UserPromptSubmit` hook
injected every turn, and its default text says:

> For anything a reviewer should sign off on, use the repeat loop: `wf-coder`
> then `semantic_reviewer`, in that order, with a stopCondition on the review
> verdict file. The reviewer is always last.

That is live repo behavior, and it **auto-enables**: the reminder defaults on
whenever `workflows` is in `unlockedRolloutFeatures` (`mkKiro.nix:792-795` —
`null` means auto, "the feature under-elicits without it").

**But the hook is a remedy, not the cause — and the difference is the whole
mechanism.** Operator account, 2026-08, with the ordering established
first-hand: the pattern was already appearing unprompted _before_ the hook
existed. Talking about workflows elicited it; working on an unrelated task
without saying the word stopped it. The hook was added days later precisely
because that coupling made the behavior unreliable.

The elicitation source is therefore the **vendor's** `workflows_default`
steering — ~19.3k characters, emphatic ("always delegate implementation to
workflows"). What makes it topic-coupled is _where_ it sits, and
`workflowReminder.nix`'s own header names the symptom exactly:

> What decays is ATTENTION: one block near the top of a growing conversation
> loses out to everything since, which is exactly the reported symptom (the
> model elects workflows while you are talking about workflows, and stops when
> you stop).

`workflows_default` lands in **msg0**, computed on the first turn and thereafter
replayed byte-for-byte. It never decays in _content_; it decays in _position_,
losing ground to everything said since — so the operator's own prompt is what
re-activates a standing instruction that was there all along. A
`UserPromptSubmit` hook lands beside each prompt, which is why it works where
more steering would not: a second copy would sit in the same place, competing
with the same context.

**That matters for where the pattern comes from.** Someone who sees
`wf-planner → [repeat] → (wf-coder, semantic_reviewer)` appear without having
designed it is not seeing a bundled recipe run, and need not have any repo-local
config at all — they are seeing bundled _agents_ assembled into a shape bundled
_steering_ asked for. Three layers, easy to conflate:

| Layer          | Bundled?                   | Evidence                                                       |
| -------------- | -------------------------- | -------------------------------------------------------------- |
| the agents     | **yes** — all ten, vendor  | ledger §3.5                                                    |
| the pattern    | **yes** — vendor steering  | `workflows_default` in msg0; elicited pre-hook, topic-coupled  |
| the definition | **no** — generated per run | matches no bundled recipe's plan; ids vary across runs (below) |

This repo's hook amplifies the middle row by buying it position; it does not
supply it.

The receipt for that last row, in two independent parts. First, two runs of the
same shape observed 2026-08-05 carried **different loop ids** — `review-loop` in
one, `build-loop` in the other, with the same three agents in the same order. A
`bundled://` recipe has fixed node ids (`ralph`'s loop is always `ralph-loop`),
so ids that vary run to run are the signature of a definition being synthesized
each time rather than replayed.

Second, and this is what closes **R-19**: the elicited shape can now be compared
against the recipe it was suspected of being. It is **not** `feature-pipeline`
under a generated name, and it is not any of the other six either. Neither
`review-loop` nor `build-loop` appears in any bundled plan, and
`feature-pipeline` differs structurally in every way that matters — it runs a
whole `design-loop` on `wf-design` / `wf-design-reviewer` **before** its planner
node, wraps its reviewers in a `parallel` pair pinned to two different models,
follows them with a `wf-review-aggregator`, and ends on a separate
`validate-gate`. The elicited shape has none of that: one planner, one loop, two
agents, no parallel, no aggregator, no gate. Fourteen nodes and six agents
against roughly four nodes and three.

What the comparison does confirm is the middle row. Every agent the elicited
shape uses — `wf-planner`, `wf-coder`, `semantic_reviewer` — is a bundled one
that `feature-pipeline` also uses, and `feature-pipeline` even orders its
reviewer after its coder inside a `repeat` with a verdict-file stop condition.
So the model is not inventing the vocabulary or the idiom; it is assembling
bundled parts into a graph of its own each run, which is exactly what "bundled
agents, bundled pattern, generated definition" predicted.

The sanctioned channel is a **verdict file**, read by a `stopCondition`.

Two corroborations that review output moves as files rather than as captured
text: `wf-review-aggregator` "merges verdict files and nothing else" and cannot
execute anything, and `semantic_reviewer` lacks `str_replace` so it reads and
writes whole files rather than patching (ledger §3.6).

**One hazard, and it is sharp: a loop artifact's presence is not a first-pass
test.** The canonical loop has the coder branch on whether the reviewer's
verdict file exists, to tell a first pass from a later one. After an
interrupted-step resume that file is still absent — the reviewer is the step
that died before writing it — so a re-running coder concludes "first pass" and
may redo committed work. Derive idempotence from inspecting the repository,
never from whether a loop artifact happens to be there (ledger §7.4).

**What is _not_ established:** the ledger documents the reviewer→next-writer
direction only. Nothing records how the writer's output reaches the reviewer in
that observed run. Treat the writer→reviewer leg as your design choice among the
four channels above, not as something measured.

## 4. Composition and reuse

### Workflows do not compose

**There is no ref, include, import, or extends primitive anywhere in the
definition vocabulary.** The five node types in §1 are complete; none references
an external definition. The only cross-definition pointer in the whole surface
is `workflowPath`, and that is a **run-time argument** to a launch call — it
cannot appear inside a definition and cannot be reached from one node to
another. The only intra-definition reference mechanism is template interpolation
over runtime _data_, never over definitions.

A step also cannot start a workflow at the contract level, so
composition-by-nesting is closed too (§6 has the nuance, which is a live open
question).

What you get instead:

| Mechanism                              | Reusable? | Notes                                           |
| -------------------------------------- | --------- | ----------------------------------------------- |
| `.kiro/workflows/<name>.workflow.json` | yes       | launch by absolute path; shadows a bundled name |
| `generated://<id>`                     | **no**    | consumed when the run starts; re-save each time |
| `bundled://<name>`                     | yes       | the seven shipped recipes                       |
| a generator script emitting JSON       | yes       | what the fixtures do — see §7                   |

Name-level **shadowing** between recipe sources is the closest thing to reuse,
and it is whole-recipe override rather than composition — with the side effect
that a broken workspace recipe is silently masked by a same-named bundled one.

That last row is the practical answer to "how do I get six of these", and the
fixtures reached for it for exactly this reason: the language has no way to fan
one branch definition over a list, so `workflows/generate.sh` emits the whole
definition and is the only place the branch count `K` lives.

**Composition happens at the run layer, not the definition layer.** Concurrency
composes across simultaneous runs through a shared filesystem — the engine never
needs to know the pools cooperate (ledger §6, finding 2).

### Can an LLM synthesize a workflow from saved ones?

Yes, and there is a dedicated agent for it — but read the constraints first.

`wf-workflow-creator` builds and saves definitions, and it is the only agent
holding `save_workflow_definition`. Note that tool is **not** on the ordinary
agent-facing surface at all — it lives in its own custom-agent pool — so
creation is not something a normal orchestrator session does directly. The
creator has **five tools, no file tools and no `execute_bash`** (ledger §3.6).
It cannot read the repository. It composes JSON purely from the prompt you hand
it, which means:

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

**But pick your exemplars carefully.** The ledger's own §11 worked definition —
the obvious thing to hand a creator agent — would be **rejected by this repo's
validator**: it uses templated `fileCheck` paths (`"{{workdir}}/w1-done.json"`),
a hard `E-FILE-CHECK-PATH-TEMPLATE` error, plus `joinPolicy: "all"` and
`onMaxIterations: "continue"`, both warnings. A synthesized copy inherits all
three.

### What validation catches, and what it does not

`validate_workflow` **does** check schema conformance, the caps in §5, that
every step has `prompt` or `input`, that a `repeat` does not define both stop
forms, that `stopWhen` watch references resolve, the ordering rules in §3, and
that `fileCheck` paths are not provably outside the workspace roots.

It does **not** check agent names, watch handler configs, `modelId`,
`effortLevel`, or bare `{{identifier}}` references. A `watch` node with a
completely empty `config` validates clean (ledger §3.4).

The failure timing is what matters in practice:

| mistake                 | caught when                                                                      |
| ----------------------- | -------------------------------------------------------------------------------- |
| bad schema / over a cap | validation — and it is free to probe, since validation executes nothing          |
| unregistered `agent`    | **launch**, cleanly, before any step runs — checked live against disk            |
| unknown `modelId`       | **mid-run**, at that step's session creation, with no fallback — _contract only_ |
| missing `inputs`        | never — the placeholder stays literal in the prompt and in the path              |

The `modelId` row is worth flagging: the ledger states it under a `(Contract)`
heading and **no probe of that failure is recorded**, in pointed contrast to the
unregistered-agent row, which carries a verbatim runtime refusal
(`Workflow execution failed: Workflow references custom agent 'wf-imaginary' which is not registered.`).
Treat the late-failure behavior as designed rather than observed.

The agent-name check is live rather than snapshotted: a profile deleted
mid-session stopped working immediately, even though its name still sat in the
orchestrator's own delegation list. Note also that the TUI may display
`agent "<name>" not found, using "default"` alongside a launch refusal — that
message announces a fallback which **did not happen**; the refusal is
authoritative (ledger §3.5).

One diagnostic quirk when reading rejections: **descent stops at a node whose
`type` is missing or unknown**, so one bad `type` suppresses every diagnostic
beneath it. A definition reported as having one error may have many.

Do not use `kiro-cli agent validate` as a pre-flight. It exits 0 unconditionally
— five inputs including a nonexistent path all returned 0, with only stderr
separating them — it is JSON-only so it cannot read a Markdown profile at all,
and it does not check tool-group names (ledger §3.8).

### Validating without a session

There is a bootstrapping problem worth knowing about: `validate_workflow` only
exists in a session where `workflowsEnabled` is true, and enabling that requires
either a patched binary or a pre-seeded session — so the tool that would vet
your definition only exists in a session you can only create by already having a
definition worth seeding.

`fixtures/kiro-primitives/workflows/contract.jq` breaks that circle. It
re-implements the definition contract from the bundle read, runs on nothing but
`jq`, and each diagnostic carries a `basis` saying whose rule it is: `engine`
(the engine performs an equivalent check), `policy` (the engine **accepts**
this; the rule exists because acceptance is silent and the consequence
expensive), or `mechanical`. Run it with `validate-workflow.sh --strict`; match
on `code`, never on `message`. It is a model of the engine, not the engine — but
every rule traces to a quoted schema or function, and its self-test re-derives
the engine's constants from the installed bundle on every run.

## 5. Limits and fan-out

### The node cap is 20, not 18 — and it counts `step` nodes only

Two independent methods agree, which makes this one of the few numbers here
worth leaning on directly:

- **Static read:** `DEFAULT_MAX_STEP_NODES = 20`, alongside
  `DEFAULT_MAX_NESTING_DEPTH = 8` and `MAX_REPEAT_ITERATIONS = 1000`
  (R-workflow-5, from the engine's validator module).
- **Live validation:** a flat `parallel` of 20 plain steps is valid; 21 is
  rejected with `Workflow has 21 step nodes, exceeding the maximum of 20.`
  (ledger §3.2).

**`repeat`, `parallel`, `sequence` and `watch` wrappers are free.** A 12-worker
pool with 25 total nodes validated fine because only 12 of them were `step`
nodes. An earlier draft of the ledger claimed 9 workers per run by wrongly
counting wrappers; if you see that figure anywhere, it is wrong.

There is no bundled recipe named "coder", so the "coder uses 3" figure has no
referent among the recipes — though it maps neatly onto a three-stage
`orchestrate_subagent` pipeline (§3). For calibration: `ralph` and `investigate`
are **one** step node each.

### Does 6 parallel × 3-agent chains fit?

**Yes, comfortably.** Six branches, each a `sequence` of three `step` nodes:

```
6 branches × 3 step nodes            = 18 step nodes   (cap 20 → 2 spare)
wrappers: 1 parallel + 6 sequences   =  0 counted
nesting: parallel → sequence → step  =  3 levels        (cap 8)
```

Two spare step nodes is exactly enough for the pattern §7 recommends: one
top-level verification step after the join. If each per-branch stage is instead
a `repeat` (a self-draining worker), that costs nothing extra — still 18 `step`
nodes, with the `repeat` wrappers free. Note a `sequence` inside a branch runs
**serially**, so this shape is 6-wide, not 18-wide.

The real limits on that shape are not node count:

| Limit                                    | Value                                       | Source          |
| ---------------------------------------- | ------------------------------------------- | --------------- |
| concurrent step sessions, **single run** | **19** measured; no ceiling found           | ledger §6       |
| concurrent step sessions, across runs    | **27** measured (3 runs)                    | ledger §6       |
| subagents dispatched _by_ one step       | **5**, and it **queues** past that          | R-concurrency-1 |
| sub-agent nesting depth                  | **5** (`MAX_SUB_EXECUTION_DEPTH`)           | R-nesting-1     |
| model turns per sub-execution            | **300**, effectively, for an unattended run | R-limits-1      |
| `orchestrate_subagent` repeat            | **20** iterations, not 1000                 | raw f22         |
| watch poll floor                         | 30 s                                        | ledger §7.7     |
| `execute_bash`                           | 30-minute clamp                             | raw f22         |

There is **no wall-clock bound, no token bound and no per-dispatch credit
bound** on a subagent anywhere in the sources — the 300-turn counter and the two
timeouts above are the only time-shaped limits that exist.

### Concurrency: step sessions are not capped; delegated subagents are

Kiro's documented pool of 4 concurrent subagents **does not describe either
population here**. Step sessions showed no ceiling — but read the numbers
carefully, because the headline figures are multi-run: the 18/18 peak was across
**two** concurrent runs and 27/27 across **three**. **The largest concurrency
measured inside one run is 19**, and that run is the one to copy: it needs no
cross-run coordination and carried an in-workflow verification step as its 20th
step node.

Subagents spawned _by_ a step are a different population with a ceiling of **5**
— and two independent methods agree:

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

One caution on the evidence: the engine's own steering tells the model
`Dispatch up to MAX_CONCURRENT_SUBAGENTS (5) ready tasks concurrently`, so a
dispatcher's self-reported `FANOUT=5` may be echoing its prompt rather than
observing the limiter. The timing evidence — a peak of exactly 5, never 6, with
leaf 6 starting while leaves 4 and 5 were still in flight — is what actually
carries the finding.

### The compaction hazard, and exactly who it hits

**A sub-execution crossing 80% context tombstones its _parent_ session's stored
history** (R-limits-3). Compaction fires at `SUMMARIZATION_THRESHOLD = 80`; the
detection guard contains no sub-execution, depth, or session-identity test; and
a dispatched sub-agent's `chatSessionId` **is its parent's**, carried verbatim
through the dispatch context. When the summarization cycle completes it persists
against that id, appending a tombstone whose `truncatedMessageCount` covers
_all_ the target session's messages. The damage is invisible at the time — the
parent's live context is untouched — and lands on the next session load.

**This does not apply to workflow step nodes.** A step runs as a _full session_,
not a sub-execution — `createWorkflowStepSession` calls `host.newSession` — so
the parent-history-truncation trap misses it. The hazard is specifically about
**delegated subagents** (§6): a step that dispatches leaves, or an orchestrator
that dispatches subagents.

A second, separate hazard rides the same mechanism and hits the **orchestrator**
rather than storage: the sub-agent event forwarder filters the terminal
summarization event but cannot filter the opening phase, which shares a generic
event type. So when a worker compacts, the parent client latches a compaction
indicator that **never resolves and silently swallows later prompts** — a live
session failure rather than an on-reload data loss.

Both argue for the same design: **keep delegated workers short by construction,
not by convention.** A fresh session per task never accumulates enough context
to compact.

### Dynamic node editing

You can rewrite a running workflow's future, with three hard edges (ledger §5):

- **Top-level only.** `replace_remaining` cannot reach inside a `sequence` or
  `parallel`. If your whole workflow is one `sequence` — as most good shapes are
  — it is effectively immutable, and a "replacement" appends instead.
- **Applied at the next step boundary** while a step runs; immediately when
  paused or idle.
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
per worker** — a noisy four-point fit, so use the measured value for your size,
not the coefficient. The three sizing points, predicted vs actual (ledger §6.1):

| workers | model              | overhead/iter | predicted | actual     |
| ------- | ------------------ | ------------- | --------- | ---------- |
| 18      | `claude-opus-5`    | 9.2–11.4 s    | 50.6 s    | **54.5 s** |
| 19      | `claude-haiku-4.5` | median 14.6 s | 60.3 s    | **71.6 s** |
| 27      | `claude-haiku-4.5` | median 18.2 s | 99.7 s    | **98.0 s** |

The formula `wall ≈ iterations_per_worker × (task_duration + overhead(workers))`
**predicts low** — every worker spends an extra iteration discovering the queue
is empty, and the ragged final round leaves most idle. At 19 workers, 26 of 69
iterations did no task work at all. Treat it as a lower bound, and **keep tasks
per worker at 5 or more** so drain and trailing-round costs amortize. Effective
parallelism was 6.3× at 18 workers and 8.7× at 27 — far below peak.

Fan-out startup latency is erratic and unexplained: 24.6 s for a 6-branch
fan-out, 5.0 s for 9, ~0.3 s for 27. Do not rely on any of those figures.

One more cost that only shows up unattended: **each dispatch costs one approval
consult keyed on the agent name**, and each `contextFiles` entry costs a
separate `read_file` approval. A 6 × 3 delegating fan-out is 18 dispatch
approvals plus one per context file.

## 6. Ad-hoc agents and nested workflows

### Can a step spawn agents outside the graph?

**Yes — but not with any bundled agent.** This is a property of the agent
_profile_, not of the step surface, and the distinction is the whole answer.
There is no workflow-level spawn primitive; a step delegates only because the
profile it runs happens to carry a delegation tool.

**None of the ten bundled agents can delegate.** There is no
`orchestrate_subagent`, `delegate`, `subagent`, `spawn` or `Task` in any of
them. For `wf-coder` this was corroborated three ways: the step's own report,
the enumerated tool list, and the absence of any artifact from the delegated
work (ledger §3.6). Two names invite confusion and grant nothing —
`subagent_response` returns the step's own result to its parent, and
`disclose_context` only loads skill/steering text. A third, `kiro_powers`, is
held by `semantic_reviewer` alone and is **never shown to be a delegation
capability** anywhere in the sources; that silence is the answer, so do not go
looking.

A workflow built entirely from bundled agents is therefore exactly **two tiers
deep** — the orchestrator and its step agents — and its parallelism is
`step nodes per run (≤20) × concurrent runs`, never multiplied by fan-out from
within a step.

**A custom `.kiro/agents/` profile declaring the `subagent` group does delegate,
and the dispatch genuinely works.** This was proved by construction rather than
by asking: a parent profile was given `subagent` **and nothing else** — no
write, no shell, no way to create a file by any means — and told to dispatch a
leaf that writes a token to an absolute path. The file exists and holds the
token, so the leaf ran (ledger §3.7). Withholding the capability, rather than
forbidding its use, is what makes that airtight. The formula then gains a third
factor.

At the step surface the tool shape is **one tool per callable target**, not one
tool taking a role:

```
subagent_probe-echo-leaf   subagent_wf-coder   subagent_semantic_reviewer   …
```

The target set is every registered custom profile plus all ten bundled agents —
15 in the measured environment — and it is **self-inclusive**, so a dispatcher
can name itself. Bundled agents appear as targets without existing on disk.
Orchestrator-side modes (`context-gatherer`, `custom-agent-creator`,
`general-task-execution`, `introspect`) are a _fourth_ population and are
**not** step targets.

Note the raw notes see a different shape at 2.15.1 — one role-taking
`invoke_sub_agent` — while the ledger measured per-target tools at 2.16.0. The
likeliest reconciliation is that these are **different surfaces** (step session
vs chat session) rather than a version change, which is also the ledger's own
open question. Nothing arbitrates it.

Custom profiles are picked up **mid-session** without a restart. One caveat: a
delegation inventory taken right after a registry change is unreliable — one run
saw only 2 targets and no bundled agents at all, while an identical later run
saw the full 15. A deliberate reproduction attempt failed, so this is not
timing-triggered and not reliably reproducible; the advice is simply to re-run
the inventory before believing it (ledger §3.5).

**How deep, how wide, and what a leaf actually is:**

- Depth is capped at **5** (`MAX_SUB_EXECUTION_DEPTH`), gated as
  `if (currentDepth >= MAX_SUB_EXECUTION_DEPTH)` _before_ dispatching — so the
  deepest reachable execution is depth 5 with root at 0: six levels of
  execution, five of nesting. A root/dispatcher/worker arrangement spends 2,
  leaving 3 (R-nesting-1).
- Width is **5 per delegating step**, queueing past that (§5).
- **A dispatched subagent is not a session.** It is a sub-_execution_: one flat
  `.jsonl` inside the parent session's directory, with no `session.json`, no
  metadata and no independent lifecycle. It therefore cannot outlive its parent.
  That structural difference is _why_ step sessions and step-spawned subagents
  have different ceilings.
- **Orchestrator subagent sessions cost zero node budget** (ledger §8.1) — but
  that is a population a workflow step cannot reach, since a step cannot call
  `orchestrate_subagent`. That a _step-spawned_ leaf likewise costs no node
  budget follows from §3.6's multiplier formula but was never measured directly;
  no run approached the cap while delegating.
- **A spawned worker cannot self-loop** unless the dispatching profile sets
  `dispatchKind: custom-agent`. Under the default sub-agent adapter a dispatched
  worker's `Stop` hook never fires, so a loop primitive built on it silently
  does nothing.

**One thing to know before you rely on the rejection.** A depth-limit refusal is
**not thrown**. It is emitted as an `Error`-state action and returned as a
_synthetic tool message with an empty response_, so the parent model sees a
failed tool call and keeps going. Code that expects an exception, or that reads
an empty response as "no work found", will misread it (R-nesting-1).

**Whether a dispatch blocks the calling step is not settled by anything in this
repository.** No source says `invoke_sub_agent` awaits its child, and none names
a fire-and-forget or background mode — the six-field input schema has no
detach/background knob. Every mechanism described is consistent with a blocking
awaited tool call, and the awaited semaphore acquire plus the synchronous
synthetic-message return path point that way, but the word never appears. The
measured five simultaneously-open leaf windows rule out one-at-a-time
serialization; they do not distinguish "awaits a batch of five" from "returns
handles". That is register item R-2.

### Can a step create a second workflow?

**The contract says no; the mechanism that would block it is visibly switched
on; nobody has run it.** This is the most consequential open question in the
brief.

- The workflow contract states plainly that a workflow step cannot start a
  workflow (ledger §3.1).
- The ledger's own drift ledger lists this as **open**, because later static
  surface analysis found that workflow-step sessions may expose `run_workflow`
  when enabled. Its working rule: _do not depend on nested workflows without a
  targeted live probe._
- Two independent static reads show why: a workflow step runs as a **full
  session**, and the step-session builder explicitly injects
  `settings: {workflows: {enabled: true}}`. The engine's own registration
  comment says so — "**Workflow step sessions always pass this gate**:
  `createWorkflowStepSession` sets `settings.workflows.enabled` explicitly, so
  the step completion protocol keeps its `send_message` signal" (R-workflow-4).
  Since registration is all-or-nothing on that boolean (§1), a step session
  passing the gate receives `run_workflow` **along with** the `send_message` it
  actually needs.

So the two claims are reconcilable — the _engine_ may well register the tool in
a step session while the _scheduler_ refuses a nested run — but the second
filter nobody has read is whether the step's agent profile carries the tool at
all. That is register item R-3, and it is the one worth spending a probe on,
because it decides whether the 20-node cap is a per-run budget or a per-tree
one.

**There is, however, an established nesting path that needs no step to call
anything.** An external ACP client can attach a workflow to an existing session
via `_kiro/workflow/new` with `parentSessionId`, and that arm is ungated. So
even if a step cannot self-start a workflow, nesting is reachable client-side.

Taking those together, who can create or launch a workflow: an external ACP
client (ungated), the model via `run_workflow` (gated on `workflowsEnabled`),
and the step-session builder (self-gating). At 2.15.1, notably, **not** the
stock TUI user.

**Parallel workflow runs are not in doubt.** Concurrency composes across runs
through the filesystem, and three simultaneous runs were measured (ledger §6,
finding 2). Multi-run composition is only _necessary_ beyond 20 workers.

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
workspace**.

For agent-native work — reviewing a file rather than running a command — have
the step prompt run a claim script, do the work in the agent's own context, then
run a completion script. **One agent session per task is desirable**: it gives
each task a fresh, uncontaminated context, which is what makes the per-iteration
overhead of §5 a price worth paying rather than waste. The shipped `drain-queue`
fixture goes further and forbids the agent from touching files at all — the
script owns every mutation, and the agent reports only `exit=<code>`, because "a
hand edit corrupts a queue that 4 other branches are claiming from
concurrently."

### Pattern B — the 6 × 3 fan-out

For six independent chains of three stages, the shape is a `parallel` of six
`sequence` branches. It costs 18 of 20 step nodes (§5), leaving room for a
verify step. Two settings are worth arguing about, and the fixtures argue both:

- **`joinPolicy: "allSettled"`, not `"all"`.** `all` aborts every sibling on the
  first branch _failure_, so one poisoned item cancels every other branch. Under
  `allSettled` a failing branch is contained, the other five run to completion,
  and the run **still reports `failed`** — nothing is swallowed. Use it to avoid
  killing siblings, not to tolerate failure: under both policies the step after
  the join never runs (ledger §7.7). Only `joinPolicy: "any"` lets a run
  continue past a failed branch, and it does so by aborting the losers
  mid-flight.
- **`onMaxIterations: "abort"`** for any `repeat` inside. Not `pause` — resuming
  grants no further iterations and a paused run cannot be retried, so it is a
  state you cannot leave. Not `continue` — it marks the repeat COMPLETED on
  exhaustion, indistinguishable from a genuine drain, so an unfinished branch
  scores as success. (`continue` is right only when a verify step judges the
  outcome, as in Pattern A.)

Note the vendor's own long-loop recipes (`ralph`, `goal`) ship
`onMaxIterations: "pause"`. Do not copy that field from them.

`fixtures/kiro-primitives/workflows/drain.workflow.json` is a working
five-branch instance of this shape, and its per-branch prompt shows the full
read-modify-write iteration protocol for a file channel: _if the state file does
not exist, create it and decompose the goal into items; if it does, take the
first item whose `done` is false, do just that one, write the file back marked
done; set top-level `drained` only when nothing remains._ `generate.sh` beside
it is the only place the branch count lives, and is the practical answer to "how
do I get six of these" (§4).

### Pattern C — a writer → reviewer loop

Build it as a `repeat` containing a `sequence` of two steps, and thread state
through a **verdict file** — which is what this repo's own per-turn reminder
prescribes (§3). Then:

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

If you would rather have the orchestrator run the loop than the engine,
`orchestrate_subagent`'s `stages[] + depends_on + repeat` is that shape natively
(§3) — at the cost of a 20-iteration cap, unbounded fold-back into your context,
and the empty-response-is-failure trap.

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

After that change, zero no-ops across three runs at 27 workers (95 engine
iterations matching invocations worker-by-worker), and the prompt-vs-model
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
  `kiro-cli chat --list-models -f json`.
- **Pinning a cheap model to mechanical steps is worth it** — 27 workers on
  `claude-haiku-4.5` (0.4×) instead of `claude-opus-5` (2.2×) is a 5.5× cost
  reduction on work that runs one shell command. Just not on a step whose output
  something downstream reads.
- **Step agents run in the parent workspace, not a worktree.** Pass the worktree
  path as an input, make every path in every prompt absolute, use
  `git -C <worktree>`, and do not describe the worktree as the agent's "working
  directory" — the agent will believe you and use relative paths (ledger §8.5).
- **Pick step agents by tool set, not by name.** `wf-review-aggregator` cannot
  execute anything (no `execute_bash`); `wf-workflow-creator` cannot read the
  repository at all; `semantic_reviewer` lacks `str_replace` so it rewrites
  whole files rather than patching (ledger §3.6).
- **Probing a bundled recipe name is cheap only in one direction.** A name that
  does not exist fails immediately with `no bundled recipe named '<name>'`; a
  name that _does_ exist **starts it**, and `autoresearch` and `ralph` commit.
- **The 21 validator error templates are transcribed verbatim** in
  `records/workflow-surface.md` R-workflow-6 — worth grepping when a rejection
  message is cryptic.

## 8. Open-item register

Questions this repository's research cannot answer, each with the single
measurement that would settle it. Borrowing the ledger's own framing: **this is
an index into research debt, not a backlog.** Probe a row only when the answer
would change a concrete design.

| #    | Question                                                                                                                                                                                                                                                                               | The one measurement                                                                                                                                                                                                                                                                       |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R-2  | Does a `subagent_<role>` dispatch **block** the calling step, or is there an async mode?                                                                                                                                                                                               | One step on a `subagent`-only profile dispatches one leaf that sleeps 30 s and writes an end marker; the step writes its own marker on return. Compare timestamps: step-marker after leaf-marker means blocking.                                                                          |
| R-3  | Can a step create or launch a **second workflow**? The contract forbids it; the step-session builder demonstrably turns the gate on.                                                                                                                                                   | One step whose profile carries the workflow tool group, prompted to call `run_workflow` on a trivial one-step definition and report the exact response. Three outcomes: it runs; it is refused with an engine message; the tool is absent.                                                |
| R-4  | Do the ACP run-control verbs actually drive a live run? They were probed for reachability and param shape; **`invoke` was never sent**, so nothing shows a run executes while ungated.                                                                                                 | Launch the §7 pool over ACP, `pause` mid-drain, `inspect` to confirm the transition, `resume`, confirm workers resume claiming. One session, one run.                                                                                                                                     |
| R-5  | Which iteration limit binds a workflow **step** session? The chat flavour carries `ITERATION_LIMIT = 300` with an 8× transition factor; the custom-agent flavour 300 with 4×.                                                                                                          | Read which flavour `workflow.session_driver.starting_step` constructs. A static read, no run.                                                                                                                                                                                             |
| R-6  | Can `update_workflow` / `update_status` be **granted** to a custom step agent? No bundled agent has it, contradicting the contract.                                                                                                                                                    | Write a `.kiro/agents/` profile declaring the group that carries `update_workflow`, run it as a single top-level step, have it report its own tool inventory.                                                                                                                             |
| R-7  | Does a permission `match` rule on a `subagent_<role>` tool name **bind** inside a step?                                                                                                                                                                                                | Give one step agent two delegation targets, write a rule matching one name and not the other, run a step that calls both. Three distinguishable outcomes: both go through (no bind), one refused (binds), or the step stalls.                                                             |
| R-8  | Is the per-target `subagent_<role>` shape a step-surface property or a version change? Raw notes see one role-taking `invoke_sub_agent` at 2.15.1; the ledger sees per-target at 2.16.0.                                                                                               | Enumerate the delegation tools in a step session and in a chat session **on the same build**. If they differ, it is the surface; if not, the version.                                                                                                                                     |
| R-9  | Where does step-session concurrency actually break? 19 in one run, 27 across three, with no engine complaint.                                                                                                                                                                          | The economics likely fail before the engine does, so make it a cost question: wall-clock per task at 20 / 25 / 30 workers in a **single** run, and find where it stops improving.                                                                                                         |
| R-10 | Is `stopCondition.completionSignal` **honored at runtime**? The bundled `goal` recipe uses it verbatim (§3), so it is vendor-real rather than a schema artifact — but no run has ever confirmed the engine acts on it.                                                                 | A two-iteration `repeat` whose step signals `success` via `send_message`, with `"stopCondition": {"completionSignal": "success"}` and `maxIterations: 3`. Count the iteration wrappers.                                                                                                   |
| R-11 | Does the fan-out ceiling of 5 hold across profiles and leaf types? All three runs used the same capability-starved parent and the same shell leaf.                                                                                                                                     | Repeat the N=8 dispatch probe with a parent holding a full tool set and a leaf that is not a shell one-shot.                                                                                                                                                                              |
| R-12 | Does the same ceiling bind the **orchestrator's** own `orchestrate_subagent`? Only the step surface was probed, and the two differ in tool shape already.                                                                                                                              | The same peak-overlap sweep, run from an orchestrator session instead of a step.                                                                                                                                                                                                          |
| R-13 | What triggers the resume of a run paused by an interrupted step, and how long is the paused window?                                                                                                                                                                                    | A deliberate mid-step interruption followed by an open-ended wait with **nothing** else touching the run or the host, timing the transition if it comes. Cheap in setup, expensive only in patience.                                                                                      |
| R-14 | Which component emits `agent "<name>" not found, using "default"`, and does a silent fallback to `default` ever actually happen?                                                                                                                                                       | The second half is what matters — a measurement taken on a silently-downgraded surface would look plausible and mean nothing. Run one step naming a deleted profile and check whether _any_ artifact appears.                                                                             |
| R-15 | Is `save_workflow_definition`'s validation genuinely stricter? The bundled spec claims agent names are checked at load time; `validate_workflow` does not check them.                                                                                                                  | Have the creator agent save a definition naming `wf-imaginary` and report the response. It is not a tool the orchestrator can call directly, so this has to go through the agent.                                                                                                         |
| R-16 | What does the viewer's `s steer` actually do to the selected node — inject a user message into that node's session, queue one for the whole run, or something else? And does it reset the 300-turn counter (R-limits-1)?                                                               | Steer a node mid-run with a distinctive token, then read that node's captured output and its siblings' for the token. Sibling containment answers the addressing question; `inspect_workflow` iteration counts answer the budget one.                                                     |
| R-17 | What else does the TUI expose that the other two surfaces do not? The viewer alone shows `Tab agents`, `l stack`, and per-node output panes that appear nowhere in the research.                                                                                                       | Drive the TUI once with the feature unlocked and enumerate every binding and view, the way the ledger's §3.5 enumerated the agent roster. The surface is currently undocumented here.                                                                                                     |
| R-18 | What total concurrency does a delegating workflow actually reach? Arithmetic says 20 step nodes x 5 permits = ~100 leaves at one delegating tier, but composition was only ever measured at n=2 dispatchers, and the overhead law suggests the economics break before the engine does. | Scale the peak-overlap sweep: 4, then 8, then 16 delegating steps, each dispatching 5 marker leaves, one run each. Read peak simultaneous leaf windows and wall-clock per leaf. Stop when wall-clock per leaf stops improving — that number, not the engine's ceiling, is the usable one. |

### Closed by measurement

Rows leave this register when they are answered, so the table above stays a list
of open debt. What they cost and what they bought is recorded here, because "how
expensive was that actually" is the part a future reader needs in order to price
the next row.

| #    | Closed     | Answer                                                                                                                                                                                  | Cost                                     |
| ---- | ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| R-1  | 2026-08-05 | All seven recipe plans are in §3. `plan` is a structural projection — no prompts — so it answers node structure and cannot reconstruct a definition. Identical on 2.15.1 and 2.16.1.    | One ACP call. No model, no tokens, ~10s. |
| R-19 | 2026-08-05 | **No.** The elicited planner/coder/reviewer shape is not `feature-pipeline` under a generated name, nor any other bundled recipe. It reuses bundled _agents_; the graph is synthesized. | Free — fell out of R-1 as predicted.     |

Both were closed by replaying the in-repo ACP driver against
`_kiro/workflow/listRecipes`, which is the cheapest probe in this document by a
wide margin: the extension methods are registered unconditionally, so it needs
**no `workflows` unlock, no session, no model and no credentials** — the driver
answers the engine's one `_kiro/auth/getAccessToken` request with a JSON-RPC
error and the call still succeeds. If a question can be phrased against
`listRecipes`, `inspect` or `list`, ask it that way before designing a run.

The register's estimate for R-1 said "token-free, model-free" and was right,
which is a small mark in favor of trusting the other rows' cost estimates.

Three standing caveats that are not open questions but should travel with every
figure above:

- **Version skew.** The live measurements are `kiro-cli 2.16.0`; the code reads
  are KAS 2.15.1, with byte offsets known to have moved in 2.15.2. Where both
  exist they agree, which is the main reason to trust either. **The constants
  are the durable part; the offsets are not.** One direct measurement now backs
  that split: the seven recipe plans are byte-identical on 2.15.1 and 2.16.1
  (§3), so the bundle's _content_ held across the same range in which its
  offsets moved.
- **Static reads predict; live runs measure.** The `KIRO_ENABLED_FEATURES` story
  in §1 is the cautionary case: a 2.15.2 static read showed the consumer had
  appeared and concluded the variable should now work, and a 2.16.0 live probe
  showed it still does not. Prefer the measurement where they conflict.
- **Pre-release.** `workflows` is dark-shipped at 0% pending certification,
  absent from all upstream documentation. Every behavior here can change without
  notice.
