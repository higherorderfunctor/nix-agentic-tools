> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# ACP-P — live read-only ACP probe of the v3 engine (G4, G5-partial, G3 live half)

Method: five scripted stdio sessions driven through
`/nix/store/3xcnc3lw1r36ngzkifxjxd82r2sh8jz2-kiro-cli-2.15.1/bin/kiro-cli acp --agent-engine v3`,
each with `HOME` set to a fresh scratch dir, `XDG_DATA_HOME` left real,
`KIRO_LOG_LEVEL=debug`. The client answers every agent->client
`_kiro/auth/getAccessToken` with a JSON-RPC error and NEVER sends
`session/prompt`. Driver + step files + verbatim frame captures live under
`.../scratchpad/acp/` (`acp-drive.py`, `steps-{1..5}-*.json`,
`frames-{ext,workflow,model,refine,rename}.jsonl`, `out-{1..5}-*.json`). No
model call, no credits.

**Teardown disclosure (SEQUENCE step 0/7).** Baseline `pgrep -fa acp-server`
before any spawn: ONE process, `PID 3971258 ... kas/2.13.0-6b915aea.../acp-server.js --transport=stdio --auth=acp-callback`
— a pre-existing orphaned KAS **2.13.0** engine, NOT mine, left running. After
all five probes and killpg teardown, `pgrep -fa acp-server` shows the SAME single
2.13.0 orphan and zero 2.15.1 engines. All five engines I spawned exited (probes
2 and 5 exited 0 on stdin-close; probes 1/3/4 held a live-session auth-refresh
loop and took SIGKILL from killpg after the 8 s wait — expected, not a defect).

---

## 1. The question

G4: enumerate the live v3 ACP surface reachable with no token, no model, no
seeded session — every advertised extension method, the unadvertised workflow
methods, and standard session methods — recording each handler's harvested Zod
param error (the schema documentation) and, where read-only-safe, its real
result. G5-partial: which of those are reachable token-free vs token-gated. G3
live half: does a `model`/`effortLevel` reach and persist, and is an unknown
top-level key stripped or rejected. "Settled" = each method classified
result / reached-handler-param-error / method-not-found, with the discriminating
frame cited.

## 2. What is already known (going in)

- ACP-W (`private/kiro-phase2/acp-wireline.md`): standard + advertised + 14
  unadvertised workflow methods, the agent->client `_kiro/auth/getAccessToken`
  request, error-code taxonomy, `session/update` kinds. This probe CONFIRMS the
  wireline read against a live engine.
- ACP-C / G2,G3,G9 (mission CONFIG DIGEST): model-free handshake; per-session
  model via `_meta.kiro.modelId` + `set_config_option`; `set_model` unimplemented;
  session/new `_meta` defaults (`semanticReviewEnabled:true`, rest false,
  `specWorkflow:"quick"`).
- Corpus C-4 (two-engine hook split), C-11 (`workflows` env inert), settled
  facts on `workflowsEnabled:false` at session/new.

## 3. The interface, fully enumerated (all verbatim from frames)

### 3.1 `initialize` result

`protocolVersion: 1`. `agentCapabilities`:
`loadSession:true`; `promptCapabilities:{image:true, embeddedContext:true}`;
`mcpCapabilities:{http:true, sse:true}`;
`sessionCapabilities:{list:{}, fork:{_meta.kiro.messageId:true}}`.
`_meta.kiro`: `checkpoints:true`, `sessionList:true`,
`policyNotifications:true`, `sessionSources:["local"]`,
`sessionListScopes:["workspace"]`, `executionTargets:["local"]`,
`sourceProviders:false`, `replayMarking:true`, and
`logging:{logDir, channels:[kiro,mcp,powers]}` (paths under
`<HOME>/.kiro/logs/<stamp>/`).
`extensionMethods` (EXACTLY 7, in order):
`_kiro/knowledge`, `_kiro/codeIntelligence`, `_kiro/session/context`,
`_kiro/session/compact`, `_kiro/session/export`, `_kiro/session/history`,
`_kiro/config/template`. `authMethods:[aws-builder-id, aws-iam-identity-center]`.
No `sourceProviders/list` in the advertised set (`sourceProviders:false` = the
unwired case ACP-W predicted). **No model/effort key anywhere in the handshake**
— confirms the argv-doc read-side finding live.

