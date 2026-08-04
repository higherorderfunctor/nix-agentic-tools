# F10 — the full builtin tool interface (Kiro CLI v3 / KAS engine)

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

All byte offsets below are into the pretty-printed bundle at
`~/.local/share/kiro-cli/kas/<KASID>/node_modules/@kiro/agent/dist/server/acp-server.js`
and were read with bounded `head -c $((OFF+N)) | tail -c M` windows. Offsets are
release-specific; anchor on the quoted identifiers, not the numbers.

## 1. The question

Enumerate every builtin tool the v3 engine registers per session, with schema,
defaults, limits, truncation, and error shape; then settle (a) whether tool
calls in one model response execute in parallel and under what bound, and (b)
whether the shell tool has an async/detached surface usable across turns.
"Settled" = each tool traced to a construction site inside the session
`getTools()` assembly, and (a)/(b) traced to the executing code path, not a
description string.

## 2. What is already known (corpus)

- `records/workflow-surface.md` (~579-690): the six workflow tools
  (`run_workflow`, `inspect_workflow`, `update_workflow`, `validate_workflow`,
  `send_message` in chat pool; `validate_workflow` in spec pool;
  `save_workflow_definition`) appear only when `workflowsEnabled` is true; no
  partial mode. Their schemas are settled there — NOT re-derived here.
- `records/concurrency-and-nesting.md` R-concurrency-1/2:
  `MAX_CONCURRENT_SUBAGENTS = 5`, per-execution `Sema`, nesting multiplies.
  That is SUB-EXECUTION concurrency, not tool-call concurrency — this file
  settles the tool-call side.
- Corpus settled: dispatched sub-executions always take the first-turn branch;
  builtin mode ids load-then-filter; hooks approval path separate (C-4).
- Vendor docs `private/kiro-v3-docs.md`: no per-tool schema claims found worth
  citing; treated as input only.

## 3. The interface, fully enumerated

### 3.1 Registration architecture

Master export list: `// src/tools/index.ts` (offset 17596569) names every tool
class. The per-session pool assembly is the `getTools:` closure inside
`createACPWorkspaceConnection` (`// src/acp/acp-workspace-connection.ts`,
around offset 19303469). It returns SIX pools, all filtered through
`filterDenied` (policy capability deny):

| Pool | Fed to | Contents (summary) |
| --- | --- | --- |
| `chat` | plain chat turns | coreTools + client-capability tools + MCP tools + `todo_list` + `update_session_information` (+ gated: tool_search, code, introspect, workflowChatTools, subagent tool, disclose_context, kiro_powers, knowledge, createHook) |
| `customAgent` | dispatched sub-agents (CustomAgentGraph `getCustomAgentTools()`) | chatTools + `subagent_response` + `report_progress` (+ `user_input` iff `workspace.isDelegatedExecution()`) (+ `switch_to_execution` iff plan policy explicitly allows) + workflowCustomAgentTools + per-agent `subagent_<id>` tools + c2s tools |
| `specAgent` | spec-mode agents | coreTools + spec tools + client tools + MCP + `invoke_sub_agent` (spec mode) |
| `specOrchestrator` | spec conversational entry | spec tools + spec powers + disclose_context + `get_diagnostics` + `invoke_sub_agent` |
| `taskOrchestrator` | task execution | `mergeTools(getTaskTools(), specOrchestratorTools)` |
| `subAgent` | coordination-only bundle | `report_progress` + `subagent_response` + per-agent invocation tools |

**Two implementations exist for every core IO tool** — an ACP-delegating
variant (`src/tools/*.ts`, origin `"acp"`, does IO through the ACP client
connection) and a node-local variant (`src/tools/default/*.ts`, origin
`"default"`). Both are constructed every `getTools()` call and deduplicated by
id via `mergeTools(first, second)` where **second wins**:

```
coreTools = hasClientIOTools ? mergeTools(builtInTools, acpTools)
                             : mergeTools(acpTools, builtInTools);
coreTools = mergeTools(coreTools, searchTools);      // search providers
coreTools = mergeTools(coreTools, filteredClientTools); // client tools win last
```

