# Kiro Workflow Engine — Mechanics and Measured Behavior

Reference for adopting the workflow engine in another repository. Written for a
reader who was not present for the experiments.

**Provenance labels.** Every heading that makes a behavioral claim carries one:

- **(Contract)** — transcribed from the `run_workflow` / `validate_workflow` /
  `update_workflow` tool schemas, or from the workflow authoring specification
  the harness embeds in `acp-server.js` (§13). Not tested unless stated. §12
  lists exactly which contract claims were never exercised. Contract text is not
  authoritative where a measurement contradicts it, and at least one place it
  does (§3.4).
- **(Measured)** — established empirically on 2026-07-31 / 2026-08-01 against
  `kiro-cli 2.16.0` (kas bundle `2.16.0-9ec8655…`). The evidence is given
  inline.
- **(Inferred)** — a conclusion drawn from contract text, not observed. Treated
  as the weakest class. **No section currently carries this label**: §5 was the
  last one, and it has since been measured.

Four container sections (§3, §4, §7, §8) carry no label of their own, because
they deliberately mix classes — read the label on each subsection instead.
Vocabulary (§2), adoption guidance (§11), the untested-claims list (§12) and
methodology (§13) make no behavioral claims and so carry none.

## 1. What this is, and what it is not (Measured)

The workflow system is **dark-shipped, pre-release upstream code**. It is absent
from the official Kiro CLI documentation — not in the slash-command reference,
the CLI command reference, or the built-in tools reference — and it is **off by
default**. §1.1 covers unlocking it; nothing else in this document is runnable
until you have.

It is reachable two ways, and an earlier version of this section wrongly claimed
only the second existed:

- **A `/workflow` slash-command family in the TUI**, all seven entries gated on
  the same `workflows` rollout feature (§1.1). Two are visible in the palette
  and five are `hidden`:

  | command            | description                                 | visible |
  | ------------------ | ------------------------------------------- | ------- |
  | `/goal`            | Work toward a goal in a loop until done     | yes     |
  | `/workflow`        | Browse and manage workflows or run a recipe | yes     |
  | `/workflow-cancel` | Cancel a workflow                           | no      |
  | `/workflow-resume` | Resume a paused workflow                    | no      |
  | `/workflow-run`    | Run a workflow                              | no      |
  | `/workflow-status` | Check workflow status                       | no      |
  | `/workflows`       | Browse workflow history                     | no      |

  `/workflow` takes `run <recipe> [inputs]` or `list`; `/goal` takes
  `<description> [--max N]`. Re-derive the set from the TUI bundle:

  ```bash
  grep -o -E '\{name:"/[a-z-]+",description:"[^"]*",feature:"workflows"[^}]*\}' \
    ~/.local/share/kiro-cli/tui.js
  ```

- **Agent-facing tools**: `run_workflow`, `inspect_workflow`, `update_workflow`,
  and `validate_workflow`. This is the surface every measurement in this
  document was taken through, because they were taken from an **ACP session**,
  where the TUI's slash commands are not reachable — the client owns the slash
  namespace there. That is the whole reason the earlier "there is no `/workflow`
  command" claim survived: it is true of an ACP session and false of the
  product.

Consequences for adoption:

- **Users do have an entry point** in the TUI, so `/workflow` and `/goal` are
  worth teaching. Under ACP they do not, and the agent must decide to use a
  workflow from a natural-language request.
- `/workflow-resume` and `/workflow-cancel` exist, which matters because the
  agent-facing tools expose no way to resume or cancel a run (§7.4, §7.5).
- Nothing in `~/.kiro/` configures the engine, and Kiro does not create a
  `.kiro/workflows/` directory. The agent will run recipes placed there, but you
  must create it yourself.
- Document it to **agents** via steering as well (§11); under ACP that is the
  only path.

### 1.1 Prerequisite: the feature must be force-unlocked (Measured)

`workflows` is one of **14 rollout features** listed in
`overlays/kiro-cli-extracted.json` under `rolloutFeatures`, gated by a JSON
rollout manifest carried in the chat binary's **ELF rodata** in two identical
copies. See `packages/kiro-cli/docs/launcher-argv.md` for the full anatomy.

In this repository it is unlocked by patching that manifest:

```nix
ai.kiro.unlockedRolloutFeatures = ["workflows"];
```

declared in `packages/kiro-cli/lib/mkKiro.nix`. Two assertions guard it: the
option requires a `package` exposing `passthru.withRolloutFeatures`, and it
requires `ai.kiro.v3 = true` — the feature-gated commands reach the palette only
on the v3 (`kas`) engine, so patching the binary is necessary but not
sufficient.

**`KIRO_ENABLED_FEATURES` does not work.** `tui.js` reads it, which makes it
look like an env var you can simply set, but the rust chat binary **recomputes
and overwrites it** before spawning bun: measured, the parent process held
`["workflows"]` and the child received `["tangent"]`. The manifest's own
`workflows` description says "enable locally through `KIRO_ENABLED_FEATURES`" —
that line is **stale** and does not describe shipped behavior. Neither
`KIRO_ROLLOUT_FORCE_INTERNAL` nor `KIRO_ROLLOUT_FORCE_NIGHTLY` helps either,
since `segment: "internal"` resolves off the authenticated identity rather than
the environment. Patching the manifest is the only client-side seam.

**Unlocking `workflows` also enables `/goal`**, because the one flag gates both
commands — both registry entries carry `feature:"workflows"` (see the grep
above). `/goal` is the closest user-facing analogue to a workflow, so expect to
be asked about it.

**This documents pre-release, uncertified behavior.** Upstream describes
`workflows` as "Dark-shipped at 0% until release certification is complete".
Everything measured here could move without notice.

Confirm the unlock is live in your own session before trusting any probe in this
document: call `validate_workflow` on a trivial definition. If the workflow
tools are absent, the feature is not unlocked and nothing here is reproducible.

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
mandatory, and the validator is the lenient one (Measured).** `run_workflow`
says exactly one of `stopCondition` / `stopWhen`, "not both, not neither", and
the bundled authoring spec (§13) agrees. But `validate_workflow` accepts a
`repeat` with **neither** (`valid: true`), and rejects only the both-at-once
case:

