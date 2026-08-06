# Kiro v3 ACP — engine deep dive

> **Verified against:** KAS
> `2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
> (kiro-cli 2.15.1 installed; the argv-layer companion
> `private/kiro-acp-and-launcher-argv.md` was measured against 2.15.2).
> Measured 2026-07-30. Sources: `private/kiro-phase2/acp-wireline.md` (bundle
> read), `private/kiro-phase2/acp-config.md` (G2/G3/G7–G10),
> `private/kiro-phase2/acp-live-probe.md` (live stdio probes), plus the
> f09/f10/f11 verification passes. Byte offsets churn per release — anchor on
> the semantic names, not the numbers.

This is the final v3 ACP synthesis. The argv layer (launcher flag positions,
`--v3` translation, the v3+`acp` conflict set, engine fingerprinting) is NOT
re-derived here — see the companion doc. The frame for §6 is that doc's Gaps
G1–G10.

## 1. TL;DR — how to talk to the v3 ACP arm

1. **Spawn:** `kiro-cli --v3 acp` (or `kiro-cli acp --agent-engine=v3`).
   Always the LAUNCHER, never `kiro-cli-chat` directly (G7: the chat binary's
   top-level `--v3` does not reach `acp`, so you silently get v2). The Rust
   side then spawns the Node engine as
   `acp-server.js --transport=stdio --auth=acp-callback`.
2. **Framing:** newline-delimited JSON-RPC 2.0 on stdout/stdin. stdout carries
   ONLY frames; all `[INFO]` chatter is stderr. First stderr line on v3 is the
   `--auth=acp-callback` announcement — the engine fingerprint.
3. **Auth callback — a client MUST implement it.** The engine immediately
   sends a REQUEST to the client, `_kiro/auth/getAccessToken {}`, and stalls
   until answered. Answer with
   `{accessToken, expiresAt}` (Date-parseable; keep it >3 min out — inside the
   180 s refresh buffer it is `TokenInvalidError`), or a JSON-RPC error to run
   token-free. A v2-only client hangs here with no error.
4. **Id-matching is mandatory.** The agent interleaves its own requests
   (auth, permission, userInput, fs/terminal delegation) between your request
   and its response, and multiplexes without awaiting — multiple agent→client
   requests can be outstanding at once. Route strictly by `id`; naive
   send/read pairs the wrong frames.
5. **Teardown:** close stdin → wait → `killpg` (the `bin/` entries are bash
   wrappers that `exec`, so a bare kill orphans the child holding the pipes;
   spawn with a fresh process group). Idle engines exit on stdin close; a
   session with a live auth-refresh loop needs the killpg.

## 2. Capability tables (live handshake, verbatim)

`initialize` result, token-free, fresh HOME (`protocolVersion: 1`):

| field                        | value                                                              |
| ---------------------------- | ------------------------------------------------------------------ |
| `loadSession`                | `true`                                                             |
| `promptCapabilities`         | `{image:true, embeddedContext:true}`                               |
| `mcpCapabilities`            | `{http:true, sse:true}`                                            |
| `sessionCapabilities`        | `{list:{}, fork:{_meta:{kiro:{messageId:true}}}}`                  |
| `authMethods`                | `aws-builder-id`, `aws-iam-identity-center`                        |
| `_meta.kiro` booleans        | `checkpoints`, `sessionList`, `policyNotifications`, `replayMarking` all `true`; `sourceProviders:false` |
| `_meta.kiro.sessionSources`  | `["local"]` (`+"remote"` when remote source wired)                 |
| `_meta.kiro.sessionListScopes` | `["workspace"]` (`+"user"` gated the same way)                   |
| `_meta.kiro.executionTargets` | `["local"]` (`+"cloud-sandbox"` when relay wired)                 |
| `_meta.kiro.logging`         | `{logDir, channels:[kiro,mcp,powers]}`                             |
| `_meta.kiro.extensionMethods` | exactly 7 (below) — grows by 2 (`_kiro/sourceProviders/list`, `listResources`) when a source-provider catalog is wired; never hardcode 7 |

`session/new` result (params `{cwd, mcpServers:[]}`): top-level `_meta`,
`configOptions`, `modes`, `sessionId` (`sess_<uuid>`). `_meta.kiro`:
`schemaVersion:"1.0.0"`, `agentMode:"vibe"`, `semanticReviewEnabled:true`,
`ftaEnabled:false`, `workflowsEnabled:false`, `specPlanEnabled:false`,
`specWorkflow:"quick"`, `specSkipClarificationEnabled:true`,
`source:"local"`. `modes.availableModes` = 7: `vibe`, `spec`, `quick-spec`,
`bug-fix`, `plan`, `autonomous`, `semantic_reviewer`. `configOptions`
token-free = exactly **3** (`mode`, `autopilot`, `contentCollection`);
`model` + `effortLevel` options appear only with a warm model catalog (real
token) — a fixture pinning the count must pin the auth state too. v3 modes
are workflows, not agents (v2 semantics differ; companion doc §4).

## 3. Complete method reference

Auth-gating shorthand: **TF** = works token-free (measured live); **TG** =
reachable token-free but real data/validation needs a token. Activation:
everything client→agent in this section is **external-ACP-client only** (the
shipped TUI is one such client; nothing here is model-electable — verified:
no tool reaches either command router, and no slash command is
model-electable). Exceptions noted per row.

### 3.1 Standard ACP methods

| method                      | status              | notes |
| --------------------------- | ------------------- | ----- |
| `initialize`                | TF                  | reads `clientCapabilities` + `_meta.kiro` levers (§4.5) |
| `session/new`               | TF                  | `{_meta?, additionalDirectories?, cwd, mcpServers}`; unknown top-level keys STRIPPED (zod strip, live-verified) |
| `session/load`              | TF                  | `session/new` + `sessionId`; replays history with `_meta.kiro.replay:true` |
| `session/list`              | TF                  | cursor-paginated |
| `session/fork`              | TG                  | fork point rides `_meta.kiro.messageId` (not top-level); needs prior conversation — fresh session → `No effective messages to fork from`. `createdReason:"tangent"` is accepted here and reachable ONLY by an external client (no shipped surface forks at all except `/rewind`) |
| `session/set_mode`          | TF                  | `{modeId, sessionId}`; mode switch can change model+effort when the target profile carries `model` |
| `session/set_config_option` | TF (validation TG)  | §4.4 |
| `session/prompt`            | token + credits     | empty prompt → `end_turn` no model call; prompt into a paused workflow step is EATEN by the runner (`tryResumeStepWithMessage`, any non-empty text); prompt during a turn aborts active executions. Exactly two slash-relevant interceptions engine-side: that resume, and `/goal ` parsing gated on clientMeta `settings.goal`. Also hook-driven (`triggerHook askAgent`) and workflow-step-driven |
| `authenticate`              | TF                  | `{methodId}` |
| `session/cancel` (notif)    | TF                  | `{sessionId}` |
| `session/set_model`         | **-32601 dead**     | SDK-advertised, never implemented (`unstable_setSessionModel` absent) — negative control for probes |
| `session/resume`, `session/close`, `logout`, `nes/*` | -32601 or silent no-op | not implemented |

`session/prompt` result:
`{stopReason: end_turn|max_tokens|max_turn_requests|refusal|cancelled, usage?, userMessageId?}`.

### 3.2 Advertised extension methods (the 7)

Params are NOT SDK-validated (`zExtRequest = unknown`); handlers validate ad
hoc. Domain errors often come back as `{success:false, message}` RESULTS, not
JSON-RPC errors — probes keyed on error frames misclassify them as healthy.

| method                    | schema (client→agent)                                   | gating | live result |
| ------------------------- | ------------------------------------------------------- | ------ | ----------- |
| `_kiro/knowledge`         | `{sessionId, subcommand: show\|add\|remove\|update\|clear\|cancel, name?, path?, target?, operationId?}` | TF | `show` → `{success:true, entries:[]}` |
| `_kiro/codeIntelligence`  | `{sessionId, subcommand: status\|init\|overview}`       | TF     | needs `codeTool` wired, else `{success:false, "Code intelligence is not enabled for this session"}` |
| `_kiro/session/context`   | `{sessionId, subcommand: show\|add\|remove\|clear, path?, force?}` | TF | fresh session `show` → `null` |
| `_kiro/session/compact`   | `{sessionId}`                                           | TG     | empty session → `{success:true}` no-op; a REAL compaction is a model call (credits); refused while an execution/compaction is in flight |
| `_kiro/session/export`    | `{sessionId}`                                           | TF     | zips session to `$TMPDIR/kiro-exports/` — **outside HOME**; sandbox fixtures must allow it |
| `_kiro/session/history`   | `{sessionId, beforeMessageId?, limit?}`                 | TF     | page default 50, hard cap 200 |
| `_kiro/config/template`   | params ignored                                          | TF     | session-LESS static `{modes, configOptions}`; reads/writes nothing (G3) |

### 3.3 Unadvertised ext surface (non-workflow, all reachable TF)

`_kiro/session/list` (alias), `_kiro/session/rename` (`{sessionId, title}`,
trimmed to 80 chars, persists to `session.json`), `_kiro/session/delete`
(`{sessionId, sessionSource?}`, removes the dir), `_kiro/checkpoint/revert`
(`{sessionId, filePath, snapshotUri?, toolCallId?}`) and `revertMultiple`
(`{sessionId, messageId}`, refused mid-execution), `_kiro/mcp/resetServer` /
`getPrompt` / `getResource` (throw when MCP governance-disabled or server
unwired), `_kiro/hooks/triggerHook` (`askAgent` re-enters `prompt()` —
CONSUMES A TURN), `_kiro/hooks/setEnabled`, `_kiro/hooks/list` (**v2-only**:
errors `not available when v2Hooks is disabled`; v3 hooks are agent→client,
§3.5), `_kiro/spec/invoke` (`operation` ∈ `executeTask`, `runAllTasks`,
`generateDocument`, `analyzeRequirements`, `createSpec`, …),
`_kiro/spec/resolveSession` (`{featureName, strategy, workspacePaths}`),
`_kiro/spec/getTaskStatuses`, `_kiro/permissions/explain`,
`_kiro/permissions/list` (full default ruleset returned TF — deny writes to
`.kiro/settings`, ask on `.git/**` etc., curated read-only shell allowlist,
subagent allowlist), `_kiro/policy/check`, `_kiro/account/getUsage` (TG:
answers `{success:false, "Authentication failed…"}` token-free — does NOT
stall), `_kiro/safety/getProperties`, `_kiro/sandbox/applyConfig`
(`{configId, value}`), `_session/steer`
(`{sessionId, message, messageId?}` → `{queued:true, messageId}`; the only
non-`_kiro` ext method besides `_session/steer/clear`).

The shipped TUI's `/spec run` rides `_kiro/spec/resolveSession` +
`_kiro/spec/invoke {operation:"runAllTasks"}` — verified; no client-side task
loop. `_kiro/help` does not exist engine-side (the client adapter's case for
it is dead code). No `session/spawn` on v3 (`kiro.dev/session/spawn` is
v2-only; `/spawn` is stubbed in KAS mode).

### 3.4 `_kiro/workflow/*` — 14 request methods, 9 notifications

Registered UNCONDITIONALLY (not gated on `workflowsEnabled`), NOT advertised,
all reachable TF. "20 methods" from the mission brief was a regex artifact.

| method             | params → result |
| ------------------ | --------------- |
| `new`              | exactly one of `workflow` (inline, `WorkflowSchema`) or `workflowPath` (absolute, `bundled://<name>`, `generated://<id>`); `workspacePaths` REQUIRED without `parentSessionId`; `inputs?` → `{workflowId:"wf_<16hex>", initialState}` — created, NOT started (live: `root` stays `pending`) |
| `invoke`           | `{workflowId}` → `{workflowId, status}`; fire-and-forget; restarts terminal runs |
| `load`             | `{workflowId}` → state + `stepSessions`; (re)wires the notification bridge to THIS connection |
| `inspect`          | read-only state, no bridge rewire |
| `list`             | `{workspacePaths?}` → `{runs:[…]}` |
| `pause` / `resume` / `resumeAll` | by id; `resumeAll {}` sweeps all base dirs |
| `cancel`           | `{workflowId, targetStatus?}` (default `aborted`) |
| `delete`           | refuses a running run owned by a live process |
| `retry`            | terminal runs only; `nodeId` must be failed/aborted |
| `update`           | `action:"replace_remaining"` (non-empty `remainingSteps`) or a status update |
| `listRecipes`      | 7 bundled: `autoresearch`, `feature-pipeline`, `goal`, `investigate`, `publish-pr`, `ralph`, `semantic-review-multi-model` (workspace `.kiro/workflows/` shadows by name) |
| `listWatchHandlers` | 2: `github-pr`, `crux-cr` (poll configs with 60 s default interval) |

Notifications (agent→client): `run_start`, `run_complete`, `node_start`,
`node_complete`, `node_paused`, `loop_iteration`, `watch_poll`, `paused`,
`steps_queued` — delivered only after a bridge is wired by
`new`+`invoke`/`load`/`resume`/`resumeAll` on the SAME connection; a second
connection's `load` STEALS the stream; bridge self-unsubscribes on terminal
`run_complete`. Sending a notification name as a request is the
`[PersistenceClassification]` error (§5).

### 3.5 Agent→client requests (the client contract)

The client MUST answer these or the engine stalls. Drivers: engine-elected
(auth timer) and model-elected (tool use); never optional.

- `_kiro/auth/getAccessToken {}` → `{accessToken, expiresAt, profileArn?, authMethod?, provider?}`.
  Refresh fires inside the 3-min buffer; in-flight refreshes coalesce to one.
  Transport error → `TokenExpiredError`; missing/late `expiresAt` →
  `TokenInvalidError` (both -32000). `profileArn` segment 4 selects the AWS
  region (fallback `us-east-1`).
- `session/request_permission` → `{outcome:{outcome:"selected", optionId}}`
  or `cancelled`.
- `fs/read_text_file`, `fs/write_text_file`, `terminal/*` — only when the
  matching capability was advertised. Note (verified): advertising these
  routes IO through the client but does NOT swap the model-facing core tool
  schemas — `clientTools` is a constructor-only injection point, so the model
  always sees the default `execute_bash`/`read_file` variants.
- `_kiro/userInput` — only when `userInput` advertised in clientMeta;
  otherwise falls back to `request_permission`, and an option-less free-form
  question auto-advances (never blocks).
- `_kiro/hooks/list` / `sessionStart` / `executeHook` — the v3 delegating
  hook binding (client-side hooks), selected at initialize.
- `_kiro/fs/*`, `_kiro/search/*`, `_kiro/terminal/shell_type`,
  `_kiro/workspace/*`, `_kiro/tool/get_diagnostics` / `semantic_rename` /
  `smart_relocate` — the fs/tool delegation set, gated on
  `fs._meta.kiro.*` / client-tool capabilities.
- `_kiro/openExternalUrl`, `_kiro/secret/get` / `store` / `delete`,
  `_kiro/mcp/elicitation` — capability-gated.

### 3.6 Notifications

Client→agent (inbound): exactly three — `_kiro/powers/refresh` `{}`,
`_kiro/policy/ignore_files_changed` `{files}`, `_kiro/mcp/toggle`
`{enabled?}`. Anything else is SILENTLY ignored. The first and third are also
classified as ext methods but have no request handler — the request form
errors `Unknown ext method` (live-confirmed); only the notification works.
Both mutate PROCESS-level state across all sessions on the connection.

Agent→client: `session/update` kinds `user_message_chunk`,
`agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
`tool_call_update`, `plan`, `available_commands_update`,
`current_mode_update`, `config_option_update`, `session_info_update`,
`usage_update`. Plus ~25 `_kiro/*` ext notifications (mcp/status,
sessions/changed, governance/state, policy/changed, tools/didChange,
powers/items_changed, steering/documents_changed, knowledge/indexing*,
spec/taskStatusChanged, error/rate_limit, …) and the 9 workflow ones. At
session/new a fresh engine emits 7 ext notifications + 2 session/update
kinds (live list in acp-live-probe §3.8); `available_commands_update` for
`vibe` advertises 5 commands. The steering-command `contextQuery` field in
that payload is producer-only dead weight — no shipped client reads it; only
an external client could.

Multiplex layer (ws transport only): `primary`/`observer` roles; extra
inbound notifications `_kiro/permission/respond` and `_kiro/userInput/respond`
synthesize responses for clients that don't know the JSON-RPC id; observer
raw responses are discarded; pending-permission TTL 5 min. None of this
exists on stdio.

## 4. Configuration surface

### 4.1 What the engine reads — files, never the settings store

The engine reads the `.kiro/settings/` FILE family: `mcp.json` (home +
workspace, watched), `permissions.yaml` / `permissions.json` (watched),
`knowledge.json` (`indexType` only), workspace `lsp.json`, `kiroignore`,
plus admin `/etc/kiro/managed-settings.json` (per-OS paths). The CLI's
key-value settings store (`kiro-cli settings`, the `chat.*` keys) has **no
engine reader** — `chat.defaultModel` included (G2). Settings-shaped inert
keys verified inert engine-side: `thinking`, `todoList`, `_delegate`,
`_subagent` (schema-accepted, consumed by nothing). The KRS experiment fetch
is DEAD at 2.15.1 (`EXPERIMENT_CONFIG_ENABLED = false`, no env override) —
experiments cannot flip anything at this version.

### 4.2 Env vars (engine-meaningful subset)

`ACP_WS_PORT` (ws port, default 8082), `KIRO_API_KEY` (auth-provider apiKey
mode — bypasses the callback flow; precedence vs `--auth=acp-callback`
untraced), `KIRO_LOG_LEVEL`, `KIRO_CHAT_LOG_FILE`, `KIRO_DISABLE_RECAP`,
`KIRO_CONTENT_COLLECTION_ENABLED`, `KIRO_CUSTOM_USER_AGENT`,
`KIRO_TOOL_SEARCH_THRESHOLD`, `KIRO_DUMP_REQUESTS`, `GLOBAL_ENV_FILE`,
endpoint overrides (`CLOUD_CONFIG_ENDPOINT`, `KIRO_REMOTE_SESSIONS_ENDPOINT`).
`KIRO_HOME` has ZERO engine hits — `HOME` is the isolation lever. Client-side
(Rust) levers for the ACP arm: `KIRO_KAS_NODE_PATH` / `KIRO_KAS_SERVER_PATH`
(pin a custom node/engine build — the override rung above embedded
extraction), `KIRO_MOCK_ACP` (client-side mock, no engine). Full enumeration
with offsets: acp-config.md ENV section.

### 4.3 Argv

Engine argv = 15 `--name=value` flags (`--transport`, `--auth`,
`--token-path`, `--region`, endpoints, `--execution-environment`,
`--home-dir`, `--sandbox*`, `--test-traffic`); empty value = exit 1. The
launcher passes exactly `--transport=stdio --auth=acp-callback`. Launcher
argv model, flag positions, the v3+`acp` conflict set and its
`--agent-engine=v2` escape hatch: companion doc §1–3 (settled).

### 4.4 Session `_meta` flags and config options (G9)

Resolver defaults: `semanticReview.enabled` → **true** (inverse default —
the discriminator), `fta.enabled` / `workflows.enabled` / `specPlan.enabled`
→ false, `specPlan.workflow` → `"quick"`, `specPlan.skipClarification` →
true. FTA = **Functional Task Alignment** validator sub-agent. Writers:
(a) client `_meta.kiro.settings` at `session/new` / `session/load` — the
shipped client's fixed 23-key allowlist CANNOT set
workflows/fta/goal/specPlan/semanticReview; an external ACP client can;
(b) persisted metadata fallback on `session/load` (editing `session.json` is
the no-patch enable path); (c) experiments — dead at 2.15.1 (§4.1). Flags
resolve ONCE per create/load; not toggleable mid-session. Consumers: bundled
agent-profile loading, workflow steering + tools, quick-spec vs spec mode.

`session/set_config_option` configIds: `mode`, `model`, `effortLevel`,
`autopilot`, `contentCollection`, `sandbox`, `sandboxNetworkMode`,
`mcpSandboxing`, plus `_meta.kiro.mcpServers` to live-update the MCP roster.
The sandbox trio is process-global (fans out to all sessions).

### 4.5 initialize-time clientMeta levers (external-ACP-client only)

Read from `initialize.clientCapabilities._meta.kiro`: `telemetryEnabled`,
`telemetry`, `specLinks`, `requirementsAnalysis`, `userInput`, `helpDocs`,
`settings` (initialize-time settings channel — `settings.goal` unlocks
`/goal ` prompt parsing), `hooks` (selects the delegating hook binding),
`secretStorage`, `openExternalUrl`, `knowledge`, `infrastructureSafety`,
`c2sViews` — **plus two the wireline doc's list missed, settled by the f10
verification passes:** `backgroundProcesses: true` (connection-scoped,
immutable; the ONLY way to enable `control_bash_process` /
`control_pwsh_process` / `list_processes` / `get_process_output`; note
`get_process_output` with `lines` omitted returns the FULL buffer despite its
"defaults to 100 lines" description) and
`settings.largeToolOutputHandler.enabled` (routes successful ≥30k-char
`execute_bash` output into a session file, replaced in context by a
500+500-char head/tail reference; default off).

### 4.6 Model selection (G2/G3 verdicts)

- **G2 verdict: the engine never reads `chat.defaultModel`** (0 bundle hits,
  positive controls found). It is client-side sugar: after `session/new` the
  shipped client applies `--model` (wins) or `chat.defaultModel` via
  `session/set_config_option {configId:"model"}`. External-client topology:
  inert.
- **G3 verdict: two live wire paths, one dead verb.**
  (1) `session/new` `_meta.kiro.modelId` + `effortLevel` — persisted under
  `_meta.kiro` in `session.json`, unvalidated record; a malformed
  `_meta.kiro` drops the WHOLE meta silently, so always verify persistence.
  (2) `session/set_config_option {configId:"model"}` — writes the top-level
  `session.json` `modelId`, the effective field; `effortLevel` validated
  against the model's levels, invalid silently ignored. (3) `session/set_model`
  → -32601, dead.
- Precedence: `set_config_option "model"` > `_meta.kiro.modelId` at new >
  agent-profile `model` (only when nothing explicit) > engine pin (catalog
  `defaultModel` → first model) > `'auto'` sentinel.
- **Auth-state coupling (live):** token-free the model catalog never loads —
  no `model`/`effortLevel` configOptions are advertised, a BOGUS model string
  persists unvalidated, and effort does not persist at all. "Invalid silently
  ignored" holds only WITH a token. Setting a model can silently change
  effort (`applyModelId` reconciliation).

## 5. Wireline discipline

- **Stream rules:** stdout = frames only; stderr = logs; newline-delimited;
  answer agent→client requests out-of-order by id; expect notifications
  interleaved everywhere. Replayed `session/load` history carries
  `_meta.kiro.replay:true`.
- **Error taxonomy:** -32700 parse; -32600 invalid request; -32601
  method-not-found (`data.method`); -32602 invalid params (SDK Zod
  `data` = ZodError.format(), or Kiro `InvalidParamsError`); -32603 internal
  (thrown `Error` message in `data.details`; if the message parses as JSON it
  BECOMES `data` — a real quirk); -32000 the Kiro `AgentError` family
  (`SessionNotFoundError`, `TokenExpiredError`, `TokenInvalidError`,
  `ContextWindowExceededError`, …); -32002 resource-not-found.
- **Three-outcome probe classification** (how every method above was
  settled): a call yields (a) a result, (b) a reached-handler param error
  (-32602 or a handler-specific -32603), or (c) -32601 never-reached. Two
  -32603 fingerprints disambiguate the ext layers:
  `[PersistenceClassification] Ext method … has no persistence classification`
  = name unknown to the allowlist;
  `Unknown ext method: …` = allowlisted but no request handler (the
  notification-only trap). Domain failures may be `{success:false, message}`
  RESULTS — never key health on error frames alone.
- **Concurrency:** the engine starts streamed tool calls eagerly with no
  concurrency bound and multiplexes agent→client requests — clients must
  tolerate N outstanding requests.

## 6. Gaps ledger (G1–G10 from the companion doc)

| gap | status | verdict |
| --- | ------ | ------- |
| G1 — does v2 `acp` honor `--model`/`--agent`/`--effort`? | **OUT OF SCOPE** (v2-only) | Unresolved; needs a credit-burning prompt-level comparison on v2. |
| G2 — does the v3 engine read `chat.defaultModel`? | **CLOSED** | No. Client-side sugar over `set_config_option "model"`; inert for external clients (§4.6). |
| G3 — any per-session model selection on v3 ACP? | **CLOSED** | Yes: `_meta.kiro.modelId` at new + `set_config_option "model"`; `session/set_model` dead. Residue (flagged): end-to-end proof the pinned id SERVES the turn = SPEC-M1, one real-token prompt. |
| G4 — what do the 7 advertised ext methods do? | **CLOSED** | Full schemas + live results (§3.2). `codeIntelligence` = LSP roster/init/overview, no symbol queries (those ride client-tool delegation). |
| G5 — real-auth v3 end-to-end | **NARROWED** | Token-free surface fully mapped: EVERYTHING is reachable; a token buys only catalog/validation, usage data, and turns. Remains: the real-token arm. Cheapest probe: SPEC-M2 — real auth, NO prompt: `set_config_option model=bogus` → expect rejection + 5 configOptions. |
| G6 — `agentInfo.version` 2.15.1 from a 2.15.2 binary | **NARROWED** | Mechanism identified: the KAS engine is a separately versioned, content-hashed bundle (`kas/2.15.1-<sha256>/…`) extracted by the client; `agentInfo.version` reports the ENGINE's version. 2.15.2 CLI ships a 2.15.1 KAS. Cheapest probe: `ls ~/.local/share/kiro-cli/kas/` on 2.15.2 vs one handshake's `agentInfo.version`. |
| G7 — `kiro-cli-chat --v3 acp` vs launcher | **NARROWED** | Conflict guard lives in the CHAT binary keyed on `acp`'s explicit `--agent-engine`; the `--v3` translation lives ONLY in the launcher. One flagged inference: `kiro-cli-chat --v3 acp` runs v2 → the launcher is canonical. Cheapest probe: spawn `kiro-cli-chat --v3 acp` stdin-closed; v3 prints the acp-callback INFO line on stderr line 1, v2 is silent. |
| G8 — why the v3 acp arm forbids the five flags | **CLOSED** | Deliberate: bespoke post-parse guard, value- and subcommand-specific; the v3 acp topology has no consumer for them; every one has a protocol/file intake instead. Do not wait for upstream; route through the protocol. |
| G9 — session `_meta` flags, and what FTA is | **CLOSED** | Defaults/writers/consumers table (§4.4); FTA = Functional Task Alignment validator sub-agent. Correction over acp-config: the experiments contributor is DEAD at 2.15.1, so the "experiment made it behave enabled" replay trap is theoretical at this version. |
| G10 — log channels + "powers" | **CLOSED** | `kiro`/`mcp`/`powers` JSON-line files under `~/.kiro/logs/<stamp>/`, `MAX_LOG_DIRS=10`, level via `KIRO_LOG_LEVEL`; sandbox mode collapses to one `kiro-agent.log`. Powers = plugin/packaging primitive (`~/.kiro/powers/installed/<name>/POWER.md`, `kiro_powers` tool, `_kiro/powers/refresh` / `items_changed`, `_providerPowers` experiment). |

## 7. Verification story — exact re-runs

All against KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`,
measured 2026-07-30. No probe below consumes credits: no `session/prompt` is
ever sent, and the driver answers `_kiro/auth/getAccessToken` with a JSON-RPC
error (never reads the operator's credential store).

**Argv contract** (seconds, no ACP): run the four-check block in
`private/kiro-acp-and-launcher-argv.md` §"Argv-contract probe" — prepend-ok,
append-fails, `--v3` translation intact, escape hatch intact.

**Live ACP probes** — driver + step files preserved in
`private/kiro-phase2/probes/`:

- `acp-drive.py` — generalized stdio driver (id-matching inbox, token
  refusal, JSONL frame capture, `${VAR}` substitution, killpg teardown).
  Edit the `KIRO` constant to the current store path first
  (`nix build --no-link --print-out-paths .#kiro-cli`).
- `steps-1-ext.json` — advertised + unadvertised ext sweep (§3.2/3.3 + the
  three-outcome fingerprints).
- `steps-2-workflow.json` + `drain.workflow.json` — workflow `new` /
  `inspect` / `list` / `delete` round trip, `listRecipes`,
  `listWatchHandlers`.
- `steps-3-model.json` — G3 live half: `_meta.kiro.modelId` persistence,
  top-level-key strip, `set_config_option` model/effort/autopilot,
  `session/set_model` → -32601.
- `steps-4-refine.json`, `steps-5-rename.json` — permissions/policy/steer
  refinements; rename/delete persistence.
- `steps-6-recipes.json` — `listRecipes` with and without `workspacePaths`,
  for the per-recipe `plan` field. Closed R-1/R-19 in
  `dev/references/kiro-workflow-ref.md` §3; needs no `workflows` unlock, no
  session and no credentials, so it is the cheapest probe here.

```bash
P=private/kiro-phase2/probes
mkdir -p /tmp/acp-home /tmp/acp-ws
python3 "$P/acp-drive.py" ext /tmp/acp-home /tmp/acp-ws \
  "$P/steps-1-ext.json" /tmp/frames-ext.jsonl
python3 "$P/acp-drive.py" workflow /tmp/acp-home /tmp/acp-ws \
  "$P/steps-2-workflow.json" /tmp/frames-wf.jsonl "$P/drain.workflow.json"
python3 "$P/acp-drive.py" model /tmp/acp-home /tmp/acp-ws \
  "$P/steps-3-model.json" /tmp/frames-model.jsonl
```

Pass criteria: `initialize` advertises exactly the 7 extensionMethods of
§2 with `sourceProviders:false`; `session/new` `_meta.kiro` matches §2
verbatim (3 configOptions token-free); the five error fingerprints of §5
reproduce; the four persisting calls (`rename`, `delete`,
`set_config_option`, `workflow/new`) leave the documented on-disk deltas
under the scratch HOME (`session.json`, `workflows/`) — except
`_kiro/session/export`, which writes under `$TMPDIR/kiro-exports/`.

Known environment hazard: orphaned engines from OTHER versions survive on the
machine (a 2.13.0 `acp-server.js` was found running at probe time).
`pgrep -fa acp-server` before and after; kill only your own process group.
