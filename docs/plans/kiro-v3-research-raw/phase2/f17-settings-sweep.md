> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# F17 — Undocumented settings sweep + the "full parent context to subagent" claim

## 1. The question

Two parts, each with a testable "settled" condition:

**A (the claim).** Does any setting — settings-file key, `_meta.kiro.settings`
key, env var, or agent-profile field — cause a dispatched subagent to receive
the FULL PARENT conversation history? Settled = either a consumer-traced lever
that changes what the dispatch context forwards, or a bounded negative with
positive controls at the one site that could forward it.

**B (the sweep).** Enumerate every settings key the ENGINE (KAS bundle) reads
and every key the CLIENT (Rust binaries) knows, with type, default, consumer,
gate, and documented-vs-undocumented status. Settled = a key list whose
denominators are named and whose consumers are traced (C-11: registered-but-
unconsumed is a distinct state).

## 2. What is already known (corpus / docs)

- `records/hooks-dispatch-gate.md` R-hooks-4/R-hooks-5: dispatch context
  hard-codes `previousMessages: void 0` (offset 18030796); the
  `ctx.previousMessages` read at 17712396 is reached only when the adapter opts
  in via `includePreviousMessages: true`, "but `ctx.previousMessages` is the
  `void 0` above, so both branches yield an empty previous-message list".
  `dispatchKind` (`sub-agent`|`custom-agent`|`spec`, optional, undocumented)
  picks the adapter; `custom-agent` flips `includePreviousMessages` to true.
- `records/limits-and-engine.md` R-limits-5: `AgentSettingsSchema` has exactly
  31 keys; the CLI's embedded client forwards 23 distinct `chat.*`/`toolSearch.*`
  /`knowledge.*`/`compaction.*` keys via a fixed `[cliKey, kasName]` allowlist;
  no subagent timeout/budget/concurrency key exists; `chat.disableAutoCompaction`
  and the two compaction sub-options are forwarded-but-unconsumed (inert);
  `subagentOrchestration` is defaulted ON client-side, kill-switched only by
  `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1`.
- `records/workflow-surface.md` R-workflow-2/3: `parseSettings` passes unknown
  keys through untouched (catchall); `_meta.kiro.settings.workflows` is the
  workflow enable path; the CLI's settings builder (the `[kas-settings]` log
  string) is the only producer of `clientMeta.settings`.
- `carried-negatives.md` C-11: `KIRO_ENABLED_FEATURES` is read by the CLI
  client (4 hits in the chat binary, fresh count) and its catalog's "workflows"
  entry has no consumer; verified 0 hits in the launcher and 0 in the bundle.
- Vendor docs: `private/kiro-v3-docs.md` documents ZERO settings keys (no
  `chat.*`, no `settings.json`, no `kiro-cli settings` anywhere in its 757
  lines). `private/kiro-v2-experimental.md` documents 7 `chat.enable*` keys
  (v2 doc, input only).

## 3. The interface, fully enumerated

### 3A. THE CLAIM — RULED OUT as a setting; the one code path is dead at 2.15.1

**Verdict: no setting exists that passes parent conversation history to a
dispatched subagent, at any of the four levers (settings file, `_meta.kiro.
settings`, env var, agent profile).** The only mechanism-shaped thing is the
undocumented agent-profile field `dispatchKind: "custom-agent"`, and it is
inert for this purpose:

The guard (fresh read, offset 17712368, inside
`buildDispatchedCustomAgentDefinition`):

```
contextMessages: ctx.contextMessages,
...opts.includePreviousMessages ? { previousMessages: ctx.previousMessages } : {}
```

