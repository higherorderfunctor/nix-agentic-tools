# Kimchi/pi workflow-extension feasibility

INFERRED — Feasible as a third-party extension for a persistent Kimchi session.
Most primitives exist; the integration is medium work. Safe live graph mutation
and durable execution beyond session shutdown are hard. Recommend a thin runner
around the kimchi-workflows engine, replacing its launch/agent host surfaces
rather than using its current `/workflow` command unchanged.

## Evidence convention and scope

OBSERVED — The supplied pi package identifies itself as
`@earendil-works/pi-coding-agent` 0.85.1 (`P/package.json:2–3`). Kimchi pins
coding-agent and pi-tui 0.85.1 and patches all three pi packages
(`K/../package.json:53–54,98,141–143`).

Citation roots (all remaining `file:line` citations resolve under these exact
directories):

- `K` = `getkimchi/kimchi@v1.5.1/src`
- `P` = `@earendil-works/pi-coding-agent@0.85.1 (npm tarball, unpacked)/package`
- `W` = `@kimchi-dev/kimchi-workflows@0.0.9 (npm tarball, unpacked)`

INFERRED — This is source feasibility analysis, not a running prototype or
provider-load test. Absence findings below are scoped to inspected APIs and
targeted source searches, not proof about every possible implementation.

## 1. TUI: existing primitives, small dashboard integration

OBSERVED — Extension UI supports keyed status strings, string/component widgets
above or below the editor, custom headers/footer, and custom components with
overlay positioning and handles (`P/dist/core/extensions/types.d.ts:80–127`).
These are pi-tui types: `Component`, `TUI`, `OverlayHandle`, and
`OverlayOptions` are imported from `@earendil-works/pi-tui`
(`P/dist/core/extensions/types.d.ts:12`).

OBSERVED — The documented pi-tui component contract is
`render(width): string[]`, optional keyboard/mouse input, and `invalidate()`;
rendering is requested through `tui.requestRender()`
(`P/docs/tui.md:11–29,522`). Custom UI normally replaces the editor temporarily;
overlays float above it and can change focus/visibility
(`P/docs/extensions.md:2733–2794`).

INFERRED — A stage/node panel can be a persistent widget plus an interactive
overlay. Mutate a view model on progress events, invalidate cached rendering,
then request a frame. There is no requirement to patch Kimchi's terminal
renderer. The supplied coding-agent bundle documents/re-exports the pi-tui
contract; this investigation did not independently inspect a separate pi-tui
source checkout.

Concrete Kimchi precedents:

- OBSERVED — Todos store subscriptions call `syncTodoWidget`; it updates a
  component widget, keyed count/status, and forces `requestRender(true)`
  (`K/extensions/todos/index.ts:168–174`;
  `K/extensions/todos/widget.ts:331–408,422–429`). `/todos` registers through
  `registerCommand` (`K/extensions/todos/command.ts:265–277`).
- OBSERVED — `/ferment` registers its controller; its progress selector
  subscribes to domain events, aborts/recreates the selector with fresh options,
  and closes it around blocking prompts
  (`K/extensions/ferment/commands.ts:426–460,1150–1161`).
- OBSERVED — `/agents` opens a management menu; the conversation viewer uses a
  centered custom overlay guarded by `ctx.mode === "tui"`, subscribes to session
  events, and requests rendering. Its persistent widget refreshes every 80 ms
  (`K/extensions/agents/index.ts:2601–2617,3052–3057`;
  `K/extensions/agents/ui/conversation-viewer.ts:51–54`;
  `K/extensions/agents/ui/agent-widget.ts:193–196,464–483`).
- OBSERVED — `/remote-run` launches a background cloud agent; the model-facing
  dispatch tool is excluded from print runs because consent requires a human
  (`K/extensions/remote-run/index.ts:70–94`). This is a background launch
  precedent, not evidence of a local stage dashboard.