```
Schema error at steps.0: RepeatNode allows at most one of stopCondition or stopWhen
```

"At most one" is the validator's actual rule. So omitting both relies on a
leniency the spec disowns, and a run that depends on it is depending on
undocumented behavior. **Safe rule: always supply exactly one** — that form
satisfies every reading.

`stopWhen` is sugar for common `stopCondition` shapes: `"<watchId>.terminal"`,
or `"{{expr}} contains <text>"`. The `contains` form is Measured (§7.6).

Two `step` field details from the bundled spec that the tool schemas omit:

- **`captureOutput` defaults to `true`.** Capture is on unless you set it to
  `false`; omitting the field keeps it on. Corroborated — a step that never
  declared the field still had its output captured (§3.3).
- **`input` takes precedence over `prompt`** when both are set. It is the field
  used to pipe a `watch` payload into the following step, as
  `"input": "{{watch_id.output}}"`.

`joinPolicy` semantics, all three Measured (§7.7):

| policy       | on a branch failure                      | on first success        |
| ------------ | ---------------------------------------- | ----------------------- |
| `all`        | aborts surviving siblings, fails the run | n/a                     |
| `allSettled` | lets every branch finish, fails the run  | n/a                     |
| `any`        | does **not** satisfy the join            | wins; aborts the losers |

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

### 3.3 Template variables and artifacts (Measured)

Workflow `inputs` interpolate into prompts as `{{name}}`. Step output is
addressable three ways:

| reference              | meaning                                              |
| ---------------------- | ---------------------------------------------------- |
| `{{previous.output}}`  | the immediately prior **sibling** step               |
| `{{<id>.output}}`      | a named earlier step (also `{{steps.<id>.output}}`)  |
| `{{artifacts.<name>}}` | a path declared in an earlier step's `artifacts` map |

Ordering is enforced at validation, and every rule below was exercised against
`validate_workflow` rather than transcribed. A reference must name a producer
that runs **earlier**; each rejection names the offending pair:

| shape                                                | result                                                     |
| ---------------------------------------------------- | ---------------------------------------------------------- |
| `{{previous.output}}` on the first step              | rejected — "has no prior sibling step to read output from" |
| `{{s2.output}}` where `s2` is a later sibling        | rejected — "node 's2' does not run before it"              |
| `{{artifacts.p}}` where a later step declares `p`    | rejected — names the declaring step                        |
| `{{a.output}}` across concurrent `parallel` branches | rejected — "does not run before it"                        |
| all four backward forms in a later step              | valid                                                      |

`{{previous.output}}` is also rejected inside a stop-condition context, since a
stop condition has no preceding sibling — though a `repeat`'s stop condition may
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

**A relative artifact path resolves against the workspace root**, so the bundled
recipes' bare `pr.json` / `questions.md` land at the top of the checkout. Two
consequences. An **undefined** input is not an error — it stays literal and
becomes part of the path, which is how `bundled://investigate` launched with no
inputs produced this artifact:

```
report = /home/caubut/.../nix-agentic-tools/{{report_path}}
```

a real directory name containing braces (§4.1). And a relative path in a
worktree-targeted workflow silently lands in the parent workspace, for the same
reason step agents' relative paths do (§8.5). Interpolate an absolute input.

#### The three output forms are aliases, and output arrives wrapped (Measured)

`{{previous.output}}`, `{{<id>.output}}` and `{{steps.<id>.output}}` naming the
same step resolve to **byte-identical** text. Measured by passing all three plus
`{{artifacts.rep}}` as separate arguments to a script that recorded each one's
length and value: the three output forms were 102 characters each and equal; the
artifact was a readable absolute path.

The surprise is what those 102 characters are. A step's captured output is
**not** interpolated raw — it is wrapped in a delimiter carrying a per-run
random nonce:

```
<prior_step_output_e94daa17f05467d6 id="producer">
TOKEN-PC-7731
</prior_step_output_e94daa17f05467d6>
```

The payload was 13 characters; the envelope accounts for the other 89. The nonce
differs per run (a second run produced `3ea54b996998d3c6`), which is the
signature of a prompt-injection guard — content cannot forge a closing tag it
cannot predict.

**So `{{<id>.output}}` is a channel for an agent to read, not a value to compute
on.** Anything parsing it must strip the envelope, and must not assume a stable
tag. `inspect_workflow` is the exception: its captured-output map shows the raw
payload with no envelope, which makes it the right place to read output
programmatically.

### 3.4 What validation does and does not check (Contract, exceptions Measured)

`validate_workflow` **does** check schema conformance, the caps in §3.2, that
every step has at least one of `prompt` / `input`, that a `repeat` does not
define both stop forms, that `stopWhen` watch references resolve to real watch
ids, the ordering rules in §3.3, and that `fileCheck` paths are not provably
outside the workspace roots (§7.1).

It does **not** check agent names, watch handler configs, `modelId`,
`effortLevel`, or bare `{{identifier}}` references — those pass through as
literal text, with at most an advisory server-log warning on a likely typo. A
`watch` node with a completely **empty** `config` validates clean, which is the
handler-config gap made concrete.

Note that the bundled authoring spec (§13) lists "every agent name must match a
registered agent exactly" among its load-time constraints. **That is not true of
`validate_workflow`**, which accepted `agent: "wf-imaginary"` as valid. The spec
is describing `save_workflow_definition`, the stricter save path available only
to `wf-workflow-creator`; whether that path really is stricter is untested
(§12).

**Passing validation does not mean the run works** — but the failure is earlier
and cleaner than "session-creation time" suggests. `run_workflow` rejects an
unregistered agent **before any step runs**, returning:

```
Workflow execution failed: Workflow references custom agent 'wf-imaginary' which is not
registered.
```

An unknown `modelId` is the genuinely late failure: it passes validation with
only an advisory warning and then fails when that step's session is created,
with no silent fallback to another model (§10).

#### The interpolated-path blind spot (Measured)

The `fileCheck` workspace-root check is a **prefix test on literal text**, so it
cannot see through interpolation. A path that begins with a template escapes it:

| `fileCheck` path                          | result                                    |
| ----------------------------------------- | ----------------------------------------- |
| `/tmp/c.json`                             | rejected, naming the workspace root       |
| a sibling worktree of the checkout        | rejected — worktrees are outside the root |
| `{{workdir}}/../../../../tmp/escape.json` | **valid**                                 |

So §7.1's silent-forever-false failure is still reachable, and reachable exactly
where it is hardest to spot. The rejection message is worth reading in full,
because it names the only escape hatch mentioned anywhere in the surface:

```
... resolves outside the allowed workspace roots (/home/caubut/.../nix-agentic-tools).
The stop condition would never match; move the file inside the workspace or add
its directory to additionalDirectories.
```

`additionalDirectories` is a property of the **run**, not of the workflow JSON —
the `watch` handler docs also treat it as an allowed root for `prRef`
resolution. Nothing in the agent-facing tool surface sets it, so treat it as
read-only context rather than a lever.

### 3.5 Step agent roster (Measured, this environment)

The `agent` field names a registered agent mode. **Names are not validated at
authoring time** (see §3.4), but an unregistered name fails the whole run at
launch, so a typo is loud rather than subtle.

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

### 3.6 What tools a step agent has (Measured, all ten agents)

Enumerated by asking each agent to list its own tool set: first `wf-coder`, via
a workflow that was a **single top-level `step`**, then the remaining nine as
one `parallel` of nine branches under `joinPolicy: allSettled`. Each was told to
write the list to a file as well as report it, so a claim of "no file tool" is
corroborated by an absent file rather than taken on trust.

| agent                  | n   | notable                                                              |
| ---------------------- | --- | -------------------------------------------------------------------- |
| `wf-coder`             | 10  | the baseline set below                                               |
| `wf-auto-researcher`   | 10  | same as `wf-coder`                                                   |
| `wf-pr-responder`      | 10  | same as `wf-coder`                                                   |
| `semantic_reviewer`    | 10  | **adds `kiro_powers`**, drops `str_replace`                          |
| `wf-planner`           | 9   | no `str_replace`                                                     |
| `wf-design`            | 9   | no `str_replace`                                                     |
| `wf-design-reviewer`   | 9   | no `str_replace`                                                     |
| `wf-review-aggregator` | 8   | **no `execute_bash`** — cannot run anything                          |
| `wf-pr-submitter`      | 7   | no `file_search`, no `grep_search`                                   |
| `wf-workflow-creator`  | 5   | **no file tools, no `execute_bash`**; has `save_workflow_definition` |

The `wf-coder` baseline:

```
disclose_context   execute_bash    file_search   fs_write      grep_search
read_file          report_progress  send_message  str_replace   subagent_response
```

Three of those rows change how you design a workflow:

- **`wf-review-aggregator` cannot execute anything.** It merges verdict files
  and nothing else — do not ask it to run a test, a build, or `git diff`.
- **`wf-workflow-creator` cannot read the repository at all.** No file tools, no
  shell. It composes JSON purely from the prompt you hand it, which is why a
  creator prompt has to carry every path and constraint explicitly (§8.4), and
  why it cannot verify that an agent or path it references exists.
- **`semantic_reviewer` alone has `kiro_powers`** and alone lacks `str_replace`
  — it reads and writes whole files, so it is not set up to patch code.

**No step agent can delegate.** There is no `orchestrate_subagent`, `delegate`,
`subagent`, `spawn`, or `Task` in any of the ten. For `wf-coder` this was
corroborated three ways: the step's own report, the enumerated list, and the
absence of any artifact from the delegated work (so it also did not quietly
perform that work itself).

**No step agent has web, knowledge, or todo tooling.** A step needing external
fetch or search cannot get it from any bundled agent; that work belongs to the
orchestrator or a custom `.kiro/agents/` agent.

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

**No bundled agent has `update_workflow`** — not one of the ten. All nine
non-`wf-coder` agents reported `NO_UPDATE_WORKFLOW` in the same parallel probe,
and `wf-coder` was measured separately. The `wf-coder` probe satisfied the
contract's "top-level step agent" precondition exactly (it was the sole entry in
`steps[]`), so this **contradicts** the contract's claim that such a step may
call `update_workflow` with either action.

The consequence is stronger than "do not rely on it": **`update_status` is
unreachable dead surface** for every bundled agent, and the step-agent half of
`replace_remaining` is too. Only the orchestrator's `replace_remaining` is real
(§5). A custom `.kiro/agents/` agent might be granted the tool, which is
untested (§12).

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

**The recipe set is version-scoped.** Those seven appear in kas **2.15.1 and
later**; they are absent from 2.12.3, 2.13.0, 2.13.1, 2.14.1 and 2.14.2, whose
`acp-server.js` contains no `*.workflow.json` reference at all. Re-derive the
list against the kas version actually in use rather than carrying it forward.

#### Running one: inputs are not enforced (Measured)

`bundled://investigate` was run — the read-only recipe, deliberately, since
`autoresearch` and `ralph` commit. It is a **single `step` node on
`wf-planner`**, declaring one artifact, `report`.

Launched with **no `inputs` at all**, it started anyway. Nothing validates that
a recipe's inputs were supplied: the launch succeeded, the run reached
`running`, and the unresolved placeholders were passed through **literally** —
into the prompt and into the artifact path alike, producing

```
report = /home/caubut/.../nix-agentic-tools/{{report_path}}
```

The step agent, not the engine, caught it. It replied at `warning` severity
naming both missing values, which paused the run (§4.3):

> Cannot start: the step prompt's placeholders were never substituted — the
> brief is literally `{{brief}}` and the output path is literally
> `{{report_path}}`.

So `investigate` expects `brief` and `report_path`. Two lessons generalize: **a
missing input is not an error**, it is a literal `{{name}}` in the prompt; and
whether that gets caught depends entirely on the step agent noticing. A
mechanical step would have run with a corrupt path and reported success.

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

### 4.3 Step lifecycle is controlled by `send_message` severity (Measured)

When a **workflow step** calls `send_message`, the severity is not cosmetic — it
drives the step's lifecycle:

| severity  | effect on the step                               |
| --------- | ------------------------------------------------ |
| `success` | marks the step completed; the workflow advances  |
| `warning` | **pauses the workflow** and waits for user input |
| `error`   | marks the step failed                            |
| `info`    | informational only, no lifecycle effect          |

Both consequential rows are now Measured. `error`: a branch instructed to signal
it was marked `[failed]` with the reason `Step signaled error via send_message.`
(§7.7). `warning`: the `investigate` run above paused on it, with the reason
`Step requested user input via send_message.` (§4.1).

`warning` is a load-bearing hazard: a step reaching for it to flag something
non-fatal will halt the entire run pending human input — and the agent-facing
tools offer **no way to resume** (§7.4). Only the hidden `/workflow-resume`
command can, and that is TUI-only (§1).

**(Measured)** Steps routinely ignore an instruction not to call `send_message`
at all. Every probe here told its worker "Do not call send_message" and dozens
of `[notification/success]` messages arrived regardless. Treat step
notifications as something to tolerate, not something you can switch off by
asking.

#### The three pause reasons (Measured)

A run can be `paused` for three distinct reasons, and the string is diagnostic:

| reason string                                                          | cause                                   | resumes itself                       |
| ---------------------------------------------------------------------- | --------------------------------------- | ------------------------------------ |
| `Step requested user input via send_message.`                          | a step used `warning` severity          | no                                   |
| `Step '<id>' is waiting for the next user message.`                    | an unmet step `completion` block (§7.5) | on its own once the condition is met |
| `Transient model service error (service 5xx/throttling); will resume.` | upstream model error                    | claims to; did not (see below)       |

The third is the engine self-healing and needs no action — except that **"will
resume" is not a guarantee.** One probe (`claude-opus-5`, mid-`repeat`) sat in
that state indefinitely, stalled on iteration 5 of a 12-iteration loop with 4
clean iterations behind it, and never advanced. Relaunching the identical
workflow completed it. So treat a long-lived transient-error pause as a stall to
relaunch, not a wait to sit out. Frequency is unmeasured — n=1 of the runs in
this series.

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

## 5. Runtime DAG mutation (Measured)

`update_workflow` has two actions. Only one of them is reachable at all:

- `update_status` — set the current step's status (`completed`, `failed`,
  `paused`, `running`). Documented as callable only by a top-level step agent.
  **No bundled agent has the tool** (§3.6), so this action is unreachable dead
  surface.
- `replace_remaining` — replace **all steps after the currently-running step**.
  Callable by the orchestrator, which is how everything below was measured.

### 5.1 The mutation granularity is the top-level `steps[]` array (Measured)

This is the finding that matters, and it is not what the contract's wording
suggests. `replace_remaining` operates **only on the top-level `steps[]` list**.
It cannot reach inside a `sequence` or a `parallel`.

Two runs, differing only in whether the steps were nested:

| workflow shape                                       | call made while step 1 ran | outcome                                                                                            |
| ---------------------------------------------------- | -------------------------- | -------------------------------------------------------------------------------------------------- |
| `steps: [sequence[ parallel[a1,a2], orig1, orig2 ]]` | replace with `[new1]`      | **nothing replaced.** `orig1` and `orig2` both ran; `new1` was _appended_ after the whole sequence |
| `steps: [s1, o1, o2]` (three top-level steps)        | replace with `[newX]`      | **replaced.** `o1`/`o2` never ran — no marker files, no log lines                                  |

In the nested case the engine had one top-level node, so "all steps after the
currently-running step" was the empty set, and replacing the empty set with
`[new1]` is an append. The final tree shows it plainly — `new1` is a sibling of
the declared `sequence`, not a member of it:

```
[completed] sequence:run
  [completed] parallel:pool
  [completed] step:orig1      ← ran despite the "replacement"
  [completed] step:orig2      ← ran despite the "replacement"
[running]   step:new1         ← appended at top level
```

Each step wrote a timestamped marker, so "never ran" is an absence of evidence
on disk, not an inference from the node tree.

**Consequence for the patterns in this document: §9's pool and §11's minimal
definition are both a single top-level `sequence`, so both are immune to
`replace_remaining`.** Anything you intend to rewrite at runtime has to be a
top-level sibling. That is a design constraint, not a footnote.

### 5.2 Application timing, and what the response tells you (Measured)

The response string reports which of two paths was taken:

| run state                     | response                                                                         |
| ----------------------------- | -------------------------------------------------------------------------------- |
| a step running                | `Queued: the remaining steps will be replaced after the current step completes.` |
| paused, or idle between steps | `Applied: the remaining steps were replaced.`                                    |

So the contract's "queued and applied at the next step boundary" holds for a
running step, and "applied immediately when no step is running" holds for a
paused one. A queued replacement is visible in `inspect_workflow`:

```
Pending replacement (queued, will apply after current step completes):
  step:new1 (agent: wf-coder)
```

Already-executed steps were never altered in any run — consistent with the
contract's immutability claim, though note that with top-level-only granularity
there is no API by which you could try.

**`replace_remaining` does not un-pause a paused run.** Applied to a run halted
by a `warning`-severity step, the call reported `Applied` and the new step
appeared as `[pending]` — and stayed there, because the _current_ step is still
waiting. §7.4 suggests `replace_remaining` as the remedy for a stuck loop; it
rewrites the future but cannot unstick the present.

### 5.3 You cannot add a branch to an in-flight `parallel` (Measured)

The earlier edition inferred this from the mutation point being the join. The
real reason is more basic: **there is no API that addresses a running node.**
`replace_remaining` replaces a suffix of the top-level list, and a running
`parallel` is not in that suffix — it is the current node. Nothing else in the
tool surface mutates a node.

So the original conclusion stands, and the practical advice is unchanged. If
your goal is to eliminate wave barriers so freed slots backfill immediately,
`replace_remaining` does not help. Every concurrency primitive the engine has
(`parallel` plus a join) is a barrier; `joinPolicy: any` aborts the losers
rather than backfilling (§7.7).

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
the concurrency penalty rather than a like-for-like comparison. That confound
was **not** retired — see §12 for why, and for the cheaper experiment that would
settle it.

