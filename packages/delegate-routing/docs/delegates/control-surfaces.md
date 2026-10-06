# Delegate control surfaces

Where each delegate capability can be set, per harness, and where it cannot.
Numeric capacities are in [tools.md](tools.md); lifecycle behavior is in
[lifecycle.md](lifecycle.md).

- **Config** = settings files, agent/role/persona definitions, and per-call tool
  parameters.
- **Patch** = only reachable by changing the shipped code.
- **Not possible** = no native path at the pinned version.
- **Pins and marks:** [evidence.md](evidence.md).
- **Replay:** scripts live in
  `packages/delegate-routing/probes/delegates/<harness>/`. Case ids are
  `<side>:<case>`, as in the judged runs (`claude:`, `codex:` and `judge:` name
  the side that ran the case).

## Claude

### Main model

Replay: claude:ctl, codex:H.

| Surface | Fact                     |
| ------- | ------------------------ |
| Config  | `model` (V)              |
| Config  | agent `model` (V)        |
| CLI     | `--model`, `--agent` (V) |
| CLI     | SDK `set_model` (V)      |

### Child model (Agent)

Replay: claude:model_effort, claude:model_force, claude:hooks_rewrite.

| Surface     | Fact                                       |
| ----------- | ------------------------------------------ |
| Config      | Agent param `model` (4 aliases) (V)        |
| Config      | frontmatter / `--agents` `model` (V)       |
| Config      | PreToolUse `updatedInput` (V)              |
| Env         | `CLAUDE_CODE_SUBAGENT_MODEL` (default) (V) |
| Env         | `_FORCE=1` beats param + frontmatter (V)   |
| Unavailable | fork ignores override (V)                  |
| Unavailable | IDs outside enum (V)                       |

### Child model (Workflow node)

Replay: claude:wf_allowed, claude:wf_force.

| Surface     | Fact                                    |
| ----------- | --------------------------------------- |
| Config      | `agent()` `model` / `agentType` (V)     |
| Env         | SUBAGENT_MODEL / `_FORCE` apply (V)     |
| Unavailable | hook rewrite (PreToolUse not fired) (V) |

### Main effort

Replay: judge:judge_effort_env, claude:ctl_effort.

| Surface     | Fact                                                               |
| ----------- | ------------------------------------------------------------------ |
| Config      | `effortLevel`, `modelSettings.*.effortLevel`, `maxEffortLevel` (V) |
| CLI         | `--effort` (V)                                                     |
| CLI         | SDK `apply_flag_settings` (V)                                      |
| Env         | `CLAUDE_CODE_EFFORT_LEVEL` (beats `--effort`) (V)                  |
| Unavailable | models without effort (haiku) (V)                                  |

### Child effort (Agent)

Replay: claude:model_effort, claude:agents_json, judge:judge_effort_env.

| Surface     | Fact                                             |
| ----------- | ------------------------------------------------ |
| Config      | frontmatter / `--agents` `effort` (V)            |
| Config      | else session (V)                                 |
| CLI         | `--effort` (session-wide) (V)                    |
| Env         | `CLAUDE_CODE_EFFORT_LEVEL` beats frontmatter (V) |
| Patch       | add `effort` to Agent schema + spawn path (V)    |
| Unavailable | per-call param (V)                               |

### Child effort (Workflow node)

Replay: claude:wf_allowed.

| Surface | Fact                         |
| ------- | ---------------------------- |
| Config  | `agent()` `effort` (V)       |
| Config  | else session (V)             |
| Env     | env vs node precedence U (U) |

### Main system / extra prompt

Replay: codex:P.

| Surface     | Fact                                                                        |
| ----------- | --------------------------------------------------------------------------- |
| Config      | agent body (V)                                                              |
| Config      | SDK `initialize` `systemPrompt` / `appendSystemPrompt` (V)                  |
| CLI         | `--system-prompt[-file]`, `--append-system-prompt[-file]` (V)               |
| Unavailable | resume snapshot re-sends old text unless `--system-prompt-snapshot off` (V) |

### Child system / extra prompt

Replay: codex:P, claude:hooks_obs.

| Surface     | Fact                                                                                   |
| ----------- | -------------------------------------------------------------------------------------- |
| Config      | agent body replaces base (V)                                                           |
| Config      | SubagentStart `additionalContext` (user msg) (V)                                       |
| CLI         | hidden `--append-subagent-system-prompt[-file]` (`-p`) (V)                             |
| Env         | `CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT` gates SDK `appendSubagentSystemPrompt` (V) |
| Patch       | per-call field (V)                                                                     |
| Unavailable | per-call system field (V)                                                              |
| Unavailable | main append never reaches non-fork children (V)                                        |

### Delegation clamp (`heron_brook`)

Replay: claude:tools_default.

| Surface     | Fact                                                      |
| ----------- | --------------------------------------------------------- |
| Config      | hook mitigation `ai.claude.delegationClampMitigation` (G) |
| Patch       | system-prompt section (G)                                 |
| Unavailable | off switch (G)                                            |

### Child tools

Replay: claude:model_effort, codex:W.

