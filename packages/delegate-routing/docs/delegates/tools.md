# Delegate tools

Every way a delegate starts, per harness.
[Control surfaces](control-surfaces.md) owns configuration precedence; this file
owns numeric depth and concurrency limits.

Pins and evidence marks: [evidence.md](evidence.md).

Replay: a case id `<side>:<case>` resolves under
`packages/delegate-routing/probes/delegates/<harness>/`. The prefix is the probe
side (`claude`, `codex`, `judge`), not the harness.

## Claude

### `Agent` (alias `Task`)

Replay: claude:depth, judge:judge_parallel_fg22, claude:tools_deny_agent.

| Surface      | Fact                                                             |
| ------------ | ---------------------------------------------------------------- |
| Caller       | model (main + children) (V)                                      |
| Caller       | MCP host (V)                                                     |
| Parameters   | `description` (V)                                                |
| Parameters   | `prompt` (V)                                                     |
| Parameters   | `subagent_type` (V)                                              |
| Parameters   | `model` (sonnet/opus/haiku/fable) (V)                            |
| Parameters   | `run_in_background` (default bg) (V)                             |
| Parameters   | `isolation` worktree/remote (V)                                  |
| Parameters   | no effort/tools/perm/system field (V)                            |
| Limits       | depth 3 below main (Agent withheld at cap) (V)                   |
| Limits       | 20 concurrent, excess **refused** "Do not retry", not queued (V) |
| Result       | fg: report + agentId + usage (V)                                 |
| Result       | bg: agentId + `output_file`, later `<task-notification>` (V)     |
| Availability | `--tools`/`--disallowedTools Agent` (V)                          |
| Availability | `permissions.deny` (V)                                           |
| Availability | PreToolUse deny (V)                                              |
| Availability | frontmatter `disallowedTools` (V)                                |

### Built-in types

Replay: claude:agents_nobuiltin.

| Surface      | Fact                                                                                     |
| ------------ | ---------------------------------------------------------------------------------------- |
| Caller       | model via Agent (V)                                                                      |
| Parameters   | general-purpose, claude, Explore, Plan, statusline-setup (V)                             |
| Limits       | Explore/Plan get no Agent (V)                                                            |
| Availability | `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS`, `CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS` (V) |

### Named agents (`.claude/agents`, `--agents`, plugin, SDK `agents`)

Replay: claude:model_effort, claude:agents_json, claude:fm_turns.

| Surface      | Fact                                                                                                   |
| ------------ | ------------------------------------------------------------------------------------------------------ |
| Caller       | model via Agent (V)                                                                                    |
| Caller       | user via `--agent` (V)                                                                                 |
| Parameters   | frontmatter model, effort, tools, disallowedTools, permissionMode, maxTurns, background, isolation (V) |
| Parameters   | memory/skills/hooks/mcpServers untested (G)                                                            |
| Availability | remove file (V)                                                                                        |
| Availability | deny paths above (V)                                                                                   |

### Background Agent

Replay: claude:bg, claude:parallel_bg.

| Surface      | Fact                                                     |
| ------------ | -------------------------------------------------------- |
| Caller       | model (`run_in_background` (V)                           |
| Caller       | frontmatter `background:true` wins) (V)                  |
| Limits       | 12 ran concurrently (V)                                  |
| Limits       | bg child lacks Task\*/Cron\*/ListAgents (V)              |
| Result       | launch text now (V)                                      |
| Result       | notification later (V)                                   |
| Result       | `-p` waits (V)                                           |
| Availability | `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` drops param (V) |

### Fork (`subagent_type:"fork"`)

Replay: claude:tools_fork, codex:C.

| Surface      | Fact                              |
| ------------ | --------------------------------- |
| Caller       | model (V)                         |
| Parameters   | parent context + parent model (V) |
| Parameters   | `model` ignored (V)               |
| Result       | always bg (V)                     |
| Availability | `CLAUDE_CODE_FORK_SUBAGENT=1` (V) |

### Isolation `worktree` / `remote`

Replay: claude:iso_worktree, codex:H.

| Surface      | Fact                                                     |
| ------------ | -------------------------------------------------------- |
| Caller       | model (param) or frontmatter (V worktree; G/U remote)    |
| Result       | worktree path only when changed (V worktree; G/U remote) |
| Result       | removed if clean / remote gated (V worktree; G/U remote) |
| Availability | omit param (V worktree; G/U remote)                      |

### `Workflow` (alias `RunWorkflow`), `agent()` nodes

Replay: claude:wf_default, claude:wf_allowed, codex:W.