`includePreviousMessages` occurs exactly **3** times in the bundle: the guard
plus its two call sites — `CustomAgentAdapter` (`true`) and
`DefaultSubAgentAdapter` (`false, skipHooks: true`). `adapter.buildDefinition(`
has exactly **1** caller (offset 18031114, the invoke-subagent handler), and
the `ctx` it passes is the `dispatchCtx` literal at 18030796 whose
`previousMessages: void 0` sits mid-object with **no conditional, no settings
read, no feature check** anywhere in the surrounding ±3 KB window (window
re-read this run; the only nearby conditionals are `FILE_TREE_SUBAGENTS.has()`
for extra context files and the `subagentResponse` prompt suffix). So even with
`dispatchKind: "custom-agent"` the spread produces
`{ previousMessages: undefined }` — empty history, first-turn branch,
SessionStart fires (corpus R-hooks-4).

**Positive controls** (same method finds live forwarding elsewhere):
`previousMessages` has 69 occurrences; 16 are property assignments. Live ones:
`session.previousMessages` x10 (offsets 20403036..20559411 — normal ACP prompt
turns), and the workflow-step path at 17390430:

```
const previousMessages = await host.getPersistedMessages(sessionId);
... previousMessages.length > 0 ? { previousMessages: [...previousMessages] } : {}
```

— a workflow STEP session gets its OWN persisted step history on resumed
iterations (step-session continuity, not parent context). Also
17250791/17279540 (`params.input.previousMessages` — definition plumbing) and
17715622 (`params.previousMessages` — adapter plumbing of the same void 0).

**Concept sweep** (bundle counts; a hit does not mean relevant — every hit was
windowed):

| needle                                     | hits | disposition                                                                |
| ------------------------------------------ | ---- | -------------------------------------------------------------------------- |
| `parentContext`                            | 20   | ALL vendored OpenTelemetry span/baggage propagation                         |
| `conversationHistory` / `ConversationHistory` | 13 | prompt-assembly normalization helpers (`getUserMessagesFromConversationHistory`) |
| `passContext`                              | 2    | ajv (JSON-schema codegen) internals                                         |
| `includeContext`                           | 3    | MCP sampling param (`none`/`thisServer`/`allServers`) — MCP protocol, not Kiro dispatch |
| `passthrough`/`Passthrough`                | 66   | zod `.passthrough()` and vendor libs                                        |
| `inheritContext`, `contextInherit`, `inheritHistory`, `includeHistory`, `fullContext`, `shareContext`, `forwardHistory`, `forwardContext`, `parentMessages`, `parentHistory`, `contextPassthrough`, `inheritMessages`, `withHistory`, `carryHistory`, `keepHistory`, `historyDepth`, `fullHistory`, `entireHistory`, `copyHistory`, `transferHistory` | 0 each | absent |

Neither the 31-key engine schema, the ~65-key client table (3C), nor the engine
env-var list (3D) contains any context/history/inherit-shaped key.

**What a dispatched subagent DOES get** (so the memory has somewhere to land):
`contextMessages` is forwarded UNCONDITIONALLY — the parent's `contextFiles`
plus (for `FILE_TREE_SUBAGENTS`) a cached spec-task file tree; the vendor
comment calls this "reference context". Plausible sources of the operator's
memory, none of which is parent-conversation passing:

1. `dispatchKind: "custom-agent"` + `includePreviousMessages: true` — real
   code, reads as exactly the remembered feature, dead at the only ctx producer.
2. The `inlineAgents` schema doc-comment: "system prompt + optional
   model/effort, **inherited perms**" — permissions inheritance, not context.
3. Client key `chat.disableInheritingDefaultResources` — agent default
   RESOURCES (context files) inheritance, not conversation history.
4. v2 delegate (`chat.enableDelegate`) docs — background chat sessions; the v2
   doc makes no context-passing claim either.

**Proposed carried negative (C-15 candidate):** "No setting passes full parent
context to a dispatched subagent (KAS 2.15.1). The only opt-in
(`dispatchKind: "custom-agent"` → `includePreviousMessages: true`) forwards
`ctx.previousMessages`, whose sole producer hard-codes `void 0`
unconditionally. Positive controls: 10 live `session.previousMessages`
assignments; the workflow-step `getPersistedMessages` forwarding. Goes stale if
the `dispatchCtx` literal at the invoke-subagent handler stops hard-coding
`void 0`."