### 3.2 `session/new` result (params `{cwd, mcpServers:[]}`)

Top-level keys: `_meta`, `configOptions`, `modes`, `sessionId`.
`_meta.kiro`: `schemaVersion:"1.0.0"`, `id`, `title:"New Session"`,
`agentMode:"vibe"`, `workspacePaths:[cwd]`, `createdAt`, `lastModifiedAt`,
`semanticReviewEnabled:true`, `ftaEnabled:false`, `workflowsEnabled:false`,
`specPlanEnabled:false`, `specWorkflow:"quick"`,
`specSkipClarificationEnabled:true`, `source:"local"`. **Confirms G9 + the
mission's stated v3 session/new `_meta` verbatim.**
`modes.availableModes` = 7: `vibe` (name "Default"), `spec`, `quick-spec`,
`bug-fix`, `plan`, `autonomous`, `semantic_reviewer`; `currentModeId:"vibe"`.
`configOptions` at session/new = **exactly 3** (token-free): `mode`
(select, 7 values = the mode ids, current `vibe`), `autopilot`
(select `on|off`, current `on`), `contentCollection` (select
`enabled|disabled`, current `enabled`). **No `model` or `effortLevel`
configOption appears token-free** — see 3.5.

### 3.3 Advertised extension methods (harvest `{}` -> reached-handler error; then real)

| method | `{}` outcome | real call outcome |
|---|---|---|
| `_kiro/knowledge` | RESULT `{success:false,"Unknown subcommand: undefined"}` | `{subcommand:"show"}` -> `{success:true,entries:[]}`; subcommands (bundle) = `add,remove,show,update,clear,cancel` |
| `_kiro/codeIntelligence` | RESULT `{success:false,"Session not found: undefined"}` | `{sessionId}` -> `{success:false,"Code intelligence is not enabled for this session"}` |
| `_kiro/session/context` | RESULT `{success:false,"Session undefined not found",entries:[]}` | `{sessionId}` fresh -> `null` |
| `_kiro/session/history` | ERR -32000 `Session 'undefined' not found` | `{sessionId}` -> `{updates:[],hasMore:false}` |
| `_kiro/session/export` | ERR -32603 `{details:"Invalid sessionId"}` | `{sessionId}` -> `{success:true, filePath:"/tmp/kiro-exports/kiro-session-<id>.zip"}` — **writes OUTSIDE scratch HOME** (see 6) |
| `_kiro/session/compact` | ERR -32000 `Session 'undefined' not found` | `{sessionId}` fresh -> `{success:true}` (no-op) |
| `_kiro/config/template` | RESULT: static `{modes, configOptions}` (same modes block as session/new) | reads nothing from caller, writes nothing — confirms G3 |

### 3.4 Unadvertised extension surface (all reachable token-free)