`hasClientIOTools` = client-registered tools include any of
`CORE_IO_TOOL_IDS = {execute_bash, read_file, fs_write, str_replace, grep_search, file_search}`
(Set at offset 19293313). **This gate is not wire-controllable.** `clientTools`
is a KiroAgent CONSTRUCTOR option
(`this.clientTools = options.clientTools ?? []`, sole write at offset
20266372) — never read from session/new params, initialize params, or
clientMeta; the clientMeta route gates only the fixed client-capability
catalog of 3.2 (no core IO ids), feeding a different variable. Both real
KiroAgent constructions in the bundle — startStdio (20727326) and
startWebSocket (20728280) — omit `clientTools`, and the Rust launcher spawns
the engine with `--transport=stdio --auth=acp-callback`, so `clientTools = []`
and `hasClientIOTools = false` statically for the shipped TUI AND for every
external ACP client. The SCHEMA THE MODEL SEES for `execute_bash`,
`read_file`, etc. is therefore ALWAYS the default variant:
`coreTools = mergeTools(acpTools, builtInTools)` (builtins evict colliding ACP
variants), and search providers are Node-based with origin `"default"`.
`clientTools` is an in-process-embedder injection point (sibling options
`fileSystem`/`terminalManager`), unreachable from the shipped CLI by any
activation lever.

Tool lookup at dispatch: `tools.find(t => t.id === name) ?? tools.find(t => t.displayName === name)`
(processChunkStream) — default-variant `displayName`s `bash`, `read`, `glob`,
`grep`, `task` resolve as aliases.

### 3.2 Tool inventory

#### Core IO — node-local ("default") variants (always win in the shipped CLI — `clientTools` is statically empty, see 3.1)

| id (displayName) | schema | limits / behavior |
| --- | --- | --- |
| `execute_bash` (`bash`) | `command` req; `cwd` opt (req when multi-root); `run_in_background` bool default false; `timeout` ms opt | timeout default 120000, clamped to max 1800000 (30 min); output sanitized (hidden unicode stripped) then truncated to 30000 chars, head 80% / tail 20% with `... [N characters truncated — output exceeded 30000 char limit] ...`; timeout returns partial output; long-running pattern detection REJECTS with warning (NO `ignoreWarning` bypass in this variant); `run_in_background` on POSIX appends ` &` to the command, non-POSIX passes `background: true` to `runBashCommand` |
| `read_file` (`read`) | `path` req; `offset` (0-indexed) opt; `limit` opt (default 2000 lines) | text max 250KB or 2000 lines; images (png/jpg/jpeg/gif/webp) max 10MB base64; description tells model "PARALLEL READING: call this tool multiple times in a single response" |
| `fs_write` | `path`, `text` req | parent dirs auto-created; per-URI FileLock serializes same-file writes |
| `str_replace` | `path`, `oldStr`, `newStr` req; `replace_all` bool opt | exact-match, multi-match fails unless `replace_all`; CRLF normalization fallback |
| `grep_search` (`grep`) | `query` req; `caseSensitive` (default false), `file_type`, `includePattern`, `excludePattern`, `context`, `context_before`, `context_after`, `limit` (default 50), `offset` opt | GREP_MAX_RESULT_COUNT2=100, GREP_MAX_CONTEXT_CHARS2=200 per line, GREP_MAX_TOTAL_OUTPUT_SIZE2=10000 chars |
| `file_search` (`glob`) | glob `pattern`-style query | FILE_MAX_RESULT_COUNT2=200, newest-first, respects .gitignore, brace expansion |
| `web_fetch` | `url` req; `mode` enum full/truncated/selective (default truncated); `searchPhrase` (selective) | truncated=8KB, full=10MB, ≤5 redirects, non-HTTPS redirect refused, HTTP auto-upgraded |

#### Core IO — ACP-delegating variants (reachable only from an in-process embedder injecting `clientTools` — see 3.1; IO via client connection)