### 3B. Engine settings surface (KAS bundle)

Shapes: `BaseSettingSchema = z.object({ enabled: z.boolean() })` (strict per
key — `isSettingEnabled` returns `val.enabled` only when the value is an
object, else **false**, so a bare boolean value is silently ignored).
`AgentSettingsSchema = BaseAgentSettingsSchema.catchall(...)` — unknown keys
pass through (corpus R-workflow-2). **Five** keys carry typed sub-options (the
corpus counted four; `specPlan` is a fifth via `.extend` rather than
`createToolConfigSchema`): `toolSearch{minPct,minTokens,neverDefer}`,
`knowledge{includePatterns,excludePatterns,maxFiles,chunkSize,chunkOverlap,indexType}`,
`compaction{excludePercent,excludeMessages}`, `sessionEviction{maxBytes}`,
`specPlan{workflow:"quick"|"full", skipClarification:bool}`.

Engine accessors (all three enumerated with digit-inclusive classes —
`[A-Za-z0-9_]` — after finding `isFeatureEnabled("c2s")` is invisible to
`[A-Za-z_]+`; see flags):

- `isSettingEnabled(settings, key)` — 9 call sites, keys: `codeIntelligence`,
  `goal`, `inlineAgents` x2, `knowledge`, `_providerPowers`,
  `subagentOrchestration` x2, `toolSearch`.
- `isFeatureEnabled(name)` — 15 distinct names: `c2s` **x5**,
  `infraSafetyEnforce`, `infraSafetyMonitor`, `largeToolOutputHandler`,
  `memoryEnable`, `mergeVibeSpec`, `parallelTasks`, `_providerPowers`,
  `quickSpec`, `requirementAnalyzer`, `sessionRecap`, `steeringReminders`,
  `subagentOrchestration`, `toolSearch`, `verifyFirstWorkflow`.
- Resolvers (read at session/new and session/load): `resolveSemanticReview`
  (default **true**), `resolveFta` (false), `resolveWorkflows` (false),
  `resolveSpecPlan` ({enabled:false, workflow:"quick", skipClarification:true}),
  `resolveSessionEviction` ({enabled:false, maxBytes ?? 500 MB}),
  `resolveSteeringSupervisor` (enabled ?? persistedDefault, i.e. undefined).
- `isExperimentsFeatureEnabled` — named in THREE schema doc-comments
  (`_steeringReminders`, `_mergeVibeSpec`, `_c2s`) and **does not exist**: no
  definition, no call site. The real calls use `isFeatureEnabled` with the
  UNPREFIXED name. Vendor doc-comments are stale against their own bundle.