- OBSERVED — Teleport registers its commands and renders centered progress
  overlays with timer-driven redraw/cleanup; quota promises request redraw on
  resolution (`K/extensions/teleport/index.ts:44–65`;
  `K/extensions/teleport/ui/progress.ts:66–83,299–315`;
  `K/extensions/teleport/ui/quota-footer.ts:28–45`).
- OBSERVED — `/budget` refreshes billing then uses `notify`; billing
  subscriptions redraw the header/footer
  (`K/extensions/billing/command.ts:82–103`; `K/extensions/ui.ts:408–430`). It
  is not a custom workflow-like panel.

OBSERVED — `ctx.mode` distinguishes TUI/RPC/JSON/print; `hasUI` is true for RPC
as well as TUI, false for print/JSON (`P/docs/extensions.md:966–974,2930–2937`).
Pi RPC forwards status and string widgets, but ignores component/header/footer
factories and returns undefined from `custom()`
(`P/dist/modes/rpc/rpc-mode.js:101–154`).

OBSERVED — Kimchi ACP binds extensions as RPC; its UI forwards status/string
widgets but drops component factories and custom terminal UI
(`K/modes/acp/server.ts:634–652`; `K/modes/acp/acp-ui-context.ts:300–352`).
Supported clients can receive elicitation dialogs
(`K/modes/acp/acp-ui-context.ts:182–195`).

INFERRED — Guard terminal factories with `mode === "tui"`, not just `hasUI`. Use
string progress for ACP, whose client decides presentation. Print/JSON must
report events/results through headless output. No extension can make a terminal
overlay appear in an ACP client merely by using pi-tui.

## 2. Async callbacks: existing, with lifecycle caveats

OBSERVED — Tools return a promise of a result; the API separately offers event
subscriptions, an extension event bus, custom-message renderers, `sendMessage`,
and `sendUserMessage`
(`P/dist/core/extensions/types.d.ts:372,932–944,965–985,1082–1083`).

OBSERVED — `sendMessage` accepts `triggerTurn` and
`deliverAs: steer | followUp | nextTurn`; `sendUserMessage` always triggers a
turn (`P/dist/core/extensions/types.d.ts:971–984`). During streaming, a
triggering custom message is queued; when idle, `triggerTurn:true` starts
`_runAgentPrompt`. `nextTurn` explicitly defers; an idle non-triggering message
is only appended (`P/dist/core/agent-session.js:1099–1139`).

INFERRED — `workflow_run` can create a run/controller, attach asynchronous
completion handlers, start the engine without awaiting it, and return the run
ID. Later send one custom completion message with
`{deliverAs:"followUp", triggerTurn:true}`. Events and UI notifications alone do
not wake inference; there is no need to wait for another user turn when the
session remains alive.

OBSERVED — Kimchi background Agent returns its ID/results-notification promise
immediately (`K/extensions/agents/index.ts:1915–1916`). Completion releases the
manager slot, calls completion handlers, and drains the queue
(`K/extensions/agents/manager/agent-manager.ts:349–384`). Individual/group
notifications use `{deliverAs:"followUp", triggerTurn:true}`
(`K/extensions/agents/index.ts:875–882,924–931`).

OBSERVED — `get_subagent_result(wait:true)` is a bounded join capped at 60
seconds; cancelled/expired waits preserve eventual notification
(`K/extensions/agents/index.ts:153,2311–2314`). `steer_subagent` accepts running
agents, queues messages during initialization, then uses `session.steer`
(`K/extensions/agents/index.ts:2390–2409`;
`K/extensions/agents/manager/agent-runner.ts:1028–1030`). Resume retains
session/persona/model/task and requires bounded continuation limits
(`K/extensions/agents/resume-tool.ts:12,39–65`).

OBSERVED — Kimchi watches long-running shell exit via `registry.whenExited`,
with disposed/session-replaced/in-flight-control guards; its message uses
`deliverAs:"steer"` without `triggerTurn:true`
(`K/extensions/bash-background/bash-control-extension.ts:166–210`). Pi's
file-trigger example explicitly sets `triggerTurn:true`
(`P/examples/extensions/file-trigger.ts:18–28`).

