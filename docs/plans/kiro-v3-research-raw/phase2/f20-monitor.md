# F20 — The monitor pattern: waiting on external async work

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

## 1. The question

Can a Kiro v3 agent wait on long-running EXTERNAL work (canonical: push a PR,
wait for CI + review feedback, act on the outcome) without burning a model turn
per poll and without the operator prompting each check? "Settled" means: every
candidate mechanism is enumerated with per-poll cost in turns/credits, minimum
achievable latency, and whether an unfinished job is distinguishable from a
finished one at every exit path.

**Headline answer: a harness-native wait EXISTS and it is push-complete.** The
workflow `watch` node type polls an external system with **zero model
invocations per poll** (a `gh`/`cr` subprocess on a clock-timer loop inside the
KAS process), and TWO independent auto-wake paths start a model turn on the
idle parent session when something happens (`send_message` severity
warning/error, and `run_complete` on any terminal workflow status). Waiting is
free; only reacting costs. The catches are gating (stock TUI sessions have
`workflowsEnabled:false`) and a specific mis-scoring failure mode
(idle-timeout masquerades as terminal-state — §7 F1).

## 2. What is already known (citations)

- Watch node type exists in `NodeTypeSchema` with
  `WatchOutcomeSchema = ["idle", "new-activity", "terminal-state"]` —
  corpus `records/workflow-surface.md` R-workflow-5 (offsets 816170/816429).
- Repeat traps: post-body stop evaluation; missing `fileCheck` file reads
  silently false; `onMaxIterations:"continue"` marks the repeat COMPLETED on
  exhaustion; `stopCondition.completionSignal` undocumented in both
  description surfaces — corpus workflow-surface (StopCondition record) and
  the settled-facts block.
- Hook trigger vocabulary is CLOSED at 11 names — corpus
  `records/hooks-dispatch-gate.md` R-hooks-1 (TRIGGER_ALIAS_TABLE, 27 keys,
  11 canonical). No subagent-lifecycle trigger — R-hooks-2.
- Hook action types `command` and `agent` (askAgent) — corpus
  `records/hooks-io-contract.md` (offset 5069050 doc block; per-trigger table).
- `run_workflow`/`inspect_workflow`/`update_workflow`/`send_message` gated on
  per-session `workflowsEnabled`; ACP `_kiro/workflow/*` arm unconditional —
  corpus workflow-surface R-workflow-4 + settled facts.
- Background shell tiers, gates and truncation — F10 digest
  (`private/kiro-phase2/f10-builtin-tools.md`).
