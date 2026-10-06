# Delegate tools

Every way a delegate starts, per harness.
[Control surfaces](control-surfaces.md) owns configuration precedence; this file
owns numeric depth and concurrency limits.

Pins and evidence marks: [evidence.md](evidence.md).

Replay: a case id `<side>:<case>` resolves under
`packages/delegate-routing/probes/delegates/<harness>/`. The prefix is the probe
side (`claude`, `codex`, `judge`), not the harness.

How to read the tables:

- Unmarked cells are V.
- A mark after the tool name covers that whole row; a mark inside a cell or
  footnote overrides it.
- `—` means no fact is recorded. `U` means unknown.
- Availability is how the tool is enabled, gated or removed.

## Claude

| Tool                                                                 | Caller                            | Params                                                | Limits                              | Result                                             | Availability                                           |
| -------------------------------------------------------------------- | --------------------------------- | ----------------------------------------------------- | ----------------------------------- | -------------------------------------------------- | ------------------------------------------------------ |
| `Agent` (alias `Task`)                                               | model (main + children); MCP host | ¹                                                     | depth 3 below main²; 20 concurrent³ | ⁴                                                  | ⁵                                                      |
| Built-in types                                                       | model via Agent                   | ⁶                                                     | Explore/Plan get no Agent           | —                                                  | ⁷                                                      |
| Named agents⁸                                                        | model via Agent; user `--agent`   | frontmatter⁹                                          | —                                   | —                                                  | remove file; `Agent` deny paths⁵                       |
| Background Agent                                                     | model `run_in_background`¹⁰       | —                                                     | 12 ran concurrently; ¹¹             | launch text now, notification later; `-p` waits    | `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` drops param   |
| Fork (`subagent_type:"fork"`)                                        | model                             | parent context + parent model; `model` ignored        | —                                   | always bg                                          | `CLAUDE_CODE_FORK_SUBAGENT=1`                          |
| Isolation `worktree` / `remote` (V worktree; G/U remote)             | model (param) or frontmatter      | —                                                     | —                                   | ¹²                                                 | omit param                                             |
| `Workflow` (alias `RunWorkflow`), `agent()` nodes                    | model (main only); MCP host       | ¹³                                                    | ¹⁴                                  | ¹⁵                                                 | ¹⁶                                                     |
| `SendMessage` / `ListAgents`                                         | model (main, children)            | `to`¹⁷, `message`, `notify_when_idle`                 | —                                   | queued ack or "Resuming agent"¹⁸                   | `--disallowedTools`                                    |
| `TaskStop`                                                           | model                             | `task_id` (agentId, workflow task, name)              | —                                   | `{message, task_id, task_type}`                    | `--disallowedTools`                                    |
| `claude -p`                                                          | user/host                         | all CLI flags                                         | one root per process                | text/json/stream-json; `result.subagents` counters | CLI                                                    |
| SDK stream-json¹⁹                                                    | host                              | ²⁰                                                    | as `-p`                             | stream events + `control_response`                 | CLI                                                    |
| `claude mcp serve`                                                   | host (MCP client)                 | ²¹                                                    | —                                   | ²²                                                 | don't start it                                         |
| `--bg` / `claude agents\|attach\|logs\|stop\|rm\|respawn` (G (help)) | user                              | `--model`, `--effort`, `--agent`, `--permission-mode` | U (U)                               | short id                                           | CLI                                                    |
| Remote/cloud²³ (G/U)                                                 | user                              | env/session ids                                       | U (U)                               | U (U)                                              | account/feature gates                                  |
| Hook `type:"agent"`/`"prompt"`                                       | host on hook event                | `prompt`, `model`, `timeout`                          | U (U)                               | hook verdict                                       | `hooks`, `disableAllHooks`, `--bare`                   |
| Skill `context: fork`; plugin `model.complete`/`model.fork` (G/I/U)  | user/model/plugin                 | skill frontmatter; plugin API                         | U (U)                               | skill/plugin result                                | skill/plugin gates                                     |
| Agent teams (V schema; U behavior)                                   | model                             | Agent `name`; structured SendMessage                  | U (U)                               | —                                                  | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (schema only) |
| `Monitor` (G/U)                                                      | model (interactive)               | watch/filter, `timeout_ms`                            | —                                   | events                                             | absent from `-p` and MCP inventories; gate U (U)       |
| ACP host (G)                                                         | —                                 | not in binary; no `claude-code-acp` package in repo   | —                                   | —                                                  | external adapter                                       |

