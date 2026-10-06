# Delegate lifecycle control

How a running delegate is steered, cancelled, updated, observed, resumed, timed
out, permission-gated and read back, per harness.

Pins and evidence marks: [evidence.md](evidence.md).

Replay `side:case` means case `case` in
`packages/delegate-routing/probes/delegates/<harness>/`; `side` is the probe run
that produced it (`claude`, `codex`, `judge`). A mark inside a cell (for example
"(G)") overrides the row mark for that clause.

Cross-harness tables use one representative row set: each harness's main
delegate primitives plus its richest host session API. Additional surfaces
follow those tables.

## Steer

| Harness | Delegate         | Steer a running delegate                                                   | Mark | Replay                        |
| ------- | ---------------- | -------------------------------------------------------------------------- | ---- | ----------------------------- |
| Claude  | Agent fg         | none from model (parent blocked); host `background_tasks` (G)              | V    | claude:ctl                    |
| Claude  | Agent bg         | `SendMessage`, queued, lands at next tool round                            | V    | claude:steer_bg               |
| Claude  | Workflow node    | **no**: `SendMessage` to node agentId starts a separate copy; node runs on | V    | judge:judge_wf_msg            |
| Claude  | `-p` / SDK       | stream-json user frames; `interrupt {cancel_queued}`                       | V    | claude:ctl                    |
| Codex   | V2 child         | model `followup_task` / `send_message`; host steer **rejected**            | V    | claude:R4, claude:R7          |
| Codex   | V1 child         | `send_input` (`interrupt:true`)                                            | A    | claude:R8                     |
| Codex   | app-server root  | `turn/steer` + `expectedTurnId`                                            | V    | claude:R6                     |
| Codex   | `codex exec`     | none after launch                                                          | I    | claude:R0                     |
| Kiro    | v3 invoke        | parent steer reaches in-flight child; no per-child address                 | V    | judge:k-steer                 |
| Kiro    | v3 workflow      | `send_message` both ways; `update_workflow`; TUI node steer (G)            | V; A | judge:k-wfctl, judge:send-dir |
| Kiro    | v2 crew          | steer by child id reaches only that child                                  | V    | claude:a2-steerchild          |
| Kiro    | ACP v3 session   | `steer`, `steer/clear`                                                     | V; A | judge:k-steer, codex:R3       |
| Kimchi  | `Agent` fg       | none to child; host steer lands on parent after return                     | V    | claude:s6-rpc-steer-parent    |
| Kimchi  | `Agent` bg       | `steer_subagent`                                                           | V    | claude:s2-rpc-bg              |
| Kimchi  | Workflow bg step | none                                                                       | V    | codex:W                       |
| Kimchi  | RPC session      | `steer`, `follow_up`                                                       | V    | codex:R                       |

## Cancel and propagation