| Surface      | Fact                                                                       |
| ------------ | -------------------------------------------------------------------------- |
| Caller       | model (main only) (V)                                                      |
| Caller       | MCP host (V)                                                               |
| Parameters   | `script`/`name`/`scriptPath`, `args`, `resumeFromRunId` (V)                |
| Parameters   | node `model` (V)                                                           |
| Parameters   | `effort` (V)                                                               |
| Parameters   | `agentType` (V)                                                            |
| Parameters   | `schema` (V)                                                               |
| Parameters   | `isolation` (V)                                                            |
| Parameters   | `label` (V)                                                                |
| Parameters   | `phase` (+`disallowedTools`, `bashCommandClamp` G) (V)                     |
| Limits       | nodes min(16,max(2,cpus−2)) (V)                                            |
| Limits       | 1,000 `agent()` per tree (V)                                               |
| Limits       | `workflow()` 1 level (G)                                                   |
| Limits       | nodes lack Agent/Workflow/SendUserMessage (V)                              |
| Result       | async: Task ID, Run ID, script, transcript dir (V)                         |
| Result       | notification + `journal.jsonl` (V)                                         |
| Availability | `enableWorkflows`, `disableWorkflows`, `CLAUDE_CODE_DISABLE_WORKFLOWS` (V) |
| Availability | `-p` default mode auto-denies dynamic script (V)                           |

### `SendMessage` / `ListAgents`

Replay: claude:steer_bg, judge:judge_wf_msg.

| Surface      | Fact                                                                     |
| ------------ | ------------------------------------------------------------------------ |
| Caller       | model (main, children) (V)                                               |
| Parameters   | `to` (name, agentId, `main`, session), `message`, `notify_when_idle` (V) |
| Result       | queued ack or "Resuming agent" (V)                                       |
| Result       | ListAgents shows other local sessions, not workflow nodes (V)            |
| Availability | `--disallowedTools` (V)                                                  |

### `TaskStop`

Replay: claude:stop_bg, claude:wf_stop.

| Surface      | Fact                                         |
| ------------ | -------------------------------------------- |
| Caller       | model (V)                                    |
| Parameters   | `task_id` (agentId, workflow task, name) (V) |
| Result       | `{message, task_id, task_type}` (V)          |
| Availability | `--disallowedTools` (V)                      |

### `claude -p`

Replay: claude:bg, codex:H.

| Surface      | Fact                            |
| ------------ | ------------------------------- |
| Caller       | user/host (V)                   |
| Parameters   | all CLI flags (V)               |
| Limits       | one root per process (V)        |
| Result       | text/json/stream-json (V)       |
| Result       | `result.subagents` counters (V) |
| Availability | CLI (V)                         |

### SDK stream-json (`--input-format stream-json` + `initialize`)

Replay: claude:ctl, codex:H.

| Surface      | Fact                                                             |
| ------------ | ---------------------------------------------------------------- |
| Caller       | host (V)                                                         |
| Parameters   | init `systemPrompt`, `appendSystemPrompt`, `agents`, `hooks` (V) |
| Parameters   | control requests (V)                                             |
| Limits       | as `-p` (V)                                                      |
| Result       | stream events + `control_response` (V)                           |
| Availability | CLI (V)                                                          |

### `claude mcp serve`

Replay: claude:mcp_serve_agent, claude:mcp_serve_wf.

| Surface      | Fact                                                                         |
| ------------ | ---------------------------------------------------------------------------- |
| Caller       | host (MCP client) (V)                                                        |
| Parameters   | 21 tools incl. Agent, Workflow, SendMessage, TaskStop (V)                    |
| Parameters   | Agent adds `name`, ignored `team_name`/`mode`, no `run_in_background` (V)    |
| Result       | Agent **synchronous** `{status, agentId, content, resolvedModel, usage}` (V) |
| Result       | Workflow `async_launched` (V)                                                |
| Availability | don't start it (V)                                                           |

### `--bg` / `claude agents\|attach\|logs\|stop\|rm\|respawn`

Replay: codex:H.

| Surface      | Fact                                                             |
| ------------ | ---------------------------------------------------------------- |
| Caller       | user (G (help))                                                  |
| Parameters   | `--model`, `--effort`, `--agent`, `--permission-mode` (G (help)) |
| Limits       | U (U)                                                            |
| Result       | short id (G (help))                                              |
| Availability | CLI (G (help))                                                   |

### Remote/cloud: `--cloud`, `--environment`, `--remote-control`, `--teleport`, `ultrareview`, `RemoteTrigger`

Replay: codex:H.

| Surface      | Fact                        |
| ------------ | --------------------------- |
| Caller       | user (G/U)                  |
| Parameters   | env/session ids (G/U)       |
| Limits       | U (U)                       |
| Result       | U (U)                       |
| Availability | account/feature gates (G/U) |

### Hook `type:"agent"`/`"prompt"`

Replay: codex:P.

| Surface      | Fact                                     |
| ------------ | ---------------------------------------- |
| Caller       | host on hook event (V)                   |
| Parameters   | `prompt`, `model`, `timeout` (V)         |
| Limits       | U (U)                                    |
| Result       | hook verdict (V)                         |
| Availability | `hooks`, `disableAllHooks`, `--bare` (V) |

### Skill `context: fork`; plugin `model.complete`/`model.fork`

Replay: codex:A, codex:P.

