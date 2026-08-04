> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# F13 — task and TODO list mechanics (folds F7)

Two UNRELATED constructs share the word "task" in this engine. They are
documented separately throughout:

- **A. `todo_list`** — the chat-mode TODO tool. Session-scoped, in-memory,
  model-facing planning scratchpad.
- **B. Spec tasks** — the durable, file-backed task system (`tasks.md` +
  metadata stores + DAG) driven by `task_list` / `task_get` / `task_update`
  and the spec orchestration flows.

All byte offsets below are into the KAS bundle at the pinned path.

## 1. The question

1. Were TODO lists a v2 experiment only, or a first-party v3 construct?
   (vendor docs list `todo_list` as a tool TAG — verify.)
2. Enumerate schema, on-disk/in-session representation, every operation.
3. Who may create/read/mutate/reorder/delete; are entries immutable (F7)?
   Per-session or durable?
4. Activation drivers per operation; does anything render to the user?

"Settled" = every operation named with its exact contract, every store named
with its path and shape, and every driver on the axis classified
yes/no/indirect with evidence.

## 2. What is already known (corpus + docs)

- `todoList` is one of 31 keys in the KAS `BaseAgentSettingsSchema`
  (corpus `records/limits-and-engine.md:1221`, offset 872016) and one of 21
  keys the CLI's embedded client forwards, from the pair
  `["chat.enableTodoList","todoList"]`
  (corpus `records/workflow-surface.md:173,545`).
- `PreTaskExec` / `PostTaskExec` hook triggers: stdin payload carries
  `spec_name` + `task_name` (+ `task_success` for Post); `PreTaskExec` blocks
  on exit code 2, `PostTaskExec` never blocks; frontmatter aliases
  `preTaskExecution`/`postTaskExecution`
  (corpus `records/hooks-io-contract.md:118,204-214,810`,
  `records/hooks-dispatch-gate.md:140-151`). Not re-derived here.
- Vendor v3 doc (`private/kiro-v3-docs.md:489,734`) lists `todo_list` in the
  "Tags" tables of the `tools` field. Vendor v2 doc
  (`private/kiro-v2-experimental.md:74-93`) documents a v2 `todo` tool with a
  `/todo` command gated by `chat.enableTodoList`.
- v3 advertised `extensionMethods` are 7, none task/spec related (pinned
  mission facts / ACP argv doc).

### Verdict on the headline question

TODO lists were a v2 **experiment** (Rust `task_tool.rs`, opt-in
`chat.enableTodoList`, `/todo` command) AND are a **first-party v3
construct**: the KAS bundle reimplements the tool in TypeScript at
`src/tools/todo-list.ts` (offset 18221641) with the literal comment
`--- CLI parity: error messages match Rust task_tool.rs exactly ---`, and —
unlike v2 — registers it **unconditionally**: the `chat.enableTodoList` /
`todoList` gate has **no consumer** in the KAS engine (section 3-A6). v2
details beyond this line are out of scope.

The vendor "tag" claim is **wrong in letter, right in effect**: the tag
registry (`src/tools/tool-tags.ts`, offset 4965696) contains only
`read write shell web subagent spec context @mcp @powers @builtin @subagent
@subagent-explicit` — no `todo_list`, and no `knowledge` either. But
`matchesPattern` (offset 4973706) matches a `tools` pattern against the tool
**id** first, so `tools: ["todo_list"]` in an agent profile works anyway.
It selects exactly one tool, not a group.

## 3-A. `todo_list` — the interface, fully enumerated

Source: `src/tools/todo-list.ts` (offset 18221641). Tool id `todo_list`,
title "Task List", displayName "task", tags `[@builtin]`, class `TodoList
extends SyncTool`, telemetry name `TodoList`.

### A1. Schema (Zod, advertised to the model)

| field | type | used by | contract |
| --- | --- | --- | --- |
| `command` | enum `create\|complete\|add\|remove\|list` | all | required |
| `tasks` | `TaskItem[]` | create | required, non-empty, no blank descriptions |
| `task_list_description` | string | create | required, non-empty |
| `completed_task_ids` | `string[]` | complete | required, non-empty, every id must exist |
| `context_update` | string | complete | required, non-empty |
| `modified_files` | `string[]` | complete | optional; deduped + sorted into state |
| `new_tasks` | `TaskItem[]` | add | required, non-empty |
| `new_description` | string | add, remove | optional; if present must be non-empty |
| `remove_task_ids` | `string[]` | remove | required, non-empty, every id must exist |

`TaskItem = { task_description: string, details?: string }`.