INFERRED — Reuse shell-watcher lifecycle guards, but not its idle-wake behavior:
under this pi version, that shell notification cannot itself start an idle turn.

OBSERVED — Workflows persist progress before drawing; command-bound telemetry
uses `pi.events.emit`; headless progress goes to stderr
(`W/src/host/progress-sink.ts:7–17,64–74,104–107`;
`W/src/host/extension.ts:71–77`). Its run command awaits tracked execution and
then reports outcome (`W/src/host/commands/run.ts:225–253`;
`W/src/host/extension.ts:96`). The `triggerTurn:true` message in its Pi bridge
starts an agent step, not an independent completion notification
(`W/src/host/pi-agent.ts:500–507`).

OBSERVED — Print mode disposes its runtime in `finally` after processing prompts
(`P/dist/modes/print-mode.js:103–108,132–139`). Kimchi Agent documents
foreground defaults for headless runs
(`K/extensions/agents/index.ts:1564–1569`).

INFERRED — Detached tasks cannot rely on a disposed `-p` parent to receive
completion. Either await in headless mode, or use a persistent worker plus
reconnect/result retrieval. ACP has session-level messaging primitives, but
autonomous completion beyond an outstanding ACP prompt needs a
client/session-lifecycle integration test; RPC-style UI transport alone does not
prove client-visible autonomous turns.

## 3. Inference fan-out: existing choices; explicit effort adapter needed

OBSERVED — Kimchi Agent accepts both `model` and `thinking`; thinking overrides
persona defaults (`K/extensions/agents/index.ts:1533–1543`;
`K/extensions/agents/resolution/invocation-config.ts:70`). Runner selects a
model, shares the parent's model runtime, and creates an independent session
with explicit thinking
(`K/extensions/agents/manager/agent-runner.ts:427,524–548`).

OBSERVED — Public `createAgentSession` options expose `modelRuntime`, `model`,
and `thinkingLevel`; defaults come from settings and are clamped to capabilities
(`P/dist/core/sdk.d.ts:10–24`; `P/dist/core/sdk.js:115–137`). Each session
constructs its own agent using the runtime stream interface
(`P/dist/core/sdk.js:177–206`).

OBSERVED — Pi's subagent example spawns `--mode json -p --no-session` with
`--model` and optional `--thinking`
(`P/examples/extensions/subagent/index.ts:300–307`). CLI supports both flags and
lists thinking levels (`P/dist/cli/args.js:112–120,270–292`).

OBSERVED — Raw inference is demonstrated through
`ctx.modelRegistry.complete(model, context, {reasoningEffort:"high"})`
(`P/examples/extensions/summarize.ts:181–189`). A direct pi-ai `streamSimple`
example supplies `apiKey` and `reasoning:"low"`
(`P/examples/extensions/custom-provider-gitlab-duo/test.ts:66–70`). The runtime
resolves credentials per request before provider streaming
(`P/dist/core/model-runtime.js:425–450,461–465`).

INFERRED — Prefer public SDK sessions sharing `ctx.modelRegistry.runtime` for
tool-using nodes; use registry completion for raw text nodes. Direct pi-ai calls
are possible but require explicit auth/provider setup. Private Kimchi Agent
manager imports create version coupling; external JSON children give process
separation but need carefully pinned executable/configuration. Effort maps to
provider-supported thinking, not a guarantee of identical computation across
models.

OBSERVED — Agent manager defaults to four concurrent background agents; queued
jobs start when slots free
(`K/extensions/agents/manager/agent-manager.ts:57,364–369`). Credential files
use locks; in-memory operations and runtime credential mutations serialize
(`P/dist/core/auth-storage.js:76–100,234–259`;
`P/dist/core/model-runtime.js:355–370`).

OBSERVED — Workflows expose per-step model, default model, and a root
concurrency ceiling defaulting to four; scheduler uses a FIFO semaphore plus
foreach-local limits (`W/src/flow/types.ts:219,457–463`;
`W/src/engine/scheduler.ts:11–21,37–60,71–104`). Engine passes resolved model to
its host (`W/src/engine/step-runner.ts:380,411–428`). Inspected
AgentRequest/step surfaces lack a thinking field
(`W/src/engine/types.ts:234–245`; `W/src/flow/types.ts:219`).