1. `description`, `prompt`, `subagent_type`, `model` (sonnet/opus/haiku/fable),
   `run_in_background` (default bg), `isolation` worktree/remote. No
   effort/tools/perm/system field.
2. Agent is withheld at the cap.
3. Excess is **refused** "Do not retry", not queued.
4. fg: report + agentId + usage. bg: agentId + `output_file`, later
   `<task-notification>`.
5. `--tools`/`--disallowedTools Agent`, `permissions.deny`, PreToolUse deny,
   frontmatter `disallowedTools`.
6. general-purpose, claude, Explore, Plan, statusline-setup.
7. `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS`,
   `CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS`.
8. `.claude/agents`, `--agents`, plugin, SDK `agents`.
9. model, effort, tools, disallowedTools, permissionMode, maxTurns, background,
   isolation (V). memory/skills/hooks/mcpServers untested (G).
10. Frontmatter `background:true` wins.
11. bg child lacks Task\*/Cron\*/ListAgents.
12. worktree path only when changed; removed if clean / remote gated.
13. `script`/`name`/`scriptPath`, `args`, `resumeFromRunId`. Node `model`,
    `effort`, `agentType`, `schema`, `isolation`, `label`, `phase` (V)
    (+`disallowedTools`, `bashCommandClamp` G).
14. Nodes min(16,max(2,cpus−2)); 1,000 `agent()` per tree; nodes lack
    Agent/Workflow/SendUserMessage. `workflow()` 1 level (G).
15. Async: Task ID, Run ID, script, transcript dir; then notification +
    `journal.jsonl`.
16. `enableWorkflows`, `disableWorkflows`, `CLAUDE_CODE_DISABLE_WORKFLOWS`. `-p`
    default mode auto-denies a dynamic script.
17. name, agentId, `main`, session.
18. ListAgents shows other local sessions, not workflow nodes.
19. `--input-format stream-json` + `initialize`.
20. init `systemPrompt`, `appendSystemPrompt`, `agents`, `hooks`; control
    requests.
21. 21 tools incl. Agent, Workflow, SendMessage, TaskStop. Agent adds `name`,
    ignores `team_name`/`mode`, has no `run_in_background`.
22. Agent **synchronous** `{status, agentId, content, resolvedModel, usage}`;
    Workflow `async_launched`.
23. `--cloud`, `--environment`, `--remote-control`, `--teleport`, `ultrareview`,
    `RemoteTrigger`.

Replay: `Agent` claude:depth, judge:judge_parallel_fg22, claude:tools_deny_agent
· built-ins claude:agents_nobuiltin · named claude:model_effort,
claude:agents_json, claude:fm_turns · background claude:bg, claude:parallel_bg ·
fork claude:tools_fork, codex:C · isolation claude:iso_worktree, codex:H ·
`Workflow` claude:wf_default, claude:wf_allowed, codex:W · `SendMessage`
claude:steer_bg, judge:judge_wf_msg · `TaskStop` claude:stop_bg, claude:wf_stop
· `-p` claude:bg, codex:H · stream-json claude:ctl, codex:H · `mcp serve`
claude:mcp_serve_agent, claude:mcp_serve_wf · `--bg` codex:H · remote codex:H ·
hooks codex:P · skill/plugin codex:A, codex:P · teams claude:tools_teams ·
`Monitor` codex:A · ACP codex:H.

## Codex