| id | schema differences vs default | limits |
| --- | --- | --- |
| `execute_bash` / `execute_pwsh` (Windows shell) | `command`, `cwd`, `ignoreWarning` bool, `timeout` ms, `warning` str (PBT-only). NO `run_in_background`. Description: "Run one command per invocation. Command lists (&&, \|\|, ;) are not supported; invoke the tool multiple times in the same turn instead" | timeout DEFAULT INFINITE (`configuredTimeout: void 0` in factory); long-running detection rejectable via `ignoreWarning: true`; output redacted via `redactSensitiveEnvVars` then `Exit Code: N` appended; no unconditional cap in the handle path (`truncateBashOutput`/30k lives only in the default variant), BUT `withSyncToolMessage` routes successful `execute_bash` messages through the large-output handler (threshold 30000 chars; `execute_pwsh` NOT allowlisted): when the external ACP client enables `settings.largeToolOutputHandler.enabled` in clientMeta at initialize or session/new, any successful ≥30000-char output is written to a session file and replaced in context by a 500+500-char head/tail reference — a HARDER truncation than the default variant's 30k cap; gate defaults OFF, failed commands always bypass it, and the engine requests no ACP `outputByteLimit`, so client-side collection truncation stays possible and invisible to the engine |
| `read_file` | `path`, `start_line` (default 1), `end_line` (default -1), `explanation` req | fs-layer MAX_READ_SIZE = 10MB |
| `read_files` | `paths` array req, `start_line`/`end_line` (negative = from EOF), `explanation` | ACP pool only — no default-variant counterpart |
| `fs_write` | `path`, `text`; description mentions WRITE_LIMIT = "50 lines" → then use `fs_append` | streaming preview via `onParameterChunk("text", 500)` |
| `fs_append` | `path`, `text`; file MUST exist | ACP pool only |
| `str_replace` | `path`, `oldStr`, `newStr`; NO `replace_all`; description: "PARALLEL TOOL CALLS: … invoke the 'str_replace' tool multiple times simultaneously in the same turn … Prioritize calling this tool in parallel whenever possible" | fails on multiple matches |
| `delete_file` | `explanation`, `targetFile` | ACP pool only; in ACP mode `promptUser` auto-accepts (approval still consulted) |
| `list_directory` | `path` (~ ok), `explanation`, `depth` opt (default 1) | `ls -la`-style long format |
| `file_search` | `explanation` (fuzzy name), `query` regex, `excludePattern`, `includeIgnoredFiles` ("yes"/"no" STRING) | FILE_MAX_RESULT_COUNT = 10 |
| `grep_search` | `query`, `caseSensitive`, `excludePattern`, `explanation`, `includePattern` — no context/limit/offset params | 100 results, 200 chars/line, 10000 chars total |
| `web_fetch` | `url` (HTTPS only, no query params/fragments allowed), `mode` full/truncated/selective/**rendered** (browser engine, retry-only), `searchPhrase` | same 8KB/10MB |

#### Process management family (the async shell surface — see 3.4)

| id | schema | notes |
| --- | --- | --- |
| `control_bash_process` / `control_pwsh_process` | `action` enum start/stop; `command` (start); `cwd` opt; `terminalId` (stop) | start returns `{terminalId, isReused}` immediately; same command+cwd reuses a running process; stopped id NOT restartable (new start → new id) |
| `get_process_output` | `terminalId` req; `lines` opt int>0 | description claims "defaults to 100 lines" but the implementation returns the FULL buffer when `lines` omitted (`if (lines && lines > 0) slice(-lines)`) — doc drift, offset 18652591 region |
| `list_processes` | `{}` | returns `{terminalId, command, path, status: running\|stopped\|unknown}` per process |

#### Session/meta tools (chat pool, unconditional)

| id | schema | notes |
| --- | --- | --- |
| `todo_list` (`task`) | `command` enum create/complete/add/remove/list; `tasks[]{task_description, details}`, `task_list_description`, `completed_task_ids[]`, `context_update`, `modified_files[]`, `new_tasks[]`, `new_description`, `remove_task_ids[]` | lenient validation schema coerces records→arrays, aliases description/title/name/task → task_description; single session-scoped instance shared into workspace config |
| `update_session_information` | `title` ≤100, `description` ≤500, `status` enum in_progress/waiting_on_user/completed/idle — all optional | pure emit; no approval |

#### Gated chat-pool tools (gate → tool)

| Gate | Tool(s) |
| --- | --- |
| `isSettingEnabled(settings,"toolSearch")` | `tool_search` — `tool_id` (server_name::tool_name), `query`, `max_results` (default 5); loads deferred MCP tools; env `KIRO_TOOL_SEARCH_THRESHOLD` (default 1.5) |
| `isSettingEnabled(settings,"codeIntelligence")` | `code` — op enum: search_symbols, lookup_symbols (max 10), get_document_symbols, generate_codebase_overview, search_codebase_map, pattern_search, pattern_rewrite (dry-run default), goto_definition, find_references, rename_symbol, format_code, hover, completion, diagnostics (LSP ops take file_path/row/column 1-based) |
| `isSettingEnabled(settings,"knowledge")` && store resolvable | `knowledge` — `command` enum show/add/remove/clear/search/update/status/cancel + name/value/context_id/path/query/limit/offset/snippet_length/sort_by/file_type |
| `isSettingEnabled(settings,"subagentOrchestration")` | `orchestrate_sub_agent` (stages with name/role/prompt_template/depends_on, `{task}` interpolation) REPLACES `invoke_sub_agent` in chat pool |
| else (registry present) | `invoke_sub_agent` — `name`, `prompt`, `explanation` req; `preset`, `contextFiles[]{path,startLine,endLine}` opt; + `inlineAgent` field iff `isSettingEnabled(settings,"inlineAgents")` |
| `options.introspectArtifactsPath` | `introspect` — kiro.dev self-docs QA (delegates to web_fetch/read_file) |
| `progressiveContextManager` present | `disclose_context` — `name` (exact skill/steering name); description dynamically lists activatable items; skills denied by policy filtered out |
| `powersManager` present | `kiro_powers` — `action` enum list/activate/use/readSteering/configure; `powerName`, `serverName`, `toolName`, `arguments` record, `steeringFile` |
| `clientMeta.hooks.v2 === true` && primaryCwd | `createHook` — `id`, `name`, `description`, `trigger` (v2 trigger names), `matcher` regex, `actionType` command/agent, `command`/`prompt`, `timeout` s (default 60) |
| `workflowsEnabled` | `options.workflowChatTools` — the six workflow tools (corpus workflow-surface.md) |
| `isFeatureEnabled("c2s")` | `code_to_spec` + `c2s_*` query/view tools (customAgent + spec pools) |

#### Subagent coordination + per-agent tools

- `report_progress` — `message` (1-2 sentences); no approval; emit-only.
- `subagent_response` — `response` req (may be empty), `files[]{path,startLine,endLine}`; REQUIRED final action of a dispatched sub-agent.
- `subagent_<agentId>` (displayName `subagent/<id>`) — one per registry agent
  via `createSubagentInvocationTools`; FREEFORM_SCHEMA `{prompt, explanation}`
  or STRUCTURED_SCHEMA (`user_instruction_verbatim`…) for ids in
  {planner, coder, asbx-planner, asbx-coder, semantic_reviewer}; self-invocation
  excluded via `excludeAgentId` (ticket P431519364).
- `invoke_sub_agent` depth check: rejects at `MAX_SUB_EXECUTION_DEPTH` with
  `Sub-agent nesting depth limit (N) exceeded` tool-error (no throw).
- Builtin subagent allowlist set: context-gatherer, general-task-execution,
  custom-agent-creator, spec-task-execution, feature-design-first-workflow,
  feature-requirements-first-workflow, bugfix-workflow.

#### Spec/task pools

- `getSpecTools`: `user_input`, `update_pbt_status`, `prework`,
  `analyze_requirements`, `verify_requirements` (registered unconditionally,
  graceful "engine not available" outside workflow) (+ c2s tools).
  Empty workspace → only `user_input` + `prework`.
- `getTaskTools`: `task_list`, `task_get`, `task_update`, `user_input`.
- `user_input` — `question` req (markdown bold), `options[]` (string or
  {title, description, recommended, subOptions[], subOptionsLabel}), `reason`
  enum ["general-question"], `metadata.featureName`. NOT in plain chat pool;
  in customAgent pool only when `isDelegatedExecution()`.
- `switch_to_execution` — `plan` (1..100000 chars, non-blank); sets
  `execution.requestedExecutionPlan`; in customAgent pool ONLY when the active
  plan tool-policy explicitly allowlists it.

#### Client-capability tools (engine-side stubs calling the CLIENT)

`clientToolDefinitions` (offset 814735): each enabled by `clientMeta[metaKey] === true`,
invoked over `_kiro/tool/<id>` extension method to the client:
`semantic_rename` (metaKey `clientToolSemanticRename`),
`smart_relocate` (`clientToolSmartRelocate`),
`get_diagnostics` (`clientToolGetDiagnostics`). FILE_MODIFYING set =
{semantic_rename}. `get_diagnostics` is additionally injected into the spec
orchestrator pool.

### 3.3 (a) Parallel tool calls — YES, eager-start, sequential join, no cap

`processChunkStream` (`// src/graphs/process-chunk-stream.ts`, offset 14084507)
is the single dispatch site for every graph (chat, custom-agent, spec):

1. As the model's stream yields a `tool_call_chunk` with id+name, the engine
   immediately invokes `tool2.call(state, toolCallId, messageId, inputStream)`
   — a promise pushed into `toolCalls[]`, NOT awaited. Each tool gets its own
   `AsyncStream` of argument chunks, closed at that call's `stop` marker.
2. `SyncTool.call` consumes its input stream, Zod-parses (with one number-
   coercion retry), runs the PreToolUse gate, then `handle()`. So tool N's
   handle starts the moment its args finish streaming — while tool N+1's args
   are still arriving and while tool N-1 may still be executing. Genuine
   wall-clock overlap, engine-driven.
3. After the model stream ends, results are joined IN ORDER:
   `for (const toolCallRes of toolCalls) { await abortable(toolCallRes, signal); … }`
   — state/context merges are sequential and deterministic in emission order.
4. Each call receives the state snapshot at its dispatch; same-block tools do
   NOT see each other's effects (Claude-parallel-block semantics). Same-file
   writes serialize only via per-URI FileLock.
5. **No concurrency bound.** No semaphore, no limit constant in this path.
   Positive controls by the same method: `MAX_CONCURRENT_SUBAGENTS` (5) and
   `new Sema(` are found for the sub-execution path; `Promise.all` is absent
   from the join. The only brake: `shouldBlockToolInvocation()` →
   `waitForYieldRelease()` pauses STARTING new calls while a user-interaction
   yield is held (e.g. an approval prompt).
6. Arg-truncation error: if the stream ends with an unclosed tool receiving
   args, ALL active streams get `OutputTruncatedError` ("model output was
   truncated") and every in-flight call errors.
7. Whether parallelism happens is model-elected; the engine merely allows it —
   and the default `read_file`/`file_search` and ACP `str_replace`/
   `execute_bash` descriptions actively instruct the model to parallelize.

### 3.4 (b) Shell async surface — EXISTS, TWO tiers, loudly:

**Tier 1 — managed background processes: YES, real, cross-turn, but
clientMeta-gated.** `control_bash_process` (`action:"start"`) returns
`{terminalId, isReused}` immediately; the process is held by the session-scoped
`ACPBackgroundProcessManager` (offset 18652591) in in-memory Maps keyed by
`term_<ts>_<rand>`. `get_process_output(terminalId, lines?)` re-reads
stdout+stderr on ANY later turn via the client terminal handle's
`currentOutput()`; `list_processes` shows status; `control_bash_process`
`action:"stop"` kills+releases. A started process survives the turn that
started it and every later turn until stopped or session teardown — exactly
the F20 monitor pattern. **Gate:** the three tools enter the pool only when
`includeControlProcess = clientMeta?.backgroundProcesses === true`
(initialize-time clientMeta), AND execution is client-hosted: startProcess
calls `connection.createTerminal` (ACP `terminal/create` on the CLIENT), so the
client must implement the terminal capability. The shipped 2.15.1 Rust chat
binary implements `terminal/create` (2 string hits) but contains ZERO hits for
`backgroundProcesses` / `background_processes` / `BackgroundProcesses` — so the
stock TUI appears unable to enable this surface; an external ACP client
declaring `backgroundProcesses: true` gets it for free.

**Tier 2 — `run_in_background` on the default `execute_bash`: fire-and-forget
only.** POSIX: the engine literally appends ` &` to the command string;
non-POSIX passes `background: true` to `runBashCommand`. NO handle is
returned, output after return is not retrievable, exit cannot be observed.
It is NOT a monitor primitive.

Timeouts: default variant 120 s default / 30 min clamp, returns partial output
on expiry; ACP variant default infinite (`configuredTimeout: void 0` in both
`createAcpExecuteBashTool` and the workspace factory), `timedOut` detected as
`code === undefined && output.includes("timed out")`.

### 3.5 Permission/approval gating map (F18 cross-ref)

`acpToolApproval({operationId, toolId, path|command, toolTags, …})` →
`createAcpToolApproval` (policySession pre-check, then ACP
`session/request_permission`, decisions allow/reject/always-*; reject reason
"The user rejected this tool call."). Consulted by: `read_file`, `read_files`,
`fs_write`, `fs_append`, `str_replace`, `delete_file`, `list_directory`,
`file_search` (once per workspace folder), `grep_search`, `web_fetch`,
`execute_bash` (via `runEditApprovalLoop` — supports user EDITING the command;
edited command noted to the model), `control_bash_process`,
`invoke_sub_agent`/`subagent_*` (title `Sub-agent: <id>`, path = agent id),
`orchestrate_sub_agent`, `disclose_context`, `kiro_powers`, `code` (mutating
ops), `update_pbt_status`, client-capability tools. NOT consulted (no approval
call in handle): `get_process_output`, `list_processes`, `todo_list`,
`update_session_information`, `switch_to_execution`, `report_progress`,
`subagent_response`, `tool_search`, `introspect`, `user_input`, `createHook`
(writes hook file directly after id sanitization). Additionally
`validateCwdAccess` runs approval for out-of-workspace `cwd`, and
`filterDenied` strips capability-denied tools from every pool unless the
policy file had a fatal parse error (then NOTHING is filtered — fail-open,
offset ~19315600).

## 4. Activation drivers

| Lever | Who can pull it |
| --- | --- |
| Any builtin tool RUN | model-elected only — there is no user-typed, hook, or ACP method that directly invokes a builtin tool; external ACP clients cannot call them (tools are model-facing; extensionMethods don't include tool invocation) |
| Parallel multi-tool block | model-elected; engine permits unboundedly; tool descriptions (agent-system-prompt-driven) actively solicit it |
| `control_*_process` family presence | external-ACP-client only (`clientMeta.backgroundProcesses: true` at initialize) |
| Default vs ACP core-IO schema variant | NO lever — not wire-controllable; `clientTools` is a KiroAgent constructor option omitted by both shipped constructions, so the TUI and every external ACP client statically get the default variants; in-process embedder only (see 3.1) |
| `tool_search`, `code`, `knowledge`, `orchestrate_sub_agent`, `inlineAgent` field | external-ACP-client via initialize-time `settings` (`isSettingEnabled` — `{enabled: true}` objects) |
| Large-output handler on ACP `execute_bash` (500+500 head/tail file reference) | external-ACP-client only, via clientMeta `settings.largeToolOutputHandler.enabled` at initialize or session/new; default off |
| `createHook` | external-ACP-client (`clientMeta.hooks.v2 === true`) |
| `semantic_rename`/`smart_relocate`/`get_diagnostics` | external-ACP-client (`clientToolSemanticRename` etc.) |
| workflow tools in pools | workflowsEnabled (corpus: persisted metadata / _kiro/workflow/new) — workflow-step-driven sessions then carry them |
| `user_input`, `switch_to_execution`, spec/task tools | pool selection = execution type (workflow-step-driven / subagent dispatch), not user choice |
| `disclose_context` targets | user-provisioned skills/steering on disk; activation itself model-elected (description says matching skill is BLOCKING requirement — agent-system-prompt-driven) |
| Tool approval / command edit | user-typed (permission prompt; execute_bash supports user-edited command replacement) |
| `web_fetch` removal | enterprise governance (`webToolsDisabled`) or sandbox+`PRINCIPAL_TYPE=MIDWAY_USER` |

## 5. Fixture design

- **F10-a (parallel proof, no live model needed for the mechanism):** the
  mechanism is code-settled; the model-election half needs one live session:
  prompt "read files A and B" with a client that logs
  `session/update` tool_call timestamps; PASS = second tool_call begins before
  first tool_call_update completes. Fixture SPEC only (model call).
- **F10-b (async shell, no model):** ACP-direct client (reuse the Mode-F
  harness): initialize with `clientMeta: {backgroundProcesses: true}` and
  terminal capability implemented; session/new; verify via
  `_kiro/session/context` or tools listing notification
  (`ToolsDidChangeMethod`) that the SHELL tag set includes control tools —
  discriminator: `buildSessionToolsListing` emits tag rows only, so instead
  drive one scripted prompt that calls `list_processes` (cheapest model call)
  OR statically: assert `includeControlProcess` by grepping the session's
  advertised tool list if the client requests it. Negative arm: omit the
  clientMeta key, assert the three ids absent. The no-model variant: bundle
  grep positive controls (`control_bash_process` present,
  `clientMeta?.backgroundProcesses` consumer at the assembly site) — already
  done here.
- **F10-c (get_process_output default-lines drift, no model):** unit-level:
  `getProcessOutput` with `lines` undefined returns full buffer — observable
  only through a live process; fixture SPEC: start `seq 1 500` via
  control tool, call get_process_output without `lines`, PASS = 500 lines
  returned (description said 100).
- **F10-d (truncation):** node-local execute_bash `printf 'x%.0s' {1..40000}`
  → PASS = output contains `characters truncated — output exceeded 30000`.
  Any shipped session qualifies — the pool always resolves to the default
  variant (see 3.1).

## 6. Cross-interactions

- **Compaction:** every tool result flows into `SUMMARIZATION_DETECTION`
  projected-usage math (tool responses since last bot message are estimated) —
  a giant grep/read in a parallel block can trigger summarize (>80%) or
  truncate (>95%) immediately after the join. Corpus C-9 (sub-execution
  compaction truncating parent) compounds with parallel tool spam.
- **Iteration limit:** a parallel block of N tools costs ONE model invocation
  against the 300-limit — parallelism is strictly cheaper than sequential.
- **Steering:** file reads/writes feed `addSteeringTriggerPath` →
  fileMatch steering injection next invoke; `injectPostToolSteering` runs after
  the join, once per block, not per tool.
- **Hooks:** PreToolUse gate runs inside each tool's `call` (so parallel tools
  each fire it); post-file hooks fire per fileAccess during the SEQUENTIAL
  join, order = tool emission order.
- **Policy fail-open:** `filterDenied` skips filtering entirely on fatal
  policy parse error — a malformed permissions.yaml silently un-denies every
  capability-denied tool (pool level; per-call approval still runs).
- **MCP name collisions:** `mergeTools` dedupes by id at each stage; an MCP
  tool named `execute_bash` silently replaces the builtin (client tools are
  the last merge, but that route is reachable only from an in-process
  embedder — see 3.1).
- **`todo_list` singleton:** one instance is shared via workspace config into
  graph internals — parallel `todo_list` calls in one block mutate shared
  session state (last-writer-wins per command semantics).
- **Workflow tools:** enablement is per-session (`workflowsEnabled`), never
  per-pool-partial (corpus workflow-surface.md); `send_message` rides the same
  gate — no builtin-tool interaction beyond pool membership.

## Corrections from adversarial verification

1. **Default-vs-ACP core-IO schema variant: SETTLED as DEFAULT, not
   client-dependent.** This file previously framed the schema the model sees
   for `execute_bash`/`read_file` (and the other four core IO ids) as
   depending on what the ACP client registered, leaving the shipped-TUI answer
   open. Refuted: `hasClientIOTools` is not wire-controllable. `clientTools`
   is a KiroAgent CONSTRUCTOR option
   (`this.clientTools = options.clientTools ?? []`, sole write at offset
   20266372), never read from session/new params, initialize params, or
   clientMeta; the clientMeta route gates only the fixed catalog
   (`semantic_rename`/`smart_relocate`/`get_diagnostics` — no core IO ids)
   feeding a different variable. Evidence: `grep -boF clientTools` on the
   2.15.1-e20633b4 bundle → 10 occurrences, all classified (destructure+use in
   `createACPWorkspaceConnection` 19290901-19294073 incl. `CORE_IO_TOOL_IDS`
   Set at 19293313 and the `hasClientIOTools = clientTools.some(...)` check;
   class field 20248570; constructor write 20266372; single call site
   `clientTools: this.clientTools` at 20480303 inside the only call of
   `createACPWorkspaceConnection` — def 19290741, call 20480123).
   `grep -boF "new KiroAgent"` → 3 hits: 18578955 is a
   `KiroAgentWorkflowSessionDriver` prefix false-positive; the byte windows at
   20727326 (startStdio) and 20728280 (startWebSocket) show full options
   objects with NO `clientTools` key, and the Rust launcher spawns the engine
   with `--transport=stdio --auth=acp-callback` (settled). So
   `clientTools = []` and `hasClientIOTools = false` statically for the TUI
   AND every external ACP client;
   `coreTools = mergeTools(acpTools, builtInTools)` and the builtins evict
   colliding ACP variants. No live capture needed. Corrected in 3.1, both 3.2
   core-IO headers, the activation-drivers table, fixture F10-d, and the MCP
   name-collision bullet. Corpus grep for
   `hasClientIOTools`/`clientTools`: zero hits (new finding, not
   re-derivation). [KASID
   2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc]

2. **ACP-variant `execute_bash` output is NOT categorically un-truncated.**
   This file previously stated "no 30k truncation in this variant's handle
   path", implying only the default variant caps output. Refuted: the handle
   path itself applies no unconditional cap (`grep -boF truncateBashOutput` →
   only 18745791/18746553, both in the default module
   src/tools/default/execute-bash.ts with `MAX_BASH_OUTPUT_CHARS = 3e4` at
   18740525, and the ACP handle at ~17632490 passes raw output — that part
   reproduces), but a downstream cap EXISTS: `withSyncToolMessage` (17118207)
   calls `processToolOutput` (12844089, src/utils/large-output-handler.ts)
   with `BASE_THRESHOLD: 3e4` and HANDLED_TOOLS including `execute_bash` — the
   ACP variant's dispatched id (getConfigInternal at 17629569 overrides the
   static id `run_command`). When enabled it replaces any successful
   ≥30000-char `execute_bash` output with a 500+500-char head/tail file
   reference — harder truncation than the default variant's cap. Gate:
   `isFeatureEnabled("largeToolOutputHandler")` — ACPModelConfigProvider is
   registered at 20272411 without an `isFeatureEnabled` option, the
   constructor at 19657693 defaults it to `() => false`, and it is bridged ON
   only by clientMeta settings `{largeToolOutputHandler: {enabled: true}}` at
   initialize (~20294308) or session/new (~20345143; `isSettingEnabled` at
   867793) — so the driver is external-ACP-client only and default-off. Failed
   (non-zero exit) commands skip the handler in BOTH variants; `execute_pwsh`
   is not allowlisted; and the engine never sets ACP `outputByteLimit` (single
   bundle occurrence = zod schema at 481850; `ACPTerminal.runCommand` at
   18661871 passes none), so an ACP client may truncate at collection
   invisibly. Corrected in the 3.2 ACP `execute_bash` row and the
   activation-drivers table.