- `/spawn` is v2-only; KAS adapter stubs it ("/spawn is not supported in KAS
  mode"); v3 slash workflow-run/resume/status/cancel are inert — F11 digest.
- `_session/steer`, `_kiro/hooks/triggerHook`, prompt-meta `agentInitiated`,
  ws mux — ACP wireline digest (`private/kiro-phase2/acp-wireline.md`).

Everything below that is new was read from the bundle at the pinned KASID.

## 3. The interface, fully enumerated

### 3a. The `watch` node (src/workflow/watch-handler-registry.ts, handlers/, workflow-runner executeWatch)

Node schema (offset 821691):

```json
{ "type": "watch", "id": "<id>", "handler": "<handler-id>",
  "config": { }, "idleTimeoutSec": 0 }
```

- `config` — `record(unknown)`, optional. Top-level STRING values pass through
  `resolvePrompt` template interpolation (inputs, artifacts, capturedOutputs,
  previous completed sibling) at watch start (`interpolateWatchConfig`,
  17540781); non-string values (arrays like `ignoreAuthors`) are NOT
  interpolated.
- `idleTimeoutSec` — positive number, optional. Unset = poll forever.

Base config accepted by EVERY handler (`BaseWatchConfigSchema`, passthrough):
`pollIntervalSec` (positive; registry rejects values below the handler's
`minPollIntervalSec`), `commandTimeoutSec` (positive; per-spawned-CLI timeout,
unset waits indefinitely; enforced by the handler via `CommandRunner.run`).
Effective cadence: caller `pollIntervalSec` if >= handler min, else handler
`defaultPollIntervalSec`.

Registered handlers (exactly two; `list()` drives
`_kiro/workflow/listWatchHandlers`, returning id, description,
defaultPollIntervalSec, minPollIntervalSec, and a jsonSchema7 rendering of the
config schema, sorted by id):

**`github-pr`** (default 60s, min 30s): config
`{ prRef?, url?, pollIntervalSec?, commandTimeoutSec?, includeOwnActivity?, ignoreAuthors? }`,
refine: `prRef` or `url` required. `prRef` = workspace-relative (or absolute,
confined to workspace roots + additionalDirectories) JSON file whose `url`
field is the PR. Poll = spawn
`gh pr view --json url,state,isDraft,mergedAt,closedAt,comments,reviews,statusCheckRollup -- <url>`.
Outcome mapping, in order:

1. state MERGED/CLOSED (or `mergedAt` set) → `terminal-state`, payload
   captured.
2. unseen comments or reviews by non-excluded authors → `new-activity`,
   payload captured.
3. else → `idle` (cursor unchanged).

Payload (JSON string) = `{ url, state, newComments, newReviews,
excludedComments, excludedReviews, checkRollup }`. Novelty is id-based:
cursor carries `seenCommentIds`/`seenReviewIds` (cap `SEEN_IDS_CAP` = 1000)
plus legacy `lastCommentId`/`lastReviewId` sentinels. First poll with no
cursor: last `FIRST_POLL_CAP` = 5 items count as unseen. Exclusion: own
`gh api user --jq .login` identity (cached; lookup only attempted when
`includeOwnActivity` !== true and something is unseen) and `ignoreAuthors`
logins, case-insensitive; excluded items still ride in
`excludedComments`/`excludedReviews`.

**`crux-cr`** (default 60s, min 30s): Amazon-internal `cr` CLI; config
`{ crRef?, crId?, pollIntervalSec?, commandTimeoutSec? }`; crId must match
`^CR-\d+$`; terminal states MERGED, SUBMITTED, REJECTED, CLOSED, ABANDONED;
first-poll backfill last 5 comments / last 3 revisions. Unusable outside
Amazon; documented for completeness only.

Executor loop (`executeWatch`, ~17523802): forever { check abort → poll →
on `idle`: persist cursor, emit `watch_poll` notification
`{workflowId, nodeId, nodePath, outcome, at}`, check idle budget,
`clock.sleep(pollIntervalSec)`; on `new-activity`/`terminal-state`: capture
payload into `capturedOutputs[node.id]` (so `{{<id>.output}}` resolves
downstream), set `watchTerminal=true` if terminal, mark node **completed**,
emit `watch_poll`, return }. The watch node is ONE-SHOT: it completes on the
first non-idle outcome. Idle budget measured from watch START (never reset —
irrelevant since any activity completes the node).

Idle timeout path (`completeIdleTimedOutWatch`): payload =
`{"outcome":"idle-timeout","idleTimeoutSec":N}`, sets `watchTerminal=true`,
node completed, and emits `watch_poll` with outcome **`terminal-state`** —
deliberately mirroring a real terminal poll. See §7 F1.

Stop wiring: repeat `stopWhen` grammar (`parseStopWhen`, 17275691) accepts
EXACTLY two forms: `{{expr}} contains <literal>` (template must open the
string, single-space ` contains `) or `<watchId>.terminal` (single identifier,
no dots/whitespace). The watchTerminal evaluator errors if the id resolves to
a non-watch node and returns `nodes.some(n => n.watchTerminal === true)`
across all iteration instances. Watch cursors are CARRIED across repeat
iterations (`ensureRepeatIteration` → `collectWatchCursors`/`seedWatchCursors`
from the previous iteration, including into nested sequence/parallel/repeat
subtrees) — no re-delivery of already-seen items on iteration N+1.

Ordering inside a repeat iteration: body executes sequentially; the sibling
step AFTER the watch still runs in the same iteration that the watch went
terminal in (stop is evaluated post-body), so the "act on outcome" step always
sees the terminal payload.

### 3b. Result delivery and auto-wake (push, not poll)

Three independent client/parent-ward channels:

1. **`_kiro/workflow/*` notifications** to the ACP connection (bridge binds to
   the LAST connection that called load/invoke/resume; lifecycle payloads
   carry `parentSessionId` and route through the parent session's broadcast
   outbound in ws mux mode; parentless runs fall back to raw connection emit).
   `watch_poll` and `loop_iteration` are wire-only — `persistWorkflowEvent`
   explicitly skips them from the parent transcript.
2. **`send_message` tool** (workflow step sessions only): resolves target
   `"parent"` or an authorized in-workflow session id; persists a
   `[notification/<severity>]` steering row to the target's message store
   (loading the target session ON DEMAND with `noReplay` if not in memory —
   works after restarts); appends to the live steering buffer; emits
   `_kiro/session/notify` to the client; and **if severity is `warning` or
   `error` and the target has NO active execution, auto-wakes it** via an
   internal `prompt()` with `_meta.kiro.agentInitiated:true` (hidden: no user
   row persisted, no user_message_chunk echo). Severity also doubles as the
   completion-signal writer: success→`success`, error→`error`,
   warning→`need_input` (feeds `stopCondition.completionSignal`), with
   run-ownership lease verification and an explicit warning string when
   another process owns the run.
3. **`run_complete` auto-wake** (`autoWakeParentOnComplete`, 18592424): on ANY
   terminal status (completed | failed | aborted), resolves the parent
   session (loads it on demand), and if idle, prompts it agent-initiated with
   `A workflow you launched ("<name>") <completed|failed|aborted>. Review its results and continue if you were waiting on it.`
   If the parent is mid-turn, the same text is appended to its steering
   buffer instead (delivered at the next model invocation; queued steering
   also resets the 300-consecutive-invocation counter).

### 3c. Run lifetime, persistence, restart

Workflow state persists under
`<sessionsPath>/<workspaceHash>/workflows/<workflowId>/` (combined-hash dir;
single-path hash dirs also probed). Liveness: `run.beat` heartbeat every 30s,
staleness threshold 135s, `run.claim` takeover arbitration, wake-drift
(laptop-sleep) defer window. `startupRecovery()` is called at the END of the
`initialize` handshake — every engine start with any client sweeps stale runs
(`sweepStaleWorkflowRuns` → `sweepStaleRuns`): stale RUNNING runs are
reconciled (mid-LLM-step nodes paused with reason
"Interrupted by agent restart; the previously running step was paused for resume.")
and — ONLY if the run was parked at watch nodes — auto-resumed after takeover
arbitration, with the notification bridge wired before invoke. The sweep is
"intentionally unconditional with respect to the per-session workflows
setting" (continuation is process-level; the flag gates only the model-facing
creation surface). Mid-step-interrupted runs stay paused until an ACP client
calls `_kiro/workflow/resume` (slash commands inert; no model-facing resume
tool).