| Surface      | Fact                        |
| ------------ | --------------------------- |
| Caller       | user/model/plugin (G/I/U)   |
| Parameters   | skill frontmatter (G/I/U)   |
| Parameters   | plugin API (G/I/U)          |
| Limits       | U (U)                       |
| Result       | skill/plugin result (G/I/U) |
| Availability | skill/plugin gates (G/I/U)  |

### Agent teams

Replay: claude:tools_teams.

| Surface      | Fact                                                                          |
| ------------ | ----------------------------------------------------------------------------- |
| Caller       | model (V schema; U behavior)                                                  |
| Parameters   | Agent `name` (V schema; U behavior)                                           |
| Parameters   | structured SendMessage (V schema; U behavior)                                 |
| Limits       | U (U)                                                                         |
| Availability | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (schema only) (V schema; U behavior) |

### `Monitor`

Replay: codex:A.

| Surface      | Fact                                       |
| ------------ | ------------------------------------------ |
| Caller       | model (interactive) (G/U)                  |
| Parameters   | watch/filter, `timeout_ms` (G/U)           |
| Result       | events (G/U)                               |
| Availability | absent from `-p` and MCP inventories (G/U) |
| Availability | gate U (U)                                 |

### ACP host

Replay: codex:H.

| Surface      | Fact                                     |
| ------------ | ---------------------------------------- |
| Parameters   | not in binary (G)                        |
| Parameters   | no `claude-code-acp` package in repo (G) |
| Availability | external adapter (G)                     |

## Codex

### V2 `collaboration.spawn_agent`

Replay: claude:R2, claude:R3, codex:R1.v2-nested-depth-zero, judge:J1.

| Surface      | Fact                                                                                |
| ------------ | ----------------------------------------------------------------------------------- |
| Caller       | model (V)                                                                           |
| Parameters   | `task_name`, `message`, `fork_turns` (default all), `model`, `reasoning_effort` (V) |
| Parameters   | `agent_type` only if user role declared (V)                                         |
| Limits       | no depth cap (3 seen) (V)                                                           |
| Limits       | 4 incl. root (V)                                                                    |
| Result       | `{task_name}` (V)                                                                   |
| Result       | result later as mailbox message (V)                                                 |
| Availability | catalog `multi_agent_version` (V)                                                   |
| Availability | off: `agents.enabled=false` unless V2 explicitly on (V)                             |

### V2 `followup_task`

Replay: claude:R4, codex:R1.v2-lifecycle.

| Surface      | Fact                                 |
| ------------ | ------------------------------------ |
| Caller       | model (V)                            |
| Parameters   | `target`, `message` (V)              |
| Limits       | existing child (V)                   |
| Limits       | reload uses slot (V)                 |
| Result       | `""` (V)                             |
| Result       | starts idle child (V)                |
| Availability | `disable_direct_message` removes (V) |

### V2 `send_message`

Replay: codex:R1.v2-lifecycle, claude:R11.

| Surface      | Fact                                               |
| ------------ | -------------------------------------------------- |
| Caller       | model (V)                                          |
| Parameters   | `target`, `message` (V)                            |
| Result       | `""` (V)                                           |
| Result       | queued, no idle start (V)                          |
| Availability | `disable_direct_message` removes (needs board) (V) |

### V2 `wait_agent`

Replay: claude:R2, codex:R1.v2-lifecycle.

| Surface      | Fact                                      |
| ------------ | ----------------------------------------- |
| Caller       | model (V)                                 |
| Parameters   | `timeout_ms` (10 s–1 h, default 30 s) (V) |
| Result       | completed/timed_out flag, no content (V)  |
| Availability | `wait_agent_enabled=false` (V)            |

### V2 `interrupt_agent`

Replay: claude:R4, codex:R1.v2-interrupt-tree.

| Surface      | Fact                  |
| ------------ | --------------------- |
| Caller       | model (V)             |
| Parameters   | `target` (V)          |
| Result       | `previous_status` (V) |
| Availability | always with V2 (V)    |

### V2 `list_agents`

Replay: claude:R2, codex:R1.v2-resident-eviction.

| Surface      | Fact                         |
| ------------ | ---------------------------- |
| Caller       | model (V)                    |
| Parameters   | `path_prefix` (V)            |
| Result       | resident agents + status (V) |
| Result       | evicted omitted (V)          |
| Availability | always with V2 (V)           |

### V1 `spawn_agent`

Replay: claude:R8, codex:R1.v1-lifecycle.

| Surface      | Fact                                                                             |
| ------------ | -------------------------------------------------------------------------------- |
| Caller       | model (V)                                                                        |
| Parameters   | `message`/`items`, `agent_type`, `fork_context`, `model`, `reasoning_effort` (V) |
| Limits       | depth 1 (`max_depth`) (V)                                                        |
| Limits       | 6 open (V)                                                                       |
| Result       | `{agent_id, nickname}` (V)                                                       |
| Availability | catalog v1 (V)                                                                   |
| Availability | deferred behind tool search (V)                                                  |