| Harness | Delegate         | Cancel by                                                | Reaches descendants?                                  | Mark | Replay                                                        |
| ------- | ---------------- | -------------------------------------------------------- | ----------------------------------------------------- | ---- | ------------------------------------------------------------- |
| Claude  | Agent fg         | host `stop_task` / `interrupt`                           | aborts the child request                              | V    | claude:ctl                                                    |
| Claude  | Agent bg         | `TaskStop` → `killed`                                    | **yes**: fg grandchild aborted too                    | V    | claude:stop_bg, claude:stop_bg_propagate                      |
| Claude  | Workflow node    | `TaskStop`                                               | aborts in-flight node                                 | V    | claude:wf_stop                                                |
| Claude  | `-p` / SDK       | `interrupt`; `send_task_message` unsupported             | aborts turn + running fg child                        | V    | claude:ctl                                                    |
| Codex   | V2 child         | `interrupt_agent`, host `turn/interrupt`                 | **no**                                                | V    | claude:R4, claude:R7, codex:R1.v2-interrupt-tree              |
| Codex   | V1 child         | `close_agent`                                            | yes, cascades                                         | A    | claude:R8, codex:R1.v1-close-tree                             |
| Codex   | app-server root  | `turn/interrupt`                                         | **no**: children keep running                         | V    | claude:R5                                                     |
| Codex   | `codex exec`     | signal                                                   | children die at root end                              | I    | claude:R0, codex:R1.exec-resume-fork                          |
| Kiro    | v3 invoke        | parent turn cancel only; no selective cancel             | yes: shared signal to child + grandchild              | V    | claude:k-cancel                                               |
| Kiro    | v3 workflow      | `_kiro/workflow/cancel`                                  | **parent cancel leaves the run going**                | V    | judge:k-wfctl                                                 |
| Kiro    | v2 crew          | child-id cancel terminates child                         | **no**: child ran `shell` after parent cancel         | V    | judge:j-a2-cancel-cfg, claude:a2-cancelchild                  |
| Kiro    | ACP v3 session   | `cancel`, `close`, `delete`                              | as v3 invoke                                          | V; A | codex:R3, codex:R6                                            |
| Kimchi  | `Agent` fg       | RPC `abort`, ACP cancel, Esc                             | yes                                                   | V    | claude:s4-rpc-abort-fg, claude:a1-acp-cancel-fg               |
| Kimchi  | `Agent` bg       | Ctrl+X (newest); shutdown; no model-callable cancel      | **no** for RPC/ACP cancel; `-p` shutdown loses output | V    | claude:s5-rpc-abort-bg, claude:s3c-print-bg                   |
| Kimchi  | Workflow bg step | `/workflow cancel`: SIGTERM→SIGKILL 5 s; RPC `abort`: no | direct child process only                             | V    | claude:w3b-workflow-cancel-late, claude:w4-workflow-rpc-abort |
| Kimchi  | RPC session      | `abort`                                                  | parent + fg children only                             | V    | codex:R                                                       |

## Update mid-run (model, effort, instructions)

| Harness | Delegate         | Mid-run update                                                                                                   | Mark | Replay                          |
| ------- | ---------------- | ---------------------------------------------------------------------------------------------------------------- | ---- | ------------------------------- |
| Claude  | Agent fg         | no                                                                                                               | V    | claude:ctl                      |
| Claude  | Agent bg         | text only (`SendMessage`)                                                                                        | V    | claude:steer_bg                 |
| Claude  | Workflow node    | no; stop, edit script, `resumeFromRunId`                                                                         | V    | claude:wf_resume                |
| Claude  | `-p` / SDK       | `set_model`, `apply_flag_settings {effortLevel}`, `set_permission_mode`; later children inherit; running child U | V    | claude:ctl, claude:ctl_effort   |
| Codex   | V2 child         | no; host settings rejected                                                                                       | V    | claude:R7                       |
| Codex   | V1 child         | no; resume resets effort to parent                                                                               | A    | claude:R8                       |
| Codex   | app-server root  | `turn/settings/update` (needs `step_model_switching`): next step; some model pairs rejected                      | V    | claude:R6, codex:R2             |
| Codex   | `codex exec`     | no                                                                                                               | I    | claude:R0                       |
| Kiro    | v3 invoke        | no; spawn snapshot                                                                                               | V    | judge:j-a2-cancel-cfg, codex:R3 |
| Kiro    | v3 workflow      | remaining plan at node boundary; active step kept                                                                | V; A | judge:k-wfctl                   |
| Kiro    | v2 crew          | no                                                                                                               | V    | judge:j-a2-cancel-cfg           |
| Kiro    | ACP v3 session   | `set_config_option`, `set_mode`: next turn (v2 ACP: −32601)                                                      | V    | judge:j-a2-cancel-cfg, codex:R2 |
| Kimchi  | `Agent` fg       | none; fixed at spawn                                                                                             | V    | codex:R                         |
| Kimchi  | `Agent` bg       | none                                                                                                             | V    | codex:R                         |
| Kimchi  | Workflow bg step | none                                                                                                             | V    | codex:W                         |
| Kimchi  | RPC session      | `set_model`, `set_thinking_level`: next turn, parent only                                                        | V    | codex:R                         |

No harness shows a path to change a **running child's** model or effort.

## Status

