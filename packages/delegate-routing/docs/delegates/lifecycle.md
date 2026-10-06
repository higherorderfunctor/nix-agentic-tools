# Delegate lifecycle control

How a running delegate is steered, cancelled, updated, observed, resumed, timed
out, permission-gated and read back, per harness.

## Key

| Harness     | Pinned version                             |
| ----------- | ------------------------------------------ |
| Claude Code | 2.1.289                                    |
| Codex CLI   | 0.160.0                                    |
| Kiro CLI    | 2.27.1 (KAS 0.66.22)                       |
| Kimchi      | 1.5.1 / Pi 0.85.1 / kimchi-workflows 0.0.9 |

| Mark  | Meaning                          |
| ----- | -------------------------------- |
| V     | executed                         |
| A     | read from the AST                |
| G     | grep only                        |
| I     | inferred                         |
| U     | unknown                          |
| SPLIT | probe sides disagree (none here) |

Replay `side:case` means case `case` in
`packages/delegate-routing/probes/delegates/<harness>/`; `side` is the probe run
that produced it (`claude`, `codex`, `judge`). A mark inside a cell (for example
"(G)") overrides the row mark for that clause.

Cross-harness tables use one representative row set: each harness's main
delegate primitives plus its richest host session API. Every other surface is in
the per-harness tables.

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

| Harness | Delegate         | Resume / fork                                                                                                                                           | Mark | Replay                           |
| ------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | -------------------------------- |
| Claude  | Agent fg         | `SendMessage` after completion resumes                                                                                                                  | V    | claude:live_resume               |
| Claude  | Agent bg         | `SendMessage` after completion → full history; fork copies parent system + history                                                                      | V    | claude:live_resume, codex:C      |
| Claude  | Workflow node    | `resumeFromRunId`, same session; cached nodes, 0 new requests                                                                                           | V    | claude:wf_resume                 |
| Claude  | `-p` / SDK       | `--resume`, `--continue`, `--fork-session`, `--session-id`; resume re-sends the **first** session's system prompt unless `--system-prompt-snapshot off` | V    | claude:resume_fork               |
| Codex   | V2 child         | `followup_task` reloads; fork only at spawn (`fork_turns`)                                                                                              | V    | claude:R4                        |
| Codex   | V1 child         | `resume_agent` after close                                                                                                                              | A    | claude:R8                        |
| Codex   | app-server root  | `thread/resume`, `thread/fork`; resuming a loaded thread ignores new overrides                                                                          | V    | codex:R2                         |
| Codex   | `codex exec`     | `exec resume`, `exec fork`                                                                                                                              | I    | codex:R1.exec-resume-fork        |
| Kiro    | v3 invoke        | parent only; child none                                                                                                                                 | V    | codex:R5                         |
| Kiro    | v3 workflow      | pause→resume same step session (old prompt kept); retry fresh; no fork                                                                                  | V; A | judge:k-wfctl                    |
| Kiro    | v2 crew          | U                                                                                                                                                       | U    | —                                |
| Kiro    | ACP v3 session   | load / resume / fork / list; resumed session reuses persisted prompt                                                                                    | V; A | codex:R3                         |
| Kimchi  | `Agent` fg       | `resume_subagent`; `inherit_context` at spawn                                                                                                           | V    | codex:B, judge:J3                |
| Kimchi  | `Agent` bg       | `resume_subagent` (2-continuation cap: Ferment-linked only)                                                                                             | V    | claude:s8b-resume-yolo, judge:J3 |
| Kimchi  | Workflow bg step | `/workflow resume`, `resumable`; no fork                                                                                                                | V    | codex:W                          |
| Kimchi  | RPC session      | `fork`, `clone`, switch/new session                                                                                                                     | V    | codex:R                          |

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

## Claude Code 2.1.289 — all surfaces