### V1 `send_input`

Replay: claude:R8, codex:R1.v1-lifecycle.

| Surface      | Fact                                         |
| ------------ | -------------------------------------------- |
| Caller       | model (V)                                    |
| Parameters   | `target`, `message`/`items`, `interrupt` (V) |
| Result       | `{submission_id}` (V)                        |
| Availability | V1 surface (V)                               |

### V1 `wait_agent` / `close_agent` / `resume_agent`

Replay: claude:R8, codex:R1.v1-lifecycle.

| Surface      | Fact                                          |
| ------------ | --------------------------------------------- |
| Caller       | model (V)                                     |
| Parameters   | `targets`+`timeout_ms` / `target` / `id` (V)  |
| Limits       | close frees slot (V)                          |
| Limits       | resume takes one (V)                          |
| Result       | status map / prev status / `pending_init` (V) |
| Availability | V1 surface (V)                                |

### Agent roles

Replay: claude:R2, codex:R1.v2-role-model.

| Surface      | Fact                                                               |
| ------------ | ------------------------------------------------------------------ |
| Caller       | user/host defines (V)                                              |
| Caller       | model picks (V)                                                    |
| Parameters   | `[agents.<name>] config_file` (V)                                  |
| Parameters   | role sets model, effort, dev instructions, disables some tools (V) |
| Limits       | backend limits (V)                                                 |
| Result       | normal child (V)                                                   |
| Availability | declare/remove role (V)                                            |

### Message-board extension

Replay: codex:R0.

| Surface      | Fact                                    |
| ------------ | --------------------------------------- |
| Caller       | model (A)                               |
| Parameters   | channel/post/subscribe tools (A)        |
| Limits       | spawns nothing (A)                      |
| Limits       | no idle wake (A)                        |
| Result       | posts, channels (A)                     |
| Availability | `features.agent_message_board` + V2 (A) |

### `codex exec` (+ `resume`, `fork`)

Replay: codex:R1.exec-resume-fork, claude:R0.

| Surface      | Fact                                                                                                     |
| ------------ | -------------------------------------------------------------------------------------------------------- |
| Caller       | user/host (V)                                                                                            |
| Parameters   | prompt/stdin, `-m`, `-c`, `-s`, `-C`, `--worktree`, `--json`, `-o`, `--output-schema`, `--ephemeral` (V) |
| Parameters   | no `-a` (V)                                                                                              |
| Limits       | one root per process (V)                                                                                 |
| Result       | events, last message, rollout (V)                                                                        |
| Availability | CLI (V)                                                                                                  |

### `codex app-server` JSON-RPC

Replay: claude:R1, codex:R2.

| Surface      | Fact                                                                                  |
| ------------ | ------------------------------------------------------------------------------------- |
| Caller       | host (V)                                                                              |
| Parameters   | `thread/start`, `turn/start` (model, effort, instructions, sandbox, dynamicTools) (V) |
| Limits       | many roots (V)                                                                        |
| Limits       | no root cap (V)                                                                       |
| Result       | RPC results + notifications (V)                                                       |
| Availability | command (V)                                                                           |
| Availability | experimental capability gates 63 methods (V)                                          |

### SDKs (TS → exec, Python → app-server)

Replay: codex:R0.

| Surface      | Fact                          |
| ------------ | ----------------------------- |
| Caller       | host (A)                      |
| Parameters   | thread/launch options (A)     |
| Limits       | as underlying (A)             |
| Result       | events / protocol objects (A) |
| Availability | SDK use (A)                   |

### Review (`review`, `exec review`, `review/start`)

Replay: codex:R2, claude:R1.

| Surface      | Fact                                      |
| ------------ | ----------------------------------------- |
| Caller       | user/host (V)                             |
| Parameters   | target flags (V)                          |
| Parameters   | `delivery` inline/detached (V)            |
| Limits       | detached rejected on paginated parent (V) |
| Result       | review output (V)                         |
| Availability | detached deprecated (V)                   |

### Internal workers (review, compact, memory, guardian)

Replay: claude:R1, codex:R0.

| Surface      | Fact                    |
| ------------ | ----------------------- |
| Caller       | harness (I)             |
| Parameters   | none exposed (I)        |
| Limits       | U (U)                   |
| Availability | feature/config keys (I) |

### TUI / daemon / `agents` / `queue` / `--remote`

Replay: claude:R0, codex:R0.

| Surface      | Fact                                            |
| ------------ | ----------------------------------------------- |
| Caller       | user/host (V)                                   |
| Parameters   | TUI flags, `--remote`, queue thread+message (V) |
| Result       | interactive (V)                                 |
| Availability | Nix wrapper forces `--no-daemon` (V)            |

### `codex cloud exec`

Replay: claude:R0, codex:R0.

