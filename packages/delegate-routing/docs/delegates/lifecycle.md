# Delegate lifecycle control

How a running delegate is steered, cancelled, updated, observed, resumed, timed
out, permission-gated and read back, per harness.

Pins and evidence marks: [evidence.md](evidence.md). Open questions and settling
steps: [evidence.md](evidence.md#open-unknowns).

How to read the tables:

- Each harness's main table uses one representative column set: its main
  delegate primitives plus its richest host session API. Its other surfaces
  follow that table.
- Every harness table has the same rows in the same order: compare harnesses row
  by row.
- A column header carries the kind's mark; a header with none leaves it to each
  cell. A mark inside a cell overrides the header; a footnote has its own mark.
- In the main tables, `Reach:` in a `Cancel` cell says whether the cancel
  reaches descendants.
- Replay `side:case` is case `case` in
  `packages/delegate-routing/probes/delegates/<harness>/`; `side` is the probe
  run that produced it (`claude`, `codex`, `judge`).

No harness shows a path to change a **running child's** model. Only Claude
changes a running child's effort: SDK `apply_flag_settings`, at the child's next
request (V).

## Claude

|         | Agent fg (V)                                                                            | Agent bg (V)                                                                                                                                             | Workflow node (V)                                                                                                                | `-p` / SDK (V)                                                                                                                   |
| ------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Steer   | none from model (parent blocked)¹ · claude:ctl                                          | `SendMessage`, queued, lands at next tool round · claude:steer_bg                                                                                        | **no**² · judge:judge_wf_msg                                                                                                     | stream-json user frames; `interrupt {cancel_queued}` · claude:ctl                                                                |
| Cancel  | host `stop_task` / `interrupt`. Reach: aborts the child request · claude:ctl            | `TaskStop` → `killed`. Reach: **yes**, fg grandchild aborted too · claude:stop_bg, claude:stop_bg_propagate                                              | `TaskStop`. Reach: aborts in-flight node · claude:wf_stop                                                                        | `interrupt`; `send_task_message` unsupported. Reach: aborts turn + running fg child · claude:ctl                                 |
| Update  | no · claude:ctl                                                                         | text only (`SendMessage`) · claude:steer_bg                                                                                                              | no; stop, edit script, `resumeFromRunId` · claude:wf_resume                                                                      | `set_model`, `apply_flag_settings {effortLevel}`, `set_permission_mode`; later children inherit³ · claude:ctl, claude:ctl_effort |
| Status  | SubagentStart/Stop hooks; `task_started` + `spawn_depth` · claude:ctl, claude:hooks_obs | `task_progress`, `task_updated`, `<task-notification>` · claude:bg                                                                                       | `workflow_progress`; per-node SubagentStart/Stop; `/workflows`; not in `ListAgents` · claude:hooks_wf, judge:judge_wf_msg        | `task_*` events, `result.subagents` · claude:ctl                                                                                 |
| Resume  | `SendMessage` after completion resumes · claude:live_resume                             | `SendMessage` after completion → full history; fork copies parent system + history · claude:live_resume, codex:C                                         | `resumeFromRunId`, same session; cached nodes, 0 new requests · claude:wf_resume                                                 | `--resume`, `--continue`, `--fork-session`, `--session-id`⁴ · claude:resume_fork                                                 |
| Timeout | frontmatter `maxTurns`; no per-call wall clock · claude:fm_turns                        | `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS` → `failed`; in `-p`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`⁵ → `killed` · claude:bg_stall, claude:bg_print_ceiling | `agent()` `stallMs`: 6 attempts, then the run fails; no run or node deadline⁶ · claude:dmu_wf_stall, claude:dmu_wf_deadline      | `--max-budget-usd` (spend); no wall-clock flag · codex:H                                                                         |
| Prompts | inherits parent mode⁷ · claude:perm_default, claude:perm_none                           | as fg                                                                                                                                                    | `-p` default mode denies the `Workflow` call; nodes inherit; PreToolUse not fired for nodes · claude:wf_default, claude:hooks_wf | `--permission-prompts host\|none`, `--permission-prompt-tool`⁸ · claude:perm_none, claude:perm_default                           |
| Output  | tool_result; `subagents/agent-<id>.jsonl` · claude:ctl                                  | notification `<result>`; `output_file` · claude:bg                                                                                                       | notification `<result>`, `journal.jsonl`, node transcripts · claude:wf_resume                                                    | stdout⁹ · codex:H                                                                                                                |

- ¹ host `background_tasks` (G)
- ² `SendMessage` to the node agentId starts a separate copy; node runs on (V)
- ³ an already-running child takes the new effort at its next request, not the
  model (V; claude:dmu_running_switch_fg, claude:dmu_running_switch_bg)
- ⁴ resume re-sends the **first** session's system prompt unless
  `--system-prompt-snapshot off` (V)
- ⁵ ceiling 600 s (G)
- ⁶ a script can race nodes against the VM's `setTimeout`; the run's end aborts
  the slow node (V). `budget.total` has no setter at any entrypoint: null,
  `remaining()` Infinity (V; claude:dmu_wf_budget_sdk, claude:wf_budget)
- ⁷ `-p` without host → is_error "needs approval"; `--permission-prompts none` →
  auto-denied; nothing hangs (V)
- ⁸ `can_use_tool` (G)
- ⁹ `--forward-subagent-text` (G)

Other surfaces:

|         | `claude mcp serve` (V)                                                                                  | `--bg` daemon (V)                                        |
| ------- | ------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Steer   | none: `SendMessage` to an MCP agent finds no transcript                                                 | interactive session; `claude attach` shows it            |
| Cancel  | `notifications/cancelled` aborts an Agent call, no reply; Workflow: no path (`TaskStop`: no task found) | `claude stop`; the transient daemon outlives `stop`/`rm` |
| Update  | —                                                                                                       | —                                                        |
| Status  | `ListAgents`: no reachable agents                                                                       | `claude agents --json` (`kind: background`), `logs`      |
| Resume  | no                                                                                                      | `claude respawn`: new process, idle, no new request      |
| Timeout | —                                                                                                       | —                                                        |
| Prompts | —                                                                                                       | interactive session (`cc_entrypoint=cli`)                |
| Output  | synchronous Agent result; Workflow `async_launched`                                                     | `logs`                                                   |
| Replay  | claude:dmu_mcp_lifecycle, claude:dmu_mcp_wf_alone                                                       | claude:dmu_bg_daemon, claude:dmu_bg_limits               |

## Codex

|         | V2 child (V)                                                                                                                                                                                                           | V1 child (A)                                                                                   | app-server root (V)                                                | `codex exec` (V)                                                                                                                                                |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Steer   | model `followup_task` / `send_message`; host steer **rejected** · claude:R4, claude:R7                                                                                                                                 | `send_input` (`interrupt:true`) · claude:R8                                                    | `turn/steer` + `expectedTurnId` · claude:R6                        | none after launch · claude:R0                                                                                                                                   |
| Cancel  | `interrupt_agent`, host `turn/interrupt`. Reach: **no** · claude:R4, claude:R7, codex:R1.v2-interrupt-tree                                                                                                             | `close_agent`. Reach: yes, cascades (V) · claude:R8, codex:R1.v1-close-tree, codex:L4.v1-close | `turn/interrupt`. Reach: **no**, children keep running · claude:R5 | root end exits 0; signal: INT 1, TERM 143, KILL 137. Reach: child streams dropped; child-spawned shells survive · codex:L1.exec-root-ends, codex:L1.exec-signal |
| Update  | no; host settings rejected · claude:R7                                                                                                                                                                                 | no; resume resets effort to parent · claude:R8                                                 | `turn/settings/update`: next step¹ · claude:R6, codex:R2           | no · claude:R0                                                                                                                                                  |
| Status  | `list_agents` (evicted omitted), thread notifications, `subAgentActivity` · claude:R2, codex:R1.v2-resident-eviction                                                                                                   | `wait_agent` map, `<subagent_notification>` · claude:R8                                        | notifications, `thread/read`, loaded/list · codex:R2               | `--json` stream; no item for a V2 spawn · codex:L1.exec-root-ends                                                                                               |
| Resume  | `followup_task` reloads; fork only at spawn (`fork_turns`); after a restart children reload on `followup_task`, a mid-turn child with `<turn_aborted>` · claude:R4, codex:L5.v2-restart                                | `resume_agent` after close · claude:R8                                                         | `thread/resume`, `thread/fork`² · codex:R2                         | `exec resume`, `exec fork` · codex:R1.exec-resume-fork                                                                                                          |
| Timeout | `wait_agent` `timeout_ms` only³ · codex:R1.v2-invalid, judge:J2                                                                                                                                                        | wait only · claude:R8                                                                          | none · codex:R2                                                    | none · claude:R0                                                                                                                                                |
| Prompts | inherits parent policy; approval sent to host with child threadId, no deadline⁴; `auto_review` goes to the reviewer model, 90 s → denied · claude:R9, codex:R9.unanswered, codex:R9.auto-review, codex:R9.auto-timeout | inherits parent policy · claude:R8                                                             | server requests to host · codex:R2                                 | approval forced never; requests rejected · claude:R0                                                                                                            |
| Output  | mailbox FINAL_ANSWER, rollout; `wait_agent` returns no content · claude:R2, codex:R1.v2-lifecycle                                                                                                                      | `wait_agent` result, rollout · claude:R8                                                       | `thread/read`, turn/item reads · codex:R2                          | `-o`, `--json`, rollout · codex:R1.exec-resume-fork                                                                                                             |

- ¹ needs `step_model_switching`; some model pairs rejected (V)
- ² resuming a loaded thread ignores new overrides (V)
- ³ 10 s–1 h, default 30 s (V); `agents.job_max_runtime_seconds` no-op (G)
- ⁴ the child waits in `waitingOnApproval` (170 s seen); the parent's
  `wait_agent` times out and the root completes; host `turn/interrupt` on the
  child ends it (V)

Other surfaces:

|         | SDK session (A)                  | TUI / daemon / `--remote` (V)                                                                                         | Cloud task (A client; U server)         |
| ------- | -------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| Steer   | Python RPC; TS none              | interactive; `codex queue` = a new turn after the active one                                                          | none                                    |
| Cancel  | Python interrupt; TS AbortSignal | interactive. Reach: daemon / `--remote` client exit leaves root + children running; `--no-daemon` TUI kill drops them | no CLI cancel, no backend cancel method |
| Update  | as underlying                    | via app-server                                                                                                        | none; client sends no model/effort      |
| Status  | events                           | agent browser; `thread/read`, loaded list                                                                             | `status`, `list`                        |
| Resume  | Python resume/fork; TS resume    | interactive; an idle thread with no client unloads after `thread_unload_delay_secs` (60 A)                            | none                                    |
| Timeout | host                             | no turn deadline                                                                                                      | U                                       |
| Prompts | as underlying                    | an approval stays pending with no client; a client resuming the child thread gets it, one resuming the root does not  | U                                       |
| Output  | structured                       | UI                                                                                                                    | `diff`, `apply`                         |
| Replay  | codex:R0                         | codex:L2.daemon-detach, codex:L2.daemon-approval, codex:L2.daemon-tui, codex:L2.tui-embedded, codex:L2.tui-remote     | codex:R0, claude:R0                     |

The Nix wrapper runs the TUI with `--no-daemon`.

## Kiro

|         | v3 invoke (V)                                                                                                                                                  | v3 workflow (V)                                                                                                   | v2 engine (not used by this config): crew (V)                                                                                         | ACP v3 session                                                                                                                     |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Steer   | parent steer reaches in-flight child; no per-child address · judge:k-steer                                                                                     | `send_message` both ways; `update_workflow` (V; A)¹ · judge:k-wfctl, judge:send-dir                               | steer by child id reaches only that child · claude:a2-steerchild                                                                      | `steer`, `steer/clear` (V; A) · judge:k-steer, codex:R3                                                                            |
| Cancel  | parent turn cancel only; no selective cancel. Reach: yes, shared signal to child + grandchild · claude:k-cancel; next turn `Sub-agent execution was cancelled` | `_kiro/workflow/cancel`. Reach: **parent cancel leaves the run going** (V; A) · judge:k-wfctl                     | child-id cancel terminates child. Reach: **no**, child ran `shell` after parent cancel · judge:j-a2-cancel-cfg, claude:a2-cancelchild | `cancel`, `close`, `delete`. Reach: as v3 invoke (V; A) · codex:R3, codex:R6                                                       |
| Update  | no; spawn snapshot (A) · codex:R6                                                                                                                              | remaining plan at node boundary; active step kept (V; A) · judge:k-wfctl                                          | no · judge:j-a2-cancel-cfg                                                                                                            | `set_config_option`, `set_mode`: next turn (v2 engine (not used by this config) ACP: −32601) (V) · judge:j-a2-cancel-cfg, codex:R2 |
| Status  | parent `tool_call` + child events under parent sid · codex:R5                                                                                                  | `list` / `inspect` / `load`; node events (V; A) · codex:R4                                                        | `_kiro.dev/subagent/list_update` · judge:j-a2-cancel-cfg                                                                              | `update`, `sessions/changed` (V; A) · codex:R3                                                                                     |
| Resume  | parent only; child none (A) · codex:R6                                                                                                                         | pause→resume same step session, prompt snapshot kept; next step renders fresh; retry fresh · codex:R4, mx-wf-snap | not mapped (v2 engine)                                                                                                                | load / resume / fork / list (A); load replays the persisted `history[0]` (V) · codex:R6, mx-resume                                 |
| Timeout | idle `KIRO_SUBAGENT_DEADLINE_MS` 1 h (`0` off); 300 turns; no total wall clock · claude:k-stall, codex:R5                                                      | watch-node `idleTimeoutSec`; else none (V; A) · codex:R6                                                          | `api.subagentTimeout` (G)                                                                                                             | host-owned (V) · codex:R3                                                                                                          |
| Prompts | prompts under parent sid; child `user_input` too; headless rejects · claude:k-perm, mx-child-uinput                                                            | headless: rejected silently, `-a` runs; ACP: request on the step's own session · mx-wf-perm                       | headless error unless trusted · claude:h2-trustdel                                                                                    | `request_permission` callback; unanswered holds the turn, no deadline; `session/cancel` releases (V) · codex:R3, mx-perm-ignore    |
| Output  | result + files; `sub-executions/*.jsonl` · codex:R5                                                                                                            | outputs, artifacts, step sessions (V; A) · codex:R4                                                               | consolidated text · claude:h2-all                                                                                                     | `_kiro/session/export` carries `sub-executions/<agentSubtaskId>.jsonl`; history empty (V) · mx-child-hist                          |

- ¹ TUI node steer (G)

Other surfaces:

|         | orchestrate (v3) (V)                  | v1 `use_subagent` / `delegate` (V; G) | Headless chat (V)                          | TUI (A)             | `serve` (V)                                                      | Cloud / crew CLI (U) |
| ------- | ------------------------------------- | ------------------------------------- | ------------------------------------------ | ------------------- | ---------------------------------------------------------------- | -------------------- |
| Steer   | as invoke                             | no                                    | none                                       | steer or queue      | as ACP v3                                                        | U                    |
| Cancel  | as invoke                             | not mapped (v2 engine)                | kill process (I)                           | Escape              | as ACP v3                                                        | U                    |
| Update  | `repeat` only                         | no                                    | no                                         | model/mode controls | as ACP v3                                                        | U                    |
| Status  | per stage                             | `delegate status`                     | `stream-json`                              | dashboard           | as ACP v3; `session/list`                                        | U                    |
| Resume  | none                                  | no                                    | `--resume`, `--resume-id`                  | load, rewind/fork   | as ACP v3                                                        | U                    |
| Timeout | as invoke                             | not mapped (v2 engine)                | none                                       | engine              | one in-flight prompt per session (A)                             | U                    |
| Prompts | headless: orchestrate unavailable     | v2 engine (not used by this config)   | deny unless trusted                        | interactive         | WS clients are observers: approve via `_kiro/permission/respond` | U                    |
| Output  | stage text                            | summary/status                        | stdout/JSONL                               | panels              | as ACP v3                                                        | U                    |
| Replay  | claude:h3-trustdel2: tool unavailable | claude:g-v1-deleg                     | codex:R1; claude:h3-perm: tool unavailable | codex:R6            | mx-serve                                                         | codex:R1             |

## Kimchi

|         | `Agent` fg (V)                                                                             | `Agent` bg (V)                                                                                                                                                                            | Workflow bg step (V)                                                                                                                                       | RPC session (V)                                                     |
| ------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Steer   | none to child; host steer lands on parent after return · claude:s6-rpc-steer-parent        | `steer_subagent` · claude:s2-rpc-bg                                                                                                                                                       | none · codex:W                                                                                                                                             | `steer`, `follow_up` · codex:R                                      |
| Cancel  | RPC `abort`, ACP cancel, Esc. Reach: yes · claude:s4-rpc-abort-fg, claude:a1-acp-cancel-fg | Ctrl+X (newest); shutdown; no model-callable cancel. Reach: **no** for RPC/ACP cancel; `-p` shutdown loses output · claude:s5-rpc-abort-bg, claude:s3c-print-bg                           | `/workflow cancel`: SIGTERM→SIGKILL 5 s; RPC `abort`: no. Reach: direct child process only · claude:w3b-workflow-cancel-late, claude:w4-workflow-rpc-abort | `abort`. Reach: parent + fg children only · codex:R                 |
| Update  | none; fixed at spawn · codex:R                                                             | none · codex:R                                                                                                                                                                            | none · codex:W                                                                                                                                             | `set_model`, `set_thinking_level`: next turn, parent only · codex:R |
| Status  | streamed tool updates · codex:C                                                            | `get_subagent_result` (`wait` ≤60 s); completion starts a parent turn, which an ACP client never sees streamed · claude:s8-resume-ctx, claude:s2-rpc-bg, claude:a3-acp-bg-completion-turn | `/workflow status`, run list · codex:W                                                                                                                     | `get_state`, stats, events · codex:R                                |
| Resume  | `resume_subagent`; `inherit_context` at spawn · codex:B                                    | `resume_subagent` · claude:s8b-resume-yolo                                                                                                                                                | `/workflow resume`, `resumable`; no fork · codex:W                                                                                                         | `fork`, `clone`, switch/new session · codex:R                       |
| Timeout | 900 s wall default (G), 120 s idle, 30+5 turns, output-token budget · codex:Q, judge:J4    | as fg · judge:J4                                                                                                                                                                          | `maxDurationMs` · codex:W                                                                                                                                  | none · codex:R                                                      |
| Prompts | none: child tools ungated · claude:s9-perm-default, claude:a2-acp-default-perm             | as fg                                                                                                                                                                                     | none: forced `KIMCHI_PERMISSIONS=yolo` · codex:W                                                                                                           | `extension_ui_request` to client (parent only) · codex:R            |
| Output  | tool result, `.output`, session file · codex:C                                             | verbose `get_subagent_result`, `.output` · claude:s8-resume-ctx                                                                                                                           | final turn / `workflow_submit_result`; step session · codex:W                                                                                              | messages, last text, `export_html` · codex:R                        |

<a id="resume-and-fork"></a>Other surfaces:

|         | Ferment-linked `Agent` (A)    | Workflow in-session step (V)     | `-p` / json (V)                                                    | Pi SDK (A)               |
| ------- | ----------------------------- | -------------------------------- | ------------------------------------------------------------------ | ------------------------ |
| Steer   | `steer_subagent`              | parent-turn                      | none                                                               | steer / follow-up        |
| Cancel  | as `Agent`                    | `/workflow cancel`, Esc          | signal; daemons survive                                            | abort                    |
| Update  | —                             | step model leaks to main session | none                                                               | model/thinking           |
| Status  | outcome + report              | `/workflow status`               | JSONL                                                              | subscriptions            |
| Resume  | 2 continuations, 1 finalizer¹ | `/workflow resume`               | `--continue`, `--resume`                                           | session managers         |
| Timeout | tier budgets                  | `maxDurationMs`, `maxTokens`     | none; a stdio MCP server blocks exit²                              | host                     |
| Prompts | as `Agent`                    | parent posture                   | classifier fails closed; `--yolo` runs                             | no gate unless installed |
| Output  | `submit_agent_report`         | run store                        | stdout                                                             | export                   |
| Replay  | codex:N                       | claude:w2-workflow-model-leak    | claude:s9-perm-default, codex:B, claude:x1-print-exit-after-settle | codex:P                  |

- ¹ continuation guard only for `ferment_step` (A) · judge:J3
- ² a stdio MCP server Kimchi starts (user `mcp.json`, or project `.mcp.json`
  trusted by `--approve`) is never closed, so the process idles after
  `agent_settled` until killed; without one it exits in under 1 s (V)

|         | Cloud dispatch (A)                                                         | External launchers (A) | `bash` (A)                     | `daemon` (A)                          |
| ------- | -------------------------------------------------------------------------- | ---------------------- | ------------------------------ | ------------------------------------- |
| Steer   | `steer_subagent` via ACP                                                   | target                 | none                           | none                                  |
| Cancel  | explicit abort (`session/cancel`); shutdown spares remote                  | signals forwarded      | stop/abort/deadline kills tree | explicit stop; parent abort leaves it |
| Update  | none                                                                       | target                 | deadline, checkin              | none                                  |
| Status  | notification, polling                                                      | stdio                  | `/processes`                   | list/status                           |
| Resume  | reattach on resume                                                         | target                 | not across resume              | ID kept                               |
| Timeout | creation 10 min                                                            | none                   | 120 s                          | none                                  |
| Prompts | worker forced `yolo`; its permission requests answered `cancelled` locally | target                 | parent gate only               | parent gate                           |
| Output  | local mirror                                                               | target                 | tail + spill                   | log file                              |
| Replay  | codex:P                                                                    | codex:P                | codex:P                        | codex:P                               |