| Tool              | Steer                                        | Cancel (propagates?)                      | Update mid-run                                            | Status                             | Resume/fork                    | Timeout                     | Perm prompts in child                              | Output                      | Mark                | Replay                                                                         |
| ----------------- | -------------------------------------------- | ----------------------------------------- | --------------------------------------------------------- | ---------------------------------- | ------------------------------ | --------------------------- | -------------------------------------------------- | --------------------------- | ------------------- | ------------------------------------------------------------------------------ |
| Agent fg          | none from model; host `background_tasks` (G) | host `stop_task`/`interrupt` aborts child | no                                                        | SubagentStart/Stop; `task_started` | `SendMessage` after completion | `maxTurns`                  | inherit; `-p` is_error / auto-deny                 | tool_result; transcript     | V                   | claude:ctl, claude:perm_default, claude:perm_none                              |
| Agent bg          | `SendMessage` queued                         | `TaskStop`; fg grandchild too             | text only                                                 | `task_progress`, notification      | `SendMessage` → full history   | stall env; `-p` ceiling (G) | as fg                                              | `<result>`; `output_file`   | V                   | claude:steer_bg, claude:stop_bg_propagate, claude:live_resume, claude:bg_stall |
| Fork              | as bg                                        | as bg                                     | model fixed to parent                                     | as bg                              | parent system + history copied | as bg                       | as bg                                              | as bg                       | V fork; I lifecycle | codex:C                                                                        |
| Workflow node     | no (separate copy)                           | `TaskStop`                                | no; `resumeFromRunId`                                     | `workflow_progress`, `/workflows`  | `resumeFromRunId`, cached      | none; stall retry ≤5 (G)    | `-p` denies Workflow call                          | `<result>`, `journal.jsonl` | V                   | judge:judge_wf_msg, claude:wf_stop, claude:wf_resume, claude:hooks_wf          |
| `-p` / SDK        | stream-json frames; `interrupt`              | `interrupt` + fg child                    | `set_model`, `apply_flag_settings`, `set_permission_mode` | `task_*`, `result.subagents`       | `--resume`, `--fork-session`   | `--max-budget-usd`          | `--permission-prompts`, `--permission-prompt-tool` | stdout                      | V                   | claude:ctl, claude:ctl_effort, claude:resume_fork, codex:H                     |
| `mcp serve` Agent | U                                            | U                                         | no                                                        | none observed                      | agentId; U                     | U                           | U                                                  | sync JSON                   | V output; U rest    | claude:mcp_serve_agent, codex:H                                                |
| `--bg` session    | `claude attach`                              | `claude stop`                             | `respawn`                                                 | `claude agents --json`             | `--resume <id>`                | U                           | U                                                  | `claude logs`               | G                   | codex:H                                                                        |
| Hook agent        | event input only                             | hook `timeout`                            | no                                                        | `--include-hook-events`            | no                             | config `timeout`            | U                                                  | hook decision               | V/G                 | codex:P                                                                        |
| Remote/cloud      | U                                            | U                                         | U                                                         | U                                  | teleport/attach (G)            | `ultrareview --timeout` (G) | U                                                  | U                           | G/U                 | codex:H                                                                        |
| Monitor           | re-arm                                       | `TaskStop` / expiry                       | re-arm                                                    | events                             | no                             | `timeout_ms`                | U                                                  | notifications               | G/U                 | codex:A                                                                        |

## Codex CLI 0.160.0 — all surfaces

| Tool                         | Steer                                             | Cancel (propagates?)                    | Update mid-run                    | Status                            | Resume/fork                     | Timeout   | Perm prompts in child              | Output               | Mark | Replay                                                      |
| ---------------------------- | ------------------------------------------------- | --------------------------------------- | --------------------------------- | --------------------------------- | ------------------------------- | --------- | ---------------------------------- | -------------------- | ---- | ----------------------------------------------------------- |
| V2 child                     | `followup_task`/`send_message`; host rejected     | `interrupt_agent`, `turn/interrupt`; no | no                                | `list_agents`, `subAgentActivity` | followup reloads; fork at spawn | wait only | inherit; to host w/ child threadId | mailbox, rollout     | V    | claude:R4, claude:R7, claude:R9, codex:R1.v2-interrupt-tree |
| V1 child                     | `send_input`                                      | `close_agent`; cascades                 | no; resume resets effort          | wait map                          | `resume_agent`                  | wait only | inherit                            | wait result, rollout | A    | claude:R8, codex:R1.v1-close-tree                           |
| Root interrupt over children | —                                                 | children keep running                   | —                                 | wait: "aborted by user"           | —                               | —         | —                                  | —                    | V    | claude:R5                                                   |
| Host interrupt of V2 child   | —                                                 | works; parent wait not woken            | —                                 | child turn interrupted            | —                               | —         | —                                  | —                    | V    | claude:R7                                                   |
| `codex exec`                 | none                                              | signal; children die at root end        | no                                | `--json`                          | `exec resume`/`fork`            | none      | forced never; rejected             | `-o`, `--json`       | I    | claude:R0, codex:R1.exec-resume-fork                        |
| app-server root              | `turn/steer`                                      | `turn/interrupt`; no                    | `turn/settings/update`: next step | `thread/read`                     | `thread/resume`/`fork`          | none      | server requests                    | `thread/read`        | V    | claude:R6, codex:R2                                         |
| Review                       | thread controls                                   | `turn/interrupt`                        | no                                | review notifications              | detached = own thread           | none      | frontend policy                    | review JSON          | V    | codex:R2, claude:R1                                         |
| Hooks as control             | SubagentStart context; SubagentStop block re-runs | PreToolUse blocks spawn                 | —                                 | `hook/*`                          | —                               | per-hook  | PermissionRequest unprobed         | stdin JSON           | V    | claude:R10                                                  |
| SDK session                  | Python RPC; TS none                               | Python interrupt; TS AbortSignal        | as underlying                     | events                            | Python resume/fork; TS resume   | host      | as underlying                      | structured           | A    | codex:R0                                                    |
| TUI/daemon/remote            | interactive, `queue`                              | interactive                             | via app-server                    | agent browser                     | interactive                     | U         | interactive                        | UI                   | U    | codex:R0                                                    |
| Cloud task                   | none                                              | none exposed                            | none                              | `status`, `list`                  | none                            | U         | U                                  | `diff`, `apply`      | U    | codex:R0, claude:R0                                         |