OBSERVED — Existing workflow host runs background/isolated nodes as JSON-print
subprocesses, rejects overlapping in-session turns, passes optional model, and
sets `KIMCHI_PERMISSIONS:"yolo"` (`W/src/host/pi-agent.ts:369–400,605–641`).
In-session model choice changes the parent via `pi.setModel`
(`W/src/host/pi-agent.ts:404–412`).

INFERRED — Add thinking to the DSL/node request and a custom host adapter; do
not rely on current child defaults or change the orchestrator model to execute
nodes. Limits are per manager/run, not a global provider quota. Add one shared
limiter across workflow runs, plus budgets/timeouts. Separate children need the
Kimchi executable/environment/agent directory to preserve provider
configuration; arbitrary `pi` startup is not equivalent to Kimchi's patched
authentication setup.

## 4. Control tools: existing registration, small initial surface

OBSERVED — `registerTool` registers model-callable tools; `ToolDefinition`
carries name, description, TypeBox `parameters`, typed `Static<TParams>`
execution args, abort signal, updates, and result
(`P/dist/core/extensions/types.d.ts:344–372,944`). Agent demonstrates
`Type.Object` with strings, optional model/thinking, bounds, and background
boolean (`K/extensions/agents/index.ts:1522–1575`).

INFERRED — Register `workflow_run`, `workflow_status`, `workflow_cancel`,
`workflow_steer`, and `workflow_update` with typed run/node IDs and
operation-specific parameters. Registration is small; implementing semantics is
separate. Give detached runs their own AbortControllers: the original tool-call
signal is not a durable run owner after return.

INFERRED — Status reads event-projected state; cancel aborts the run and its
workers; steer addresses an active child. Make initial update support change
inputs/prompts for pending nodes only, with revisions. Arbitrary mutation of
running/completed graph nodes needs stronger validation and should not be
claimed as an existing engine capability.

## 5. Script execution and reusable engine

OBSERVED — Loader evaluates TypeScript through jiti without module cache,
accepts default or named `workflow`, and checks shape
(`W/src/host/load-workflow.ts:90–100`). Virtual imports expose
authoring/engine/TypeBox/Pi modules; Node built-ins resolve natively
(`W/src/host/load-workflow.ts:47–59`).

INFERRED — This is executable module loading, not a sandbox. A model-authored
temp module can use the same loader. Dynamic import similarly executes code; a
VM would require additional module/permission design and cannot be assumed
secure merely because it is a VM. A separate process gives a killable execution
boundary, but not filesystem/network isolation by itself.

OBSERVED — Package exports engine/host/extension; public host exports include
loader/store/bridge (`W/package.json:55–65`; `W/src/host/index.ts:25–28,43–45`).
`HostPort` abstracts clock, sleep, agent start, durable emit, transient updates;
AgentSession abstracts turns/history/disposal (`W/src/engine/types.ts:382–412`).
Store appends event JSONL with serialized per-path writes and partial-tail
recovery (`W/src/host/fs-store.ts:17,38–39,56–65,84–104,208–212`).

OBSERVED — Resume reconstructs outputs, skips completed nodes, restarts
incomplete enclosing nodes, reloads the source definition, and rejects removed
completed steps/invalid completed outputs
(`W/src/engine/resume-workflow.ts:39–81,315,323`;
`W/src/host/recorded-workflow.ts:74–81`). Child cancellation escalates SIGTERM
to SIGKILL (`W/src/host/subagent-process.ts:153–158`).

INFERRED — Reuse engine/store/projection, with an
`agent()/parallel()/pipeline()` facade that constructs the existing definition.
Add explicit effort and isolated sessions at the HostPort seam. Source edits do
not patch the loaded graph; later resume uses drift checks, which are not a
general live-update transaction system. A custom thin scheduler is simpler only
if deliberately dropping engine features such as durable resume, typed outputs,
retries, loops and questionnaires.