| method | harvested / real | notes |
|---|---|---|
| `_kiro/sourceProviders/list` | ERR -32000 `no source provider catalog is configured` | confirms `sourceProviders:false` unwired |
| `_kiro/session/list` | RESULT `{sessions:[...]}` token-free | per-session `_meta.kiro.{agentMode,createdAt,source,executionTarget,...}` |
| `_kiro/session/rename` | `{}` -> -32602 `title must be a non-empty string`; `{sessionId,title}` -> `{success:true}` | **persists**: `session.json` `title` rewritten on disk (verified) |
| `_kiro/session/delete` | `{}` -> -32603 `Invalid sessionId`; `{sessionId}` -> `{success:true}` | removes session dir; gone from subsequent `list` |
| `_kiro/permissions/list` | `{}` -> -32603 `Unknown session: undefined`; `{sessionId}` -> full default ruleset | see 3.6 |
| `_kiro/permissions/explain` | `{}` -> `Unknown session`; `{sessionId}` -> -32603 `Either capability or toolId is required` | needs `{sessionId, capability|toolId}` |
| `_kiro/policy/check` | `{}` -> `Unknown session`; `{sessionId}` -> -32603 `Invalid or missing capability: undefined` | needs `{sessionId, capability}` |
| `_kiro/account/getUsage` | RESULT `{success:false,"Failed to retrieve usage information: Authentication failed..."}` | **reachable token-free, DATA token-gated, does NOT stall** (G5) |
| `_kiro/safety/getProperties` | `{}` -> -32603 `sessionId is required`; `{sessionId}` -> `{properties:[]}` | |
| `_kiro/hooks/list` | ERR -32603 `_kiro/hooks/list is not available when v2Hooks is disabled` | **v2-only method; v3 hooks are a different path — live corroboration of C-4** |
| `_kiro/spec/getTaskStatuses` | `{}` -> -32602 `workspacePaths must be a non-empty array`; `{workspacePaths}` -> `{tasks:[]}` | |
| `_session/steer` | `{}` -> -32603 `missing or invalid sessionId`; `{sessionId}` -> -32603 `missing or empty message` | needs `{sessionId, message}` |
| `_session/steer/clear` | `{sessionId}` -> `{cleared:true, messageIds:[]}` | token-free |
| `_kiro/mcp/getPrompt` / `getResource` | -32603 `No connected MCP server: undefined` | reached; need a wired server |
| `_kiro/powers/refresh` (as REQUEST) | ERR -32603 `Unknown ext method: _kiro/powers/refresh` | confirms ACP-W notification-only |
| `session/set_mode` | `{}` -> -32602 (modeId+sessionId required); `{sessionId, modeId:"plan"}` -> `{}` | switch succeeds token-free |
| `session/fork` | `{}` -> -32602 (cwd+sessionId required); `{sessionId,cwd}` on a message-less session -> -32603 `No effective messages to fork from` | fork needs prior conversation; unreachable token-free on a fresh session |
| `session/set_config_option` | `{}` -> -32602 (configId/value/type) | see 3.5 |
| `session/load` | `{}` -> -32602 (sessionId+cwd+mcpServers required); `{sessionId,cwd,mcpServers}` of a real id -> full session hydrated | |

### 3.5 Model + effort live half (G3)

- **Unknown top-level key stripped, not rejected.** `session/new` with an extra
  top-level `model:"..."` -> session created normally, key absent from persisted
  `session.json`. Confirms `zNewSessionRequest` strips unknown keys (G3).
- **`_meta.kiro.{modelId,effortLevel}` at session/new persist under `_meta.kiro`**
  in `session.json` (e.g. `_meta.kiro.modelId:"probe-meta-model-id"`,
  `effortLevel:"high"`). Unvalidated record, exactly as G3 says.
- **`set_config_option configId "model"` persists a TOP-LEVEL `modelId`** on
  `session.json` (e.g. `modelId:"probe-bogus-model-xyz"`), distinct from the
  `_meta.kiro.modelId`. `configId "autopilot" value "on"` persists top-level
  `autopilot:true`.
- **Token-free, model validation does NOT happen.** A bogus model string
  persisted with no rejection. The engine log shows why:
  `network.listAvailableModels.error ... TokenExpiredError` then
  `[ACPModelConfigProvider] Failed to refresh models`. The model catalog never
  loads without a token, so (a) no `model`/`effortLevel` configOption is ever
  advertised, and (b) any model string is accepted unvalidated. **This qualifies
  G3's "invalid silently ignored": that holds only WITH a token; token-free,
  invalid persists.**
- **`set_config_option configId "effortLevel" value "low"` returned success and
  fired a `config_option_update` notification, but did NOT write a top-level
  `effortLevel` to `session.json`** (only the session/new `_meta.kiro.effortLevel`
  remained). Effort reconciliation (`applyModelId`) needs the model's default
  from the catalog, which was unavailable token-free. Effort persistence is
  therefore also token-gated.
- **`session/set_model` -> -32601 `Method not found`** (data `{method:"session/set_model"}`).
  Confirms ACP-W + G3: `unstable_setSessionModel` never implemented. SOLID.

### 3.6 `_kiro/permissions/list` default ruleset (verbatim highlights)