| Surface      | Fact                                      |
| ------------ | ----------------------------------------- |
| Caller       | user (V)                                  |
| Parameters   | `--env`, `--branch`, `--attempts` 1–4 (V) |
| Parameters   | no model/effort (V)                       |
| Limits       | remote, U (U)                             |
| Result       | task id/URL (V)                           |
| Availability | ChatGPT account (V)                       |

### Hooks (command/MCP)

Replay: claude:R10, codex:R0.

| Surface      | Fact                           |
| ------------ | ------------------------------ |
| Caller       | host engine (V)                |
| Parameters   | matcher, timeout, async (V)    |
| Parameters   | Subagent events (V)            |
| Limits       | host-defined (V)               |
| Result       | context/block decision (V)     |
| Availability | `[[hooks.*]]`, trust (V)       |
| Availability | prompt/agent types skipped (V) |

### Shell/background processes, `exec-server`

Replay: codex:R0.

| Surface      | Fact                               |
| ------------ | ---------------------------------- |
| Caller       | model/user/host (A)                |
| Parameters   | command, stdin, cwd, timeout (A)   |
| Limits       | processes, not model delegates (A) |
| Result       | output, exit (A)                   |
| Availability | tool policy (A)                    |

### MCP-server / ACP / workflow tool

Replay: claude:R0, codex:R0.

| Surface      | Fact             |
| ------------ | ---------------- |
| Parameters   | none (V)         |
| Availability | do not exist (V) |

## Kiro

### `subagent` crew (v2)

Replay: claude:h2-all, claude:g-sub-off, codex:R2.

| Surface      | Fact                                                                                          |
| ------------ | --------------------------------------------------------------------------------------------- |
| Caller       | model, v2 main (V)                                                                            |
| Parameters   | `task`, `mode` blocking only, stages `name/role/prompt_template/depends_on/loop_to/model` (V) |
| Limits       | depth 1 (child lacks tool) (V)                                                                |
| Limits       | parallel stages (V)                                                                           |
| Limits       | cap U (U)                                                                                     |
| Result       | consolidated text (V)                                                                         |
| Result       | child `summary` (V)                                                                           |
| Availability | agent `tools` only (V)                                                                        |
| Availability | `enableSubagent`/`enableDelegate`/`enableMainAgentSubagentTool` no effect (V)                 |

### `use_subagent` (v1)

Replay: claude:g-v1-deleg, codex:R2.

| Surface      | Fact                                                            |
| ------------ | --------------------------------------------------------------- |
| Caller       | model (V; G limit)                                              |
| Parameters   | `subagents[{query, agent_name, relevant_context}]` (V; G limit) |
| Limits       | ≤4 parallel (tool text) (V; G limit)                            |
| Result       | per-child summary (V; G limit)                                  |
| Availability | v1 engine only (V; G limit)                                     |
| Availability | absent in v2 (V; G limit)                                       |

### `delegate` (v1)

Replay: claude:g-v1-deleg.

| Surface      | Fact                                                  |
| ------------ | ----------------------------------------------------- |
| Caller       | model (V spec; G behavior)                            |
| Parameters   | `launch/status`, `agent`, `task` (V spec; G behavior) |
| Limits       | async (V spec; G behavior)                            |
| Limits       | one task per agent (V spec; G behavior)               |
| Result       | status output (V spec; G behavior)                    |
| Availability | v1 + `chat.enableDelegate` (V spec; G behavior)       |

### `invoke_sub_agent` (v3)

Replay: claude:k-pins, codex:R3, codex:R5.

| Surface      | Fact                                                 |
| ------------ | ---------------------------------------------------- |
| Caller       | model: ACP main, KAS children, steps (V)             |
| Parameters   | `name` (V)                                           |
| Parameters   | `prompt` (V)                                         |
| Parameters   | `explanation` (V)                                    |
| Parameters   | `preset` (V)                                         |
| Parameters   | `contextFiles` (V)                                   |
| Parameters   | `specTask` (V)                                       |
| Parameters   | gated `inlineAgent{systemPrompt,model,effort}` (V)   |
| Limits       | rejects depth ≥5 (V)                                 |
| Limits       | 5 slots per parent execution (V)                     |
| Limits       | 300 turns (V)                                        |
| Result       | `subagent_response` + files (V)                      |
| Result       | `subExecutionId` (V)                                 |
| Availability | ACP `subagentOrchestration` swaps to orchestrate (V) |
| Availability | agent tools (V)                                      |
| Availability | hooks (V)                                            |

### `subagent_<id>` wrappers (v3)

Replay: codex:R3, codex:R6.

| Surface      | Fact                                                    |
| ------------ | ------------------------------------------------------- |
| Caller       | model: KAS children, steps (V list; A factory)          |
| Parameters   | `prompt` (or verbatim/context pair) (V list; A factory) |
| Limits       | as invoke (V list; A factory)                           |
| Result       | as invoke (V list; A factory)                           |
| Availability | registry contents (V list; A factory)                   |

### `orchestrate_subagent` (v3)

Replay: claude:h3-all, codex:R6.