| Surface     | Fact                                           |
| ----------- | ---------------------------------------------- |
| Config      | frontmatter `tools` / `disallowedTools` (V/G)  |
| Config      | node `disallowedTools`, `bashCommandClamp` (G) |
| CLI         | parent `--tools` bounds children (V/G)         |
| Patch       | Agent/Workflow inside nodes (V/G)              |
| Unavailable | per-call tools (V/G)                           |
| Unavailable | node allowlist (V/G)                           |

### Child permissions

Replay: claude:perm_named_accept, claude:perm_named_bypass.

| Surface     | Fact                                                                  |
| ----------- | --------------------------------------------------------------------- |
| Config      | inherit parent (V; bypass cause U)                                    |
| Config      | frontmatter `permissionMode: acceptEdits` honored (V; bypass cause U) |
| Config      | `bypassPermissions` not under default parent (V; bypass cause U)      |
| Config      | plugin agents ignore it (G)                                           |
| CLI         | `--permission-mode` (V; bypass cause U)                               |
| Unavailable | per-call `mode` (ignored) (V; bypass cause U)                         |

### Permission prompt routing (`-p`)

Replay: claude:perm_none, claude:perm_default.

| Surface | Fact                                                                      |
| ------- | ------------------------------------------------------------------------- |
| Config  | permission rules (V; G tool)                                              |
| CLI     | `--permission-prompts host\|none`, `--permission-prompt-tool` (V; G tool) |

### Depth

Replay: claude:depth_env1, claude:depth_settings_env1, codex:A.

| Surface     | Fact                                       |
| ----------- | ------------------------------------------ |
| Config      | `settings.env` (V)                         |
| Env         | `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` (V) |
| Patch       | spawn-depth constant (V)                   |
| Unavailable | node → Agent (V)                           |
| Unavailable | `workflow()` > 1 level (V)                 |

### Agent concurrency

Replay: judge:judge_parallel_fg22, claude:parallel_settings_cap3.

| Surface     | Fact                                       |
| ----------- | ------------------------------------------ |
| Config      | `settings.env` (V)                         |
| Env         | `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS` (V) |
| Unavailable | queueing (excess refused) (V)              |

### Workflow concurrency / size

Replay: claude:wf_bypass_cap4, codex:W.

| Surface | Fact                                             |
| ------- | ------------------------------------------------ |
| Config  | `workflowSizeGuideline` (G, guidance) (V)        |
| Env     | `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` (V) |
| Patch   | call-count cap (V)                               |

### Enable/disable Agent

Replay: claude:tools_deny_agent, claude:hooks_deny.

| Surface | Fact                                     |
| ------- | ---------------------------------------- |
| Config  | `permissions.deny` (V)                   |
| Config  | frontmatter `disallowedTools` (V)        |
| Config  | PreToolUse deny (V)                      |
| CLI     | `--tools`, `--disallowedTools Agent` (V) |

### Enable/disable built-in types

Replay: claude:agents_nobuiltin, claude:agents_noexplore.

| Surface | Fact                                                                                     |
| ------- | ---------------------------------------------------------------------------------------- |
| Env     | `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS`, `CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS` (V) |

### Enable/disable Workflow

Replay: claude:tools_settings_disablewf, claude:wf_allowed, codex:W.

| Surface | Fact                                           |
| ------- | ---------------------------------------------- |
| Config  | `enableWorkflows`, `disableWorkflows` (V)      |
| Config  | org `allow_workflows` (G)                      |
| CLI     | `--allowedTools Workflow` (to run in `-p`) (V) |
| Env     | `CLAUDE_CODE_DISABLE_WORKFLOWS` (V)            |
| Env     | `CLAUDE_CODE_WORKFLOWS` (G)                    |

### Background / fork / teams

Replay: claude:tools_disable_bg, claude:tools_fork, claude:tools_teams.