Denies `fs_write` to `~/.kiro/settings/`, `.kiro/settings/`,
`~/.kiro/workspace-roots/`, `~/.kiro/sandbox-state/` (`scope:kiro`). Asks on
`fs_write` to `.git/**`, `.vscode/**`, `.kiro/agents/`, `.kiro/hooks/`,
`**/*.code-workspace`, `**/mcp.json` (+ many homoglyph variants). Allows
`fs_read ./**`; a curated read-only `shell` allowlist (pwd/whoami/git-status/
git-log/git-diff/npm-list/docker-ps/kubectl-get/... — read verbs only);
`web_fetch kiro.dev`; `subagent` allowlist
`[context-gatherer, custom-agent-creator, general-task-execution, introspect]`.
Sources: `kiro-scope` (built-in) + `agent-profile`.

### 3.7 Workflow extension surface (14 request methods — matches ACP-W "14, not 20")

`{}` outcomes (reached-handler param errors): `new` -> -32603 `requires one of
` \`workflowPath\` ` or ` \`workflow\``; `load`/`cancel`/`inspect`/`resume` ->
-32603 `The "path" argument must be of type string`; `pause` -> `Workflow
'undefined' is not registered`; `list` -> `workspacePaths is not iterable`;
`update` -> `` `status` is required for action `update_status` ``; `retry` ->
`Workflow 'undefined' is not registered. Load or create it first`. The six
notification names sent AS requests
(`run_start`, `node_paused`, ...) -> -32603
`[PersistenceClassification] Ext method "_kiro/workflow/run_start" has no
persistence classification. Add it to KnownExtMethod in
persistence-classification.ts` — live proof they are notifications, not request
handlers, naming the source file.

Real results (token-free, NO model, NO seeded session, using the harness drain
definition):

- `list {workspacePaths}` -> `{runs:[...]}` (`{workflowId,name,status,createdAt,updatedAt}`).
- `new {workspacePaths, workflow}` -> `{workflowId:"wf_<16hex>", initialState}`.
  `initialState` keys: `artifacts, capturedOutputs, createdAt, planRevision,
  root, status, workflowId, workflowName, workspacePath`. `status:"running"` but
  `root` (`type:"sequence"`) is `status:"pending"` with the single `parallel`
  child also `pending`, children unexpanded — **created, NOT started** (confirms
  ACP-W: `new` returns state without running; nothing dispatched, no model).
  Persisted to `<HOME>/.kiro/sessions/<bucket>/workflows/`.
- `inspect {workflowId}` -> `{workflowId, state}`. `list` after `new` shows the
  run; `delete {workflowId}` -> `{ok:true}`; `list` after `delete` -> `{runs:[]}`.
- `listRecipes {}` -> the **7 bundled recipes** with `source:"bundled://<name>"`
  and input schemas: `autoresearch{benchmark_path:string, research_directions:string}`,
  `feature-pipeline{task:prompt, workdir:string}`, `goal{prompt:prompt,
  max_iterations:string}`, `investigate{brief:prompt, report_path:file}`,
  `publish-pr{branch:string}`, `ralph{goal:prompt, prd_path:file}`,
  `semantic-review-multi-model{target:prompt, workdir:string}`.
- `listWatchHandlers {}` -> **2 handlers** (NEW, not previously enumerated live):
  `crux-cr` ("Polls an Amazon Crux code review ... via the `cr` CLI",
  `defaultPollIntervalSec:60`, `minPollIntervalSec:30`, configSchema
  `{crRef,crId,pollIntervalSec,commandTimeoutSec}`) and `github-pr` ("Polls a
  GitHub pull request ... via the `gh` CLI", same intervals, configSchema
  `{prRef,url,pollIntervalSec,commandTimeoutSec,includeOwnActivity,ignoreAuthors[]}`).
- `resumeAll {}` -> `{resumed:[],skipped:[],errors:[]}`.

### 3.8 Notifications observed (client-inbound, per session)

At session/new the engine emits: `_kiro/governance/state`, `_kiro/mcp/status`,
`_kiro/powers/items_changed`, `_kiro/steering/documents_changed`,
`_kiro/tools/didChange`, `_kiro/sessions/changed`,
`_kiro/progressive_context/items_changed`, plus `session/update` of kinds
`available_commands_update` and `session_info_update`. `set_config_option`
adds `config_option_update`. `set_mode`/rename add `_kiro/policy/changed`.
The `available_commands_update` for default `vibe` mode advertised **5**
commands: `architecture-selection`, `quick-spec`, `bug-fix`,
`general-task-execution`, `context-gatherer` (F2-relevant: these are the
runtime-advertised slash commands for the default mode, token-free).