| Harness | Delegate         | Status source                                                                       | Mark | Replay                                   |
| ------- | ---------------- | ----------------------------------------------------------------------------------- | ---- | ---------------------------------------- |
| Claude  | Agent fg         | SubagentStart/Stop hooks; `task_started` + `spawn_depth`                            | V    | claude:ctl, claude:hooks_obs             |
| Claude  | Agent bg         | `task_progress`, `task_updated`, `<task-notification>`                              | V    | claude:bg                                |
| Claude  | Workflow node    | `workflow_progress`; per-node SubagentStart/Stop; `/workflows`; not in `ListAgents` | V    | claude:hooks_wf, judge:judge_wf_msg      |
| Claude  | `-p` / SDK       | `task_*` events, `result.subagents`                                                 | V    | claude:ctl                               |
| Codex   | V2 child         | `list_agents` (evicted omitted), thread notifications, `subAgentActivity`           | V    | claude:R2, codex:R1.v2-resident-eviction |
| Codex   | V1 child         | `wait_agent` map, `<subagent_notification>`                                         | A    | claude:R8                                |
| Codex   | app-server root  | notifications, `thread/read`, loaded/list                                           | V    | codex:R2                                 |
| Codex   | `codex exec`     | `--json` stream                                                                     | I    | claude:R0                                |
| Kiro    | v3 invoke        | parent `tool_call` + child events under parent sid                                  | V    | codex:R5                                 |
| Kiro    | v3 workflow      | `list` / `inspect` / `load`; node events                                            | V; A | codex:R4                                 |
| Kiro    | v2 crew          | `_kiro.dev/subagent/list_update`                                                    | V    | judge:j-a2-cancel-cfg                    |
| Kiro    | ACP v3 session   | `update`, `sessions/changed`                                                        | V; A | codex:R3                                 |
| Kimchi  | `Agent` fg       | streamed tool updates                                                               | V    | codex:C                                  |
| Kimchi  | `Agent` bg       | `get_subagent_result` (`wait` ≤60 s); completion starts a parent turn               | V    | claude:s8-resume-ctx, claude:s2-rpc-bg   |
| Kimchi  | Workflow bg step | `/workflow status`, run list                                                        | V    | codex:W                                  |
| Kimchi  | RPC session      | `get_state`, stats, events                                                          | V    | codex:R                                  |

## Resume and fork

| Harness | Delegate             | Resume / fork                                                                                                                                           | Mark | Replay                      |
| ------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | --------------------------- |
| Claude  | Agent fg             | `SendMessage` after completion resumes                                                                                                                  | V    | claude:live_resume          |
| Claude  | Agent bg             | `SendMessage` after completion → full history; fork copies parent system + history                                                                      | V    | claude:live_resume, codex:C |
| Claude  | Workflow node        | `resumeFromRunId`, same session; cached nodes, 0 new requests                                                                                           | V    | claude:wf_resume            |
| Claude  | `-p` / SDK           | `--resume`, `--continue`, `--fork-session`, `--session-id`; resume re-sends the **first** session's system prompt unless `--system-prompt-snapshot off` | V    | claude:resume_fork          |
| Codex   | V2 child             | `followup_task` reloads; fork only at spawn (`fork_turns`)                                                                                              | V    | claude:R4                   |
| Codex   | V1 child             | `resume_agent` after close                                                                                                                              | A    | claude:R8                   |
| Codex   | app-server root      | `thread/resume`, `thread/fork`; resuming a loaded thread ignores new overrides                                                                          | V    | codex:R2                    |
| Codex   | `codex exec`         | `exec resume`, `exec fork`                                                                                                                              | I    | codex:R1.exec-resume-fork   |
| Kiro    | v3 invoke            | parent only; child none                                                                                                                                 | V    | codex:R5                    |
| Kiro    | v3 workflow          | pause→resume same step session (old prompt kept); retry fresh; no fork                                                                                  | V; A | judge:k-wfctl               |
| Kiro    | v2 crew              | U                                                                                                                                                       | U    | —                           |
| Kiro    | ACP v3 session       | load / resume / fork / list; resumed session reuses persisted prompt                                                                                    | V; A | codex:R3                    |
| Kimchi  | `Agent` fg           | `resume_subagent`; `inherit_context` at spawn                                                                                                           | V    | codex:B                     |
| Kimchi  | `Agent` bg           | `resume_subagent`                                                                                                                                       | V    | claude:s8b-resume-yolo      |
| Kimchi  | Ferment-linked child | Continuation guard only for `ferment_step`                                                                                                              | A    | judge:J3                    |
| Kimchi  | Workflow bg step     | `/workflow resume`, `resumable`; no fork                                                                                                                | V    | codex:W                     |
| Kimchi  | RPC session          | `fork`, `clone`, switch/new session                                                                                                                     | V    | codex:R                     |

