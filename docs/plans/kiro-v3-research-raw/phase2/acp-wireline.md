# ACP-W — the complete v3 ACP wire surface, from the bundle

> Verified against: KAS
> 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc
> (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date:
> 2026-07-30.

## 1. The question

Enumerate every method, request, notification, schema, and error the v3 KAS
engine speaks over ACP — both directions — from the dispatch/registration
sites in the bundle, so a client author can implement against it and the
live-probe agent knows exactly what to poke. "Settled" = every name below was
read at its registration or call site (byte offsets given), not inferred.

## 2. What is already known

- `private/kiro-acp-and-launcher-argv.md` §4/4b/5 (measured 2.15.2): handshake
  capability table, auth-callback stall, `modes`=workflows, `session/new`
  result `_meta`, stderr/stdout discipline. Referenced, not re-derived.
- Corpus `records/hooks-io-contract.md` L69-105: the ACP-delegating hook
  binding (client-side hooks) is selected at `initialize` time; details there.
- Corpus `records/workflow-surface.md`: workflow tool/runner internals; it
  does NOT enumerate the ACP method names (verified by grep) — this doc is now
  the ground truth for those.
- Mission brief: "20 `_kiro/workflow/*` methods". **Corrected below (§3.6):
  14 request methods + 9 notifications; "20" was an alpha-only-regex
  truncation artifact** (`run_start`/`run_complete` collapse to `run`, etc.).

Method: bounded byte-window reads of the pretty-printed bundle only. Key
registration sites: SDK `AgentSideConnection` dispatch @516731-524200; Kiro
`extMethod` + `capabilityHandlers` in `src/agent.ts` @20299900-20305600;
`src/workflow/workflow-handlers.ts` @18533524 (+36.8 KB);
`src/acp/ext-method-routing.ts` @19563971;
`src/acp/persistence-classification.ts` @19445583;
`src/server/multiplex-stream.ts` @20637674; SDK zod schemas @446292-515724.

## 3. The interface, fully enumerated

### 3.0 Engine argv + transports (server process, not the launcher)

`src/server/acp-server.ts` parses `--<name>=<value>` argv directly
(`getCliArg`): `transport` (`stdio`|`ws`; default `stdio`), `auth`
(`user`|`machine`|`acp-callback`; default `user`), `token-path`, `region`,
`endpoint`, `control-plane-endpoint`, `cloud-config-endpoint`,
`remote-sessions-endpoint`, `execution-environment` (default `local`),
`home-dir`, `sandbox` (`auto`|`seatbelt`|`bubblewrap`|`docker`|`none`),
`sandbox-allow-write` (comma list), `sandbox-network-mode`
(`default_allowed`|`default_blocked`|`common_dependencies`),
`sandbox-rootfs`, `test-traffic`. Empty value → exit 1. The Rust launcher
passes exactly `--transport=stdio --auth=acp-callback` (settled, corpus).
`ws` transport wraps the same JSON-RPC in WebSocket frames and adds the
multiplex layer (§3.10).

### 3.1 Standard ACP methods — SDK dispatch, and which ones Kiro implements

The SDK (`@agentclientprotocol/sdk`, AGENT_METHODS table @445509) dispatches
by name; optional handlers absent on the agent object throw
`RequestError.methodNotFound`. KiroAgent (class @20297000 region) implements:

| Method | Kind | Kiro handler | Status |
| --- | --- | --- | --- |
| `initialize` | req | `initialize` @20290752 | implemented |
| `session/new` | req | `newSession` @20336663 | implemented |
| `session/load` | req | `loadSession` @20406904 | implemented |
| `session/list` | req | `listSessions` @20325170 | implemented |
| `session/fork` | req | `unstable_forkSession` @20430186 | implemented |
| `session/set_mode` | req | `setSessionMode` @20359098 | implemented |
| `session/set_config_option` | req | `setSessionConfigOption` @20434235 | implemented |
| `session/prompt` | req | `prompt` @20379626 | implemented |
| `authenticate` | req | `authenticate` @20334690 | implemented |
| `session/cancel` | notif | `cancel` @20432197 | implemented |
| `session/resume` | req | — | method-not-found |
| `session/close` | req | — | method-not-found |
| `session/set_model` | req | — | **method-not-found** (see §3.11) |
| `logout` | req | — | method-not-found |
| `nes/start`, `nes/suggest`, `nes/close` | req | — | method-not-found |
| `nes/accept`, `nes/reject` | notif | — | silent no-op |
| `document/did_open`/`did_change`/`did_close`/`did_save`/`did_focus` | notif | — | silent no-op |

Absence evidence: each `unstable_*` identifier occurs ONLY in the SDK
dispatch block (<530000), zero hits in the 16.9M+ Kiro code region
(positive controls: `unstable_forkSession` and `extNotification` both hit in
both regions).

Request schemas (SDK Zod, all fields; `_meta` is always
`record(string, unknown).nullish()`):

- `initialize`: `{_meta?, clientCapabilities?: ClientCapabilities (default {auth:{terminal:false}, fs:{readTextFile:false, writeTextFile:false}, terminal:false}), clientInfo?: Implementation, protocolVersion}`.
- `session/new`: `{_meta?, additionalDirectories?: string[], cwd: string, mcpServers: McpServer[]}`. Response: `{_meta?, configOptions?, models?, modes?, sessionId}`.
- `session/load`: `session/new` + `sessionId`. Response adds replay stream.
- `session/list`: `{_meta?, additionalDirectories?, cursor?, cwd?}` →
  `{_meta?, nextCursor?, sessions: SessionInfo[]}`.
- `session/fork`: `{_meta?, additionalDirectories?, cwd, mcpServers?, sessionId}`
  → `{_meta?, configOptions?, models?, modes?, sessionId}`. The fork POINT is
  NOT a top-level field: `_meta.kiro.messageId` (plus `modeId`, `title`,
  `createdReason`, `isEmptyWorkspace`) — read in `unstable_forkSession`.
  Response `_meta.kiro.parentSessionId` names the parent.
- `session/set_mode`: `{_meta?, modeId, sessionId}` → `{_meta?}`.
- `session/set_config_option`:
  `({type:"boolean", value:boolean} | {value: string}) ∩ {_meta?, configId, sessionId}`
  → `{configOptions: [...]}` (full refreshed option list). See §3.11.
- `session/prompt`: `{_meta?, messageId?: string, prompt: ContentBlock[], sessionId}`
  → `{_meta?, stopReason, usage?, userMessageId?}`. `stopReason` ∈
  `end_turn | max_tokens | max_turn_requests | refusal | cancelled`. `usage` =
  `{inputTokens, outputTokens, totalTokens, cachedReadTokens?, cachedWriteTokens?, thoughtTokens?}`.
  `ContentBlock` = `text | image | audio | resource_link | resource`.
- `authenticate`: `{_meta?, methodId}` → `{_meta?}`.
- `session/cancel` (notif): `{_meta?, sessionId}`.

Prompt-handler behavior worth wire-level knowledge (@20379626): empty prompt
returns `{stopReason:"end_turn"}` without a model call; a prompt into a
paused workflow step session is rerouted to the workflow runner
(`tryResumeStepWithMessage`) and returns `end_turn`; a prompt while a turn is
active ABORTS the active executions and carries superseded messages forward;
non-`agentInitiated` prompts are persisted then echoed to other subscribers
as `user_message_chunk`, and the caller gets a
`session_info_update {kind:"user_message_id_assigned", userMessageId}`.

### 3.2 initialize response — the advertisement (@20297000)

`loadSession:true`, `promptCapabilities {image:true, embeddedContext:true}`,
`mcpCapabilities {http:true, sse:true}`, `sessionCapabilities {list:{}, fork:{_meta:{kiro:{messageId:true}}}}`,
`authMethods [aws-builder-id, aws-iam-identity-center]`, and
`agentCapabilities._meta.kiro`:

- `checkpoints:true, sessionList:true, policyNotifications:true, replayMarking:true`
- `extensionMethods`: the 7 fixed (`_kiro/knowledge`, `_kiro/codeIntelligence`,
  `_kiro/session/context`, `_kiro/session/compact`, `_kiro/session/export`,
  `_kiro/session/history`, `_kiro/config/template`) **plus, only when a
  source-provider catalog is wired**, `_kiro/sourceProviders/list` and
  `_kiro/sourceProviders/listResources`. The measured "7 advertised" (argv
  doc) is the unwired-catalog case, not a constant.
- `sessionSources` `["local"]` or `["local","remote"]`; `sessionListScopes`
  `["workspace"]` or `+"user"`; `executionTargets` `["local"]` or
  `+"cloud-sandbox"` — each gated on remote source / relay wiring
  (`remoteConfigured` / `relayConfigured` predicates).
- `sourceProviders: bool`, `logging: {…}` when the file logger initialized.

### 3.3 Client capability extensions the agent READS (@resolveCapabilities, src/platform/resolved-capabilities.ts)

From `initialize.clientCapabilities`: `fs.readTextFile`, `fs.writeTextFile`,
`terminal`, `fs._meta.kiro.{readFile, writeFile, stat, readDirectory, delete}`
(the Kiro fs-delegation set), and `_meta.kiro.{secretStorage, openExternalUrl, knowledge, infrastructureSafety, c2sViews}`.
Additionally `initialize.clientCapabilities._meta.kiro` carries (read in
`initialize` @20290752): `telemetryEnabled: bool`, `telemetry: {machineId,…}`,
`specLinks`, `requirementsAnalysis`, `userInput` (gates the `_kiro/userInput`
flow §3.8), `helpDocs: [{name, description, content}]`, `settings: {…}` (the
initialize-time settings channel — `settings.goal` lives here), and
`hooks: {enabled, v2, …}` (selects the delegating hook binding; corpus
hooks-io-contract).

### 3.4 The advertised extension methods — schemas (client→agent requests)

Params are NOT Zod-validated at the SDK layer (`zExtRequest = unknown`);
each handler validates ad hoc. All are session-scoped except
`config/template`.

- `_kiro/knowledge` (@20583771): `{sessionId, subcommand, name?, path?, target?, operationId?}`;
  `subcommand` ∈ `show | add | remove | update | clear | cancel`. Returns
  `{success, message?}`; `show` returns
  `{success:true, entries: [{name, id(8-char), description, item_count, path, items_display?, indexing?}]}`.
  Unknown subcommand → `{success:false, message:"Unknown subcommand: …"}`
  (NOT a JSON-RPC error). Gated on the client `knowledge` capability only for
  server-initiated pushes; the request itself always answers.
- `_kiro/codeIntelligence` (@20610438): `{sessionId, subcommand}` with
  `subcommand` ∈ `status | init | overview`. `status` →
  `{success, status:{initialized, languages, lspServers}}`; `init` ensures +
  writes the LSP config and starts servers; `overview` →
  `{success, overview}` (codebase overview text). Requires the session to
  have `codeTool` wired, else `{success:false, message:"Code intelligence is not enabled for this session"}`.
  This is the codegraph-adjacent surface: languages detected, LSP server
  roster, and a codebase overview — no symbol-level queries here (those ride
  the client-tool delegation, §3.8).
- `_kiro/session/context` (@20590488): `{sessionId, subcommand, path?, force?}`;
  `show | add | remove | clear`. `show` →
  `{success, entries, breakdown?}`; `add`/`remove` persist the session's
  attached context files and refresh the token breakdown.
- `_kiro/session/compact` (@20615091): `{sessionId}` → `{success: bool}`.
  Refused (`success:false`) while an execution or another compaction is in
  flight. Internally summarizes via a model call under
  `COMPACTION_TIMEOUT_MS` — a live fixture MUST treat this as
  credit-consuming.
- `_kiro/session/export` (@20619026): `{sessionId}` → zips
  `session.json` + `messages.jsonl` + `sub-executions/*.jsonl` into
  `$TMPDIR/kiro-exports/…` and returns the path. Falls back to an all-session
  scan when the session isn't loaded. `{success:false, error}` if not found.
- `_kiro/session/history` (@20424969): `{sessionId, beforeMessageId?, limit?}`
  → `{updates: SessionUpdate[], hasMore, oldestLoadedMessageId?}`. Page size
  default 50, hard cap 200 (`DEFAULT_HISTORY_PAGE_SIZE`,
  `MAX_HISTORY_PAGE_SIZE` @20226574).
- `_kiro/config/template` (@20320082): params ignored (`_params`).
  Session-LESS: builds the modes + config options a fresh session would get:
  `{modes:{availableModes, currentModeId}, configOptions}`. The one
  pre-session compose surface.
- `_kiro/sourceProviders/list` / `listResources` (@20318506): catalog-gated;
  `listResources` takes `{providerType, cursor?, limit?}`.

### 3.5 The rest of the client→agent ext-request surface

Full `capabilityHandlers` map (@20301980) + `extMethod` special cases
(@20303900). Reaching a handler requires the method to appear in
`classifyKnownExtMethod` (persistence-classification.ts @19445583) — an
unlisted method throws `[PersistenceClassification] Ext method … has no persistence classification`
(→ -32603); a listed-but-unhandled one throws `Unknown ext method: …`
(→ -32603). That is the wire fingerprint distinguishing the two layers.

- `_kiro/session/delete`: `{sessionId, sessionSource?}` (`local|remote`).
- `_kiro/session/rename`: `{sessionId, title}` (title trimmed to 80 chars).
- `_kiro/session/list`: special-cased alias of standard `session/list`
  (same `listSessions`).
- `_kiro/checkpoint/revert`: `{sessionId, filePath, snapshotUri?, toolCallId?}`
  (single-file revert). `_kiro/checkpoint/revertMultiple`:
  `{sessionId, messageId}` (revert-to-message; refused mid-execution via
  `CheckpointRevertError`).
- `_kiro/mcp/resetServer`: `{serverName, startOAuth?}` → `{success:true}`.
  `_kiro/mcp/getPrompt`: `{serverName, promptName, arguments}`.
  `_kiro/mcp/getResource`: `{serverName, uri}`. All three throw when MCP
  governance-disabled.
- `_kiro/hooks/triggerHook`: `{sessionId, hookId, hookName, hookActionType, prompt?}`
  — `askAgent` re-enters `prompt()` with a synthetic `_meta.kiro`
  (`title`, `displayText`) → CONSUMES A TURN. `_kiro/hooks/setEnabled`:
  `{hookId, enabled}`; `_kiro/hooks/list`:
  `{trigger?, toolId?, workspacePaths?, includeDisabled?}` — both answer
  `success:false` / throw when the v2Hooks client config is absent.
- `_kiro/spec/invoke`: `{operation, …}` with `operation` ∈
  `executeTask | runAllTasks | generateDocument | analyzeRequirements | createSpec …`.
  `_kiro/spec/resolveSession`: `{featureName, strategy, workspacePaths}`.
  `_kiro/spec/getTaskStatuses`: `{tasksFilePath, featureName, workspacePaths}`.
- `_kiro/permissions/explain`: `{sessionId, capability?|toolId?}`;
  `_kiro/permissions/list`: `{sessionId, scope?}` →
  `{rules:[{capability, match, exclude?, scope, …}]}`;
  `_kiro/policy/check`: `{sessionId, capability, …}` — drives the approval
  pipeline with a synthetic `policy-check-<uuid>` operation.
- `_kiro/account/getUsage`: `{}` →
  `{success, message, data?: {planName, usageBreakdowns[]}}`; admin-managed
  plans answer `success:true` with `data:undefined`.
- `_kiro/safety/getProperties` and `_kiro/sandbox/applyConfig`
  (`{configId: string, value: string}` — `sandbox`=`enabled|disabled`,
  `sandboxNetworkMode`, `mcpSandboxing`): special-cased in `extMethod`.
- `_session/steer` (@20369000): `{sessionId, message, messageId?}` →
  `{queued:true, messageId}` or
  `{queued:false, messageId, dropped:"epoch_changed"}`. A
  notification-prefixed message becomes a `notify-*` id with parsed severity;
  otherwise `steer-*`. Emits `session_info_update {kind:"steering_queued"}`.
  `_session/steer/clear`: `{sessionId}`. (These two are the ONLY non-`_kiro`
  ext methods.)

Routing overlay (`classifyExtMethodResidency` @19563971, relevant only when a
session is relayed to a cloud sandbox): `sessionForwarded` (the sessionId-
bearing set) vs `localOnly` (workflow/*, session/list|delete, account,
sourceProviders, sandbox/applyConfig, spec/resolveSession, config/template)
vs `localOnlyUntilScoped` (hooks/setEnabled, mcp/resetServer|getPrompt|
getResource|toggle, powers/refresh, spec/getTaskStatuses).

### 3.6 `_kiro/workflow/*` — 14 request methods (all in workflow-handlers.ts @18533524, lazily wired through `workflowRuntime.handlers()` in agent.ts)

Registered UNCONDITIONALLY (not gated on `workflowsEnabled`), NOT advertised.

- `new`: exactly one of `workflow` (inline object, `WorkflowSchema`-parsed) or
  `workflowPath` (absolute `*.workflow.json` path within allowed roots, or
  `bundled://<name>`, or `generated://<id>`); `workspacePaths` (absolute,
  REQUIRED when no `parentSessionId`); `parentSessionId?`; `inputs?`. Parent
  session contributes roots + `parentModelId` + `parentEffortLevel`. →
  `{workflowId: "wf_<16hex>", initialState}`. Does NOT start the run.
- `invoke`: `{workflowId}` → `{workflowId, status}`; restarts a terminal run
  (resets state, clears step sessions), fire-and-forget (`runner.invoke` not
  awaited — failures surface only as notifications/log).
- `load`: `{workflowId}` → `{workflowId, state, nodePlan?, stepSessions:[{nodeId, nodePath, sessionId, iteration?, branchId?}]}`;
  also (re)wires the notification bridge to this connection.
- `inspect`: `{workflowId}` → `{workflowId, state, nodePlan?, pendingSteps?}`
  (read-only; no bridge rewire).
- `list`: `{workspacePaths?}` → `{runs: RunSummary[]}` (registry + on-disk
  scan, reconciles stale runs).
- `pause`: `{workflowId}` → runner.pause result.
- `cancel`: `{workflowId, targetStatus?}` (default `"aborted"`) →
  `{ok:true, previousStatus}`; on-disk cancel emits a synthetic
  `run_complete` notification.
- `delete`: `{workflowId}` (plain id segment enforced) → `{ok:true}`;
  refuses a running run whose owner is live (liveness check), text
  "… may be owned by a live process".
- `retry`: `{workflowId, nodeId?}` → `{workflowId, status, retriedNodeIds}`;
  only terminal runs; `nodeId` must be failed/aborted.
- `update`: `{workflowId, action, remainingSteps?, status?, statusReason?}`;
  `action` = `"replace_remaining"` (requires non-empty `remainingSteps`) or
  status update (requires `status`). → `{workflowId, updated, queued, message}`.
  A finished run answers `updated:false` with a pointer to `retry`.
- `resume`: `{workflowId}` → `{workflowId, status}` (fire-and-forget invoke).
- `resumeAll`: `{}` → `{resumed[], skipped[], errors[]}` across all base dirs.
- `listRecipes`: `{workspacePaths?}` → `{recipes:[{name, source?, builtIn, description?, inputs?, plan?, validationError?}]}`
  — workspace `.kiro/workflows/*.workflow.json` first, bundled recipes
  fill in (a broken workspace recipe is shadowed by a same-named bundled one).
- `listWatchHandlers`: `{}` → `{handlers}` (registry list; `github-pr` is a
  known id).

Errors are thrown `Error`s → -32603 with the message in `data.details`
(§3.9b); `workspacePaths`/id-shape violations use `InvalidParamsError`
(-32602).

**9 workflow notifications** (agent→client, `KIND_TO_METHOD` @18515300):
`_kiro/workflow/run_start`, `run_complete`, `node_start`, `node_complete`,
`node_paused`, `loop_iteration`, `watch_poll`, `paused`, `steps_queued` —
payload = the runner event payload `+ parentSessionId` when set. Delivered
only after a bridge is wired by `new`+`invoke`/`load`/`resume`/`resumeAll` on
the SAME connection; the bridge self-unsubscribes on terminal
`run_complete`.

### 3.7 Client→agent ext NOTIFICATIONS (inbound `extNotification` @20432834)

Exactly three: `_kiro/powers/refresh` (`{}`), `_kiro/policy/ignore_files_changed`
(`{files: string[]}` — non-array payload warned + dropped), `_kiro/mcp/toggle`
(`{enabled?: bool}` default true). Anything else is SILENTLY IGNORED
(`return Promise.resolve()`), after a relay-forward check. Note
`powers/refresh` and `mcp/toggle` are also classified as ext METHODS, but the
request path has no handler for them → sending them as requests errors
`Unknown ext method`; only the notification form works.

### 3.8 Agent→client REQUESTS (a client must answer or the agent stalls)

Standard (SDK CLIENT_METHODS; used when capability advertised): 
`session/request_permission` (`{sessionId, toolCall: ToolCallUpdate, options:[{optionId, name, kind: allow_once|allow_always|reject_once|reject_always}]}`
→ `{outcome: {outcome:"cancelled"} | {outcome:"selected", optionId}}`),
`fs/read_text_file` (`{sessionId, path, line?, limit? (uint32)}`),
`fs/write_text_file` (`{sessionId, path, content}`), `terminal/create`
(`{sessionId, command, args?, cwd?, env?, outputByteLimit?}`),
`terminal/output`, `terminal/wait_for_exit` (→ `{exitCode?, signal?}`),
`terminal/kill`, `terminal/release`, `elicitation/create` (SDK vocabulary;
Kiro's own MCP-elicitation rides the ext method below).

Kiro ext (all via `sendClientExtMethod`, enumerated exhaustively by grep):

- `_kiro/auth/getAccessToken` `{}` →
  `{accessToken: string, expiresAt: string(Date-parseable), profileArn?: string, authMethod?: string, provider?: string}`
  (acp-callback-auth-provider @19663711). Cadence: refresh fires when the
  cached token is inside `REFRESH_BUFFER_MS = 180000` (3 min) of expiry —
  non-blocking background refresh while still valid, blocking when expired;
  all in-flight refreshes coalesce to ONE outstanding request. Failure
  handling: transport error → `AuthRefreshFailedError` → surfaces as
  `TokenExpiredError` (-32000); missing `accessToken`, unparseable
  `expiresAt`, or an `expiresAt` already inside the buffer →
  `TokenInvalidError` (-32000). `profileArn` segment 4 selects the AWS
  region (fallback `us-east-1`, warned once per refresh). `authMethod` /
  `provider` are sticky across refreshes when omitted.
- `_kiro/userInput` `{sessionId, toolCallId, question, options}` →
  `{action:"answered", answer} | other` — only when the client advertised
  `userInput` in `_meta.kiro` at initialize (via `resolveAgentContext`);
  otherwise the agent falls back to `session/request_permission` with flat
  labels, and a free-form question with NO options auto-advances the
  execution (never blocks). Pending inputs are persisted
  (`withPersistedUserInput`) to survive reconnects.
- `_kiro/hooks/list`, `_kiro/hooks/sessionStart`, `_kiro/hooks/executeHook`
  — the delegating (client-side) hook binding; see corpus
  hooks-io-contract for semantics.
- `_kiro/mcp/elicitation` — MCP server elicitation forwarded to the client.
- `_kiro/openExternalUrl` `{url}` — only when capability advertised.
- `_kiro/secret/get` / `store` / `delete` — `AcpSecretStorage`, only when
  `secretStorage` advertised.

Via `connection.extMethod` (delegation adapters, gated on the `fs._meta.kiro`
/ client-tool capabilities): `_kiro/fs/read_file`, `_kiro/fs/write_file`,
`_kiro/fs/stat`, `_kiro/fs/read_directory`, `_kiro/fs/delete`,
`_kiro/search/find_files`, `_kiro/search/text_search`,
`_kiro/terminal/shell_type` (→ shell name; skipped when `session/new`
`_meta.kiro.shellType` supplied), `_kiro/workspace/active_file`,
`_kiro/workspace/currently_open_files`, and the client-tool trio
`_kiro/tool/get_diagnostics`, `_kiro/tool/semantic_rename`,
`_kiro/tool/smart_relocate` (acp-type-covenant client-tool-definitions,
metaKeys `clientToolGetDiagnostics` etc.).

### 3.9 Agent→client NOTIFICATIONS

(a) `session/update` `{sessionId, update, _meta?}` — `sessionUpdate`
discriminant (SDK zSessionUpdate @508622): `user_message_chunk`,
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
`tool_call_update`, `plan`, `available_commands_update`,
`current_mode_update`, `config_option_update`, `session_info_update`,
`usage_update`. Replayed load history carries `_meta.kiro.replay: true`.
`session_info_update` kinds observed in code: `queued`, `focus_u…`,
`steering_queued`, `user_message_id_assigned` (built by
`buildSessionInfoUpdate`).

(b) Ext notifications (exhaustive over literal `extNotification(`/
`emitNotification(` call sites): `_kiro/mcp/status`
(`{sessionId, servers:[…]}`, per-server as MCP comes up; empty roster on
disable), `_kiro/sessions/changed` (roster delta; connection-scoped),
`_kiro/system/notify`, `_kiro/session/notify` (workflow send_message →
session), `_kiro/governance/state`, `_kiro/mcp/governance_disabled`,
`_kiro/policy/changed`, `_kiro/policy/error`, `_kiro/safety/statusChanged`,
`_kiro/safety/propertiesChanged`, `_kiro/sandbox/status`,
`_kiro/hooks/didChange`, `_kiro/hooks/cancel`, `_kiro/tools/didChange`,
`_kiro/powers/items_changed`, `_kiro/progressive_context/items_changed`,
`_kiro/steering/documents_changed`, `_kiro/knowledge/indexingStarted`,
`_kiro/knowledge/indexingCompleted`, `_kiro/customAgent/config_error`,
`_kiro/customAgent/not_found`, `_kiro/error/rate_limit`,
`_kiro/spec/taskStatusChanged`, `_kiro/code_references`,
`_kiro/c2s/view/changed`, plus the 9 workflow ones (§3.6).
`_kiro/sessions/*` and `_kiro/system/*` are connection-scoped (mux does not
fan them out per session).

(c) Error taxonomy. SDK `RequestError` codes: -32700 parse, -32600 invalid
request, -32601 method-not-found (`data.method`), -32602 invalid params
(`data` = ZodError.format()), -32603 internal, -32000 auth-required, -32002
resource-not-found. Kiro `AgentError extends RequestError` (src/types/errors.ts):
`InvalidClientError` -32600, `InvalidParamsError` -32602,
`SessionNotFoundError` -32000 (`Session '<id>' not found`),
`SandboxProvisioningFailedError`, `RemoteSessionSourceError`,
`SourceProviderCatalogError`, `CheckpointRevertError`,
`RemoteSessionUnsupportedError`, `TokenExpiredError`, `TokenInvalidError`,
`AuthRefreshFailedError`, `ContextWindowExceededError` — all -32000;
`IllegalSessionPlacementError` -32603. Any other thrown Error → -32603 with
`data.details = message` (or `data` = parsed message if it happens to be
JSON — a real quirk in `#tryCallRequestHandler` @~524400). Persistence codes
(inside messages, not JSON-RPC codes): `SessionPersistenceError` ∈
`SESSION_NOT_FOUND | CHECKPOINT_NOT_FOUND | SCHEMA_MISMATCH | WRITE_FAILED | READ_FAILED | CORRUPTED_DATA | INVALID_SESSION_ID | INVALID_WORKSPACE_PATH | SUB_SESSION_NOT_FOUND`;
`SessionForkError` ∈ `SESSION_NOT_FOUND | MESSAGE_NOT_FOUND | NO_FORK_POINT`.
Three-outcome probe discipline: -32601 = never reached an agent handler;
-32602 = SDK Zod or Kiro InvalidParams; -32603 `data.details` beginning
`[PersistenceClassification]` = ext name unknown to the allowlist, vs
`Unknown ext method:` = allowlisted but unhandled (the §3.7 trap pair).

### 3.10 Multiplex layer (ws transport only, src/server/multiplex-stream.ts @20637674)

Multi-client fan-in with `primary`/`observer` roles. Adds two client→agent
notifications that SYNTHESIZE responses to pending agent→client requests (for
clients that don't know the original JSON-RPC id): `_kiro/permission/respond`
`{toolCallId, optionId, sessionId?, fileDecisions?}` (also read from
`_meta.kiro.fileDecisions`; `_meta.kiro.editedCommand`/`consent` forwarded)
— acked immediately `{success:true}`; and `_kiro/userInput/respond`
(same pattern for `_kiro/userInput`). Observer raw responses to pending
permission/userInput requests are DISCARDED. Pending permissions TTL 5 min
(`PENDING_PERMISSION_TTL_MS`). Caller identity is stamped into
`params._meta.kiro` (`stampCallerClientId`). None of this exists on stdio.

### 3.11 `_meta.kiro` request vocabularies (the hidden knobs)

- `session/new` / `session/load` `_meta.kiro` (`KiroSessionMetaSchema`):
  `modeId`, **`modelId`**, **`effortLevel`**, `overrideSessionId`,
  `idempotent` (create-or-load convergence for a stable overrideSessionId;
  without it a duplicate create rejects "Session already exists"),
  `shellType`, `noReplay` (suppresses turn replay, not the catch-up burst),
  `workflow` (step tag), `repositories`, `kiroInstanceId`, `kiroSessionId`,
  `firstMessageWaitMs`, `replayLimit`, `introspectArtifactsPath`, `steering`,
  `customAgents` (max 50), `createdReason` ∈
  `human | rewind | subagent | tangent`, `isEmptyWorkspace`. Lenient fields
  (`.catch(undefined)`) degrade alone; the REST of a malformed meta parse
  drops silently (`parseKiroMeta` returns undefined — no error).
- Dispatch meta (`SessionDispatchMetaSchema`, STRICT): `sessionSource` ∈
  `local | remote | all`, `listScope` ∈ `workspace | user | both` — an
  unrecognized value is a typed -32602, `all` only valid for list.
- `session/prompt` `_meta.kiro` (`KiroPromptMetaSchema`): `taskId`, `title`,
  `executionId`, `inputDocuments: [{type:"file", path}]`, `visibility`,
  `displayText` (UI bubble override), `agentInitiated` (no persist, no echo),
  `ttft: true`.
- `session/set_config_option` `configId`s (buildConfigOptions @20296200):
  `mode`, **`model`**, **`effortLevel`** (validated against
  `getEffortLevelsForModel(session.modelId)`; invalid values silently
  ignored), `autopilot` (`on|off`), `contentCollection`
  (`enabled|disabled`), `sandbox`, `sandboxNetworkMode`, `mcpSandboxing`;
  plus `_meta.kiro.mcpServers` to live-update the MCP roster. Model/mode/
  autopilot/effort persist to session metadata. **So the v3 wire DOES carry
  model + effort** — as config options and session meta, not as
  `session/set_model` (unimplemented) and never in the handshake; this
  refines the argv doc's "no model vocabulary" (true for the read-side
  handshake stream it measured). Model options carry
  `_meta.kiro.{rateMultiplier, rateUnit, hasEffort, effortLevels, defaultEffortLevel, effortSchemaPath}`.

## 4. Activation drivers

| Surface | Who can pull it |
| --- | --- |
| Standard session verbs, advertised + unadvertised ext requests | external-ACP-client ONLY (the TUI/CLI client is one such client; nothing model-elected) |
| `_kiro/workflow/*` requests | external-ACP-client; workflow-step-driven indirectly (runner re-enters `prompt`/`newSession` via workflowHost, not via ACP) |
| `session/prompt` | external-ACP-client; hook-driven (`_kiro/hooks/triggerHook` `askAgent` re-enters `prompt()`); workflow-step-driven (step sessions) |
| `_session/steer` | external-ACP-client (workflow send_message uses the internal path + `_kiro/session/notify`) |
| Agent→client requests (auth, permission, userInput, fs/terminal delegation) | model-elected (tool use) and engine-elected (auth timer); the CLIENT must implement them — not optional |
| Client→agent notifications (`powers/refresh`, `mcp/toggle`, `ignore_files_changed`) | external-ACP-client only |
| Workflow notifications | workflow-step-driven (runner events), fan-out gated on which connection wired the bridge |
| `model`/`effortLevel` knobs | external-ACP-client (session/new meta, set_config_option); parent-inherited for workflow runs (`parentModelId`/`parentEffortLevel`) |

Nothing in this surface is user-typed / skill-invoked / agent-system-prompt-
driven directly — slash commands and skills sit in the CLIENT and translate
to these methods.

## 5. Fixture design

All no-model, no-credit unless stated. Reuse the corpus stdio harness
(fake HOME, real XDG_DATA_HOME, placeholder token answering
`_kiro/auth/getAccessToken`).

- **F-ACPW-1 (three-outcome error probe):** send `foo/bar` (expect -32601
  `data.method`), `session/set_mode` with `{}` (expect -32602 ZodError
  format), `_kiro/not/aMethod` (expect -32603 details
  `[PersistenceClassification]…`), `_kiro/mcp/toggle` AS REQUEST (expect
  -32603 `Unknown ext method`), and `_kiro/mcp/toggle` as notification
  (expect silence + MCP disable side effect). Pass = all five signatures.
- **F-ACPW-2 (config-option model/effort):** `initialize` → `session/new` →
  read `configOptions` for ids `model`/`effortLevel` and their option
  `_meta.kiro` → `session/set_config_option {configId:"model", value:<id>}`
  → expect `config_option_update` + persisted `modelId` in `session.json`.
  Discriminates "knob exists" from "knob persists" without ever prompting.
  Then `session/set_model` → expect -32601 (negative control).
- **F-ACPW-3 (advertised ext, sessionless):** `_kiro/config/template` with
  `{}` — expect modes+configOptions; compare against `session/new` result
  for parity. `_kiro/session/history` on a seeded session with `limit: 999`
  — expect ≤200 updates (cap observable).
- **F-ACPW-4 (workflow request/notification round trip):**
  `_kiro/workflow/new` (inline minimal workflow, explicit `workspacePaths`)
  → `inspect` → `update replace_remaining` on the un-invoked run →
  `delete`. Observable: `wf_<16hex>` id shape, `initialState`, terminal
  refusal text on a second `update` after a cancel. No `invoke` → no model.
- **F-ACPW-5 (auth refresh cadence, SPEC — needs a long-lived session):**
  answer the first `getAccessToken` with `expiresAt = now+4min`; expect a
  SECOND request within ~1 min (3-min buffer), coalesced (never two
  outstanding). Answer with `expiresAt = now+1min` → expect
  `TokenInvalidError` surfaced.
- **F-ACPW-6 (compact, SPEC — consumes credits):** seeded session,
  `_kiro/session/compact` → two loud outcomes (`{success:false}` when idle
  conditions unmet vs summary persisted). Model call inside — spec only.

## 6. Cross-interactions

- `_kiro/knowledge`/`codeIntelligence`/`context` return
  `{success:false, message}` for their domain errors instead of JSON-RPC
  errors — a probe keying on error frames will MISCLASSIFY them as healthy.
- The workflow notification bridge binds to whichever connection last called
  `load`/`invoke`/`resume` — on ws multi-client, a second client's `load`
  STEALS the stream (bridge is rewired, not duplicated).
- `session/prompt` into a paused-step session never reaches the model — the
  runner eats it (`tryResumeStepWithMessage`). A prompt-based fixture on a
  step session measures the workflow engine, not the chat path.
- `_kiro/mcp/toggle` (notification) and `_kiro/powers/refresh` mutate
  PROCESS-level state (MCP pool, powers) across every session on the
  connection — not session-scoped despite the routing table's aspiration
  (`localOnlyUntilScoped` names exactly this gap).
- `sandbox`/`sandboxNetworkMode`/`mcpSandboxing` config options are also
  process-global (`applySandboxConfigOption` fans out to all sessions).
- `overrideSessionId` without `idempotent:true` rejects duplicate creates —
  the session/load create-uncreated leniency (settled) does NOT apply to
  `session/new`.
- An invalid `_meta.kiro` on session/new drops the WHOLE meta silently
  (modelId, modeId included) — a fixture must confirm the knob took effect
  (persisted metadata), never trust the request.
- Advertised `extensionMethods` grows by 2 when a source-provider catalog is
  wired; clients must not hardcode "7".