A separate **lenient validation schema** normalizes sloppy model output:
arrays may arrive as `{ "0": ..., "1": ... }` objects (`Object.values`),
task items may be bare strings, and the aliases
`description|title|name|task` are rewritten to `task_description`.

### A2. In-session representation (there is NO on-disk representation)

```
state = { tasks: Map<id, {id, taskDescription, details?, completed}>,
          description: string, context: string[],
          modifiedFiles: string[], nextId: 1 }
```

Ids are stringified integers assigned from `nextId++`, starting at 1.
Purely in-memory on the single `TodoList` instance. Nothing writes it to
disk; nothing rehydrates it (A5).

### A3. Operations — exact semantics

- **create** — wholesale replace: resets the entire state (including
  `nextId` back to 1), then inserts the given tasks. The only "edit" path.
- **add** — appends tasks (ids continue from `nextId`); may replace the
  list description.
- **complete** — marks each given id `completed: true` (error on unknown
  id); pushes the mandatory `context_update` onto `context`; merges +
  sorts `modified_files`. **If every task is now complete, the whole state
  is silently wiped back to empty** (tasks, description, context,
  modifiedFiles — everything).
- **remove** — deletes ids (error on unknown id); may replace description.
- **list** — returns full state:
  `{ tasks: [{id, task_description, completed}], description, context, modified_files }`.

Missing on purpose: **no edit of a task's text/details, no reorder, no
un-complete, no per-task delete-and-keep-context**. Commands are serialized
per instance via an internal promise chain (`pending`), so concurrent calls
from parallel executions are ordered, not interleaved.

### A4. F7 — immutability verdict

An entry's `task_description`/`details` are **immutable from creation to
death**. The only mutations are the one-way `completed` flip and removal.
The list advances by **append (`add`), one-way complete, delete
(`remove`), or whole-record replace (`create`)** — nothing else. Any queue
built on top of `todo_list` can therefore only advance by append or
whole-record replace, and it has a second hard constraint the operator must
design around: **completing the final task destroys the queue and all its
accumulated context** (A3 complete). A persistent queue must either keep a
sentinel never-completed task or treat `create` as its checkpoint format.

### A5. Lifetime and scope

- Exactly **one** `new TodoList()` per session, created unconditionally in
  `createWorkspaceConnection` (`src/acp/acp-workspace-connection.ts`,
  offset 19303469) and threaded by reference through every
  `WorkspaceConnectionImpl` reconstruction (`withToolPolicy` /
  `withContext` copy `todoList: this._todoList`, offset 4982822).
- Therefore the list is **session-global shared state**: the chat bundle
  and the custom-agent bundle (`baseCustomAgentTools = [...chatTools, ...]`,
  offset 19313892) both contain the same instance, so a dispatched
  sub-execution whose profile allows `todo_list` mutates the **parent
  session's one and only list**. There is no per-execution todo scope.
- **Not durable.** No serialization and no rehydration path exists: all 12
  `todoList` and all 11 `TodoList` occurrences in the bundle are accounted
  for (schema doc comment 877223; WorkspaceConnectionImpl plumbing
  4978378–4982838; injectTodoContext 16999394; telemetry catalog 3997605;
  export barrel 17599408; class body 18221641–18227613; instantiation
  19303458–19303473; chatTools 19308651). None touches session
  persistence. After `session/load` the model sees prior `todo_list` tool
  outputs in the transcript but `list` returns an empty state — a
  believable-lie hazard for resumed sessions.
- Each workflow-step session runs its own `createWorkspaceConnection`, so
  step sessions get **fresh, isolated** todo lists; todo state does not
  flow between steps.

### A6. Gating — `chat.enableTodoList` is inert on v3

The CLI forwards `chat.enableTodoList` as settings key `todoList` at
initialize (corpus). The KAS schema accepts it (offset 877223, doc comment
"Todo list tool — persistent task tracking within sessions" — note the
comment itself over-promises "persistent"). **No consumer exists**: the
quoted string `"todoList"` appears **zero** times in the 20 MB bundle
(positive controls by the same method: `isSettingEnabled(settings,
"knowledge")` and `"inlineAgents"` and `"subagentOrchestration"` all
present at offset ~19303469+); the unquoted occurrences are the 12
enumerated in A5, none a settings read. The tool is registered and the
context injection runs regardless of the setting. C-11 class: documented
but unconsumed. (On v2 the same key gates the Rust todo feature — v2-only
note, not explored.)

### A7. Context injection (how the model keeps seeing the list)