Effective parallelism (work-seconds ÷ wall) was 6.3× at 18 workers and 8.7× at
27 — far below peak, because trailing rounds leave most workers idle. **Keep
tasks per worker at 5 or more** so drain and trailing-round costs amortize.

## 7. Gotchas — the engine

### 7.1 `fileCheck` paths outside the workspace are silently false forever (Measured)

A `repeat` `stopCondition` or step `completion` whose path lies outside the
workspace roots evaluates to `false` permanently — no error. The loop then runs
to `maxIterations` and does whatever `onMaxIterations` says: fails under
`abort`, halts under `pause`, and continues **silently** under `continue`.

`validate_workflow` now catches the easy half of this: a **literal** outside
path is rejected before you can run it (§3.4). What it cannot catch is an
**interpolated** one — `{{workdir}}/../../../../tmp/x.json` validates clean —
because the check is a prefix test on the un-substituted string. So the silent
failure survives precisely where it is hardest to see.

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

#### The confound is retired: the fix holds at like-for-like model (Measured)

That 27-worker result changed the model at the same time as the prompt
(`claude-opus-5` → `claude-haiku-4.5`), so it only ever showed the fix was
_consistent with_ zero no-ops. Two later runs isolate the prompt by holding the
model at **`claude-opus-5`** — the same model that produced the 9% no-op rate
under the old wording:

| run | model           | prompt | stop form               | engine iterations | invocations | no-ops |
| --- | --------------- | ------ | ----------------------- | ----------------- | ----------- | ------ |
| —   | `claude-opus-5` | old    | `fileCheck`             | 67                | 61          | **6**  |
| pS  | `claude-opus-5` | fixed  | `stopWhen` … `contains` | 3                 | 3           | **0**  |
| pE2 | `claude-opus-5` | fixed  | `fileCheck`             | 8                 | 8           | **0**  |

Engine iterations are the `sequence:loop#<n>` wrappers in `inspect_workflow`;
invocations are lines the script appended to its own log, counted independently.
`pE2` ran a `repeat` with `maxIterations: 12` against a target of 8, so it had
four spare iterations to absorb a no-op and needed none: `loop#0` through
`loop#7`, eight invocations, exact 1:1.

**So the wording is the cause, at n=11 iterations across two runs on the model
that previously failed.** Still a modest sample, and it does not settle the
_mechanism_ (§12), but the prompt-vs-model confound is gone.

**One caveat survives, and it matters more than the fix.** This wording is only
safe for **idempotent** work: it instructs an agent never to skip, so applied to
a non-idempotent task it invites double-execution — and §7.5 shows a
`completion` block will re-invoke a step without any iteration cap at all. Make
the task itself idempotent or claim-guarded (§9.2) rather than relying on prompt
wording for correctness.

### 7.3 Captured outputs can be empty, and are never raw (Measured)

Two separate hazards in the same field.

**Empty under a cheap model.** Confirmed like-for-like: the same workflow was
run twice, identical structure and identical prompts, changing only the model.
Under `claude-opus-5` the producer's output was captured; under
`claude-haiku-4.5` with `effortLevel: low` both steps' captured outputs were
empty strings — even though the producer demonstrably did the work and even
emitted the token in a `send_message`. Do not build logic on a step's captured
text without checking for empty, and do not pin a cheap model to a step whose
output something downstream consumes.

**Never raw.** What a _prompt_ receives via `{{<id>.output}}` is the payload
wrapped in a per-run nonce envelope (§3.3) — and the same is true of a `watch`
node's output, verified by having a step write `{{wait.output}}` verbatim to
disk:

```
<prior_step_output_47478d893f70338d id="wait">
{ "url": "...", "state": "MERGED", ... }
</prior_step_output_47478d893f70338d>
```

Under the haiku run the envelope was still present with an **empty payload
inside it**, which is why "empty" is a thing you must test for rather than
something you will notice: the interpolated text is 89 characters of delimiter
either way. Read `inspect_workflow`'s captured-output map instead when you need
the value programmatically — that view is unwrapped.

### 7.4 `onMaxIterations: "pause"` is not resumable for more iterations (Contract)

Reaching `maxIterations` under `pause` halts the run, and resuming does **not**
grant more iterations — every slot is already used, so it re-pauses immediately.
A paused run cannot be retried (retry applies only to terminal runs: completed,
failed, aborted).

**The agent-facing tools cannot resume a run at all.** There is no resume or
cancel tool; `update_workflow` has only the two actions in §5. The contract
suggests `replace_remaining` as the remedy, and it is accepted while paused, but
it **rewrites the future without unsticking the present** — measured in §5.2,
where the injected step sat `[pending]` behind a still-paused current step. The
only real resume and cancel paths are the hidden `/workflow-resume` and
`/workflow-cancel` TUI commands (§1), unavailable under ACP.

So prefer `abort` for review loops so work that cannot be approved fails fast,
and set `maxIterations` high enough up front. The `pause`-at-exhaustion path
itself remains untested (§12).

### 7.5 A step `completion` block is an unbounded retry loop (Measured)

`completion` looks like a gate. It is a **loop with no iteration cap**, and it
is the sharpest edge found in this series.

The bundled spec is accurate but easy to skim past: "the step stays open
(interactive) until the condition is met; **each user message triggers another
agent turn**." Measured, with a `completion` whose file the step was forbidden
to create:

- the step ran its command, finished its turn, and was **nudged again**;
- it re-ran the same command on every nudge — **at least 7 invocations**, at
  roughly 8 s intervals, each one a fresh timestamped line in its own log. Seven
  is the count read off the log at the moment of intervention, and further
  invocations arrived after that, so treat it as a floor rather than a total;
- between nudges the run reported `paused`,
  `Step '<id>' is waiting for the next user message.`;
- writing the expected `{"done": true}` ended it immediately: the step completed
  and the workflow advanced to the next step.

There is **no `maxIterations` equivalent for `completion`**. Unlike a `repeat`,
nothing bounds the retries and nothing escalates to a failure. A `completion`
whose condition can never be satisfied is an open-ended repetition of that step.