## Timeouts

| Harness | Delegate         | Limit                                                                                                                  | Mark | Replay                                   |
| ------- | ---------------- | ---------------------------------------------------------------------------------------------------------------------- | ---- | ---------------------------------------- |
| Claude  | Agent fg         | frontmatter `maxTurns`; no per-call wall clock                                                                         | V    | claude:fm_turns                          |
| Claude  | Agent bg         | `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS` → `failed`; `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` (600 s, G) → `killed` in `-p` | V    | claude:bg_stall, claude:bg_print_ceiling |
| Claude  | Workflow node    | no node deadline; stall retry ≤5 (G); `budget` setter U                                                                | V    | claude:wf_budget                         |
| Claude  | `-p` / SDK       | `--max-budget-usd` (spend); no wall-clock flag                                                                         | V    | codex:H                                  |
| Codex   | V2 child         | `wait_agent` `timeout_ms` 10 s–1 h (default 30 s) only; `agents.job_max_runtime_seconds` no-op (G)                     | V    | codex:R1.v2-invalid, judge:J2            |
| Codex   | V1 child         | wait only                                                                                                              | A    | claude:R8                                |
| Codex   | app-server root  | none                                                                                                                   | V    | codex:R2                                 |
| Codex   | `codex exec`     | none                                                                                                                   | I    | claude:R0                                |
| Kiro    | v3 invoke        | idle `KIRO_SUBAGENT_DEADLINE_MS` 1 h (`0` off); 300 turns; no total wall clock                                         | V    | claude:k-stall, codex:R5                 |
| Kiro    | v3 workflow      | watch-node `idleTimeoutSec`; else none                                                                                 | V; A | codex:R6                                 |
| Kiro    | v2 crew          | `api.subagentTimeout` (G)                                                                                              | G    | —                                        |
| Kiro    | ACP v3 session   | host-owned                                                                                                             | V    | codex:R3                                 |
| Kimchi  | `Agent` fg       | 900 s wall default, 120 s idle, 30+5 turns, output-token budget                                                        | V    | codex:Q, judge:J4                        |
| Kimchi  | `Agent` bg       | as fg                                                                                                                  | V    | judge:J4                                 |
| Kimchi  | Workflow bg step | `maxDurationMs`                                                                                                        | V    | codex:W                                  |
| Kimchi  | RPC session      | none                                                                                                                   | V    | codex:R                                  |

## Permission prompts in non-interactive children