| Surface      | Fact                                              |
| ------------ | ------------------------------------------------- |
| Caller       | model: headless/TUI main (V)                      |
| Parameters   | `task`, stages + `inlineAgent`, `repeat` 1–20 (V) |
| Limits       | ready stages parallel (V)                         |
| Limits       | invoke limits apply (V)                           |
| Result       | "Pipeline completed" text (V)                     |
| Result       | first failure stops (V)                           |
| Availability | TUI on unless workflows on and setting false (V)  |
| Availability | `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1` (V)  |

### `run_workflow` + `inspect/update/validate_workflow`, `send_message`, `save_workflow_definition` (v3)

Replay: claude:k-wfpins, codex:R4.

| Surface      | Fact                                                          |
| ------------ | ------------------------------------------------------------- |
| Caller       | model (V)                                                     |
| Caller       | not from step or delegated child (V)                          |
| Parameters   | `workflowPath` XOR `workflowPrompt`, `inputs`, `runLabel` (V) |
| Parameters   | step `modelId/effortLevel` (V)                                |
| Limits       | ≤50 nodes, nest ≤8, repeat ≤1000 (V)                          |
| Limits       | parallel uncapped (V)                                         |
| Limits       | runs concurrent (V)                                           |
| Result       | immediate `{workflowId, running}` (V)                         |
| Availability | rollout `workflows` + v3 + `chat.enableWorkflows` (V)         |
| Availability | ACP `settings.workflows` (V)                                  |

### Host `_kiro/workflow/*` RPCs

Replay: codex:R4.

| Surface      | Fact                                                                  |
| ------------ | --------------------------------------------------------------------- |
| Caller       | host (ACP) (V)                                                        |
| Parameters   | `new/invoke`, definition or recipe, inputs, `modelId/effortLevel` (V) |
| Limits       | step sessions (V)                                                     |
| Limits       | global cap U (U)                                                      |
| Result       | ID, state, node events (V)                                            |
| Availability | work even with `workflowsEnabled:false` (V)                           |

### `chat --no-interactive`

Replay: codex:R1, claude:h2-all.

| Surface      | Fact                                                                                         |
| ------------ | -------------------------------------------------------------------------------------------- |
| Caller       | user/host (V)                                                                                |
| Parameters   | `--agent --model --effort -a --trust-tools --output-format --resume --v3 --mode --cloud` (V) |
| Limits       | one process (V)                                                                              |
| Result       | text or ACP JSONL (V)                                                                        |
| Result       | exit code (V)                                                                                |
| Availability | invocation (V)                                                                               |

### `kiro-cli acp`

Replay: claude:k-pins, judge:j-a2-cancel-cfg.

| Surface      | Fact                                                                        |
| ------------ | --------------------------------------------------------------------------- |
| Caller       | host (V)                                                                    |
| Parameters   | v3 needs `--auth-method cli`, rejects `-a` (V)                              |
| Parameters   | `_meta.kiro{modeId,modelId,effortLevel,steering,customAgents,settings}` (V) |
| Limits       | many sessions (V)                                                           |
| Limits       | cap U (U)                                                                   |
| Result       | v3 child events under parent sid (V)                                        |
| Result       | v2 `subagent/list_update` (V)                                               |
| Availability | `--agent-engine` (v2 default) (V)                                           |

### TUI

Replay: codex:R6.

| Surface      | Fact                                        |
| ------------ | ------------------------------------------- |
| Caller       | user (A)                                    |
| Parameters   | dashboard, background, workflow monitor (A) |
| Limits       | engine limits (A)                           |
| Result       | screen (A)                                  |
| Availability | `--tui` (A)                                 |
| Availability | v3 surfaces gated (A)                       |

### `serve --port`

Replay: codex:R1.

| Surface      | Fact                         |
| ------------ | ---------------------------- |
| Caller       | host (V help; U)             |
| Parameters   | port 8082 (V help; U)        |
| Limits       | WebSocket v3 (V help; U)     |
| Limits       | limits U (U)                 |
| Result       | WS service (V help; U)       |
| Availability | explicit command (V help; U) |

### `--cloud --repo`

Replay: codex:R1.

| Surface      | Fact                                |
| ------------ | ----------------------------------- |
| Caller       | user/host (V help; U)               |
| Parameters   | repo, `executionTarget` (V help; U) |
| Limits       | U (U)                               |
| Result       | U (U)                               |
| Availability | v3 only (V help; U)                 |
| Availability | account rollout (V help; U)         |

### `kiro-cli crew`

Replay: codex:R1.

| Surface      | Fact                            |
| ------------ | ------------------------------- |
| Caller       | user (V help; U)                |
| Parameters   | forwarded args (V help; U)      |
| Parameters   | `--yes` installs (V help; U)    |
| Limits       | U (U)                           |
| Result       | external Crew CLI (V help; U)   |
| Availability | installs if missing (V help; U) |

### Hooks (`agentSpawn` etc.)

Replay: claude:h2-hookblock, claude:h3-hookblock.