## 6. Loading, difficulty and minimal architecture

OBSERVED — Pi settings accept `packages` and `extensions`; package manifests
expose `pi.extensions` and other resource arrays, with conventional
resource-directory fallback (`P/dist/core/settings-manager.js:721–744`;
`P/dist/core/pi-manifest.js:3,7–20`;
`P/dist/core/package-manager.js:1801–1838`). Explicit extension sources can be
files/directories; loader invokes a default-export factory and supplies bundled
module aliases (`P/dist/core/package-manager.js:1046–1063`;
`P/dist/core/extensions/loader.js:416–435`).

OBSERVED — Resource loader combines CLI/discovered extension paths
(`P/dist/core/resource-loader.js:316–329`). Kimchi passes extension factories to
upstream main; bundled workflows is selected via `extensions.workflows`,
disabled by default and restart-required (`K/cli.ts:9,783,842`;
`K/resources/definitions.ts:92–97`). Kimchi enumerates native configured
packages and optional original-Pi packages
(`K/resources/package-resources.ts:33–42`). Workflows itself declares
`pi.extensions` (`W/package.json:72–76`).

INFERRED — A third-party package or settings extension path is the viable
no-Kimchi-patch route. Kimchi `extensions.*` resources govern managed built-ins;
they are not arbitrary module paths. Configure the custom extension through
package resources/normal extension discovery, and avoid duplicate `/workflow`
registration. Verify discovery in the shipped compiled Kimchi, not only
unbundled pi.

OBSERVED — Kimchi notes parent-injected CLI factories are not discovered
automatically by child resource loaders
(`K/extensions/agents/manager/agent-runner.ts:501,510–513`). Kimchi carries pi
patches; workflow development dependencies are intentionally aligned with the
pinned runtime (`K/../package.json:141–143`; `W/package.json:110`).

INFERRED — No new Kimchi patch appears necessary for terminal UI, typed tools,
session wake, or SDK-based fan-out. Per-node thinking needs our facade/host
changes or a kimchi-workflows API change. ACP autonomous-turn lifecycle, durable
out-of-process ownership, and automatic child-extension inheritance may require
deeper host integration depending on product requirements. Pin and test against
Kimchi's patched pi version; public API changes and private Agent imports are
upgrade risks.

All effort classifications below are INFERRED engineering judgments, not
measured implementation durations:

| Piece                                 | Size             | Basis                                                                 |
| ------------------------------------- | ---------------- | --------------------------------------------------------------------- |
| Completion notification/wake          | Existing + small | Agent notification and pi message routing cited in §2                 |
| Control tool schemas/status           | Existing + small | registerTool and durable event store cited in §§4–5                   |
| DSL facade and effort propagation     | Medium           | Existing model/engine seam; missing thinking field cited in §§3,5     |
| Live stage/node TUI                   | Existing + small | Widget/overlay/frame APIs and examples cited in §1                    |
| Run cancellation/active-node steering | Medium           | Worker abort/steer exists; run ownership integration cited in §§2,4–5 |
| Detached launch/session cleanup       | Medium           | Current run command awaits; persistent-session lifecycle cited in §2  |
| Arbitrary live graph update           | Hard             | Resume drift checks do not supply live mutation semantics, §5         |
| Survive parent exit/reconnect         | Hard             | Print runtime teardown and persistent ownership gap, §2               |
| Third-party extension loading         | Existing + small | Settings/manifest/resource loading cited in §6                        |

INFERRED — Minimal architecture: one extension owns a run registry and five
tools; a small DSL compiles to WorkflowDefinition; reused engine/store emits
durable events; a new HostPort creates independent SDK sessions with explicit
model/thinking and a shared limiter; projection drives a terminal widget/overlay
or ACP strings; completion sends a custom follow-up with `triggerTurn:true`
exactly once. Cancel propagates to workers; steer targets active sessions;
update initially affects pending nodes only. Keep runs session-scoped for the
first version and await them in print mode. This reaches the requested
interactive experience without reimplementing a workflow engine or patching
Kimchi's core.