| Tool                                                     | Caller                         | Params                                                 | Limits                                | Result                                         | Availability                                      |
| -------------------------------------------------------- | ------------------------------ | ------------------------------------------------------ | ------------------------------------- | ---------------------------------------------- | ------------------------------------------------- |
| V2 `collaboration.spawn_agent`                           | model                          | ¹                                                      | no depth cap (3 seen); 4 incl. root   | `{task_name}`; result later as mailbox message | catalog `multi_agent_version`²                    |
| V2 `followup_task`                                       | model                          | `target`, `message`                                    | existing child; reload uses slot      | `""`; starts idle child                        | `disable_direct_message` removes                  |
| V2 `send_message`                                        | model                          | `target`, `message`                                    | —                                     | `""`; queued, no idle start                    | `disable_direct_message` removes (needs board)    |
| V2 `wait_agent`                                          | model                          | `timeout_ms` (10 s–1 h, default 30 s)                  | —                                     | completed/timed_out flag, no content           | `wait_agent_enabled=false`                        |
| V2 `interrupt_agent`                                     | model                          | `target`                                               | —                                     | `previous_status`                              | always with V2                                    |
| V2 `list_agents`                                         | model                          | `path_prefix`                                          | —                                     | resident agents + status; evicted omitted      | always with V2                                    |
| V1 `spawn_agent`                                         | model                          | ³                                                      | depth 1 (`max_depth`); 6 open         | `{agent_id, nickname}`                         | catalog v1; deferred behind tool search           |
| V1 `send_input`                                          | model                          | `target`, `message`/`items`, `interrupt`               | —                                     | `{submission_id}`                              | V1 surface                                        |
| V1 `wait_agent` / `close_agent` / `resume_agent`         | model                          | `targets`+`timeout_ms` / `target` / `id`               | close frees slot; resume takes one    | status map / prev status / `pending_init`      | V1 surface                                        |
| Agent roles                                              | user/host defines; model picks | `[agents.<name>] config_file`⁴                         | backend limits                        | normal child                                   | declare/remove role                               |
| Message-board extension (A)                              | model                          | channel/post/subscribe tools                           | spawns nothing; no idle wake          | posts, channels                                | `features.agent_message_board` + V2               |
| `codex exec` (+ `resume`, `fork`)                        | user/host                      | ⁵                                                      | one root per process                  | events, last message, rollout                  | CLI                                               |
| `codex app-server` JSON-RPC                              | host                           | `thread/start`, `turn/start`⁶                          | many roots; no root cap               | RPC results + notifications                    | command; experimental capability gates 63 methods |
| SDKs (TS → exec, Python → app-server) (A)                | host                           | thread/launch options                                  | as underlying                         | events / protocol objects                      | SDK use                                           |
| Review (`review`, `exec review`, `review/start`)         | user/host                      | target flags; `delivery` inline/detached               | detached rejected on paginated parent | review output                                  | detached deprecated                               |
| Internal workers (review, compact, memory, guardian) (I) | harness                        | none exposed                                           | U (U)                                 | —                                              | feature/config keys                               |
| TUI / daemon / `agents` / `queue` / `--remote`           | user/host                      | TUI flags, `--remote`, queue thread+message            | —                                     | interactive                                    | Nix wrapper forces `--no-daemon`                  |
| `codex cloud exec`                                       | user                           | `--env`, `--branch`, `--attempts` 1–4; no model/effort | remote, U (U)                         | task id/URL                                    | ChatGPT account                                   |
| Hooks (command/MCP)                                      | host engine                    | matcher, timeout, async; Subagent events               | host-defined                          | context/block decision                         | `[[hooks.*]]`, trust; prompt/agent types skipped  |
| Shell/background processes, `exec-server` (A)            | model/user/host                | command, stdin, cwd, timeout                           | processes, not model delegates        | output, exit                                   | tool policy                                       |
| MCP-server / ACP / workflow tool                         | —                              | none                                                   | —                                     | —                                              | do not exist                                      |

1. `task_name`, `message`, `fork_turns` (default all), `model`,
   `reasoning_effort`; `agent_type` only if a user role is declared.
2. Off: `agents.enabled=false` unless V2 is explicitly on.
3. `message`/`items`, `agent_type`, `fork_context`, `model`, `reasoning_effort`.
4. A role sets model, effort, dev instructions, and disables some tools.
5. prompt/stdin, `-m`, `-c`, `-s`, `-C`, `--worktree`, `--json`, `-o`,
   `--output-schema`, `--ephemeral`. No `-a`.