`injectTodoContext` (`src/graphs/inject-todo-context.ts`, offset 16999097)
runs inside the chat agent graph's `MODEL_INVOKE` node (offsets 17168344
and 17169109 — the second is the context-overflow retry inside the same
node) — i.e. **before every model invocation of a chat-graph session**. It
calls `formatContextIfChanged()` and, when non-null, appends a **human**
message wrapped in `--- CONTEXT ENTRY BEGIN ---` / `--- CONTEXT ENTRY END
---` containing: "Active Task List for current session:", the description,
`Progress: n/m tasks completed`, checkbox lines `[✓]|[ ] #id. text` with
`(NEXT)` on the first incomplete task, the **last 3** context entries, and
the modified-files list.

Dedup: `formatContextIfChanged` returns null when the rendered string
equals the last injected snapshot (comment names the MODEL_INVOKE loops
via FAILURE_DETECTION / SUMMARIZATION_DETECTION / CONTEXT_RESET). Two
consequences: (a) an unchanged list is injected once, not per turn; (b)
after a compaction rebuilds the context, the todo block is **not**
re-injected until the list changes — a compacted session can lose sight of
its own list (inferred from the dedup contract; flagged in section 7).

These are the only three `injectTodoContext` occurrences — the
CustomAgentGraph `MODEL_INVOKE` (offset 14516983) and spec graphs do
**not** inject. Sub-executions can mutate the shared list but only read it
back via an explicit `list` call.

### A8. Rendering and persistence of todo actions

Every command emits an `AgentExecutionAction` with
`actionType: "todo_list"`, `input: {command}`, `output` = full formatted
state, `rawInput` = full input. The persistence classifier (offset
19446689) files `todo_list` under category **"tool"**, so the actions are
persisted with the session like any tool call. Rendering is the client's
job from that event stream — the tool description explicitly orders the
model not to print the list ("this is done for you"); the TUI draws it,
and a raw ACP client sees standard tool-call updates. No dedicated
`_kiro/todo*` or `_kiro/task*` extension method exists (0 hits each;
positive control `_kiro/workflow` = 118 hits).

## 3-B. Spec tasks — the interface, fully enumerated

### B1. `tasks.md` — the durable representation

Parser: `src/spec/tasks/markdown-task-parser.ts` (offset 15516576).
Checkbox statuses: `[ ]` not_started, `[x]`/`[X]` completed, `[-]`
in_progress, `[~]` queued. An optional marker `*` or `\*` directly after
the checkbox marks the task optional. Hierarchy comes from numbered
prefixes (`1`, `1.2`, …) or indentation nesting. **A task's id is its full
text line** — renaming a task changes its identity (see section 6).
Content lines beneath a task are captured as its `content`.

### B2. Metadata stores — there are TWO, with different shapes

1. **Home store** (`src/spec/tasks/task-metadata-storage.ts`, offset
   15522959): `~/.kiro/tasks/<workspaceHash>/<featureName>.meta.json`
   where `featureName = basename(dirname(tasksFilePath))`. Shape
   `{ tasks: { [taskId]: { taskId, specUri, executionHistory[],
   createdAt, updatedAt, pbtTestStatus?, errorMessage? } } }`.
   Execution history bounded to the last **10** entries per task. Writes
   are atomic (temp+rename) under a static per-file mutex. `loadTaskDAG`
   reconciles it on every load: prunes ids no longer in `tasks.md`,
   creates defaults for new ids (offset 15545410). Also holds the
   run-all **checkpoint** (`completedTaskIds`) used to build a resume
   prompt (offset 20548848).
2. **Sidecar store** (`src/spec/tasks/task-manager.ts` /
   `NodeTaskService`, offset 19029589): `<tasksFilePath minus .md>.meta.json`
   next to the file. Shape `{ pbtResults: {}, executionHistory: {} }`,
   entries `{executionId, chatSessionId, timestamp}`, same 10-cap.
   Written by `workspace.updateTaskStatus`, which also rewrites the
   checkbox char in `tasks.md` under a `FileLock`.

Observed split (flagged, section 7): `task_update` persists through
`workspace.updateTaskStatus` → **sidecar**, while `task_get`/`task_list`
read history through `loadTaskDAG` → **home store** (populated by
`SpecTaskStatusTracker.associateExecution`, which runs when
`_kiro/spec/executeTask` is handled — offset 20153877). History written by
one path is invisible to the other.

### B3. The tools (`getTaskTools()`, offset 19257585)