Two rules follow. **Only put a `completion` on idempotent work** — the same rule
§7.2's anti-skip wording needs, and for the same reason: this pattern will
re-execute the step body an unbounded number of times. And **make the step
itself write the completion file**, so the exit condition is under the control
of the thing being retried; a file written by any other step, or by a human,
turns the step into a spin.

Prefer a `repeat` with an explicit `maxIterations` when you want bounded
retries. Reach for `completion` only when the step genuinely must stay open.

### 7.6 `stopWhen` sugar: both forms work (Measured)

Both documented forms were exercised end to end.

`"{{<id>.output}} contains <text>"` — a `repeat` whose step printed
`INVOCATION n of 3 — TARGET REACHED` on its third call, with
`stopWhen: "{{work.output}} contains TARGET REACHED"` and `maxIterations: 8`,
stopped after exactly three iterations. Note the matched substrate is the step's
**captured output**, so this form inherits §7.3 wholesale: under a model that
captures nothing the condition can never match, and the loop silently runs to
`maxIterations`. Do not use it with a cheap model.

`"<watchId>.terminal"` — see §7.7's watch result; a `repeat` capped at 3
iterations stopped after one when the watch reported terminal.

Validation resolves watch references, so a typo is caught for free:
`references unknown watch id '<id>'`.

**There is an undocumented third `stopCondition` field.** Both the tool schema
and the bundled spec list only `containsText` and `fileCheck`, but the runtime
schema is:

```
StopCondition requires at least one of containsText, fileCheck, or completionSignal
```

and `completionSignal` accepts `'success' | 'need_input' | 'error'` — the
`send_message` severities of §4.3, minus `info`. A `repeat` can therefore stop
on its step's own signal with no file and no text match:

```json
"stopCondition": { "completionSignal": "success" }
```

That validates. Its runtime behavior was **not** tested (§12), and it is absent
from every document upstream ships, so treat it as discovered rather than
supported.

### 7.7 `joinPolicy` differs in cancellation, not only in waiting (Measured)

All three policies were run against an **identical** branch set — one branch
that marked itself and then signalled `error`, plus two that slept 40 s —
changing only `joinPolicy`. Every branch wrote a start marker and an end marker,
so a killed branch is visible as a start with no end.

| policy       | run status  | losing branches                                   | step after the join |
| ------------ | ----------- | ------------------------------------------------- | ------------------- |
| `all`        | `failed`    | `[aborted]`, **killed** mid-sleep (start, no end) | never ran           |
| `allSettled` | `failed`    | ran to completion (both end markers)              | never ran           |
| `any`        | `completed` | see below                                         | ran                 |

Three things here are not in the contract:

- **`allSettled` still fails the run.** It changes _cancellation_, not the
  verdict: every branch was allowed to finish, all markers present — and the run
  still ended `failed` and the following step never ran. If you reached for
  `allSettled` expecting the workflow to carry on past a failed branch, it does
  not. Use it to avoid killing siblings, not to tolerate failure.
- **A failed branch does not satisfy `any`.** The `error` branch settled within
  half a second; the `parallel` stayed `running` and both slow branches carried
  on. `any` waits for a _success_, not for the first branch to settle.
- **`any` really does kill the losers.** A second run with staggered durations —
  one 3 s branch, one 90 s branch — completed 14 s in: the quick branch won, and
  the 90 s branch has a start marker and no end marker, with the following step
  running immediately. So `joinPolicy: any` abandons in-flight work rather than
  letting it finish, which is what §5.3 means by "aborts the losers rather than
  backfilling".

Under `all` the failing step is reported as
`Step signaled error via send_message.`, and the enclosing nodes carry the
reason `branch 'fail' status=failed`.

#### The `watch` node and the `github-pr` handler (Measured)

A `watch` polls a non-LLM source and reports one of three outcomes — `idle`,
`new-activity`, `terminal-state`. **`stopWhen: "<id>.terminal"` fires on
`terminal-state` only**, and for `github-pr` that means the PR is **merged or
closed** — not "CI finished" and not "review received". A loop waiting on review
activity is waiting on `new-activity`, which is what feeds the next step.

Verified end to end by pointing a watch at an already-merged PR: the first poll
returned `state: "MERGED"`, `stopWhen: "wait.terminal"` fired, and the `repeat`
stopped after a single iteration against a `maxIterations` of 3.

The handler config, transcribed from the handler's own source. That source is
**not in this repository** — it is inside the kas bundle's `acp-server.js`,
which retains its build-time module banners, so
`src/workflow/handlers/github-pr.ts` below is a path within the upstream tree
and not a file you can open in the checkout (§13 shows how to read it):

| field                | meaning                                                        |
| -------------------- | -------------------------------------------------------------- |
| `prRef`              | path to a JSON file whose `url` field is the PR                |
| `url`                | the PR url directly                                            |
| `pollIntervalSec`    | override; **the registry enforces a 30 s minimum**             |
| `commandTimeoutSec`  | per-`gh` timeout; unset waits indefinitely                     |
| `includeOwnActivity` | default `false` — your own `gh` identity never wakes the watch |
| `ignoreAuthors`      | logins that never wake it, matched case-insensitively          |

Exactly one of `prRef` / `url` is required. A relative `prRef` resolves against
the workspace root. `config` string values accept `{{...}}` templates, resolved
when the watch starts.

The payload — same envelope as a step output (§7.3) — carries `url`, `state`,
`newComments`, `newReviews`, `excludedComments`, `excludedReviews` and
`checkRollup`. Reviews arrive with `author.login`, `state`, `submittedAt`,
`commit` and `body`; `checkRollup` entries carry `name`, `status`, `conclusion`
and `detailsUrl`, so CI state is observable even though it never makes the watch
terminal. Own-identity items appear in `excludedComments` / `excludedReviews`
rather than being dropped — 3 of them in the verification run.

Two operational notes. It shells out to
`gh pr view --json url,state,isDraft,mergedAt,closedAt,comments,reviews,statusCheckRollup`,
so it inherits `gh` auth. And **a non-zero `gh` exit or unparseable JSON is
reported as `idle`**, not as an error — a broken or unauthenticated `gh` makes
the watch look permanently quiet.