6. model, effort, instructions, sandbox, dynamicTools.

Replay: `spawn_agent` (V2) claude:R2, claude:R3, codex:R1.v2-nested-depth-zero,
judge:J1 · `followup_task` claude:R4, codex:R1.v2-lifecycle · `send_message`
codex:R1.v2-lifecycle, claude:R11 · `wait_agent` (V2) claude:R2,
codex:R1.v2-lifecycle · `interrupt_agent` claude:R4, codex:R1.v2-interrupt-tree
· `list_agents` claude:R2, codex:R1.v2-resident-eviction · all V1 tools
claude:R8, codex:R1.v1-lifecycle · roles claude:R2, codex:R1.v2-role-model ·
message board codex:R0 · `exec` codex:R1.exec-resume-fork, claude:R0 ·
app-server claude:R1, codex:R2 · SDKs codex:R0 · review codex:R2, claude:R1 ·
internal workers claude:R1, codex:R0 · TUI claude:R0, codex:R0 · cloud
claude:R0, codex:R0 · hooks claude:R10, codex:R0 · shell codex:R0 ·
MCP/ACP/workflow claude:R0, codex:R0.

## Kiro

| Tool                                              | Caller                                  | Params                                             | Limits                                                               | Result                                                      | Availability                                     |
| ------------------------------------------------- | --------------------------------------- | -------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------ |
| `subagent` crew (v2)                              | model, v2 main                          | ¹                                                  | depth 1 (child lacks tool); parallel stages; cap U (U)               | consolidated text; child `summary`                          | agent `tools` only²                              |
| `use_subagent` (v1) (V; G limit)                  | model                                   | `subagents[{query, agent_name, relevant_context}]` | ≤4 parallel (tool text)                                              | per-child summary                                           | v1 engine only; absent in v2                     |
| `delegate` (v1) (V spec; G behavior)              | model                                   | `launch/status`, `agent`, `task`                   | async; one task per agent                                            | status output                                               | v1 + `chat.enableDelegate`                       |
| `invoke_sub_agent` (v3)                           | model: ACP main, KAS children, steps    | ³                                                  | rejects depth ≥5; 5 slots per parent execution; 300 turns            | `subagent_response` + files; `subExecutionId`               | ⁴                                                |
| `subagent_<id>` wrappers (v3) (V list; A factory) | model: KAS children, steps              | `prompt` (or verbatim/context pair)                | as invoke                                                            | as invoke                                                   | registry contents                                |
| `orchestrate_subagent` (v3)                       | model: headless/TUI main                | `task`, stages + `inlineAgent`, `repeat` 1–20      | ready stages parallel; invoke limits apply                           | "Pipeline completed" text; first failure stops              | ⁵                                                |
| `run_workflow` + siblings⁶ (v3)                   | model; not from step or delegated child | ⁷                                                  | ≤50 nodes, nest ≤8, repeat ≤1000; parallel uncapped; runs concurrent | immediate `{workflowId, running}`                           | ⁸                                                |
| Host `_kiro/workflow/*` RPCs                      | host (ACP)                              | ⁹                                                  | step sessions; global cap U (U)                                      | ID, state, node events                                      | work even with `workflowsEnabled:false`          |
| `chat --no-interactive`                           | user/host                               | ¹⁰                                                 | one process                                                          | text or ACP JSONL; exit code                                | invocation                                       |
| `kiro-cli acp`                                    | host                                    | ¹¹                                                 | many sessions; cap U (U)                                             | v3 child events under parent sid; v2 `subagent/list_update` | `--agent-engine` (v2 default)                    |
| TUI (A)                                           | user                                    | dashboard, background, workflow monitor            | engine limits                                                        | screen                                                      | `--tui`; v3 surfaces gated                       |
| `serve --port` (V help; U)                        | host                                    | port 8082                                          | WebSocket v3; limits U (U)                                           | WS service                                                  | explicit command                                 |
| `--cloud --repo` (V help; U)                      | user/host                               | repo, `executionTarget`                            | U (U)                                                                | U (U)                                                       | v3 only; account rollout                         |
| `kiro-cli crew` (V help; U)                       | user                                    | forwarded args; `--yes` installs                   | U (U)                                                                | external Crew CLI                                           | installs if missing                              |
| Hooks (`agentSpawn` etc.)                         | host config                             | six triggers; `askAgent` = same session            | n/a                                                                  | `preToolUse` exit 2 blocks delegate tool                    | agent `hooks`; fire in v2 crew, not KAS children |
| MCP-server mode                                   | —                                       | —                                                  | —                                                                    | —                                                           | not possible: `mcp` manages clients              |