| Harness | Delegate         | What happens to a child's approval request                                                                                    | Mark | Replay                                             |
| ------- | ---------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---- | -------------------------------------------------- |
| Claude  | Agent fg / bg    | inherits parent mode; `-p` without host → is_error "needs approval"; `--permission-prompts none` → auto-denied; nothing hangs | V    | claude:perm_default, claude:perm_none              |
| Claude  | Workflow node    | `-p` default mode denies the `Workflow` call; nodes inherit; PreToolUse not fired for nodes                                   | V    | claude:wf_default, claude:hooks_wf                 |
| Claude  | `-p` / SDK       | `--permission-prompts host\|none`, `--permission-prompt-tool`, `can_use_tool` (G)                                             | V    | claude:perm_none, claude:perm_default              |
| Codex   | V2 child         | inherits parent policy; approval sent to host with child threadId                                                             | V    | claude:R9                                          |
| Codex   | V1 child         | inherits parent policy                                                                                                        | A    | claude:R8                                          |
| Codex   | app-server root  | server requests to host                                                                                                       | V    | codex:R2                                           |
| Codex   | `codex exec`     | approval forced never; requests rejected                                                                                      | I    | claude:R0                                          |
| Kiro    | v3 invoke        | prompts under parent sid; headless rejects                                                                                    | V    | claude:k-perm                                      |
| Kiro    | v3 workflow      | U                                                                                                                             | U    | —                                                  |
| Kiro    | v2 crew          | headless error unless trusted                                                                                                 | V    | claude:h2-trustdel                                 |
| Kiro    | ACP v3 session   | `request_permission` callback                                                                                                 | V; A | codex:R3                                           |
| Kimchi  | `Agent` fg / bg  | none: child tools ungated                                                                                                     | V    | claude:s9-perm-default, claude:a2-acp-default-perm |
| Kimchi  | Workflow bg step | none: forced `KIMCHI_PERMISSIONS=yolo`                                                                                        | V    | codex:W                                            |
| Kimchi  | RPC session      | `extension_ui_request` to client (parent only)                                                                                | V    | codex:R                                            |

## Output retrieval

| Harness | Delegate         | Where the result lands                                         | Mark | Replay                           |
| ------- | ---------------- | -------------------------------------------------------------- | ---- | -------------------------------- |
| Claude  | Agent fg         | tool_result; `subagents/agent-<id>.jsonl`                      | V    | claude:ctl                       |
| Claude  | Agent bg         | notification `<result>`; `output_file`                         | V    | claude:bg                        |
| Claude  | Workflow node    | notification `<result>`, `journal.jsonl`, node transcripts     | V    | claude:wf_resume                 |
| Claude  | `-p` / SDK       | stdout; `--forward-subagent-text` (G)                          | V    | codex:H                          |
| Codex   | V2 child         | mailbox FINAL_ANSWER, rollout; `wait_agent` returns no content | V    | claude:R2, codex:R1.v2-lifecycle |
| Codex   | V1 child         | `wait_agent` result, rollout                                   | A    | claude:R8                        |
| Codex   | app-server root  | `thread/read`, turn/item reads                                 | V    | codex:R2                         |
| Codex   | `codex exec`     | `-o`, `--json`, rollout                                        | I    | codex:R1.exec-resume-fork        |
| Kiro    | v3 invoke        | result + files; `sub-executions/*.jsonl`                       | V    | codex:R5                         |
| Kiro    | v3 workflow      | outputs, artifacts, step sessions                              | V; A | codex:R4                         |
| Kiro    | v2 crew          | consolidated text                                              | V    | claude:h2-all                    |
| Kiro    | ACP v3 session   | history / export                                               | V; A | codex:R3                         |
| Kimchi  | `Agent` fg       | tool result, `.output`, session file                           | V    | codex:C                          |
| Kimchi  | `Agent` bg       | verbose `get_subagent_result`, `.output`                       | V    | claude:s8-resume-ctx             |
| Kimchi  | Workflow bg step | final turn / `workflow_submit_result`; step session            | V    | codex:W                          |
| Kimchi  | RPC session      | messages, last text, `export_html`                             | V    | codex:R                          |

## Claude — additional surfaces

| Tool | Steer | Cancel (propagates?) | Update mid-run | Status | Resume/fork | Timeout | Perm prompts in child | Output | Mark | Replay |
| ---- | ----- | -------------------- | -------------- | ------ | ----------- | ------- | --------------------- | ------ | ---- | ------ |

## Codex — additional surfaces