`ignoreAuthors` matches the `author.login` in the payload, which is not always
the login you would guess: the Actions bot is `github-actions` with no `[bot]`
suffix, and in the verification payload Copilot's reviews were attributed to
`copilot-pull-request-reviewer`, also without that suffix.

A second handler, **`crux-cr`**, exists (banner
`// src/workflow/handlers/crux-cr.ts` in the same bundle, again not a file in
this repo), taking `crRef` (a JSON file whose `crId` field is the CR id) or
`crId` directly. Untested here.

Note that `validate_workflow` does not check handler configs at all — a `watch`
with an empty `config` validates clean despite the schema requiring `prRef` or
`url` (§3.4).

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
unsupported level is reconciled to the model's default at session creation
rather than failing.

**An unknown `modelId` is the one field that passes validation and then fails
the run.** It produces only an advisory warning at validation time, and no
fallback at runtime — deliberately, so a workflow cannot quietly execute on a
model other than the one pinned. A guessed id therefore fails mid-run, at the
step. Omit `modelId` unless a specific model is actually required; omitting it
inherits from the workflow level, then the parent session, which is the correct
default.

Pinning a cheap model to mechanical steps is worthwhile — 27 workers at ~3.5
iterations each on `claude-haiku-4.5` (0.4×) instead of `claude-opus-5` (2.2×)
is a 5.5× cost reduction on work that runs one shell command. Watch for the
empty captured outputs in §7.3, and note that changing model mid-experiment
confounds timing comparisons (§6.1).

## 11. Adopting this in another repository

1. **Unlock the feature first (§1.1).** Nothing else here works until
   `workflows` is force-unlocked, and it cannot be done with an environment
   variable. Confirm the agent actually has the workflow tools before writing
   any steering that assumes them.

2. **Add agent-facing steering.** Under ACP the agent is the only entry point
   (§1), so the orchestrator must know when to reach for a workflow. A minimal
   steering rule:

   ```
   Delegate multi-step implementation work to a workflow rather than doing it
   inline. Use `wf-workflow-creator` to build and validate the definition, then
   `run_workflow` with the returned `generated://` ref. Do not hand-author
   workflow JSON. After launching, end your turn — `run_workflow` does not block,
   and a completion notification will arrive. Treat that notification as
   "finished", not "succeeded": always check the result.
   ```

   In the TUI, also teach `/workflow run <recipe>` and `/goal` (§1) — those are
   real user-facing entry points, and `/workflow-resume` is the only way to
   rescue a run paused by a `warning`-severity step (§7.4).

3. **Decide where recipes live.** Reusable shapes belong in
   `.kiro/workflows/<name>.workflow.json` and are referenced by absolute path
   (reusable). One-off shapes come from `wf-workflow-creator` as `generated://`
   refs (single-use, §4.1).

4. **Copy the pool fixture if you need concurrency.** The two scripts in §9.2
   and §9.4 are the whole pattern; they take the queue root as an argument and
   have no other repository coupling. Put the queue root inside the workspace
   (§7.1).

5. **Decide up front whether the shape must be rewritable at runtime.**
   `replace_remaining` only reaches the **top-level** `steps[]` array (§5.1), so
   wrapping everything in one `sequence` — as the definition below does, and as
   §9's pool does — makes the run immutable. That is usually what you want; it
   is a trap only if you expected otherwise.

6. **Start from a minimal working definition.** This was **run end to end**, not
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

Everything in the previous edition's "never exercised" list has since been
probed, and the results are folded into the sections above. What remains is
genuinely open.

Open questions about behavior that _was_ measured:

- **The upper concurrency ceiling.** 27 was reached with no engine complaint;
  where it breaks is **UNVERIFIED**. The overhead law (§6.1) suggests the
  economics fail before the engine does.
- **Why fan-out startup latency varies** by two orders of magnitude (§6).
- **The mechanism behind no-op iterations** — context leakage versus side-effect
  observation. The _fix_ is no longer confounded (§7.2), but why the failure
  happens is still unestablished, and distinguishing the two would need a step
  that leaves no filesystem trace.
- **Whether the overhead curve is like-for-like.** §6.1's 27-worker row is on
  `claude-haiku-4.5` while 9 and 18 are on `claude-opus-5`, so the concurrency
  penalty there is a lower bound. Deliberately not re-run: the doc's actionable
  advice is already "use the measured overhead for a given size, not the
  coefficient", which a tighter coefficient would not change, and 27 concurrent
  `claude-opus-5` sessions is a poor trade for it. The cheaper experiment that
  _would_ separate model from concurrency is 19 workers on `claude-opus-5`,
  against the existing 19-worker `claude-haiku-4.5` row.
- **How often a transient-error pause fails to self-resume** (§4.3). Seen once;
  base rate unknown.

Still untested, and to be treated as weaker than anything labelled Measured:

- **`update_status`** — unreachable rather than merely untested: no bundled
  agent has `update_workflow` (§3.6). A custom `.kiro/agents/` agent might be
  granted it; whether the action then works is unknown.
- **`onMaxIterations: "pause"` at exhaustion** (§7.4) — the re-pause-immediately
  claim. The two other `onMaxIterations` values were exercised.
- **`stopCondition.completionSignal`** (§7.6) — discovered in a runtime schema
  error and validated, never run. Absent from every upstream document, so its
  semantics are guesswork beyond the enum.
- **`save_workflow_definition`'s stricter validation.** The bundled spec claims
  agent names are checked at load time; `validate_workflow` does not check them
  (§3.4). Whether the creator agent's save path does is untested — it is not a
  tool the orchestrator can call.
- **The `crux-cr` watch handler** (§7.7) — config schema read from source, never
  instantiated.
- **`additionalDirectories`** (§3.4) — appears in the workspace-root error and
  in watch path resolution, but nothing in the agent-facing surface sets it.
- **Six of the seven bundled recipes.** Only `investigate` was run, and only far
  enough to establish input handling (§4.1). `autoresearch` and `ralph` are
  autonomous loops that commit and should not be probed casually.
- **The `/workflow` command family** (§1) — read out of the TUI registry, not
  driven. Every measurement here came through the agent-facing tools under ACP,
  where those commands do not exist.

## 13. Reproducing the measurements