### 3d. The other candidate mechanisms

**(a) Backgrounded shell** — F10 settled, restated for the cost table only.
Tier 1 `control_bash_process`/`get_process_output`/`list_processes`: real
persistent handle, survives across turns, but gated on
`clientMeta.backgroundProcesses === true` + client terminal capability at
initialize — 0 hits in the stock TUI binary (re-confirmed this run:
`backgroundProcesses` 0 hits in the 555 MB `.kiro-cli-chat-wrapped`, positive
controls "settings" 7778, "goal" 98), so external-ACP-client-only. Checking
output is model-initiated: 1 model invocation per check. Tier 2
`run_in_background` (default-variant execute_bash only): appends `" &"`, no
handle, output unrecoverable — NOT a monitor primitive.

**Blocking single call** (the degenerate but real competitor): one
`execute_bash` running a self-blocking waiter (`gh pr checks --watch`,
`gh run watch`, `sleep N && check`). Default variant: timeout default 120s,
clamped at 30 min; 30k-char truncation. ACP variant: infinite default
timeout, no run_in_background. Cost: ~2 model invocations total (issue +
read); latency ~0 after the event. Ties the turn open (steering still
possible); counts as 1 against the 300-invocation bound.

**(b) Repeat WITHOUT watch** (LLM-step polling loop): each iteration = at
least one full step session turn. Only affordable for run-until-done INTERNAL
work (that is exactly the bundled `goal` recipe: repeat maxIterations 200,
`onMaxIterations:"pause"`, `stopCondition:{completionSignal:"success"}`,
wf-coder step). As an external wait it burns a turn per poll — the thing F20
exists to avoid.