**The feature-override bridge (the sweep's biggest undocumented find).** At
`initialize` (offset ~20294308) and again at `session/load` (~20345143):

```
const rawKeys = new Set(Object.keys(kiroMeta.settings));
const bridgedIsFeatureEnabled = (feature) => {
  if (!rawKeys.has(feature)) return prev.isFeatureEnabled(feature);
  return isSettingEnabled(initSettings, feature);
};
```

The default provider answers `() => false` for everything (offset 5041063; the
model-list provider's `isFeatureEnabledFn = options.isFeatureEnabled ?? (() =>
false)`). So the `_meta.kiro.settings` bag IS the feature-flag surface: any of
the 15 `isFeatureEnabled` names can be flipped by including that literal raw
key (catchall admits undeclared ones) as `{name: {enabled: true}}`. The shipped
CLI only ever sends its fixed allowlist, so from the CLI most of these are
unreachable; an external ACP client reaches all of them. Names consumed but NOT
declared in the 31-key schema: **`memoryEnable`, `verifyFirstWorkflow`**, plus
the unprefixed twins `parallelTasks`, `steeringReminders`, `sessionRecap`,
`mergeVibeSpec`, `requirementAnalyzer`, `c2s`, `quickSpec`.

Per-key status of the 31 declared keys (consumer = engine-side; "dead" = no
literal accessor read anywhere outside the schema declaration; occurrence
counts were taken per key across the whole bundle):

| key | consumer | status/gate |
| --- | --- | --- |
| `_parallelTasks` | none (1 hit = decl) | DEAD alias; live name is raw `parallelTasks` via bridge |
| `_steeringReminders` | none | DEAD alias; live name `steeringReminders` |
| `_sessionRecap` | none | DEAD alias; live name `sessionRecap` (x2 calls); also env `KIRO_DISABLE_RECAP` |
| `_mergeVibeSpec` | none | DEAD alias; live name `mergeVibeSpec` |
| `_requirementAnalyzer` | none | DEAD alias; live name `requirementAnalyzer` |
| `_c2s` | none | DEAD alias; live name `c2s` (x5); client forwards `chat.enableC2s`→raw `c2s` only when its own catalog gate `isEnabled("c2s")` passes (KIRO_ENABLED_FEATURES) |
| `_quickSpec` | none | DEAD alias; live name `quickSpec` |
| `_subagent` | none (0 reads; `_subagent` hits beyond decl are `orchestrate_subagent` etc. substrings) | forwarded by CLI (`chat.enableSubagent`) but UNCONSUMED by engine |
| `_delegate` | none (all other hits are otel `this._delegate`) | forwarded (`chat.enableDelegate`) but UNCONSUMED by engine |
| `thinking` | none found (3 literal patterns) | forwarded; engine consumer not found — thinking display is client-side |
| `tangentMode` | none (1 hit = decl) | forwarded; UNCONSUMED (tangent is a v2 TUI feature) |
| `disableAutoCompaction` | none | INERT (corpus R-limits-5) |
| `codeIntelligence` | `isSettingEnabled` → `CodeTool` registered per session | live |
| `subagentOrchestration` | `isSettingEnabled` + `isFeatureEnabled` | live; picks `orchestrate_subagent` XOR `invoke_sub_agent` (offset 5041715); client defaults it ON in code |
| `inlineAgents` | `isSettingEnabled` x2 | live; gates `inlineAgent` field on both delegation tools; default OFF |
| `todoList` | none found; TodoList tool sits in the unconditional tool-assembly list (offset 19308601) | forwarded; engine gate not found |
| `checkpoint` | none found (quoted "checkpoint" hits are stream/debug types) | forwarded; engine gate not found |
| `semanticReview` | `resolveSemanticReview` | live; DEFAULT TRUE (matches session/new `_meta`) |
| `fta` | `resolveFta` | live; default false |
| `goal` | `isSettingEnabled(...,'goal')` | live; the /goal gate (F1) |
| `workflows` | `resolveWorkflows` | live; default false; persisted metadata wins on load (R-workflow-2) |
| `specPlan` | `resolveSpecPlan` | live; typed sub-options; default quick+skipClarification |
| `steeringSupervisor` | `resolveSteeringSupervisor` | live but SHADOW: doc comment says "runs non-blocking for evaluation only (logs + telemetry, no influence on the agent)" |
| `infraSafetyMonitor` | `isFeatureEnabled` at initialize | live; client pushes only under `KIRO_INFRA_SAFETY_ROLLOUT_ENABLED=1` |
| `infraSafetyEnforce` | same | same |
| `_providerPowers` | `isSettingEnabled` + `isFeatureEnabled` — consumed WITH the underscore (unique among `_` keys) | live |
| `largeToolOutputHandler` | `isFeatureEnabled` | live |
| `toolSearch` | `isSettingEnabled` + `isFeatureEnabled`; sub-options typed | live; also env `KIRO_TOOL_SEARCH_THRESHOLD` |
| `knowledge` | `isSettingEnabled` → Knowledge tool; sub-options typed | live |
| `sessionEviction` | `resolveSessionEviction` → `checkStorageBudget` | live; the only byte budget (500 MB disk) |
| `compaction` | none | INERT (R-limits-5); live override is the internal `compactionConfigOverride` graph channel |

### 3C. Client settings surface (Rust binaries)

`kiro-cli settings all` (and `settings list`) dump only the **stored** keys —
they are NOT a catalog. On this machine (4 keys, matching
`~/.kiro/settings/cli.json` exactly, so cli.json is the store):
`chat.enableCheckpoint=true`, `chat.enableTangentMode=true`,
`mcp.loadedBefore=true`, `chat.defaultModel="claude-opus-5"` (all `(global)`).
Note: this run may have written telemetry to data.sqlite3 (not verified).
`~/.kiro/settings.json` does NOT exist here; the chat binary nonetheless
teaches the model (v2 `session` settings tool description, offset ~7103400)
that global settings live at `~/.kiro/settings.json` and workspace settings at
`.kiro/settings.json` — a documented-path vs actual-store (`settings/cli.json`)
conflict I did not resolve further.

The chat binary (`.kiro-cli-chat-wrapped`, 555 MB; the launcher has NO settings
key table) carries one contiguous key string table at offset ~397480592,
bounded by prose on both sides (`clienttimeout` before, `failed to create http
client` after) — **64 keys + 1 ambiguous boundary**, in table order:

`telemetry.enabled`, `telemetryClientId`,
`codeWhisperer.shareCodeWhispererContentWithAWS`, `chat.enableThinking`,
`chat.enableKnowledge`, `chat.enableCodeIntelligence`, `knowledge.maxFiles`,
`knowledge.chunkSize`, `knowledge.chunkOverlap`, `knowledge.indexType`,
`chat.skimCommandKey`, `chat.autocompletionKey`, `chat.enableTangentMode`,
`chat.tangentModeKey`, `chat.enableSubagent`, `chat.delegateModeKey`,
`introspect.tangentMode`, `introspect.progressiveMode`, `chat.greeting.enabled`,
`api.timeout`, `chat.editMode`, `chat.enableNotifications`,
`chat.notificationMethod`, `api.oidc.scopePrefix`, `api.codewhisperer.service`,
`api.krs.service`, `api.cps.service`, `api.q.service`, `api.kiroauth.service`,
`mcp.initTimeout`, `mcp.noInteractiveTimeout`, `chat.defaultModel`,
`chat.disableMarkdownRendering`, `chat.defaultAgent`,
`chat.disableAutoCompaction`, `compaction.excludeContextWindowPercent`,
`compaction.excludeMessages`, `chat.enableHistoryHints`,
`chat.enablePromptHints`, `chat.enableTodoList`, `chat.enableCheckpoint`,
`chat.enableDelegate`, `chat.uiMode`, `chat.diffTool`,
[ambiguous: `chat.ui`+`cleanup.periodDays` or `chat.uicleanup.periodDays`],
`chat.disableGranularTrust`, `app.disableAutoupdates`,
`chat.autoExpandToolOutput`, `toolSearch.enabled`, `toolSearch.minPct`,
`toolSearch.minTokens`, `chat.modelDefaults`, `chat.keybindings.cancelStream`,
`chat.keybindings.closeMenu`, `chat.keybindings.quit`, `chat.allowAnimations`,
`chat.allowAsciiArt`, `chat.allowIcons`, `chat.showThinking`,
`chat.showThinkingTips`, `chat.terminalTitle`, `chat.defaultInterruptBehavior`,
`chat.keybindings.toggleInterruptBehavior`,
`chat.disableInheritingDefaultResources`, `voice.serverUrl`.

Keys found OUTSIDE that table (inline literals / other clusters, same binary):
`chat.enableC2s`, `chat.enableInfraSafetyMonitor`,
`chat.enableInfraSafetyEnforce`, `knowledge.defaultIncludePatterns`,
`knowledge.defaultExcludePatterns`, `mcp.loadedBefore`, `chat.hasSeenLogo`, and
a theme cluster at ~392327545: `chat.checkpointSeparator`,
`chat.editedFileForeground`, `chat.requestBackground`, `chat.requestBorder`,
`chat.requestBubbleBackground`, `chat.requestBubbleHoverBackground`,
`chat.slashCommandBackground`, `chat.slashCommandForeground`. (`chat.log` hits
appear to be a filename, not a key.) Denominator: prefix families
`chat|mcp|api|telemetry|app|ui|auth|desktop|acp|introspect|knowledge|toolSearch|compaction|codeWhisperer|voice`
grepped with `-aoE` over both binaries; `ui.*`/`app.kiro.dev`/`desktop.*` hits
are React/DBus/domain noise, excluded by inspection.

Scopes and validation: settings have `--global` (default) and `--workspace`
scopes; error variants `InvalidSetting` and `WorkspaceOverrideNotAllowed`
exist in the chat binary (so some keys are global-only), but the
workspace-allowed whitelist was not located as a string table (bounded stop).
The schema doc-comments' term for the v2 session-tool-settable subset,
"session_safe", appears in NEITHER binary (compiled away) — per the doc
comments, `chat.enableSubagent` and `chat.enableDelegate` are NOT session_safe;
`chat.enableThinking`, `chat.enableTangentMode`, `chat.disableAutoCompaction`,
`chat.enableCodeIntelligence`, `chat.enableTodoList`, `chat.enableCheckpoint`,
`chat.enableKnowledge` are.

v2-only (one line each, not deep-dived): the `session` tool (temporary
session-scoped setting overrides: list/get/set/reset) and the `introspect`
settings-name lookup live in the Rust chat binary's v2 engine; the v3 bundle
has an `introspect` telemetry tracking name but no session-settings tool
(`name: "session"` / settings-key literals: 0 hits in bundle).

### 3D. Environment variables (settings-adjacent)

Engine (`process.env.*` in the bundle, KIRO/relevant subset; full unique list
captured): `KIRO_API_KEY`, `KIRO_CHAT_LOG_FILE`,
`KIRO_CONTENT_COLLECTION_ENABLED`, `KIRO_CUSTOM_USER_AGENT`,
`KIRO_DISABLE_RECAP`, `KIRO_DUMP_REQUESTS`, `KIRO_DUMP_REQUESTS_DIR`,
`KIRO_LOG_LEVEL`, `KIRO_REMOTE_SESSIONS_ENDPOINT`, `KIRO_SUPERVISOR_DEBUG`,
`KIRO_TOOL_SEARCH_THRESHOLD`, `ASBX_KIRO_MANDATORY_MCPS` (comma list of MCP
server names exempted from tool filtering, `src/tools/tool-filter.ts`), plus
`DEBUG`, `LOG_STREAM`, `LOG_TOKENS`, `IS_INTERNAL`, `PRINCIPAL_TYPE`,
`AWS_LOGIN_CACHE_DIRECTORY`. None is context/history-shaped. `KIRO_HOME`: 0
hits (settled). Client-side conditional forwards (corpus R-limits-5/R-workflow-3):
`KIRO_INFRA_SAFETY_ROLLOUT_ENABLED=1` pushes the two infraSafety pairs +
`infrastructureSafety` clientMeta; `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1`
is the only off-switch for `subagentOrchestration`; `KIRO_ENABLED_FEATURES`
read by the client catalog (C-11) — its `c2s` entry IS consumed (gates the
`chat.enableC2s` forward), its `workflows` entry is not.

## 4. Activation drivers

- **`_meta.kiro.settings` feature-override bridge:** external-ACP-client ONLY
  (initialize or session/load). Not reachable by user-typed (CLI sends a fixed
  allowlist), not by model, hooks, or workflow steps.
- **`kiro-cli settings <key> <value>` (cli.json):** user-typed. Takes effect at
  next client start (client reads store once to build initialize settings).
- **v2 `session` settings tool:** model-elected (v2 chat only; not in v3 KAS).
  The model can also be TOLD to persist keys via fs_write to settings.json —
  i.e. agent-system-prompt-driven and user-typed via prompt.
- **`dispatchKind` agent-profile field:** set by whoever authors the agent
  profile (user-typed config; loadable via home or trust-gated workspace
  profiles); its effect fires when the parent model elects to dispatch
  (model-elected execution of a config-time choice).
- **Engine env vars:** user-typed at launch (or whatever spawns the engine);
  hooks inherit but cannot retroactively change the engine's env.
- **Resolver-backed session features (workflows/fta/specPlan/semanticReview/
  steeringSupervisor/sessionEviction):** external-ACP-client at session
  create/load; persisted metadata makes them sticky per session.
- **Parent-context passing:** NO driver exists (ruled out).

## 5. Fixture design

**F17-a (bridge probe, no model, no credits).** ACP-direct: initialize with
`_meta.kiro.settings = {workflows:{enabled:true}, fta:{enabled:true},
specPlan:{enabled:true, workflow:"full"}, semanticReview:{enabled:false}}`,
then `session/new`. Observable: the session/new `_meta` echoes
`workflowsEnabled:true, ftaEnabled:true, specPlanEnabled:true,
semanticReviewEnabled:false, specWorkflow:"full"` vs the known all-default
baseline (`false,false,false,true,"quick"`). Discriminates parse+resolve
end-to-end without any prompt. Extend with an undeclared key
`{memoryEnable:{enabled:true}}` — acceptance (no CORRUPTED_DATA-style
rejection) confirms catchall admits undeclared feature names; its effect is
not observable without a model, so that half stays a SPEC.

**F17-b (claim probe — SPEC ONLY, needs a model turn).** Parent session with a
`SessionStart` hook installed and a `dispatchKind: "custom-agent"` worker
profile; parent instructed to dispatch. Observable: worker fires SessionStart
(hook stdout injection tag appears in the sub-execution) — proves the
first-turn branch, i.e. empty `previousMessages`, even on the opt-in adapter.
If a context-inheritance path existed and were live, SessionStart would NOT
fire (corpus R-hooks-4: "goes stale if the dispatch context starts forwarding
real previous messages — that would make a dispatched worker stop taking the
first-turn branch"). Do not run without explicit approval (model call).

**F17-c (workspace-scope gate, no model).** `kiro-cli settings --workspace
<key> <value>` for a suspected global-only key vs a normal key; observable:
`WorkspaceOverrideNotAllowed` error vs success. WRITES to the user's config —
run only in a scratch HOME (HOME is the isolation lever, settled) and note
XDG_DATA_HOME must stay real.

## 6. Cross-interactions

- The bridge honors RAW key names only: `_parallelTasks` (declared) does
  nothing; `parallelTasks` (undeclared) works. Seven of the nine underscore
  "experimental" schema keys are dead aliases; `_providerPowers` is the lone
  underscore name that is actually consumed; `_subagent`/`_delegate` are dead
  on BOTH spellings (engine side).
- `isSettingEnabled` returns false for non-object values: sending
  `{workflows: true}` instead of `{workflows: {enabled: true}}` silently
  disables — same failure shape as the js-yaml `yes`/`no` trap.
- A `_meta.kiro.settings` bag at initialize also overrides features for every
  SESSION the connection creates; `session/load` re-bridges with the loaded
  client settings, and persisted session metadata beats client settings for
  the five resolver-backed keys on load (R-workflow-2 table).
- `chat.disableAutoCompaction`, `compaction.*` sub-options: forwarded, parsed,
  never read — do not design fixtures that assume compaction can be disabled
  (R-limits-3/C-9 worker-truncation hazard stands).
- The client's catalog gate (`KIRO_ENABLED_FEATURES`) sits IN FRONT of the
  settings forward for `c2s`: setting `chat.enableC2s=true` alone does nothing
  unless the catalog also enables `c2s` client-side; an external ACP client
  bypasses both by sending raw `c2s`.
- `settings all` cannot enumerate the key space (store dump only); the binary
  table in 3C is the only full client-side enumeration.