| Surface | Fact                                       |
| ------- | ------------------------------------------ |
| Config  | frontmatter `background` (V)               |
| Config  | `teammateMode` (G)                         |
| Env     | `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` (V) |
| Env     | `CLAUDE_CODE_FORK_SUBAGENT` (V)            |
| Env     | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` (V) |

### Steer

Replay: claude:steer_bg, judge:judge_wf_msg.

| Surface     | Fact                              |
| ----------- | --------------------------------- |
| Config      | tool `SendMessage` (bg child) (V) |
| CLI         | SDK user frames, `interrupt` (V)  |
| Unavailable | fg child (V)                      |
| Unavailable | running workflow node (V)         |
| Unavailable | SDK `send_task_message` (V)       |

### Cancel

Replay: claude:stop_bg_propagate, claude:ctl, claude:wf_stop.

| Surface | Fact                                |
| ------- | ----------------------------------- |
| Config  | tool `TaskStop` (bg child, node (V) |
| Config  | kills fg grandchild) (V)            |
| CLI     | SDK `interrupt`, `stop_task` (V)    |

### Mid-run model / effort

Replay: claude:ctl_effort.

| Surface     | Fact                                                        |
| ----------- | ----------------------------------------------------------- |
| CLI         | SDK `set_model`, `apply_flag_settings` (later children) (U) |
| Patch       | U (U)                                                       |
| Unavailable | running child: no demonstrated path (U)                     |

### Resume / fork

Replay: claude:resume_fork, claude:live_resume, claude:wf_resume.

| Surface | Fact                                                                                       |
| ------- | ------------------------------------------------------------------------------------------ |
| Config  | SendMessage after completion (V)                                                           |
| Config  | `resumeFromRunId` (workflow) (V)                                                           |
| CLI     | `--resume`, `--continue`, `--fork-session`, `--session-id`, `--no-session-persistence` (V) |
| Env     | `CLAUDE_CONFIG_DIR` (storage) (V)                                                          |

### Timeout / budget

Replay: claude:fm_turns, claude:bg_stall, claude:bg_print_ceiling,
claude:wf_budget.

| Surface     | Fact                                                                              |
| ----------- | --------------------------------------------------------------------------------- |
| Config      | frontmatter `maxTurns` (V)                                                        |
| Config      | workflow `budget` setter U (U)                                                    |
| CLI         | `--max-budget-usd` (V)                                                            |
| Env         | `CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` (V) |
| Env         | `API_TIMEOUT_MS` (G)                                                              |
| Unavailable | per-call wall clock (V)                                                           |

### Spawn-gate hooks

Replay: claude:hooks_obs, claude:hooks_block, claude:hooks_wf.

| Surface     | Fact                                   |
| ----------- | -------------------------------------- |
| Config      | SubagentStart (context, no veto) (V)   |
| Config      | SubagentStop `decision:block` (V)      |
| Config      | PreToolUse(Agent) deny/rewrite (V)     |
| Config      | `disableAllHooks` (V)                  |
| CLI         | `--bare` skips hooks (V)               |
| Unavailable | blocking a workflow node pre-start (V) |

### Isolation

Replay: claude:iso_worktree, codex:W.

| Surface     | Fact                                                                        |
| ----------- | --------------------------------------------------------------------------- |
| Config      | param / frontmatter `isolation` (V worktree)                                |
| Config      | `worktree.baseRef`, `worktree.bgIsolation`, WorktreeCreate/Remove hooks (G) |
| CLI         | `-w` (session) (V worktree)                                                 |
| Unavailable | node `remote` (G)                                                           |

## Codex

### Root model

Replay: claude:R13, codex:R1.exec-resume-fork.

| Surface | Fact            |
| ------- | --------------- |
| Config  | `model` (V)     |
| CLI     | `-m` (V)        |
| CLI     | RPC `model` (V) |

### Root effort

Replay: claude:R13, codex:R2.

| Surface | Fact                                              |
| ------- | ------------------------------------------------- |
| Config  | `model_reasoning_effort` (`ultra` → wire max) (V) |
| CLI     | `-c` (V)                                          |
| CLI     | RPC `effort` (V)                                  |

### Child model

Replay: claude:R12, claude:R2.

| Surface     | Fact                                |
| ----------- | ----------------------------------- |
| Config      | `agents.default_subagent_model` (V) |
| Config      | role `model` wins (V)               |
| Config      | spawn arg `model` (V)               |
| CLI         | `-c` (V)                            |
| Unavailable | mid-run change (V)                  |

### Child effort

Replay: claude:R12, codex:R1.v2-role-model.

| Surface     | Fact                                           |
| ----------- | ---------------------------------------------- |
| Config      | `agents.default_subagent_reasoning_effort` (V) |
| Config      | role effort wins (V)                           |
| Config      | spawn arg `reasoning_effort` (V)               |
| CLI         | `-c` (V)                                       |
| Unavailable | mid-run change (V)                             |

### Hide spawn model/effort args

Replay: claude:R11.

| Surface | Fact                                           |
| ------- | ---------------------------------------------- |
| Config  | `expose_spawn_agent_model_overrides=false` (V) |
| CLI     | `-c` (V)                                       |

### Base prompt

Replay: codex:R4.

| Surface     | Fact                                          |
| ----------- | --------------------------------------------- |
| Config      | `model_instructions_file`, `instructions` (V) |
| Config      | RPC `baseInstructions` (V)                    |
| CLI         | `-c` (V)                                      |
| Unavailable | per-child base (children inherit) (V)         |

### Extra prompt (root)

Replay: claude:R10.

| Surface | Fact                                                     |
| ------- | -------------------------------------------------------- |
| Config  | `developer_instructions` (top layer wins, no concat) (V) |
| Config  | RPC `developerInstructions` (V)                          |
| CLI     | `-c` (V)                                                 |

### Extra prompt (child)

Replay: claude:R10.

| Surface     | Fact                                             |
| ----------- | ------------------------------------------------ |
| Config      | `subagent_developer_instructions` (fallback) (V) |
| Config      | role `developer_instructions` replaces it (V)    |
| CLI         | `-c` (V)                                         |
| Unavailable | per-spawn system prompt (V)                      |

### Proactive delegation

Replay: claude:R13.

| Surface     | Fact                               |
| ----------- | ---------------------------------- |
| Config      | effort `ultra` (V)                 |
| Config      | `multi_agent_mode_hint_text` (V)   |
| CLI         | `-c` (V)                           |
| Unavailable | RPC `multiAgentMode` (ignored) (V) |

### Tools allow/deny

Replay: claude:R10, claude:R11, codex:R0.

| Surface     | Fact                                                            |
| ----------- | --------------------------------------------------------------- |
| Config      | role disables shell/apps/plugins/memory/request_permissions (V) |
| Config      | PreToolUse hook (V)                                             |
| Config      | MCP enabled/disabled tools (V)                                  |
| CLI         | `-c` (V)                                                        |
| Patch       | finer per-child lists (V)                                       |
| Unavailable | per-spawn tool list (V)                                         |

### Permissions

Replay: claude:R2, claude:R9.

| Surface     | Fact                              |
| ----------- | --------------------------------- |
| Config      | inherited from parent (V)         |
| Config      | role keys ignored (V)             |
| CLI         | root `-s`, `--approve-for-me` (V) |
| CLI         | TUI `-a` (V)                      |
| Patch       | `child_config.rs` (V)             |
| Unavailable | per-child policy (V)              |

### Concurrency

Replay: claude:R3, codex:R1.v2-concurrency, judge:J2.

| Surface | Fact                                                                  |
| ------- | --------------------------------------------------------------------- |
| Config  | `agents.max_concurrent_threads_per_session` (alias `max_threads`) (V) |
| Config  | V2 counts root (V)                                                    |
| CLI     | `-c` (V)                                                              |

### Depth

Replay: claude:R14, codex:R1.v2-nested-depth-zero.

| Surface     | Fact                                  |
| ----------- | ------------------------------------- |
| Config      | V1 `agents.max_depth` (default 1) (V) |
| CLI         | `-c` (V)                              |
| Patch       | V2 spawn guard (V)                    |
| Unavailable | V2 depth by config (V)                |

### Delegation on/off

Replay: judge:J1, claude:R11, codex:R1.disabled.

| Surface     | Fact                                                      |
| ----------- | --------------------------------------------------------- |
| Config      | `agents.enabled=false` (explicit V2 enable overrides) (V) |
| CLI         | `-c` (V)                                                  |
| Unavailable | `features.multi_agent[_v2]=false` alone (V)               |

### V1 vs V2 backend

Replay: claude:R11, claude:R14.

| Surface     | Fact                                       |
| ----------- | ------------------------------------------ |
| Config      | `features.multi_agent_v2.enabled=true` (V) |
| Config      | `model_catalog_json` (V)                   |
| CLI         | `--enable`, `-c` (V)                       |
| Patch       | catalog file (V)                           |
| Unavailable | forcing V1 on a V2 model via flags (V)     |

### Direct messaging / wait tools

Replay: claude:R4, codex:R1.v2-lifecycle.

| Surface | Fact                           |
| ------- | ------------------------------ |
| Config  | `disable_direct_message` (V)   |
| Config  | `wait_agent_enabled=false` (V) |
| CLI     | `-c` (V)                       |

### Steer

Replay: claude:R4, claude:R7, claude:R6.

| Surface     | Fact                                    |
| ----------- | --------------------------------------- |
| Config      | V2 `followup_task` / `send_message` (V) |
| Config      | V1 `send_input` (model tools) (V)       |
| CLI         | RPC `turn/steer` (root only) (V)        |
| Patch       | ownership guard (V)                     |
| Unavailable | host steer of V2 child (rejected) (V)   |

### Cancel

Replay: claude:R5, claude:R7, codex:R1.v2-interrupt-tree.

| Surface     | Fact                                            |
| ----------- | ----------------------------------------------- |
| Config      | V2 `interrupt_agent` (no propagation) (V; V1 A) |
| Config      | V1 `close_agent` (cascades) (V; V1 A)           |
| CLI         | RPC `turn/interrupt` (V; V1 A)                  |
| Unavailable | root interrupt stopping children (V; V1 A)      |

### Mid-run model / effort

Replay: claude:R6, codex:R2.

| Surface     | Fact                                       |
| ----------- | ------------------------------------------ |
| Config      | `features.step_model_switching` (root) (V) |
| CLI         | RPC `turn/settings/update` (next step) (V) |
| Unavailable | child change (V)                           |
| Unavailable | some model pairs (V)                       |

### Resume / fork

Replay: claude:R4, codex:R1.exec-resume-fork.

| Surface | Fact                                   |
| ------- | -------------------------------------- |
| Config  | V2 `followup_task` reloads (V)         |
| Config  | V1 `resume_agent` (V)                  |
| Config  | `fork_turns` at spawn (V)              |
| CLI     | `exec resume`, `exec fork` (V)         |
| CLI     | RPC `thread/resume`, `thread/fork` (V) |

### Wait timeouts

Replay: codex:R1.v2-invalid.

| Surface | Fact                                     |
| ------- | ---------------------------------------- |
| Config  | V2 `min/default/max_wait_timeout_ms` (V) |
| CLI     | `-c` (V)                                 |

### Delegate wall clock

Replay: judge:J2.

| Surface     | Fact                                         |
| ----------- | -------------------------------------------- |
| Config      | `agents.job_max_runtime_seconds` (no-op) (G) |
| Patch       | add deadline (G)                             |
| Unavailable | native deadline (G)                          |

### Hooks + trust

Replay: claude:R10, codex:R0.

| Surface     | Fact                                                                   |
| ----------- | ---------------------------------------------------------------------- |
| Config      | `[[hooks.<Event>]]`, `features.hooks` (V)                              |
| Config      | SubagentStart context, SubagentStop block, PreToolUse blocks spawn (V) |
| CLI         | `--dangerously-bypass-hook-trust` (V)                                  |
| Unavailable | prompt/agent hook types (V)                                            |

### Isolation

Replay: codex:R0, claude:R0.

| Surface     | Fact                                     |
| ----------- | ---------------------------------------- |
| Config      | `features.worktrees` (A)                 |
| CLI         | root `--worktree`, `-C`, `--add-dir` (A) |
| Patch       | spawn fields (A)                         |
| Unavailable | per-child cwd/worktree (A)               |

### State / transcripts

Replay: claude:R2, codex:R1.v2-resident-eviction.

| Surface     | Fact                                     |
| ----------- | ---------------------------------------- |
| Config      | `sqlite_home`, ephemeral (V)             |
| CLI         | `--ephemeral` (V)                        |
| Env         | `CODEX_HOME`, `CODEX_SQLITE_HOME` (V)    |
| Unavailable | evicted V2 children in `list_agents` (V) |

### Cloud model/effort/tools

Replay: codex:R0.

| Surface     | Fact                  |
| ----------- | --------------------- |
| CLI         | `--attempts` only (A) |
| Patch       | backend contract (A)  |
| Unavailable | local pinning (A)     |

## Kiro

v2 = default engine (crew `subagent`). v3 = KAS engine (`invoke_sub_agent`,
`orchestrate_subagent`, workflows).

### Engine

Replay: codex:R1.

| Surface | Fact                                   |
| ------- | -------------------------------------- |
| Config  | `chat.agentEngine` (V)                 |
| CLI     | `--v2` / `--v3` / `--agent-engine` (V) |

### Main model

Replay: codex:R1, claude:k-pins.

| Surface | Fact                    |
| ------- | ----------------------- |
| Config  | `chat.defaultModel` (V) |
| Config  | ACP `modelId` (V)       |
| CLI     | `--model` (V)           |

### Main effort

Replay: claude:g-v2-effort, claude:k-pins.

| Surface | Fact                                  |
| ------- | ------------------------------------- |
| Config  | ACP `effortLevel` (V)                 |
| CLI     | `--effort` (v2 sends only if set) (V) |

### Delegate model

Replay: claude:k-pins, claude:k-wfpins, claude:h2-agentpin.

| Surface     | Fact                                                          |
| ----------- | ------------------------------------------------------------- |
| Config      | v3 agent `model`, inline `model`, step/workflow `modelId` (V) |
| Config      | v2 stage/role `model` (V)                                     |
| CLI         | parent only (V)                                               |
| Unavailable | v3 step agent's own `model` (ignored) (V)                     |

### Delegate effort

Replay: claude:k-pins, claude:h2-effort.

| Surface     | Fact                                                                                   |
| ----------- | -------------------------------------------------------------------------------------- |
| Config      | v3 agent `effortLevel`, inline `effort`, step/workflow `effortLevel` (V (client wire)) |
| CLI         | parent only (V (client wire))                                                          |
| Patch       | v2 children (V (client wire))                                                          |
| Unavailable | v2: no field (V (client wire))                                                         |
| Unavailable | parent effort not sent (V (client wire))                                               |

### System prompt

Replay: codex:R8.

| Surface     | Fact                                                                         |
| ----------- | ---------------------------------------------------------------------------- |
| Config      | agent `prompt`, `preset`, inline `systemPrompt`, ACP `customAgents` (v3) (V) |
| CLI         | `--agent` (V)                                                                |
| Unavailable | `systemPrompt` / `appendSystemPrompt` fields (V)                             |

### Extra prompt

Replay: codex:R8.

| Surface     | Fact                                                    |
| ----------- | ------------------------------------------------------- |
| Config      | always-on steering files (user role, before prompt) (V) |
| Config      | ACP `_meta.kiro.steering` (v3) (V)                      |
| Unavailable | v2 ignores `_meta` (V)                                  |

### Tools allow/deny

Replay: claude:g-agent-nosub, codex:R6.

| Surface | Fact                                   |
| ------- | -------------------------------------- |
| Config  | agent `tools` / `excludedTools` (V; A) |
| Config  | inline inherits parent (V; A)          |
| CLI     | trust flags (approval only) (V; A)     |
| Patch   | tool factory (V; A)                    |

### Child permissions

Replay: claude:k-perm, claude:h3-trustdel2, claude:h2-trustdel.

| Surface     | Fact                                   |
| ----------- | -------------------------------------- |
| Config      | v3 agent `permissions` (V)             |
| Config      | ACP callback (V)                       |
| CLI         | `-a`, `--trust-tools` (not v3 ACP) (V) |
| Patch       | permission adapter (V)                 |
| Unavailable | interactive approval headless (V)      |

### Depth

Replay: codex:R5.

| Surface     | Fact                  |
| ----------- | --------------------- |
| Patch       | v3 `qji` constant (V) |
| Unavailable | config (V)            |

### Concurrency

Replay: codex:R5.

| Surface     | Fact                       |
| ----------- | -------------------------- |
| Patch       | v3 execution semaphore (V) |
| Unavailable | config (V)                 |
| Unavailable | v2 cap U (U)               |

### Disable delegation

Replay: claude:g-sub-off, claude:h2-hookblock.

| Surface     | Fact                          |
| ----------- | ----------------------------- |
| Config      | agent `tools` (V)             |
| Config      | `preToolUse` exit 2 (V)       |
| CLI         | withhold trust (headless) (V) |
| Unavailable | single global switch (V)      |

### Invoke vs orchestrate

Replay: codex:R6.

| Surface | Fact                                             |
| ------- | ------------------------------------------------ |
| Config  | ACP `subagentOrchestration` (A)                  |
| Config  | `chat.enableMainAgentSubagentTool` (A)           |
| Env     | `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1` (A) |

### Inline agent

Replay: codex:R3, claude:k-pins.

| Surface | Fact                                             |
| ------- | ------------------------------------------------ |
| Config  | ACP `settings.inlineAgents.enabled` (object) (V) |
| Patch   | TUI/headless never send it (V)                   |

### Workflows

Replay: claude:k-wfpins, codex:R4, codex:R7.

| Surface     | Fact                                                      |
| ----------- | --------------------------------------------------------- |
| Config      | `chat.enableWorkflows` (V)                                |
| Config      | ACP `settings.workflows` (V)                              |
| CLI         | `--v3` (V)                                                |
| Env         | `KIRO_ENABLED_FEATURES` / `KIRO_ROLLOUT_FEATURES` (V)     |
| Patch       | rollout manifest bytes (G)                                |
| Unavailable | disabling does not block host `_kiro/workflow/*` RPCs (V) |

### v1 delegate

Replay: claude:g-v1-deleg.

| Surface | Fact                      |
| ------- | ------------------------- |
| Config  | `chat.enableDelegate` (V) |
| CLI     | `--agent-engine v1` (V)   |

### Steer

Replay: judge:k-steer, claude:a2-steerchild, judge:send-dir.

| Surface     | Fact                                                          |
| ----------- | ------------------------------------------------------------- |
| Config      | v2 by child id (V)                                            |
| Config      | v3 workflow `send_message` (both ways), `update_workflow` (V) |
| Config      | ACP v3 `steer` (V)                                            |
| Patch       | v3 invoke addressing (V)                                      |
| Unavailable | per-child steer in v3 invoke (parent steer leaks in) (V)      |

### Cancel

Replay: claude:k-cancel, claude:a2-cancelchild, judge:j-a2-cancel-cfg,
judge:k-wfctl.

| Surface     | Fact                                                |
| ----------- | --------------------------------------------------- |
| Config      | v2 child-id cancel (V)                              |
| Config      | `_kiro/workflow/cancel` (V)                         |
| Patch       | v3 invoke (V)                                       |
| Unavailable | per-child cancel in v3 invoke (whole turn only) (V) |
| Unavailable | v2 parent cancel stopping child (V)                 |

### Mid-run model / effort

Replay: judge:j-a2-cancel-cfg, codex:R3.

| Surface     | Fact                                      |
| ----------- | ----------------------------------------- |
| Config      | v3 `set_config_option` (next turn) (V; A) |
| CLI         | TUI controls (V; A)                       |
| Patch       | execution snapshot (V; A)                 |
| Unavailable | v2 ACP (−32601) (V; A)                    |
| Unavailable | running child (V; A)                      |

### Resume / fork

Replay: codex:R1, judge:k-wfctl.

| Surface     | Fact                          |
| ----------- | ----------------------------- |
| Config      | ACP v3 load/resume/fork (V)   |
| Config      | workflow pause → resume (V)   |
| CLI         | `--resume`, `--resume-id` (V) |
| Unavailable | v3 child resume (V)           |
| Unavailable | workflow fork (V)             |

### Child timeout

Replay: claude:k-stall, codex:R5, codex:R6.

| Surface     | Fact                                          |
| ----------- | --------------------------------------------- |
| Config      | v2 `api.subagentTimeout` (G)                  |
| Config      | workflow watch `idleTimeoutSec` (V; G)        |
| Env         | `KIRO_SUBAGENT_DEADLINE_MS` (idle, 1 h (V; G) |
| Env         | `0` off) (V; G)                               |
| Patch       | 300-turn limit (V; G)                         |
| Unavailable | total wall clock (V; G)                       |

### Hooks in children

Replay: claude:h2-hookblock.

| Surface | Fact                         |
| ------- | ---------------------------- |
| Config  | v2 role-agent hooks fire (V) |
| Patch   | KAS child hooks (V)          |

### Isolation

Replay: codex:R5, codex:R6.

| Surface     | Fact                                |
| ----------- | ----------------------------------- |
| Config      | ACP `cwd` (V; A)                    |
| Patch       | child workspace construction (V; A) |
| Unavailable | per-delegate worktree (V; A)        |

### Event stream

Replay: codex:R1.

| Surface | Fact                              |
| ------- | --------------------------------- |
| CLI     | `--output-format stream-json` (V) |
| CLI     | `acp` (V)                         |

## Kimchi

### Parent model

Replay: codex:O.

| Surface     | Fact                                   |
| ----------- | -------------------------------------- |
| Config      | `defaultModel` / `defaultProvider` (V) |
| CLI         | `--model`, `--provider` (V)            |
| Patch       | ACP factory forwarding (V)             |
| Unavailable | ACP honoring CLI `--model` (V)         |

### Parent effort

Replay: claude:s11-thinking-inherit, codex:R.

| Surface     | Fact                                  |
| ----------- | ------------------------------------- |
| Config      | `defaultThinkingLevel` (V)            |
| CLI         | `--thinking`, `--model …:<level>` (V) |
| Patch       | ACP setter (V)                        |
| Unavailable | ACP effort option (V)                 |

### Child model (`Agent`)

Replay: claude:s1-fg-pins, judge:J1, claude:s10-multimodel.

| Surface     | Fact                                            |
| ----------- | ----------------------------------------------- |
| Config      | tool `model` param (V)                          |
| Config      | `modelRoles` (no effect in `-p`) (V)            |
| Patch       | tool path must read frontmatter `models[0]` (V) |
| Unavailable | frontmatter `model` (ignored (V)                |
| Unavailable | default = parent's) (V)                         |

### Child effort (`Agent`)

Replay: claude:s11-thinking-inherit, claude:s1-fg-pins.

| Surface     | Fact                                                 |
| ----------- | ---------------------------------------------------- |
| Config      | tool `thinking` (V)                                  |
| Config      | persona / frontmatter `thinking` (V)                 |
| Unavailable | inheriting parent level (child default `medium`) (V) |
| Unavailable | bad value → `none` silently (V)                      |

### Workflow step model

Replay: claude:w5-workflow-bg-nomodel.

| Surface     | Fact                                                 |
| ----------- | ---------------------------------------------------- |
| Config      | step `model` (V)                                     |
| Unavailable | bg step without `model` ignores parent `--model` (V) |

### Workflow step effort

Replay: claude:w5-workflow-bg-nomodel, codex:W.

| Surface     | Fact                             |
| ----------- | -------------------------------- |
| Patch       | add field + adapter plumbing (V) |
| Unavailable | not settable (V)                 |

### System / extra prompt

Replay: codex:S.

| Surface     | Fact                                             |
| ----------- | ------------------------------------------------ |
| Config      | `APPEND_SYSTEM.md` (V)                           |
| Config      | ACP `_meta["kimchi.dev"].appendSystemPrompt` (V) |
| Config      | agent `.md` body + `prompt_mode` (V)             |
| CLI         | `--append-system-prompt` (V)                     |
| Patch       | prompt-enrichment ownership (V)                  |
| Unavailable | `--system-prompt` / `SYSTEM.md` (no effect) (V)  |
| Unavailable | per-call `Agent` system prompt (V)               |
| Unavailable | parent text into replace-mode children (V)       |

### Child tools allow/deny

Replay: claude:s1-fg-pins.

| Surface     | Fact                                                                          |
| ----------- | ----------------------------------------------------------------------------- |
| Config      | persona / frontmatter `tools`, `disallowed_tools`, `extensions`, `skills` (V) |
| Config      | `isolated` (V)                                                                |
| Unavailable | Kimchi built-ins (web, todos, LSP, MCP) in children (V)                       |

### Parent tools allow/deny

Replay: codex:Q.

| Surface | Fact                               |
| ------- | ---------------------------------- |
| Config  | `permissions.json` allow/deny (V)  |
| Config  | SDK tools (V)                      |
| CLI     | `--tools` (V)                      |
| CLI     | `--allow-tool` / `--deny-tool` (V) |

### Parent permissions

Replay: claude:s9-perm-default, codex:Q.

| Surface | Fact                                                     |
| ------- | -------------------------------------------------------- |
| Config  | `permissions.json` `defaultMode` (V)                     |
| Config  | ACP `permissions-mode` (V)                               |
| CLI     | `--plan`, `--auto`, `--yolo`, `--permissions-config` (V) |
| Env     | `KIMCHI_PERMISSIONS` (V)                                 |

### Child permissions (`Agent`)

Replay: codex:Q, claude:s9-perm-yolo.

| Surface     | Fact                                                   |
| ----------- | ------------------------------------------------------ |
| Patch       | add permissions ext to `agent-runner` factory list (V) |
| Unavailable | gating child tools (child ungated) (V)                 |

### Workflow background permissions

Replay: codex:W.

| Surface     | Fact                           |
| ----------- | ------------------------------ |
| Env         | forced `yolo` (V)              |
| Patch       | `backgroundSession` policy (V) |
| Unavailable | per-step setting (V)           |

### Background selection

Replay: claude:s3b-rpc-default-bg, codex:N.

| Surface     | Fact                                   |
| ----------- | -------------------------------------- |
| Config      | persona / tool `run_in_background` (V) |
| Config      | workflow `background` (V)              |
| CLI         | `-p` → foreground (V)                  |
| Unavailable | persona pins in `-p` (V)               |

### Background concurrency

Replay: claude:s2-rpc-bg.

| Surface     | Fact                              |
| ----------- | --------------------------------- |
| Config      | `agents.json` `maxConcurrent` (V) |
| CLI         | `/agents` (V)                     |
| Unavailable | foreground cap (V)                |
| Unavailable | cross-process cap (V)             |

### Workflow concurrency

Replay: codex:W.

| Surface | Fact                 |
| ------- | -------------------- |
| Config  | `maxConcurrency` (A) |
| Config  | `.foreach` 1 (A)     |

### Depth

Replay: claude:s1-fg-pins, claude:w1-workflow.

| Surface     | Fact                                 |
| ----------- | ------------------------------------ |
| Patch       | `EXCLUDED_TOOL_NAMES` (V)            |
| Unavailable | native > 1 (workflow bg step = 2 (V) |
| Unavailable | `bash` unbounded) (V)                |

### Enable/disable `Agent` family

Replay: claude:inv.

| Surface     | Fact                                        |
| ----------- | ------------------------------------------- |
| Config      | `resources` `extensions.agents` (V)         |
| Config      | persona `enabled` (V)                       |
| CLI         | `kimchi resources disable` (V)              |
| Env         | `KIMCHI_ENABLE_RESOURCES` (enable only) (V) |
| Patch       | drop factory in `cli.ts` (V)                |
| Unavailable | one tool alone (V)                          |
| Unavailable | `--no-extensions` (V)                       |

### Enable/disable workflows

Replay: claude:inv.

| Surface | Fact                                              |
| ------- | ------------------------------------------------- |
| Config  | `ai.kimchi.extensions.workflows` → `packages` (V) |
| CLI     | `-e` (V)                                          |
| CLI     | `--no-extensions` (V)                             |

### Enable/disable cloud dispatch

Replay: claude:inv.

| Surface | Fact                        |
| ------- | --------------------------- |
| Config  | `extensions.remote-run` (V) |
| CLI     | absent in `-p` (V)          |
| Env     | `KIMCHI_REMOTE_RUN=off` (V) |

### Enable `daemon`

Replay: claude:inv.

| Surface | Fact                                 |
| ------- | ------------------------------------ |
| CLI     | `--enable-experimental-features` (V) |

### Steer

Replay: claude:s2-rpc-bg, codex:R.

| Surface     | Fact                            |
| ----------- | ------------------------------- |
| Config      | `steer_subagent` (bg child) (V) |
| Config      | RPC `steer` (V)                 |
| Config      | ACP steering (V)                |
| Patch       | workflow child bridge (V)       |
| Unavailable | fg child (V)                    |
| Unavailable | workflow bg child (V)           |
| Unavailable | daemon (V)                      |

### Cancel

Replay: claude:s4-rpc-abort-fg, claude:s5-rpc-abort-bg,
claude:w3b-workflow-cancel-late.

| Surface     | Fact                                                                  |
| ----------- | --------------------------------------------------------------------- |
| Config      | RPC `abort` / ACP `session/cancel` (parent + fg children, not bg) (V) |
| CLI         | `/workflow cancel` (direct child), Ctrl+X (newest bg), signals (V)    |
| Unavailable | model-callable `Agent` cancel (V)                                     |

### Mid-run model / effort

Replay: codex:R.

| Surface     | Fact                                                          |
| ----------- | ------------------------------------------------------------- |
| Config      | RPC `set_model`, `set_thinking_level` (parent, next turn) (V) |
| Patch       | per-child setter (V)                                          |
| Unavailable | child after spawn (V)                                         |
| Unavailable | ACP effort (V)                                                |
| Unavailable | ACP model while busy (V)                                      |

### Resume / fork

Replay: codex:N, codex:P, codex:B, judge:J3.

| Surface     | Fact                                                                    |
| ----------- | ----------------------------------------------------------------------- |
| Config      | `resume_subagent` (V)                                                   |
| Config      | Ferment continuation cap: [lifecycle](lifecycle.md#resume-and-fork) (A) |
| Config      | RPC `fork` / `clone` (A)                                                |
| Config      | ACP load (A)                                                            |
| CLI         | `--continue`, `--resume`, `/workflow resume` (A)                        |
| Unavailable | native child fork (A)                                                   |
| Unavailable | ACP fork (A)                                                            |

### Turns / timeout / tokens

Replay: codex:N, judge:J4.

| Surface     | Fact                                                                          |
| ----------- | ----------------------------------------------------------------------------- |
| Config      | tool `max_turns`, `max_duration` (default 900 s), `token_budget` (A; 900 s V) |
| Config      | `agents.json` `defaultMaxTurns`, `graceTurns` (A; 900 s V)                    |
| Config      | persona turns win (A; 900 s V)                                                |
| Config      | workflow `maxDurationMs`, `maxTokens` (A; 900 s V)                            |
| CLI         | `/agents` (A; 900 s V)                                                        |
| Patch       | 120 s idle constant (A; 900 s V)                                              |
| Unavailable | input-token budget (A; 900 s V)                                               |

### Isolation

Replay: claude:s1-fg-pins.

| Surface     | Fact                                     |
| ----------- | ---------------------------------------- |
| Config      | `isolation: worktree` parsed, unused (V) |
| Patch       | wire to worktree / cwd (V)               |
| Unavailable | effective native isolation (V)           |