1. `task`, `mode` blocking only, stages
   `name/role/prompt_template/depends_on/loop_to/model`.
2. `enableSubagent`/`enableDelegate`/`enableMainAgentSubagentTool` have no
   effect.
3. `name`, `prompt`, `explanation`, `preset`, `contextFiles`, `specTask`, gated
   `inlineAgent{systemPrompt,model,effort}`.
4. ACP `subagentOrchestration` swaps it to orchestrate; agent tools; hooks.
5. TUI on unless workflows are on and the setting is false;
   `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1`.
6. `inspect/update/validate_workflow`, `send_message`,
   `save_workflow_definition`.
7. `workflowPath` XOR `workflowPrompt`, `inputs`, `runLabel`; step
   `modelId/effortLevel`.
8. rollout `workflows` + v3 + `chat.enableWorkflows`; ACP `settings.workflows`.
9. `new/invoke`, definition or recipe, inputs, `modelId/effortLevel`.
10. `--agent --model --effort -a --trust-tools --output-format --resume --v3 --mode --cloud`.
11. v3 needs `--auth-method cli` and rejects `-a`;
    `_meta.kiro{modeId,modelId,effortLevel,steering,customAgents,settings}`.

Replay: crew claude:h2-all, claude:g-sub-off, codex:R2 · `use_subagent`
claude:g-v1-deleg, codex:R2 · `delegate` claude:g-v1-deleg · `invoke_sub_agent`
claude:k-pins, codex:R3, codex:R5 · wrappers codex:R3, codex:R6 ·
`orchestrate_subagent` claude:h3-all, codex:R6 · `run_workflow` claude:k-wfpins,
codex:R4 · host RPCs codex:R4 · `chat --no-interactive` codex:R1, claude:h2-all
· `acp` claude:k-pins, judge:j-a2-cancel-cfg · TUI codex:R6 · `serve` codex:R1 ·
`--cloud` codex:R1 · `crew` codex:R1 · hooks claude:h2-hookblock,
claude:h3-hookblock · MCP-server codex:R1.

## Kimchi