## Kiro CLI 2.27.1 — all surfaces

| Tool                           | Steer                             | Cancel (propagates?)          | Update mid-run      | Status                | Resume/fork               | Timeout                   | Perm prompts in child                | Output             | Mark | Replay                                                                                 |
| ------------------------------ | --------------------------------- | ----------------------------- | ------------------- | --------------------- | ------------------------- | ------------------------- | ------------------------------------ | ------------------ | ---- | -------------------------------------------------------------------------------------- |
| invoke / wrappers (v3)         | parent steer reaches child        | yes; not selective            | no                  | parent + child events | parent only               | idle 1 h; 300 turns       | under parent sid; headless rejects   | result + files     | V    | judge:k-steer, claude:k-cancel, claude:k-stall, claude:k-perm, codex:R5                |
| orchestrate (v3)               | as invoke                         | as invoke                     | `repeat` only       | per stage             | none                      | as invoke                 | headless: trust orchestrate + invoke | stage text         | V    | claude:h3-trustdel2                                                                    |
| workflow (v3)                  | `send_message`, `update_workflow` | **no**; RPC cancel aborts     | at boundary         | `list/inspect/load`   | pause→resume; no fork     | `idleTimeoutSec`          | U                                    | outputs, artifacts | V; A | judge:k-wfctl, judge:send-dir, codex:R4                                                |
| crew (v2)                      | by child id                       | **no**; child-id cancel works | no                  | `list_update`         | U                         | `api.subagentTimeout` (G) | headless error unless trusted        | consolidated text  | V    | judge:j-a2-cancel-cfg, claude:a2-steerchild, claude:a2-cancelchild, claude:h2-trustdel |
| v1 `use_subagent` / `delegate` | no                                | U                             | no                  | `delegate status`     | no                        | U                         | as v2                                | summary/status     | V; G | claude:g-v1-deleg                                                                      |
| Headless chat                  | none                              | kill process (I)              | no                  | `stream-json`         | `--resume`, `--resume-id` | none                      | deny unless trusted                  | stdout/JSONL       | V    | codex:R1, claude:h3-perm                                                               |
| ACP v2                         | `_session/steer` queued           | `session/cancel`              | −32601              | `session/update`      | `loadSession`             | host                      | callback                             | stream             | V    | judge:j-a2-cancel-cfg, codex:R2                                                        |
| ACP v3                         | `steer`, `steer/clear`            | `cancel`, `close`, `delete`   | next turn           | `update`              | load/resume/fork/list     | host                      | `request_permission`                 | history/export     | V; A | judge:k-steer, codex:R3, codex:R6                                                      |
| TUI                            | steer or queue                    | Escape                        | model/mode controls | dashboard             | load, rewind/fork         | engine                    | interactive                          | panels             | A    | codex:R6                                                                               |
| Cloud / serve / crew CLI       | U                                 | U                             | U                   | U                     | U                         | U                         | U                                    | U                  | U    | codex:R1                                                                               |

## Kimchi 1.5.1 — all surfaces