**(c) /goal** — engine-parsed `/goal <desc> [--max N]` (N clamped 1..200,
default 5), launches the bundled goal recipe; gate =
`clientMeta.settings.goal` at initialize (connection-level, distinct from
workflowsEnabled). Run-until-done, not an external wait; per-iteration cost =
full agent turn. Cross-ref F1 for whether the stock TUI enables the gate
(unresolved here; TUI ships a `/goal` tip string and a Rust
`handle_goal_or_respond` symbol, suggesting yes — flagged).

**(d) /spawn** — v2-only. KAS adapter stub returns `sessionId:""` →
"/spawn is not supported in KAS mode" (F11). Not a v3 mechanism; nothing to
join.

**(e) Hooks** — the trigger vocabulary is CLOSED at 11:
SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PreTaskExec,
PostTaskExec, PostFileCreate, PostFileSave, PostFileDelete, Stop, Manual
(corpus R-hooks-1). Every one except Manual fires inside the turn/session
lifecycle — **no timer, cron, schedule, or file-watch trigger exists** (this
run's sweep: `"schedule"` 0, `scheduledTrigger` 0, `ScheduledTrigger` 0,
`onSchedule` 0, `timerTrigger` 0, `TimerTrigger` 0; the 11 `cron`/14 `CRON`
raw hits are HTML entity tables (`omicron;`) and OpenTelemetry
FAAS_CRON/K8S_CRONJOB attribute constants; positive controls `watch-handler`
3, `TRIGGER_ALIAS_TABLE` 3 by the same method). Manual is fired by the CLIENT
via `_kiro/hooks/triggerHook {sessionId, hookId, hookName, hookActionType,
command?, timeout?, approved?, prompt?}`: `askAgent` hooks are delivered by
calling the SAME internal `prompt()` path ("sends the hook prompt through the
normal prompt flow so the LLM processes it", `_meta.kiro.title` +
`displayText: "Execute hook: <name>"`) — i.e. a client-driven push that DOES
start a turn on an idle session; `runCommand` hooks call back to the client
via `_kiro/hooks/executeHook` and only emit action events (stdout discarded
for Manual per the corpus per-trigger table — cannot inject context). So
hooks are a push INJECTION surface for a connected client, not a wait
primitive: nothing in the hook system fires from wall-clock time or from an
external event.

**(f) The ACP channel** — on stdio, the transport is the client's pipe:
NO side ingress exists for a third process (no socket, no signal handler, no
IPC file). Injection surfaces once you ARE the connection: `session/prompt`
(optionally `_meta.kiro.agentInitiated:true` — hidden, no echo);
`_session/steer` (appends to the shared SteeringMessageBuffer, returns
`{queued:true,messageId}`; observed by every active execution at its next
model invocation; messages matching the notification prefix get
`notify-` ids; **does NOT start a turn on an idle session** — it waits in the
buffer); `_kiro/hooks/triggerHook` (above — DOES start a turn for askAgent).
The engine also supports `--transport=ws` (`VALID_TRANSPORTS = ["stdio","ws"]`,
port `ACP_WS_PORT` default 8082, MultiplexStream, `workspaceTrusted: true`
hardcoded, POST `/graceful_shutdown` endpoint): a self-launched ws engine
accepts MULTIPLE concurrent clients, so a generic JSON-RPC speaker (websocat +
jq is enough — "bespoke client" not required, but a JSON-RPC handshake is)
can steer/prompt/trigger into a live session while a primary client drives
it. The shipped Rust launcher always spawns `--transport=stdio` (settled), so
ws is opt-in self-hosting only.