| Surface      | Fact                                         |
| ------------ | -------------------------------------------- |
| Caller       | host config (V)                              |
| Parameters   | six triggers (V)                             |
| Parameters   | `askAgent` = same session (V)                |
| Limits       | n/a (V)                                      |
| Result       | `preToolUse` exit 2 blocks delegate tool (V) |
| Availability | agent `hooks` (V)                            |
| Availability | fire in v2 crew, not KAS children (V)        |

### MCP-server mode

Replay: codex:R1.

| Surface      | Fact                                    |
| ------------ | --------------------------------------- |
| Availability | not possible: `mcp` manages clients (V) |

## Kimchi

### `Agent` (native)

Replay: claude:s1-fg-pins, claude:s2-rpc-bg, codex:O.

| Surface      | Fact                                          |
| ------------ | --------------------------------------------- |
| Caller       | model, parent only (V)                        |
| Parameters   | `prompt` (V)                                  |
| Parameters   | `description` (V)                             |
| Parameters   | `subagent_type` (V)                           |
| Parameters   | `model` (V)                                   |
| Parameters   | `thinking` (V)                                |
| Parameters   | `max_turns` (V)                               |
| Parameters   | `token_budget` (V)                            |
| Parameters   | `max_duration` (V)                            |
| Parameters   | `run_in_background` (V)                       |
| Parameters   | `isolated` (V)                                |
| Parameters   | `inherit_context` (V)                         |
| Parameters   | `task_ref` (V)                                |
| Limits       | depth 1 (V)                                   |
| Limits       | bg 4 run, rest queue (V)                      |
| Limits       | `maxConcurrent` configurable 1–1024 (V)       |
| Limits       | fg uncapped (V)                               |
| Result       | fg: text + `agent_outcome` (V)                |
| Result       | bg: ID, later notification (V)                |
| Availability | `extensions.agents` resource (V)              |
| Availability | bg default on in RPC/ACP/TUI, off in `-p` (V) |

### `get_subagent_result`

Replay: claude:s8-resume-ctx.

| Surface      | Fact                                      |
| ------------ | ----------------------------------------- |
| Caller       | model (V)                                 |
| Parameters   | `agent_id`, `wait` (≤60 s), `verbose` (V) |
| Result       | status, usage, result (V)                 |
| Availability | with `Agent` (V)                          |

### `steer_subagent`

Replay: claude:s2-rpc-bg.

| Surface      | Fact                      |
| ------------ | ------------------------- |
| Caller       | model (V)                 |
| Parameters   | `agent_id`, `message` (V) |
| Limits       | running only (V)          |
| Limits       | queued before init (V)    |
| Result       | confirmation + stats (V)  |
| Availability | with `Agent` (V)          |

### `resume_subagent`

Replay: claude:s8b-resume-yolo, codex:B.

| Surface      | Fact                                                                             |
| ------------ | -------------------------------------------------------------------------------- |
| Caller       | model (V)                                                                        |
| Parameters   | `agent_id`, `prompt`, `max_turns`, `max_duration`, `token_budget`, `purpose` (V) |
| Limits       | finished agents (V)                                                              |
| Limits       | 2-cap Ferment only (A)                                                           |
| Result       | same child session continues (V)                                                 |
| Availability | with `Agent` (V)                                                                 |
| Availability | headless classifier gates it (V)                                                 |

### 9 built-in personas

Replay: claude:s11-thinking-inherit, codex:N.

| Surface      | Fact                               |
| ------------ | ---------------------------------- |
| Caller       | model via `subagent_type` (V)      |
| Parameters   | persona tools, thinking, turns (V) |
| Availability | persona `enabled` (V)              |

### Custom agents `.md`

Replay: claude:s1-fg-pins, judge:J1.

| Surface      | Fact                                                                                        |
| ------------ | ------------------------------------------------------------------------------------------- |
| Caller       | user files (V)                                                                              |
| Caller       | model picks (V)                                                                             |
| Parameters   | `thinking`, `tools`, `disallowed_tools`, `extensions`, `skills`, `prompt_mode`, budgets (V) |
| Parameters   | `model` ignored (V)                                                                         |
| Parameters   | `isolation` ignored (V)                                                                     |
| Availability | `enabled: false` (V)                                                                        |
| Availability | package → global → project, later wins (V)                                                  |

### Ferment `start_ferment_step`

Replay: codex:N.

| Surface      | Fact                                    |
| ------------ | --------------------------------------- |
| Caller       | model (A)                               |
| Parameters   | ferment/phase/step IDs, budget tier (A) |
| Limits       | spawns nothing (A)                      |
| Limits       | linked `Agent` follows (A)              |
| Result       | `task_ref` + limits (A)                 |
| Availability | Ferment extension (A)                   |

### Workflow in-session step

Replay: claude:w1-workflow.