| Tool                     | Steer                        | Cancel (propagates?)                              | Update mid-run                              | Status                | Resume/fork                  | Timeout                      | Perm prompts in child                  | Output                | Mark | Replay                                                                  |
| ------------------------ | ---------------------------- | ------------------------------------------------- | ------------------------------------------- | --------------------- | ---------------------------- | ---------------------------- | -------------------------------------- | --------------------- | ---- | ----------------------------------------------------------------------- |
| `Agent` fg               | none; host steer hits parent | RPC/ACP/Esc: yes                                  | none                                        | streamed updates      | `resume_subagent`            | 900 s, 120 s idle, turns     | none                                   | result, `.output`     | V    | claude:s4-rpc-abort-fg, claude:s6-rpc-steer-parent, codex:C, codex:Q    |
| `Agent` bg               | `steer_subagent`             | RPC/ACP: no; Ctrl+X; shutdown                     | none                                        | `get_subagent_result` | `resume_subagent`            | as fg                        | none                                   | verbose, `.output`    | V    | claude:s5-rpc-abort-bg, claude:s3c-print-bg, claude:a2-acp-default-perm |
| Ferment-linked `Agent`   | `steer_subagent`             | as `Agent`                                        | —                                           | outcome + report      | 2 continuations, 1 finalizer | tier budgets                 | as `Agent`                             | `submit_agent_report` | A    | codex:N                                                                 |
| Workflow in-session step | parent-turn                  | `/workflow cancel`, Esc                           | step model leaks to main session            | `/workflow status`    | `/workflow resume`           | `maxDurationMs`, `maxTokens` | parent posture                         | run store             | V    | claude:w2-workflow-model-leak                                           |
| Workflow bg step         | none                         | `/workflow cancel`: direct child; RPC `abort`: no | none                                        | `/workflow status`    | `/workflow resume`; no fork  | `maxDurationMs`              | forced yolo                            | result / submit       | V    | claude:w3b-workflow-cancel-late, claude:w4-workflow-rpc-abort, codex:W  |
| `-p` / json              | none                         | signal; daemons survive                           | none                                        | JSONL                 | `--continue`, `--resume`     | none                         | classifier fails closed; `--yolo` runs | stdout                | V    | claude:s9-perm-default, codex:B                                         |
| RPC                      | `steer`, `follow_up`         | `abort`: parent + fg                              | `set_model`, `set_thinking_level`           | `get_state`           | `fork`, `clone`              | none                         | `extension_ui_request`                 | `export_html`         | V    | codex:R, claude:s6-rpc-steer-parent                                     |
| ACP                      | `_kimchi.dev/steering`       | `session/cancel`: fg yes, bg no                   | model (idle), `permissions-mode`; no effort | `session/update`      | load/list/close; no fork     | none                         | `request_permission`; children none    | stream                | V    | claude:a1-acp-cancel-fg, claude:a2-acp-default-perm                     |
| Pi SDK                   | steer / follow-up            | abort                                             | model/thinking                              | subscriptions         | session managers             | host                         | no gate unless installed               | export                | A    | codex:P                                                                 |
| Cloud dispatch           | `steer_subagent` via ACP     | explicit abort; shutdown spares remote            | none                                        | notification, polling | reattach on resume           | creation 10 min              | worker policy U                        | local mirror          | A    | codex:P                                                                 |
| External launchers       | target                       | signals forwarded                                 | target                                      | stdio                 | target                       | none                         | target                                 | target                | A    | codex:P                                                                 |
| `bash`                   | none                         | stop/abort/deadline kills tree                    | deadline, checkin                           | `/processes`          | not across resume            | 120 s                        | parent gate only                       | tail + spill          | A    | codex:P                                                                 |
| `daemon`                 | none                         | explicit stop; parent abort leaves it             | none                                        | list/status           | ID kept                      | none                         | parent gate                            | log file              | A    | codex:P                                                                 |

## Open lifecycle unknowns

| Harness | Unknown                                                          | Settles it                              | Needs account? |
| ------- | ---------------------------------------------------------------- | --------------------------------------- | -------------- |
| Claude  | running child after `set_model` / `apply_flag_settings`          | 2-turn mock child, switch between turns | no             |
| Claude  | `mcp serve` TaskStop / SendMessage / `tools/call` cancel         | extend `mcp_serve_*` cases              | no             |
| Codex   | `exec` root end with live children; signal cascade               | fake provider + slow child              | no             |
| Codex   | unanswered approval deadline in children                         | R9 variant                              | no             |
| Codex   | V1 close cascade at runtime; V2 tree after restart               | depth-2 close; app-server restart       | no             |
| Kiro    | v2 parent hang after child-id cancel (n=1)                       | rerun `a2-cancelchild`                  | no             |
| Kiro    | unanswered ACP permission callback; workflow-step perms headless | callback-omission probe                 | no             |
| Kimchi  | ACP client receiving the turn a bg completion starts             | extend `a2`                             | no             |
| Kimchi  | remote worker cancel of descendants                              | live remote run                         | yes            |