All tagged `[spec, @builtin]`; registered ONLY in the
`taskOrchestrator` bundle (`taskOrchestratorTools = mergeTools(
getTaskTools(), specOrchestratorTools)`, offset 19314914) together with
`GetUserInput`. Not in chat, customAgent, or specAgent bundles.

- **`task_list`** (offset 19134596) — input `{tasksFilePath, status?}`
  where status ∈ `not_started|queued|in_progress|completed|ready`
  (`ready` = virtual: DAG dependencies satisfied). No filter → summary
  `{total, completed, remaining, ready}`. Re-reads disk every call.
- **`task_get`** (offset 19137457) — input `{tasksFilePath, taskId}`;
  returns id, text, status, isOptional, children, and metadata
  `{executionHistory, pbtResult, lastError}` (home store).
- **`task_update`** (offset 19139595) — input
  `{tasksFilePath, taskId?, status, error?}`.
  - Single update: stores `error` truncated to **1024** chars as
    `lastError`; `dag.updateNodeStatus` computes propagated changes
    (**completing all children auto-completes the parent**); each change
    is persisted (checkbox + sidecar); transition to `in_progress` runs
    **PreTaskExec** hooks, to `completed` runs **PostTaskExec** hooks;
    hook appendices are returned to the model as `<HOOK_INSTRUCTION>`
    blocks; result lists `propagatedChanges` and `newlyReady`.
  - `status="queued"` with no `taskId` queues **all not-started
    non-optional leaf** tasks and returns the DAG `executionOrder`.
  - Emits `AgentExecutionAction` `actionType: "task_status"` with
    `{taskId, taskListUri, taskStatus}`; persistence category "tool"
    (offset 19446665).
- Validation service (`NodeTaskService.validateTaskStatusChange`):
  completing a task with incomplete non-optional subtasks is refused;
  out-of-order `in_progress` yields warnings only.

### B4. Mutability (F7 contrast)

Spec tasks are the opposite of todo entries: **everything is mutable**.
Status moves in any direction `TaskStatus` allows (the schema accepts any
of the four), text/structure are plain markdown that any file-writing
actor edits, and metadata reconciliation silently discards history for
renamed tasks. Durability: fully durable across sessions and processes
(workspace file + home store).

### B5. External ACP surface (unadvertised, hardcoded-name)

Inbound handled methods: `_kiro/spec/executeTask` (associates an
execution with a task and drives it), `_kiro/spec/getTaskStatuses`,
`_kiro/spec/resolveSession`, `_kiro/spec/invoke`. Outbound notification:
`_kiro/spec/taskStatusChanged` `{sessionId, tasksFilePath, changes}`
emitted by `SpecTaskStatusTracker` (offset 20164475). All five appear in
the ext-method persistence classifier (offset 19447893). None is in the 7
advertised `extensionMethods` — same pattern as the `_kiro/workflow/*`
family: reachable only by knowing the name.

## 4. Activation drivers

Axis: user-typed / skill-invoked / agent-system-prompt-driven /
model-elected / hook-driven / workflow-step-driven / external-ACP-client.

### `todo_list` (every one of create/complete/add/remove/list)

- **model-elected: YES** — the only direct path. Available in every chat
  session (vibe default) and to custom agents/subagents whose profile
  passes `todo_list` (id match) or a tag it carries (`@builtin`, `*`);
  plan mode allowlists it explicitly (`PLAN_TOOLS`, offset 19984942).
- **agent-system-prompt-driven: indirect** — the tool description itself
  instructs use on every multi-step task; a profile prompt can strengthen
  or suppress that.
- **user-typed: NO** — no slash command in the KAS bundle (quoted-string
  sweep found only `"todo_list"`/`"TodoList"`; v2's `/todo` has no v3
  counterpart here; final word belongs to F2).
- **hook-driven: NO direct** — hooks return text; their appendix can only
  *ask* the model to run the tool.
- **workflow-step-driven: indirect** — a step session's model may call
  it, on that step's private instance.
- **external-ACP-client: NO** — no extension method; tools are not
  client-invokable.
- **subagent → parent list: YES** — same instance by reference (A5).

### Spec tasks

- **model-elected: YES** — `task_list`/`task_get`/`task_update`, but only
  in the taskOrchestrator bundle (DAG run-all / spec execution flows);
  any agent with file tools can also edit `tasks.md` raw.
- **user-typed: YES** — `tasks.md` is a plain workspace file; checkbox
  edits by hand are first-class (parser reads disk every call). Spec
  slash flows (`/spec …`) exist per vendor doc but their gates are F2's.