| Tool                                     | Caller                                   | Params                                      | Limits                                                               | Result                                                 | Availability                                             |
| ---------------------------------------- | ---------------------------------------- | ------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------- |
| `Agent` (native)                         | model, parent only                       | ¹                                           | depth 1; bg 4 run, rest queue²; fg uncapped                          | fg: text + `agent_outcome`; bg: ID, later notification | `extensions.agents` resource³                            |
| `get_subagent_result`                    | model                                    | `agent_id`, `wait` (≤60 s), `verbose`       | —                                                                    | status, usage, result                                  | with `Agent`                                             |
| `steer_subagent`                         | model                                    | `agent_id`, `message`                       | running only; queued before init                                     | confirmation + stats                                   | with `Agent`                                             |
| `resume_subagent`                        | model                                    | ⁴                                           | finished agents; ⁵                                                   | same child session continues                           | with `Agent`; headless classifier gates it               |
| 9 built-in personas                      | model via `subagent_type`                | persona tools, thinking, turns              | —                                                                    | —                                                      | persona `enabled`                                        |
| Custom agents `.md`                      | user files; model picks                  | ⁶                                           | —                                                                    | —                                                      | `enabled: false`; package → global → project, later wins |
| Ferment `start_ferment_step` (A)         | model                                    | ferment/phase/step IDs, budget tier         | spawns nothing; linked `Agent` follows                               | `task_ref` + limits                                    | Ferment extension                                        |
| Workflow in-session step                 | user/host `/workflow run`; no model tool | ⁷                                           | 1 host turn; run `maxConcurrency` 4                                  | step result, event log                                 | workflows package in harness `packages`                  |
| Workflow background step                 | workflow engine                          | same + `background`                         | separate `kimchi -p` process, offered `Agent` → depth 2; shared gate | final turn / `workflow_submit_result`                  | same; `background`+`asks` rejected                       |
| `dispatch_to_cloud_agent`, `/remote-run` | model (user confirm) / user              | `task`, `description`; no model/effort      | remote worker, bg queue                                              | notification + sync/review                             | absent in `-p`; `KIMCHI_REMOTE_RUN=off`                  |
| Headless `-p` / `--mode json`            | host                                     | ⁸                                           | process per call                                                     | text / JSONL                                           | always                                                   |
| RPC `--mode rpc`                         | host                                     | JSONL commands                              | one session per process                                              | events + responses                                     | always                                                   |
| ACP `--mode acp`                         | host                                     | ⁹                                           | many sessions, one prompt each                                       | `session/update`                                       | always                                                   |
| Pi SDK `createAgentSession` (A)          | host / extension code                    | cwd, model, `thinkingLevel`, tools, loaders | caller-owned                                                         | `AgentSession`                                         | import                                                   |
| `kimchi claude\|codex\|opencode` (A)     | user/host                                | argv forwarded, env injected                | target harness                                                       | target output                                          | binary present                                           |
| `bash` / `bash_control` (A)              | model, parent or child                   | any command                                 | untracked; unbounded via `kimchi -p`                                 | output, handle                                         | Bash extension; child bash ungated                       |
| `daemon` / `daemon_control`              | model                                    | command, name                               | detached                                                             | ID, PID, log                                           | `--enable-experimental-features`                         |
| Extension / package tools (A)            | extension code                           | `registerTool` schema                       | ext-defined                                                          | ext-defined                                            | packages, `-e`; user file exts load in children          |
| MCP server mode (A)                      | —                                        | none; `kimchi mcp` = client probe           | —                                                                    | —                                                      | —                                                        |

1. `prompt`, `description`, `subagent_type`, `model`, `thinking`, `max_turns`,
   `token_budget`, `max_duration`, `run_in_background`, `isolated`,
   `inherit_context`, `task_ref`.
2. `maxConcurrent` is configurable 1–1024.
3. bg defaults on in RPC/ACP/TUI, off in `-p`.
4. `agent_id`, `prompt`, `max_turns`, `max_duration`, `token_budget`, `purpose`.
5. 2-cap, Ferment only (A).
6. `thinking`, `tools`, `disallowed_tools`, `extensions`, `skills`,
   `prompt_mode`, budgets. `model` and `isolation` are ignored.
7. prompt, `model`, `retry`, `asks`, output schema, `maxDurationMs`,
   `maxTokens`. No effort.
8. `--model`, `--thinking`, `--append-system-prompt`, perm/session flags, `-e`.
9. `session/new|load|list|close`, `prompt`, `cancel`, `set_config_option`.

Replay: `Agent` claude:s1-fg-pins, claude:s2-rpc-bg, codex:O ·
`get_subagent_result` claude:s8-resume-ctx · `steer_subagent` claude:s2-rpc-bg ·
`resume_subagent` claude:s8b-resume-yolo, codex:B · personas
claude:s11-thinking-inherit, codex:N · custom agents claude:s1-fg-pins, judge:J1
· Ferment codex:N · in-session step claude:w1-workflow · background step
claude:w1-workflow, codex:W · cloud claude:inv · `-p` codex:O · RPC codex:R ·
ACP claude:a1-acp-cancel-fg · Pi SDK codex:P · `kimchi claude` codex:P · `bash`
codex:P, claude:s9-perm-default · `daemon` claude:inv · extensions codex:P · MCP
server codex:P.