## 4. Activation drivers

Every method in section 3 is reachable by an **external-ACP-client** with no
token, no model, no seeded session — that is the whole point of this probe. The
same surface is also reachable:

- **user-typed** — the shipped TUI/client wraps a subset as slash commands
  (`available_commands_update` lists 5 for `vibe`); `/goal`, `/workflow-*` are
  the client-side names (see F1/F2, out of scope here).
- **agent-system-prompt-driven / model-elected** — irrelevant to this surface:
  these are host/client protocol methods, not model tools. The model reaches
  workflows only via the in-session tool (`validate_workflow` etc.), a different
  path.
- **workflow-step-driven** — a running workflow emits the `_kiro/workflow/*`
  notifications; `resumeAll` is what a client calls on reconnect.
- **hook-driven** — none of these are hook-triggered.

Net: this is the **host/client control surface**, and the driver that pulls
every lever is the ACP client (whether the shipped one or an external one). No
token needed to reach any of it; a token is needed only to (a) load the model
catalog (unlocking model/effort validation + configOptions), (b) return real
`account/getUsage` data, and (c) run any actual turn.

## 5. Fixture design

The live surface is directly fixturable **without a model**: the driver
`acp-drive.py` + a JSON step list is the cheapest mode. The discriminating
observable per method is the three-way outcome (`result` / reached-handler
`-32602`|`-32603` param error / `-32601` method-not-found) plus, for the four
persisting methods (`rename`, `delete`, `set_config_option`, `workflow/new`), the
on-disk `session.json` / `workflows/` delta. Positive control that the engine is
the v3 KAS: `initialize._meta.kiro.extensionMethods` = the exact 7 in 3.1 and
`session/new._meta.kiro.workflowsEnabled:false`. All of section 3 is a RUN, done.

**Two things remain fixture SPECs (need one real token, never run here):**

- **SPEC-M1 (does the wire honor `session.modelId` end-to-end).** With a valid
  token, `session/new {_meta.kiro.modelId:<real>}` then one `session/prompt`;
  observe the `usage_update`/converse model. Discriminator: the model that runs
  != `'auto'` and == the pinned id. Closes C-5 caveat and G3's open item.
- **SPEC-M2 (model/effort validation + configOption materialization).** With a
  token, repeat 3.5 `set_config_option model=<bogus>`; discriminator: bogus is
  now REJECTED and a `model`+`effortLevel` configOption appears in the echoed
  `configOptions` (both absent token-free). Proves validation is catalog-gated.

## 6. Cross-interactions / disclosures

- **`_kiro/session/export` writes to `/tmp/kiro-exports/` — OUTSIDE the scratch
  HOME.** I created `/tmp/kiro-exports/kiro-session-sess_7f30a5a4-...zip`
  (555 bytes, contains `<id>/session.json`). The export path is not
  HOME-relative; a fixture that asserts "writes only under scratch HOME" would
  FAIL on export. Disclosed, not cleaned (harmless scratch artifact).
- **Model/effort config is coupled to the auth/catalog state**, not just the
  session: token-free you get 3 configOptions and unvalidated model persistence;
  with a token you get 5 and validation. A fixture pinning "session/new advertises
  N configOptions" is auth-state-dependent — pin the token-free N=3 explicitly.
- **`_kiro/hooks/list` is v2-only** (`not available when v2Hooks is disabled`);
  do not treat its absence as "v3 has no hook introspection" — v3 hooks are the
  KAS-side path (C-4). The client-answerable `_kiro/hooks/{list,sessionStart,
  executeHook}` requests (ACP-W) are the v3 direction (agent->client), a
  different surface than this agent-side method.
- **`set_config_option model` and `_meta.kiro.modelId` write DIFFERENT fields**
  (top-level `modelId` vs `_meta.kiro.modelId`) that coexist in one
  `session.json` — consistent with G3's precedence `set_config_option >
  _meta.kiro.modelId` (the top-level field is the effective one).
- **`session/fork` is unreachable on a message-less session** (`No effective
  messages to fork from`); forking is not a token-free capability on a fresh
  scratch session — it needs prior conversation, i.e. a token.