| Surface      | Fact                                                                              |
| ------------ | --------------------------------------------------------------------------------- |
| Caller       | user/host `/workflow run` (V)                                                     |
| Caller       | no model tool (V)                                                                 |
| Parameters   | prompt, `model`, `retry`, `asks`, output schema, `maxDurationMs`, `maxTokens` (V) |
| Parameters   | no effort (V)                                                                     |
| Limits       | 1 host turn (V)                                                                   |
| Limits       | run `maxConcurrency` 4 (V)                                                        |
| Result       | step result, event log (V)                                                        |
| Availability | workflows package in harness `packages` (V)                                       |

### Workflow background step

Replay: claude:w1-workflow, codex:W.

| Surface      | Fact                                                        |
| ------------ | ----------------------------------------------------------- |
| Caller       | workflow engine (V)                                         |
| Parameters   | same + `background` (V)                                     |
| Limits       | separate `kimchi -p` process, offered `Agent` → depth 2 (V) |
| Limits       | shared gate (V)                                             |
| Result       | final turn / `workflow_submit_result` (V)                   |
| Availability | same (V)                                                    |
| Availability | `background`+`asks` rejected (V)                            |

### `dispatch_to_cloud_agent`, `/remote-run`

Replay: claude:inv.

| Surface      | Fact                            |
| ------------ | ------------------------------- |
| Caller       | model (user confirm) / user (V) |
| Parameters   | `task`, `description` (V)       |
| Parameters   | no model/effort (V)             |
| Limits       | remote worker, bg queue (V)     |
| Result       | notification + sync/review (V)  |
| Availability | absent in `-p` (V)              |
| Availability | `KIMCHI_REMOTE_RUN=off` (V)     |

### Headless `-p` / `--mode json`

Replay: codex:O.

| Surface      | Fact                                                                            |
| ------------ | ------------------------------------------------------------------------------- |
| Caller       | host (V)                                                                        |
| Parameters   | `--model`, `--thinking`, `--append-system-prompt`, perm/session flags, `-e` (V) |
| Limits       | process per call (V)                                                            |
| Result       | text / JSONL (V)                                                                |
| Availability | always (V)                                                                      |

### RPC `--mode rpc`

Replay: codex:R.

| Surface      | Fact                        |
| ------------ | --------------------------- |
| Caller       | host (V)                    |
| Parameters   | JSONL commands (V)          |
| Limits       | one session per process (V) |
| Result       | events + responses (V)      |
| Availability | always (V)                  |

### ACP `--mode acp`

Replay: claude:a1-acp-cancel-fg.

| Surface      | Fact                                                                          |
| ------------ | ----------------------------------------------------------------------------- |
| Caller       | host (V)                                                                      |
| Parameters   | `session/new\|load\|list\|close`, `prompt`, `cancel`, `set_config_option` (V) |
| Limits       | many sessions, one prompt each (V)                                            |
| Result       | `session/update` (V)                                                          |
| Availability | always (V)                                                                    |

### Pi SDK `createAgentSession`

Replay: codex:P.

| Surface      | Fact                                            |
| ------------ | ----------------------------------------------- |
| Caller       | host / extension code (A)                       |
| Parameters   | cwd, model, `thinkingLevel`, tools, loaders (A) |
| Limits       | caller-owned (A)                                |
| Result       | `AgentSession` (A)                              |
| Availability | import (A)                                      |

### `kimchi claude\|codex\|opencode`

Replay: codex:P.

| Surface      | Fact                             |
| ------------ | -------------------------------- |
| Caller       | user/host (A)                    |
| Parameters   | argv forwarded, env injected (A) |
| Limits       | target harness (A)               |
| Result       | target output (A)                |
| Availability | binary present (A)               |

### `bash` / `bash_control`

Replay: codex:P, claude:s9-perm-default.

| Surface      | Fact                          |
| ------------ | ----------------------------- |
| Caller       | model, parent or child (A)    |
| Parameters   | any command (A)               |
| Limits       | untracked (A)                 |
| Limits       | unbounded via `kimchi -p` (A) |
| Result       | output, handle (A)            |
| Availability | Bash extension (A)            |
| Availability | child bash ungated (A)        |

### `daemon` / `daemon_control`

Replay: claude:inv.

| Surface      | Fact                                 |
| ------------ | ------------------------------------ |
| Caller       | model (V)                            |
| Parameters   | command, name (V)                    |
| Limits       | detached (V)                         |
| Result       | ID, PID, log (V)                     |
| Availability | `--enable-experimental-features` (V) |

### Extension / package tools

Replay: codex:P.

| Surface      | Fact                                |
| ------------ | ----------------------------------- |
| Caller       | extension code (A)                  |
| Parameters   | `registerTool` schema (A)           |
| Limits       | ext-defined (A)                     |
| Result       | ext-defined (A)                     |
| Availability | packages, `-e` (A)                  |
| Availability | user file exts load in children (A) |

### MCP server mode

Replay: codex:P.

| Surface    | Fact                            |
| ---------- | ------------------------------- |
| Parameters | none (A)                        |
| Parameters | `kimchi mcp` = client probe (A) |