| Tool              | Steer                | Cancel (propagates?)             | Update mid-run | Status           | Resume/fork                   | Timeout | Perm prompts in child | Output          | Mark | Replay              |
| ----------------- | -------------------- | -------------------------------- | -------------- | ---------------- | ----------------------------- | ------- | --------------------- | --------------- | ---- | ------------------- |
| SDK session       | Python RPC; TS none  | Python interrupt; TS AbortSignal | as underlying  | events           | Python resume/fork; TS resume | host    | as underlying         | structured      | A    | codex:R0            |
| TUI/daemon/remote | interactive, `queue` | interactive                      | via app-server | agent browser    | interactive                   | U       | interactive           | UI              | U    | codex:R0            |
| Cloud task        | none                 | none exposed                     | none           | `status`, `list` | none                          | U       | U                     | `diff`, `apply` | U    | codex:R0, claude:R0 |

## Kiro — additional surfaces

| Tool                           | Steer          | Cancel (propagates?) | Update mid-run      | Status            | Resume/fork               | Timeout   | Perm prompts in child                | Output         | Mark | Replay                   |
| ------------------------------ | -------------- | -------------------- | ------------------- | ----------------- | ------------------------- | --------- | ------------------------------------ | -------------- | ---- | ------------------------ |
| orchestrate (v3)               | as invoke      | as invoke            | `repeat` only       | per stage         | none                      | as invoke | headless: trust orchestrate + invoke | stage text     | V    | claude:h3-trustdel2      |
| v1 `use_subagent` / `delegate` | no             | U                    | no                  | `delegate status` | no                        | U         | as v2                                | summary/status | V; G | claude:g-v1-deleg        |
| Headless chat                  | none           | kill process (I)     | no                  | `stream-json`     | `--resume`, `--resume-id` | none      | deny unless trusted                  | stdout/JSONL   | V    | codex:R1, claude:h3-perm |
| TUI                            | steer or queue | Escape               | model/mode controls | dashboard         | load, rewind/fork         | engine    | interactive                          | panels         | A    | codex:R6                 |
| Cloud / serve / crew CLI       | U              | U                    | U                   | U                 | U                         | U         | U                                    | U              | U    | codex:R1                 |

## Kimchi — additional surfaces

| Tool                     | Steer                    | Cancel (propagates?)                   | Update mid-run                   | Status                | Resume/fork                  | Timeout                      | Perm prompts in child                  | Output                | Mark | Replay                          |
| ------------------------ | ------------------------ | -------------------------------------- | -------------------------------- | --------------------- | ---------------------------- | ---------------------------- | -------------------------------------- | --------------------- | ---- | ------------------------------- |
| Ferment-linked `Agent`   | `steer_subagent`         | as `Agent`                             | —                                | outcome + report      | 2 continuations, 1 finalizer | tier budgets                 | as `Agent`                             | `submit_agent_report` | A    | codex:N                         |
| Workflow in-session step | parent-turn              | `/workflow cancel`, Esc                | step model leaks to main session | `/workflow status`    | `/workflow resume`           | `maxDurationMs`, `maxTokens` | parent posture                         | run store             | V    | claude:w2-workflow-model-leak   |
| `-p` / json              | none                     | signal; daemons survive                | none                             | JSONL                 | `--continue`, `--resume`     | none                         | classifier fails closed; `--yolo` runs | stdout                | V    | claude:s9-perm-default, codex:B |
| Pi SDK                   | steer / follow-up        | abort                                  | model/thinking                   | subscriptions         | session managers             | host                         | no gate unless installed               | export                | A    | codex:P                         |
| Cloud dispatch           | `steer_subagent` via ACP | explicit abort; shutdown spares remote | none                             | notification, polling | reattach on resume           | creation 10 min              | worker policy U                        | local mirror          | A    | codex:P                         |
| External launchers       | target                   | signals forwarded                      | target                           | stdio                 | target                       | none                         | target                                 | target                | A    | codex:P                         |
| `bash`                   | none                     | stop/abort/deadline kills tree         | deadline, checkin                | `/processes`          | not across resume            | 120 s                        | parent gate only                       | tail + spill          | A    | codex:P                         |
| `daemon`                 | none                     | explicit stop; parent abort leaves it  | none                             | list/status           | ID kept                      | none                         | parent gate                            | log file              | A    | codex:P                         |

Open lifecycle questions and settling steps:
[evidence.md](evidence.md#open-unknowns).