- **hook-driven: BOTH DIRECTIONS** — task transitions FIRE
  PreTaskExec/PostTaskExec (PreTaskExec can block, corpus); and a hook's
  shell command can itself rewrite `tasks.md`.
- **external-ACP-client: YES** — `_kiro/spec/executeTask`,
  `getTaskStatuses`, `resolveSession`, `invoke`; plus the
  `taskStatusChanged` notification for rendering.
- **workflow-step-driven: indirect** (a step's session can run the spec
  flows); **skill-invoked: no evidence** in this bundle.

## 5. Fixture design (all SPECS — every discriminating observable requires
a model turn or an engine launch this item does not authorize)

- **F13-t1 (shared instance + serialization).** Cheapest: one chat
  session, two prompts. P1: "create a todo list with tasks A,B,C". P2:
  "run todo_list list". Observable: `list` output ids `1,2,3` and the
  injected `--- CONTEXT ENTRY BEGIN ---` block in `_kiro/session/history`
  (or messages.jsonl) exactly once while unchanged. Discriminator: a
  second identical injection block without a list change = dedup broken.
- **F13-t2 (non-durability across resume).** Create todos; `session/load`
  the same id in a fresh engine; prompt "run todo_list list".
  PASS (as documented): empty state + no injection block.
  FAIL (refutes A5): tasks survive.
- **F13-t3 (subagent writes parent list).** Custom agent profile with
  `tools: ["todo_list"]` (+ valid `permissions`, else the profile is
  silently skipped — settled loader fact). Root prompt: create list, then
  dispatch the subagent instructed to `add` task D, then root `list`.
  PASS: root sees D with the next monotonic id. Also probes C-9
  adjacency: worker must stay short.
- **F13-t4 (all-complete wipe).** Create 2 tasks; complete both in one
  call with a `context_update`; then `list`. PASS: fully empty state
  (context gone too). This is the queue-design constraint made visible.
- **F13-s1 (spec parse, model-free once a launch is authorized).** Seed
  `.kiro/specs/f/tasks.md` with all four checkbox chars + one `*`
  optional; call `_kiro/spec/getTaskStatuses` over ACP-direct.
  Observable: statuses and optionality match B1 mapping. No model call.
- **F13-s2 (propagation + hooks + dual store).** tasks.md with parent
  `1` and children `1.1`, `1.2`; hooks for PreTaskExec/PostTaskExec that
  echo markers; drive `task_update` completed on both children.
  Observables: parent auto-completes (`propagatedChanges`), both hook
  markers fire, checkbox chars rewritten, and — the dual-store probe —
  whether `<dir>/tasks.meta.json` (sidecar) and
  `~/.kiro/tasks/<hash>/f.meta.json` (home) BOTH gained history, and
  which one `task_get` echoes back.
- **F13-i1 (compaction loses todo context).** Long session with an
  unchanged todo list pushed across the compaction threshold; after
  compaction, check history for a re-injected context block before any
  todo mutation. Absence confirms the A7 inference.

## 6. Cross-interactions

- **`chat.enableTodoList` does nothing on v3** while genuinely gating the
  v2 feature — an operator toggling it and observing v2 behavior will
  mis-model v3. Inert-flag class C-11.
- **All-complete wipe vs any queue semantics** (A3/A4): finishing the last
  item destroys description, context, and modified-files memory.
- **Resume mismatch**: transcript shows old todo outputs, live state is
  empty (A5) — the model can hallucinate a list it can no longer advance.
- **Compaction vs injection dedup** (A7): unchanged lists may drop out of
  the model's view after context rebuilds.
- **Shared instance vs parallel sub-executions**: mutations serialize on
  one promise chain (no interleaving), but siblings race on ordering;
  `create` from any branch wholesale-replaces everyone's list.
- **Spec task identity is the text line**: rewording a task orphans its
  metadata (reconcile prunes it), detaches execution history, and breaks
  run-all checkpoints keyed by `completedTaskIds`.
- **Dual metadata stores** (B2): history written via `task_update` lands
  in the sidecar; `task_get` reads the home store — audits that trust one
  file see half the picture.
- **Hooks on transitions**: a blocking PreTaskExec hook (exit 2) gates
  `in_progress` transitions made through `task_update` — but nothing
  gates raw checkbox edits to `tasks.md`, so hook-enforced policy is
  advisory against file-level writers.
- **Sandbox/deny policies**: `todo_list` has no capability mapping of its
  own observed; profile `tools` filtering and `policySession` capability
  denial (offset 19314914 `filterDenied`) are the only cut-offs.