The probes coordinated through a queue directory and per-worker append-only
event logs of the form `<timestamp> w<N> <event> <task>` (§9.2), which is what
made after-the-fact analysis possible.

Sub-second resolution needs either bash 5 (`EPOCHREALTIME`) or GNU `date`. On a
system with neither, §9.2's `now()` degrades to whole seconds. The guard works —
verified by forcing the fallback branch and shimming a BSD-style `date` whose
`%N` yields a bare `N`: timestamps came out as clean integers with no stray
letter, and `assert-drained.sh` was unaffected.

**But the peak-concurrency sweep below is not merely coarse at that resolution —
it is unreliable, in both directions.** Measured against a log of two strictly
sequential claim→done pairs, true peak 1:

- the sweep as written reports **`PEAK=0`**. Within one timestamp `sort -n` may
  place a `done` before its matching `claim`, so the running sum dips to −1 and
  never rises above zero. It reports nothing at all, silently.
- adding a tiebreak so claims sort first reports **`PEAK=2`**, over-reporting,
  because it assumes every claim in a tick precedes every release in it.

The interleaving is simply not present in whole-second data, so no sweep can
recover it. **Treat sub-second timestamps as a precondition for every "peak"
figure in §6 and every overhead figure in §6.1**, not as a nicety. Assert it
rather than assuming it:

```bash
grep -qE '^[0-9]+\.[0-9]+ ' events/w1.log \
  || { echo 'whole-second timestamps: peak/overhead analysis invalid' >&2; exit 1; }
```

The pool itself is unaffected — claiming, draining and the drain assertion never
read a timestamp. Only the analysis is.

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

**Read the bundled spec instead of inferring.** The single highest-yield move of
this round. `acp-server.js` embeds the **full workflow authoring specification**
— roughly 24 KB of it — because that text is `wf-workflow-creator`'s system
prompt. It documents every node type, the template-variable rules, the
validation constraints, the bundled agent table, design principles and four
worked recipes. Extract it:

```bash
A=~/.local/share/kiro-cli/kas/<version>-<digest>/node_modules/@kiro/agent/dist/server/acp-server.js
python3 - "$A" <<'PY'
import sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = src.find('# Workflow Schema')
j = src.find('save_workflow_definition', i)
print(src[i:j + 3000].encode().decode('unicode_escape', errors='replace'))
PY
```

The same file carries the runtime **zod schemas**, which are the authoritative
enums and the only place several fields appear at all:

```bash
grep -o -E 'WatchOutcomeSchema[^;]{0,200}' "$A"
grep -o -E 'StopConditionSchema[^;]{0,400}' "$A"
```

That is how `stopCondition.completionSignal` (§7.6) and the watch outcome enum
(§7.7) were found, and how the `github-pr` config was transcribed rather than
guessed. The bundle keeps esbuild's per-module banners, so grepping for
`// src/workflow/` locates each original TypeScript module inside it — those are
paths in the upstream tree, not files in this checkout:

```bash
grep -o -E '// src/workflow/[a-z/-]+\.ts' "$A" | sort -u
```

That yields 28 modules. The ones matching the behaviors measured in this
document are `stop-condition.ts`, `template.ts`, `validate.ts`,
`parallel-scheduler.ts`, `watch-handler-registry.ts` and
`workflow-step-update.ts` — useful starting points for anything here labelled
Inferred or listed in §12.

Treat spec text as **Contract, not Measured**: it is documentation of intent and
it is wrong in at least one place (agent-name validation, §3.4). Where the spec
and a measurement disagree, the measurement wins.

**Mine error messages for undocumented schema.** A deliberately malformed field
is cheaper than any search. Passing `completionSignal: true` returned
`Expected 'success' | 'need_input' | 'error', received boolean`, which is the
whole enum. Passing a `stopCondition` with no recognized key returned the list
of keys it accepts — including one absent from every document upstream ships.

**Distinguish "absent" from "empty" when probing a data channel.** §7.3's empty
captured output is invisible if you only check whether a downstream step got
_something_: the injection envelope arrives either way. Record the received
value's **length** and its literal text separately, so an unresolved `{{...}}`
literal, a resolved value, and an empty payload are three distinct observations.
The reference probe passed each form as its own shell argument to a script that
logged length and value per argument.

**Step agent tool roster** (§3.6): a single top-level `step` instructed to write
its own tool list to a file. Design such a probe so a false claim is detectable
— forbid the agent from doing the delegated work itself, and require a durable
artifact from each delegate, so that absent artifacts plus a self-report of
unavailability is a three-way corroboration rather than a bare assertion. To
cover many agents at once, make each a branch of one `parallel` under
`joinPolicy: allSettled` so a single agent misbehaving does not abort the rest —
nine agents cost nine step nodes and one run.

**Test a `watch` against an already-merged PR.** A watch on a live PR sits in
`idle` for as long as you are willing to wait, and `terminal` for `github-pr`
means merged or closed (§7.7). Pointing it at a PR that has already merged makes
the terminal path fire on the first poll, which turns an open-ended probe into a
single-iteration one.

Two methodology cautions. **Validate the measurement before trusting the
measurement**: the first overhead figures were contaminated by no-op iterations
spanning two engine iterations, which inflated the apparent gap until the
first-gap-only rule above was adopted. And **do not change two variables at
once** — the model changed between the 18- and 27-worker runs, which is why
§6.1's overhead comparison still carries a confound caveat (§7.2's no-op fix no
longer does).

A third, learned this round at the cost of publishing a wrong claim. **Never
conclude "X does not exist" from a truncated listing.** §1's original assertion
that there is no `/workflow` command came from a sorted, `head`-limited grep of
the TUI command table; `/workflow*` sorts after the cut, so the evidence for its
existence was in the part that was discarded. The output looked complete because
it was long. When the finding is an absence, count the results or drop the limit
— an absence proved by a truncated list is not proved at all.

A fourth, for anything involving a `parallel`. **Make cancellation observable.**
Every branch in the `joinPolicy` probes wrote a start marker and an end marker,
which is the only reason "aborted" could be distinguished from "finished but its
result was discarded" (§7.7). A branch that writes once, at the end, cannot tell
you which happened.