## 4. Cost table

Per-poll cost is model invocations charged to reach the NEXT check; "wake" =
can it start a model turn on an idle session by itself.

| Mechanism | Per-poll cost | Min latency to react | Wake idle session? | Unfinished vs finished distinguishable? | Gate |
| --- | --- | --- | --- | --- | --- |
| workflow `watch` node | **0** (gh subprocess) | pollIntervalSec >= 30s (handler min) | YES (send_message warn/error; run_complete any terminal) | Payload yes; `watchTerminal`/stopWhen NO (idle-timeout sets it too, §7 F1) | workflowsEnabled for `run_workflow`; NONE for ACP `_kiro/workflow/new` |
| blocking single `execute_bash` | ~2 invocations total | ~0 (event-driven inside the command) | n/a (turn stays open) | YES if the command distinguishes timeout from completion in output/exit code | none (default variant); 30-min clamp default-variant, infinite ACP-variant |
| Tier-1 background process + checks | 1 invocation per check | one turn per check (model or operator initiates) | NO | YES (get_process_output returns full buffer + running state) | clientMeta.backgroundProcesses + terminal capability (stock TUI: cannot) |
| repeat + LLM step poll loop | >=1 full step-session turn | one turn cycle | YES (same workflow wakes) | Subject to `onMaxIterations:"continue"` mis-scoring (settled trap) | workflowsEnabled / ACP arm |
| /goal loop | >=1 full agent turn per iteration | one turn cycle | session-bound (it IS the session's workflow) | completionSignal is self-declared by the agent | clientMeta.settings.goal |
| hooks (Manual/askAgent) | n/a (no timer; client must fire) | client-decided | YES (askAgent starts a turn) | n/a — carries no job state | connected client only |
| `_session/steer` | n/a | next model invocation of an ACTIVE turn | NO (buffers on idle) | n/a | connected client only |
| external `session/prompt` (agentInitiated) | 1 turn per delivery | ~0 | YES | whatever the sender encodes | connected client (stdio: the one client; ws: any connected) |
| `run_in_background` (Tier 2) | output unrecoverable | n/a | NO | NO | default-variant only |

Credits: watch polls and clock sleeps bill nothing (no converse call). Every
wake/step/check that runs a model invocation bills as a normal prompt turn in
that session's `promptTurnSummaries`. Workflow steps run as their OWN sessions
(`createWorkflowStepSession` in kiro-agent-session-driver) — full sessions,
not sub-executions, so the C-9 parent-history-truncation trap does not apply
to them, and their usage is recorded per step session.

## 5. Activation drivers

| Lever | user-typed | skill | agent-sys-prompt | model-elected | hook | workflow-step | external-ACP |
| --- | --- | --- | --- | --- | --- | --- | --- |
| start watch workflow | only via prompt text asking the model | prompt-text | steering can urge it | YES `run_workflow` (needs workflowsEnabled) | no | YES (nested `run_workflow` if step agent has it) | YES `_kiro/workflow/new` (+`parentSessionId` accepted!) + `invoke`, ungated |
| watch poll execution | — | — | — | — | — | harness clock loop | — |
| `send_message` wake | no | no | step prompt tells the agent WHEN | YES (step model elects severity) | no | YES (only registered in workflow step pools) | no |
| `run_complete` wake | — | — | — | — | — | automatic on terminal status | notification also mirrored to connection |
| blocking bash wait | can instruct | can instruct | can instruct | YES | no | step agent can | via prompt |
| Tier-1 background proc | no (stock TUI can't enable) | no | solicits model | YES when gated in | no | possible if gate enabled | YES (enables the gate) |
| Manual hook (askAgent) | /hooks UI → client fires | no | no | no (no tool reaches hook routers) | IS the hook | no | YES `_kiro/hooks/triggerHook` |
| `_session/steer` | no | no | no | no | no | no | YES |

Note the asymmetry that decides real deployments: in a STOCK TUI session
(`workflowsEnabled:false` in session/new `_meta`) the model cannot elect
`run_workflow` and the operator's `/workflow-*` commands are inert, so the
watch machinery — although fully present and running process-wide — is only
reachable via an external ACP client or a client that flips the session gate.
The `_kiro/workflow/new` handler accepts `parentSessionId` (verified at
18540117 window: used to resolve workspace roots for `generated://` recipes,
threaded into the run state) — an external client can therefore attach a watch
workflow to an EXISTING session so the auto-wake paths target it.

## 6. Fixture design (SPECS — none of these were run)

### 6a. Zero-model watch mechanics fixture (settles outcomes, cursor, idle-timeout)

Cheapest mode: ACP-direct arm, no session prompt, no model, stub `gh`.

- Isolation: fresh `HOME=$T/home` (settled lever), real `XDG_DATA_HOME`.
- Stub: `$T/bin/gh`, a script that reads `$T/fixture-phase` and prints a
  crafted `gh pr view --json` payload: phase 1 → no comments (idle); phase 2 →
  one new comment by author `reviewer1` (new-activity); phase 3 → state
  MERGED (terminal). `gh api user --jq .login` → `self-login`. Prepend to
  PATH before launching the engine.
- Launch: `node <bundle> --transport=stdio --auth=acp-callback` driven by the
  corpus ACP harness (answer `_kiro/auth/getAccessToken` with a dummy — token
  is never exercised because no converse call happens).
- Script: `initialize` (this alone triggers `startupRecovery`); →
  `_kiro/workflow/listWatchHandlers` (EXPECT: exactly `crux-cr`, `github-pr`
  with defaults 60/min 30 and jsonSchema7 config schemas); →
  `_kiro/workflow/new` with inline workflow
  `{name:"w", steps:[{type:"repeat", id:"loop", maxIterations:3, onMaxIterations:"abort", stopWhen:"w1.terminal", steps:[{type:"watch", id:"w1", handler:"github-pr", config:{url:"https://github.com/o/r/pull/1", pollIntervalSec:30}, idleTimeoutSec:3600}]}]}`
  (workspacePaths `[$T/ws]`); → `invoke`; flip fixture-phase 1→2→3 at ~35s
  intervals.
- PASS observables: `watch_poll` notifications idle → new-activity →
  (iteration 2) terminal-state; `loop_iteration` with `stopConditionMet:true`
  on the terminal iteration; `_kiro/workflow/inspect` shows
  `capturedOutputs.w1` containing `newComments` in iter-0…; state.json under
  `$HOME/.kiro/sessions/<hash>/workflows/`. FAIL: any model/network egress,
  or re-delivery of the phase-2 comment in the terminal iteration (cursor
  carry-over broken).
- Also asserts (validation): a workflow whose body has NO `step` nodes is
  accepted (flagged claim — if `_kiro/workflow/new` rejects it, add a step
  node and mark the fixture model-requiring).

### 6b. Idle-timeout mis-scoring fixture (THE failure mode)

Same rig, stub pinned to phase 1 (always idle), `idleTimeoutSec: 40`,
`pollIntervalSec: 30`. EXPECT after ~40-70s: `watch_poll` with outcome
`terminal-state` (NOT a distinct value), node completed,
`capturedOutputs.w1 == {"outcome":"idle-timeout","idleTimeoutSec":40}`, and
`stopWhen:"w1.terminal"` fires → repeat completed → run_complete
status `completed`. This proves a fully-timed-out wait terminates as SUCCESS
at every surface except the payload text — the discriminator a consumer MUST
check.

### 6c. End-to-end monitor SPEC (needs live model — spec only)

Session script (external ACP client, or a client that sets
`workflowsEnabled:true` at session/new):

1. `session/new` (cwd = repo worktree), prompt: "Push branch X and open a PR;
   then run the pr-monitor workflow with the PR url and stop."
2. The turn ends after the model calls `run_workflow` with inline workflow:

```json
{ "name": "pr-monitor",
  "inputs": { "pr_url": "url" },
  "steps": [
    { "type": "repeat", "id": "loop", "maxIterations": 20,
      "onMaxIterations": "abort",
      "stopWhen": "prw.terminal",
      "steps": [
        { "type": "watch", "id": "prw", "handler": "github-pr",
          "config": { "url": "{{pr_url}}",
                      "ignoreAuthors": ["github-actions"],
                      "commandTimeoutSec": 120 },
          "idleTimeoutSec": 86400 },
        { "type": "step", "id": "triage", "agent": "wf-coder",
          "prompt": "Watch result: {{prw.output}}. If outcome is idle-timeout, call send_message severity=error saying the wait timed out and STOP. If the PR is merged/closed, send_message severity=info with the final state. If there are newReviews or newComments, address them: reply or push fixes, then finish WITHOUT send_message so the loop continues. If checkRollup shows failures, fix and push." } ] } ] }
```

3. Operator walks away. Cost while quiet: zero. On review activity: one
   `triage` step session turn per activity burst. On merge/close: triage
   runs once more with the terminal payload, loop stops, `run_complete`
   auto-wakes the parent ("completed") which summarizes.
4. Failure branch is exercised by closing the PR without merging, and by
   letting it idle past `idleTimeoutSec`: PASS = the parent's wake turn
   reports timeout/closed as FAILURE (because triage's prompt branches on the
   payload), never as success.
5. `onMaxIterations` MUST be `abort` (or `pause`) — `continue` would score an
   exhausted loop as completed.

Note the CI caveat baked into the prompt: `checkRollup` is snapshot-only —
CI completion alone never wakes the watch (§7 F4); the design relies on
review/comment activity or a CI bot that comments.

## 7. Failure-mode inventory (ways the wait terminates while reporting the wrong outcome)

- **F1 — idle-timeout masquerades as terminal.** `completeIdleTimedOutWatch`
  sets `watchTerminal=true` AND emits `watch_poll` outcome `terminal-state`;
  `stopWhen "<id>.terminal"` fires; the run completes with status
  `completed`. The ONLY discriminator is the captured payload
  `{"outcome":"idle-timeout",...}` vs a real payload (which has `url`/`state`).
  A timed-out CI wait reads green everywhere except that string. Mitigate: the
  step after the watch must branch on `outcome`, and prefer `onMaxIterations`
  abort/pause.
- **F2 — poll errors are `idle`.** `gh` exit != 0 or unparseable stdout →
  `{outcome:"idle", cursor:unchanged}`. Expired auth, rate-limit, deleted PR,
  network down: the watch polls forever "quietly", then F1 fires if
  idleTimeoutSec is set. No error outcome exists in `WatchOutcomeSchema`.
- **F3 — infinite silent wait.** No idleTimeoutSec + no activity → the watch
  never completes → the ITERATION never completes → `stopWhen` never
  evaluated; `maxIterations` bounds iterations, not polls. Run sits `running`
  forever; only `_kiro/workflow/cancel`/`pause` (client) ends it.
- **F4 — CI status never wakes github-pr.** `statusCheckRollup` is carried in
  the payload but plays no part in outcome mapping (only comments/reviews →
  new-activity; merged/closed → terminal). "Wake me when checks finish"
  silently never fires.
- **F5 — first-poll backfill.** No cursor → last 5 comments/reviews count as
  unseen: pre-existing third-party comments wake the watch instantly (stale
  work re-triaged); items older than the last 5 are never delivered.
- **F6 — self-login lookup failure un-excludes own activity.**
  `resolveSelfLogin` swallows errors and returns undefined → the agent's OWN
  just-posted comment wakes the watch (feedback loop) exactly when `gh api
  user` fails. Mitigate: put the bot login in `ignoreAuthors` explicitly.
- **F7 — `onMaxIterations:"continue"` scores exhaustion as success** (settled
  corpus trap, restated because it composes with this pattern).
- **F8 — engine death stops the clock.** Polling lives in the KAS process; TUI
  exit kills it. Recovery is real but conditional: next engine `initialize`
  sweeps; watch-parked runs auto-resume (after 135s staleness + takeover
  arbitration); runs interrupted MID-STEP are paused with no model-facing or
  slash-reachable resume — an ACP client must call `_kiro/workflow/resume`.
  Nothing re-launches the engine itself (no daemon; cron absence settled §3e).
- **F9 — info/success never wakes.** `send_message` severity info/success only
  buffers; an idle parent learns of it at its NEXT turn, which may be never
  (until run_complete fires, which does wake).
- **F10 — wake is fire-and-forget.** Both auto-wake paths `void`-call
  `prompt()` and only log `auto_wake_failed`; for run_complete-while-busy the
  nudge goes to the steering buffer (safe), and send_message persists the row
  first (safe on next turn), but a failed WAKE itself is not retried.
- **F11 — notification stream stealing.** The workflow notification bridge
  binds to the LAST connection that called load/invoke/resume; a second ws
  client can silently divert lifecycle notifications (parent-session
  broadcast routing mitigates for payloads carrying parentSessionId).
- **F12 — cross-process wake divergence.** A second engine on the same HOME
  wakes the parent in ITS OWN process memory; a TUI holding the same session
  id in another process shows nothing live (transcript rows appear only on
  reload). Do not split the monitor and the interactive session across
  engines.
- **F13 — blocking-bash waits mis-score on clamp.** Default-variant
  execute_bash hard-caps at 30 min; a longer wait returns a timeout the model
  may narrate as "checks still running" or worse; 30k-char head80/tail20
  truncation can eat the discriminating tail. ACP-variant has no timeout but
  the F10 open question (downstream truncation) stands.

## 8. Cross-interactions

- **workflowsEnabled** gates model-facing creation only; continuation, the
  startup sweep, and ACP `_kiro/workflow/*` ignore it. `settings.goal` is a
  separate connection-level gate (F1's item).
- **stopCondition.completionSignal + send_message severity** interlock: a
  triage step's `send_message severity=error` both wakes the parent AND
  records signal `error` — a repeat with
  `stopCondition:{completionSignal:"error"}` (undocumented field, corpus
  drift record) stops on it. Two levers, one tool call.
- **Steering**: workflow auto-wake nudges use the same steering buffer as
  `_session/steer`; queued steering resets the 300-consecutive-invocation
  counter (settled), so a monitored session cannot starve its own turn budget
  by being woken.
- **20-step-node ceiling** counts `step` nodes only; watch/repeat/parallel
  are free — a many-watch fan-out (parallel branches of watches, joinPolicy
  `any` = first event wins and cancels the other watches) is structurally
  cheap. joinPolicy semantics per corpus R-workflow-5.
- **Hook system**: fully orthogonal — no timer trigger, no workflow trigger;
  a workflow step session fires its own SessionStart/Stop etc. like any
  session (dispatched sub-executions always take the first-turn branch —
  settled; steps are full sessions, so normal rules).
- **v2**: `/spawn`, kiro.dev/session/spawn are v2-only surfaces; nothing
  here applies to the v2 Rust engine (one-line note, per scope).

## 9. Recommended pattern (deliverable 2 summary)

Use `repeat{ watch(github-pr) → triage step }` with `stopWhen
"<watchId>.terminal"`, `onMaxIterations: "abort"`, explicit `idleTimeoutSec`,
`ignoreAuthors: ["github-actions"]` unless CI comments should wake, and a
triage prompt that BRANCHES ON `{{watch.output}}`'s `outcome` field
(idle-timeout → send_message severity=error). Start it from an external ACP
client via `_kiro/workflow/new {parentSessionId, workflow}` + `invoke` when
the interactive session is a stock TUI; via `run_workflow` when
workflowsEnabled. Zero cost while quiet; every wake is a push. The blocking
single `execute_bash` call is the right tool only for waits confidently under
30 min inside an already-open turn.
