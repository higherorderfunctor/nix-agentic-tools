> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# F9 — v2 experimental features: what survived into v3

## 1. The question

For each v2 experimental feature (knowledge management, tangent mode, TODO
lists, thinking tool, checkpointing, context-usage percentage, delegate):
did it graduate to first-party, stay gated, get removed, or get renamed in
the v3 (KAS) engine — verified against the bundle, not the vendor feature
table. Priority sub-question: is there still an explicit THINKING toggle,
what is its scope and default, and who can activate it. Plus: enumerate
every experiment catalog found and whether each entry has a live consumer.

"Settled" is testable as: for each feature, a named engine consumer (or a
bounded negative with positive controls) at this exact KASID.

## 2. What is already known (corpus)

- `records/limits-and-engine.md` R-limits-5: the engine settings schema
  (`BaseAgentSettingsSchema`, byte 872016) has exactly 31 keys including
  `thinking`, `tangentMode`, `todoList`, `checkpoint`, `knowledge`,
  `_subagent`, `_delegate`, `subagentOrchestration`; the CLI client
  forwards 23 settings keys via a fixed pair array
  (`chat.enableThinking`→`thinking`, `chat.enableKnowledge`→`knowledge`,
  `chat.enableTodoList`→`todoList`, `chat.enableCheckpoint`→`checkpoint`,
  `chat.enableTangentMode`→`tangentMode`, `chat.enableSubagent`→`_subagent`,
  `chat.enableDelegate`→`_delegate`, ...) plus hard-coded client defaults
  `{codeIntelligence:true, knowledge:true, thinking:true, subagentOrchestration:
  KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION!=="1"}`.
- `records/workflow-surface.md` R-workflow-8: engine has 10 distinct
  `isFeatureEnabled("...")` keys; client reads `KIRO_ENABLED_FEATURES`
  (JSON array) with an experiment catalog whose `workflows` entry has NO
  consumer (C-11); only literal client `isEnabled` calls are `c2s` and
  `remote_sandbox`; feature-to-setting table is `[["memory","memoryEnable"]]`.
- `carried-negatives.md` C-11 (documented-but-unconsumed is a distinct
  state), C-3 (absences need concept-level sweeps + positive controls).
- `private/kiro-v2-experimental.md` (input, v2 doc): the seven features and
  their v2 `chat.enable*` settings.
- `private/kiro-v3-docs.md` ~line 697 feature table: claims Knowledge
  "Available", tags `todo_list` and `subagent` exist — claims to verify.

Everything below that is new was read from the bundle at the pinned KASID
and from the client binary
`/nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-chat-wrapped`
(same artifact the corpus captured against).

## 3. Verdict table

| v2 feature        | v3 verdict                                                 | Engine consumer                                                                     | v2 setting fate                                    |
| ----------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------- | -------------------------------------------------- |
| Knowledge         | GRADUATED, default-ON                                      | `isSettingEnabled(settings,"knowledge")` gates Knowledge tool (line 459836)          | `chat.enableKnowledge` still live (off-switch)     |
| Tangent mode      | SETTING dead; CONCEPT reborn as session fork               | `tangentMode` schema-only (1 hit); `createdReason:"tangent"` enum member IS consumed | `chat.enableTangentMode` forwarded, ignored        |
| TODO lists        | GRADUATED, unconditional builtin tool                      | `new TodoList()` always in chatTools (459832, 459927)                                | `chat.enableTodoList` forwarded, ignored           |
| Thinking tool     | REMOVED as tool; reasoning is model-native; knob = EFFORT  | zero think-tool; `thinking` key has NO read; effort pipeline is first-class          | `chat.enableThinking` forwarded, ignored           |
| Checkpointing     | GRADUATED, redesigned (snapshots, not shadow git)          | `ACPCheckpointProvider` unconditional (459695); `_kiro/checkpoint/revert{,Multiple}` | `chat.enableCheckpoint` forwarded, ignored         |
| Context-usage pct | GRADUATED engine-side, push-based, unconditional           | `pushContextUsage` → `session_info_update` kind `context_usage` (491659)             | `chat.enableContextUsageIndicator` never forwarded |
| Delegate          | REMOVED; replaced by subagent orchestration                | `_delegate` schema-only; no delegate tool constructed                                | `chat.enableDelegate` forwarded, ignored           |

Vendor feature-table check: "Knowledge Available" — TRUE. The `todo_list`
row conflates a tool ID with a tag: the tag registry
(src/tools/tool-tags.ts, bundle offsets 4965798-4967100) contains only
`read`, `write`, `shell`, `web`, `subagent`, `spec`, `context`, `@mcp`,
`@powers`, `@builtin`, `@subagent`, `@subagent-explicit` — no
`todo_list` — and the todo tool's own `tags` are exactly
`[ToolTags.BUILTIN]` (TODO_LIST_CONFIG, offset 18221970). The row still
WORKS behaviorally: `matchesPattern` (src/tools/tool-filter.ts, offset
4972609) checks `tool.id === pattern` BEFORE any tag comparison, and no
validator rejects non-tag entries (`isValidTag` has zero consumers), so
`tools: ["todo_list"]` grants the todo tool via id equality. The vendor's
`knowledge` row has the same conflation (also a tool id, not a tag), and
the vendor table omits the real tags `spec` and `context`.

## 4. Per-feature interface

### 4.1 Knowledge — graduated

- Tool gate (459836):
  `isSettingEnabled(settings, "knowledge") && resolveKnowledgeStore` →
  `new Knowledge({homeDir, resolveStore})`. `isSettingEnabled` (22820)
  returns `val.enabled` for object values, false otherwise — so absence =
  OFF at the engine, but the CLI client hard-defaults
  `knowledge:{enabled:true}` into the initialize settings.
- Typed sub-options (KnowledgeSettingSchema, corpus R-limits-5):
  `includePatterns`, `excludePatterns`, `maxFiles`, `chunkSize` (min 64),
  `chunkOverlap`, `indexType` enum `fast|best|accurate` (accurate =
  legacy alias of best). CLI forwards them from `knowledge.*` settings.
- ACP surface: `_kiro/knowledge` is one of the 7 ADVERTISED
  extensionMethods (corpus argv doc). TUI surface: `/knowledge` panel
  ("Manage knowledge bases") is in the v3 slash-command enum.
- Session metadata carries a `knowledgeBase` field (22713) and the
  execution context carries `knowledgeListing` (corpus hooks record).

### 4.2 Tangent mode — setting dead, concept reborn

- `tangentMode: BaseSettingSchema.optional()` (22961, comment
  "Tangent/exploration mode — allows divergent investigation.
  @see kiro-cli: chat.enableTangentMode") is the ONLY `tangentMode`
  occurrence in 20.7 MB. No `isSettingEnabled` call, no `parsed2.data`
  read, no quoted `"tangentMode"` anywhere. Bounded negative; positive
  controls in section 8.
- BUT the concept survives at the session level (22487):
  `CreatedReasonSchema = enum(["human", "rewind", "subagent", "tangent"])`,
  persisted in session metadata (22527, 22659). Flow: session/new
  `_meta.kiro.createdReason` (validated 487906) → persisted →
  copied through load/replay (487858, 488738). At 470375-470380 a
  `createdReason === "tangent"` fork with a `title` sets
  `titleSetByUser: true` ("a named tangent fork carries a title the user
  deliberately chose"). So a v3 "tangent" is a forked SESSION, sibling of
  "rewind" forks — not an in-session mode. No `/tangent` in the v3
  slash-command enum (the one v3-client string is a help-docs-index
  entry); no client surface for creating a tangent fork was found.

### 4.3 TODO lists — graduated, unconditional tool

- `TODO_LIST_CONFIG` (432262): `id: "todo_list"`, title "Task List",
  commands `create|complete|add|remove|list`, task item schema
  `{task_description, details?}`, tags `[ToolTags.BUILTIN]`. Description
  instructs the model to request it "EVERY time the user gives you a task
  that will take mu[ltiple steps]" — activation is model-elected.
- Registered unconditionally: `const todoList = new TodoList()` (459832)
  and appended to every chatTools list (459927). Also in `PLAN_TOOLS`
  (476945) for plan mode.
- Context injection:
  `state2.execution.workspace.todoList?.formatContextIfChanged()`
  (408613) — changed todo state is re-injected each turn.
- The `todoList` settings key (23006) has NO reader (not in the
  `isSettingEnabled` histogram, no quoted or property access). Per-agent
  exposure control is the agent profile `tools` field, not the setting.
- No `/todo` in the v3 slash-command enum (docs-index string only).

### 4.4 Thinking — removed as a tool; the knob is EFFORT (priority answer)

**There is no thinking toggle with a consumer in v3.**

- No thinking TOOL: the only five `"think"` literals (12797, 22133,
  439297, 471039, 493730) are all the ACP `ToolKind` enum
  (`read|edit|...|execute|think|fetch|switch_mode|other`) — a rendering
  taxonomy, not a tool. Positive control: `todo_list` tool found by the
  same method.
- The `thinking` settings key (22956, comment "Extended thinking/reasoning
  — enables chain-of-thought") has NO reader: all 13 `.thinking` property
  accesses are `block.thinking` content-block reads; all 10 quoted
  `"thinking"` hits are content-block type checks; `isSettingEnabled` is
  never called with it; no `parsed2.data.thinking`. The CLI forwards
  `thinking:{enabled:true}` by hard default (`chat.enableThinking` can
  flip what is SENT) — the engine ignores it either way. C-11 state:
  documented, forwarded, unconsumed.
- Reasoning output is model-native: assistant `thinking` /
  `redacted_thinking` blocks are converted to/from `reasoning` content
  (93445-94932, 306123-306858) and streamed whenever the model produces
  them. `thinkingSignatureRetry` metrics (467389-467399) handle Anthropic
  signature retries. This is why thinking "appears auto-on with Opus
  4.8+": whether thinking happens is decided by the model/backend, and
  the client has no on/off switch — only an effort level.

**The effort interface** (the one cost knob; full precedence lattice is
F8's item — this is the interface census):

- Model catalog: control-plane `ListAvailableModels` returns per-model
  `additionalModelRequestFieldsSchema`; `parseEffortLevels` (324228)
  walks `EFFORT_SCHEMA_PATHS` = `output_config`, `reasoning` and takes
  the field's `enum` as `effortLevels` and its `default` as
  `defaultEffortLevel`. So the LEVELS AND DEFAULT ARE SERVER-DEFINED per
  model; nothing is hardcoded client-side (bundled recipes reference
  `"low"`/`"xhigh"` literals, e.g. 422371, 422436).
- Request wiring: `buildEffortRequestFields(level, schemaPath)` (324238)
  → `{output_config:{effort:level}}` or `{reasoning:{effort:level}}` as
  `additionalModelRequestFields` (334017, 407982).
- Session scope: config option id `effortLevel`
  (`EFFORT_LEVEL_CONFIG_ID`, 483949) in the session config-options
  surface (alongside mode/model/autopilot); set-config validates against
  the model's levels and persists
  `{modelId, agentMode, autopilot, effortLevel}` to session metadata
  (487996-488008). Creation-time explicit value comes from
  `_meta.kiro.effortLevel` on session/new (486045, 486095) and is
  persisted; a model-default effort is deliberately NOT persisted
  (486035 comment) so a model change re-derives it. session/load
  restores `persisted.metadata.effortLevel` (487601). Model switch
  resets an incompatible level to the new model's default (486644-486646).
- Persisted metadata doc (22540): "Persisted effort level for adaptive
  thinking (e.g. high, xhigh)" — vendor's own name for the mechanism is
  "adaptive thinking", and its lever is effort.
- Agent-profile scope: `effortLevel` is a custom-agent definition field
  (426618 frontmatter → definition).
- Per-dispatch scope (427450-427457):
  `requestedEffort = inlineSpec?.effort ?? customAgentDefinition.effortLevel`;
  `resolveEffort(chosenModelId, requestedEffort, isInlineAgent ? "belowMax" : "default")`
  (119389) — an invalid/absent request falls back to the model default,
  EXCEPT inline agents which fall back to the SECOND-HIGHEST level
  (`levels[levels.length-2]`). A model override with no effort request on
  an inline agent therefore lands on second-highest, not default.
- Workflow scope: `effortLevel` on StepNode, on the Workflow (default for
  all steps), on NodeState, and twice on WorkflowState (parent-session
  effort captured at creation as cascade fallback + workflow-level
  default) — 21800-21965; `resolveEffectiveEffortLevel(node, cascade)`
  (414907-414922, 421279+). Step > workflow > parent-session.
- User surface: `/effort` is a first-class v3 slash command ("List or set
  the reasoning effort level", subcommand `set-current-as-default`) —
  same shape as `/model`. Where set-current-as-default persists was not
  chased (F8).

### 4.5 Checkpointing — graduated, redesigned

- NOT the v2 shadow-git repo. `ACPCheckpointProvider` (443169):
  `checkpointFile` reads the file and calls
  `persistence.snapshotFile(sessionId, workspacePaths, relativePath, content)`
  (impl at 470133), returning a `kiro-snapshot://` URI + snapshotId as
  commitId. Wired unconditionally per session (459695) into
  `FileOperationsProvider` and `PendingChangesService` — snapshots are
  taken around file operations, stored inside session persistence.
- Restore surface: capability handlers `_kiro/checkpoint/revert` and
  `_kiro/checkpoint/revertMultiple` (485182-485183; revertMultiple =
  revert-to-message). These are REGISTERED but not among the 7 advertised
  extensionMethods — same hardcoded-name reachability pattern as the
  workflow methods (corpus).
- TUI surface: `/rewind` — "Fork the session at an earlier turn" (panel).
  Rewind forks carry `createdReason: "rewind"` in the new session's
  metadata. No `/checkpoint` command in the v3 enum.
- The `checkpoint` settings key (schema 22386 region) has no reader; the
  726 raw "checkpoint" hits are dominated by LangGraph channel-checkpoint
  machinery (313xxx region) and the snapshot provider — none reads the
  setting.

### 4.6 Context-usage percentage — graduated engine-side

- Engine computes and PUSHES usage: `pushContextUsage` (491659) sends
  `session_info_update` with
  `buildSessionInfoUpdate({kind: "context_usage", usagePercentage, breakdown})`;
  `pushInitialContextUsage` (491692) sends a local estimate (system
  prompt included) at session creation, before any model turn — so one
  notification is observable with ZERO model calls. Updates thereafter
  carry the backend-reported value only ("never the local estimate").
  Bridged from `AgentExecutionContextUsageUpdate` events (465127).
- Unconditional: no setting gates the push.
- The v2 setting `chat.enableContextUsageIndicator` is NOT in the CLI's
  23-key forward list (corpus R-limits-5). In the client binary it
  appears twice: once in the Rust v2 settings enum region (~5.4 MB), once
  in a help-docs INDEX inside the v3 JS (~397.9 MB) — no v3 consumer
  found, so v3 display gating is unverified (flagged).

### 4.7 Delegate — removed; successor is subagent orchestration

- `_delegate: BaseSettingSchema.optional()` (22950) is the only
  `_delegate:` in the bundle; quoted `"_delegate"` = 0; the 31
  `this._delegate` hits are telemetry-exporter delegates (unrelated).
  Same for `_subagent:` (22945; the other hits are the
  `invoke_sub_agent` / `orchestrate_subagent` tool-id substring).
- No tool named `delegate` is constructed; the capability-map row
  `delegate: "subagent"` (117404) exists only to classify tool calls
  replayed from persisted (v2-era) sessions.
- The live successor: `subagentOrchestration` — consumed via
  `isSettingEnabled(settings, "subagentOrchestration")` and via
  `isFeatureEnabled("subagentOrchestration")` at
  `getDelegationToolId(...)` (119747), which selects the delegation tool
  id: `orchestrate_subagent` when true, `invoke_sub_agent` when false.
  The CLI client sends it enabled by default; kill switch is
  `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1` (client-side, corpus).

## 5. The experiment catalogs — three distinct mechanisms

### 5.1 Client catalog (env `KIRO_ENABLED_FEATURES`, JSON array)

Read lazily by the embedded client JS (`Cae` class, corpus) into a Set;
`KIRO_INTERNAL === "1"` marks internal users. The shipped catalog has
exactly 13 entries and lives ONLY in the 555 MB Rust CHAT binary
(`.kiro-cli-chat-wrapped`, 555,372,744 B): two embedded copies at bytes
~398652171 and ~399237803, each preceded by deduped Rust key literals,
plus `struct FeatureRollout` x4 and `treatment_percent` x34. It is ABSENT
from the 53 MB Rust launcher (`.kiro-cli-wrapped`, 53,809,000 B), whose
only Rollout is fig_install's 2-field auto-update rollout: grep -oaF
counts there are 0 for `KIRO_ENABLED_FEATURES`, `FeatureRollout` (all
case variants), `treatment_percent`, `v2_non_interactive`, and every
catalog description substring (positive controls rollout=12,
fig_install=384, `struct Rollout with 2 elements` = 1 —
`fig_install::index::Rollout {start,end}`, the auto-update rollout, not
the feature catalog). Rust-side consumers are two chat-binary crates —
`chat_cli::rollout` (`Rollout::is_enabled`) and `chat_cli_v2::rollout`
(`Rollout::variation` returning TREATMENT/CONTROL) — which also export
the derived flags `KIRO_LITE_ROLLOUT_ENABLED` and
`KIRO_INFRA_SAFETY_ROLLOUT_ENABLED` (Rust env-literal region ~397456970).
Per-key Rust call sites below are evidenced by adjacent key literals, not
disassembly-proven.

| Key                  | treatment_percent | segment  | channel | Live consumer at 2.15.1                                                                             |
| -------------------- | ----------------- | -------- | ------- | --------------------------------------------------------------------------------------------------- |
| `c2s`                | 100               | internal | nightly | YES — client `isEnabled("c2s")` x2; engine `isFeatureEnabled("c2s")` x5; launcher exports `KIRO_C2S_ROLLOUT_ENABLED` |
| `infra_safety`       | 100               | internal | —       | chat-binary rollout crates export derived `KIRO_INFRA_SAFETY_ROLLOUT_ENABLED` (engine reads that env); key-literal-evidenced |
| `kas`                | 0                 | all      | —       | chat-binary Rust rollout crates (`chat_cli::rollout` / `chat_cli_v2::rollout`); key-literal-evidenced, not disassembly-proven |
| `lite`               | 100               | internal | stable  | chat-binary rollout crates; derived export `KIRO_LITE_ROLLOUT_ENABLED`; key-literal-evidenced |
| `memory`             | 100               | internal | nightly | YES — client table `[["memory","memoryEnable"]]` → engine `isFeatureEnabled("memoryEnable")` gates the `searchMemories` remote tool (477104-477115, 484821) |
| `remote_sandbox`     | 100               | internal | nightly | YES — client `isEnabled("remote_sandbox")` x3; gates `/autonomous` (`feature:"remote_sandbox"`)       |
| `test`               | 100               | —        | —       | unit-test fixture                                                                                    |
| `test_internal_only` | 100               | internal | —       | unit-test fixture                                                                                    |
| `test_nightly_only`  | 100               | internal | nightly | unit-test fixture                                                                                    |
| `tui`                | 50                | internal | —       | chat-binary Rust rollout crates (React/Ink TUI rollout); key-literal-evidenced |
| `v2_non_interactive` | 100               | —        | nightly | chat-binary Rust rollout crates; key-literal-evidenced |
| `voice`              | 100               | internal | —       | chat-binary Rust rollout crates; key-literal-evidenced |
| `workflows`          | 0                 | internal | nightly | NO consumer — corpus R-workflow-8 / C-11; the entry's own enable instruction is inert                |

Note the `memory` entry's DESCRIPTION says "Dark-shipped at 0%" while its
`treatment_percent` is 100 — description drift inside the vendor catalog.
A stray string `structured` sits in the feature-name string pool adjacent
to the catalog but has no catalog entry; not chased.

### 5.2 Engine `FeatureKey` registry (KRS experiments) — compiled OFF

`src/feature-config/features.ts` (466432) declares exactly 5 keys with
built-in defaults:

| Key                        | Default | Purpose                                                                |
| -------------------------- | ------- | ---------------------------------------------------------------------- |
| `empty_response_retry`     | true    | silent re-issue of cleanly-closed empty model streams                   |
| `steering_supervisor`      | false   | rollout gate for per-tool-call steering verifier (ORs with the setting) |
| `system_field_injection`   | false   | KAS_SYSTEM_FIELD_INJECTION experiment                                   |
| `system_prompt_migration`  | false   | KAS_SYSTEM_PROMPT_MIGRATION experiment                                  |
| `truncated_response_retry` | true    | silent re-issue of suspected-truncated streams                          |

Resolution: `FeatureConfigRegistry.get` walks providers by
`SOURCE_PRECEDENCE = ["governance","env","client","session","experiment"]`
then falls to the default — but the ONLY provider ever wired is
`ExperimentFeatureConfigProvider` (488504-488505), backed by
`ExperimentConfigService` → KRS `GetFeatureConfiguration` (per-identity,
TTL 15 min, keys obfuscated as SHA-256 of
`kiro-feature-config-key-salt-3e9b1d7a` + cleartext), and
`EXPERIMENT_CONFIG_ENABLED = false` (466551) with no constructor
override — so the remote fetch NEVER runs at 2.15.1 and all five keys sit
at their compiled defaults. The governance/env/client/session sources are
aspirational (the two other `source:` hits in the bundle are steering docs
and permission rules).

### 5.3 Engine `isFeatureEnabled` (modelConfigProvider) — client-bridgeable

10 keys (corpus R-workflow-8): `c2s` x5, `infraSafetyEnforce`,
`infraSafetyMonitor`, `largeToolOutputHandler`, `memoryEnable`,
`mergeVibeSpec`, `sessionRecap`, `steeringReminders`,
`subagentOrchestration`, `verifyFirstWorkflow`. Default provider returns
false for everything (119457), but BOTH initialize (485046-485057) and
session/new (486072-486082) bridge it:
`bridgedIsFeatureEnabled(feature)` returns
`isSettingEnabled(clientSettings, feature)` whenever the RAW
`_meta.kiro.settings` object contains a key of that name, else falls
through. `parseSettings` passes unknown keys through (corpus R-workflow-1),
so ANY of the 10 can be flipped per-session by any ACP client via
`_meta.kiro.settings.<key> = {enabled: true}` — settings keys and feature
keys share one namespace at the bridge. This is the path by which the
CLI's `memory` experiment and `subagentOrchestration` default reach the
engine.

## 6. Activation drivers (the axis)

| Lever                              | user-typed                                     | skill | agent-profile         | model-elected                 | hook | workflow-step                    | external ACP client                          |
| ---------------------------------- | ---------------------------------------------- | ----- | --------------------- | ----------------------------- | ---- | -------------------------------- | -------------------------------------------- |
| Knowledge tool on/off              | `kiro-cli settings chat.enableKnowledge`       | no    | tools field filtering | no                            | no   | inherits session settings        | `_meta.kiro.settings.knowledge`              |
| todo_list use                      | no off-switch (agent tools field only)         | no    | tools field           | YES (description-driven)      | no   | n/a                              | n/a (always registered)                      |
| Effort level (thinking depth)      | `/effort`, effortLevel config option           | no    | `effortLevel` field   | YES (inline dispatch `effort`) | no   | step/workflow `effortLevel`      | `_meta.kiro.effortLevel` + set-config        |
| Thinking on/off                    | DOES NOT EXIST (setting is inert)              | —     | —                     | model/backend decides         | —    | —                                | —                                            |
| Checkpoint snapshot/revert         | `/rewind` (fork at earlier turn)               | no    | no                    | no (automatic around writes)  | no   | no                               | `_kiro/checkpoint/revert{,Multiple}`         |
| Tangent fork                       | no v3 surface found                            | no    | no                    | no                            | no   | no                               | `_meta.kiro.createdReason:"tangent"` + title |
| Context-usage display              | client-side only; push is unconditional        | no    | no                    | no                            | no   | no                               | consumes `session_info_update` push          |
| Delegation tool id (orchestrate)   | env kill-switch via CLI                        | no    | no                    | no                            | no   | no                               | `_meta.kiro.settings.subagentOrchestration`  |
| Client experiments (memory, c2s..) | `KIRO_ENABLED_FEATURES` env (+`KIRO_INTERNAL`) | no    | no                    | no                            | no   | no                               | bypass: send the bridged setting directly    |
| Engine FeatureKeys (5)             | nobody — compiled defaults at 2.15.1           | —     | —                     | —                             | —    | —                                | —                                            |

## 7. Fixture designs (cheapest discriminating observable)

All ACP-direct, no model call, no seeded session, using the pinned real
launcher with `HOME` isolation (settled facts). Each is a SPEC where a
turn would be needed.

1. **Context-usage push (runnable now):** initialize + `session/new`,
   then wait for a `session/update` notification with
   `sessionUpdate.kind == "context_usage"` (initial local estimate,
   fires before any prompt). Pass = notification with a numeric
   `usagePercentage`; fail = none within the session/new roundtrip
   window. Discriminates "graduated, unconditional push".
2. **Checkpoint registration (runnable now):** send
   `_kiro/checkpoint/revert` with syntactically valid params for a
   nonexistent session. Pass = typed error (session/param validation),
   fail = JSON-RPC method-not-found. Mirrors the workflow ACP-direct arm.
3. **Effort surface (runnable now, needs signed-in auth for the model
   catalog):** `session/new` with `_meta.kiro.effortLevel: "xhigh"`;
   observable A = the new-session response's config options contain id
   `effortLevel` with `currentValue == "xhigh"` and the model's level
   enum; observable B = `sess_*/` persisted metadata contains
   `"effortLevel": "xhigh"`. Then set-config to an invalid level; pass =
   value rejected (unchanged current), discriminating the
   validate-against-model-levels branch (487999).
4. **Thinking-setting inertness (SPEC — needs a turn):** two otherwise
   identical one-turn sessions, one with
   `_meta.kiro.settings.thinking = {enabled:false}`. Expected: NO
   difference in request shape or reasoning output (the key has no
   reader). The discriminating observable is the model request dump
   (`KIRO_DUMP_REQUESTS=1`, engine env list, corpus): both requests carry
   identical `additionalModelRequestFields`. Any diff falsifies the
   inertness claim.
5. **Tangent fork metadata (runnable now):** `session/new` with
   `_meta.kiro.createdReason: "tangent"` and a `title`; pass = persisted
   metadata shows `createdReason: "tangent"` and `titleSetByUser: true`;
   an invalid reason (e.g. `"detour"`) is dropped (safeParse at 487906).
6. **todo_list unconditional registration (SPEC):** TUI `/tools` with
   `chat.enableTodoList false`; pass = task-list tool still listed.
   (No cheap ACP tool-listing surface; hence spec.)

## 8. Cross-interactions and traps

- **Inert-but-forwarded settings mislead diffing.** Five v2 levers
  (`thinking`, `tangentMode`, `todoList`, `checkpoint`, `_delegate`,
  `_subagent`) travel the wire and validate against the schema, so a
  wire capture "proves" they took effect. Only a consumer trace does
  (C-11).
- **The settings/feature namespace merge is a footgun and a power tool.**
  Because the bridge keys off RAW `_meta.kiro.settings` names, a client
  that invents a settings key colliding with a future feature key
  silently becomes a feature override. Conversely it is the ONLY way an
  external client flips `memoryEnable`, `sessionRecap`, `mergeVibeSpec`,
  etc.
- **Inline-agent effort clamp:** `onUnsupported="belowMax"` means an
  inline dispatch with a model override and NO effort lands on the
  second-highest level — costlier than the model default. Workers meant
  to be cheap should pin `effort` explicitly (interacts with C-9's
  short-worker rule).
- **steering_supervisor ORs across mechanisms:** the session setting and
  the (dead) experiment key OR together (486131), so enabling the setting
  is sufficient today, and a future KRS enablement could turn it on
  without any client change.
- **Stream-recovery retries default ON** (`empty_response_retry`,
  `truncated_response_retry`) and, with the experiment service compiled
  off, CANNOT be disabled at 2.15.1 — a retried turn is invisible
  double-spend in credit accounting (usage records are per prompt turn,
  corpus session-store facts).
- **Positive controls for the absences asserted here** (same grep -oF
  method, same file): `tangentMode` 1, `todoList` 12, `thinking` 43,
  `checkpoint` 726, `knowledge` 231, `_delegate:` 1, `_subagent:` 2,
  `isSettingEnabled` 16, `effortLevel` 141, `getDelegationToolId` 2,
  `snapshotFile` 2, `EXPERIMENT_CONFIG_ENABLED` 2. Concept sweeps used
  case-insensitive `tangent`, `think`, `reasoning`, `effort`,
  `interleaved` (5/5 hits are MIME types), `adaptive`, plus quoted-key,
  property-access, and `parsed2.data.` spellings.

## Corrections from adversarial verification

- **The FeatureRollout catalog's Rust consumer is the CHAT binary, not
  the launcher.** An earlier draft attributed the `tui`, `kas`, `lite`,
  `voice`, and `v2_non_interactive` entries (and the
  `KIRO_INFRA_SAFETY_ROLLOUT_ENABLED` export) to the 53 MB Rust launcher.
  Refuted: launcher ELF
  `/nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-wrapped`
  (53,809,000 B) has grep -oaF count 0 for `KIRO_ENABLED_FEATURES`,
  `FeatureRollout` (all case variants), `treatment_percent`,
  `v2_non_interactive`, and every catalog description substring, with
  positive controls rollout=12, fig_install=384, and
  `struct Rollout with 2 elements` = 1 — that lone Rollout is
  `fig_install::index::Rollout {start,end}`, the 2-field auto-update
  rollout, not the feature catalog. The chat binary
  `.kiro-cli-chat-wrapped` (555,372,744 B) carries the 13-entry catalog
  twice (byte offsets ~398652171 and ~399237803, each preceded by
  deduped Rust key literals), `struct FeatureRollout` x4,
  `treatment_percent` x34, mangled symbols
  `chat_cli::rollout::Rollout::is_enabled` and
  `chat_cli_v2::rollout::Rollout::variation` (TREATMENT/CONTROL), and
  the derived exports `KIRO_LITE_ROLLOUT_ENABLED` /
  `KIRO_INFRA_SAFETY_ROLLOUT_ENABLED` in the Rust env-literal region at
  ~397456970. Per-key call sites are evidenced by adjacent key literals,
  not disassembly-proven; the `workflows` entry remains consumer-less
  (corpus C-11/R-workflow-8 stands). KASID
  2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc.
- **`todo_list` is a tool ID, not a tools-field tag — and the id-match
  path is now verified, not open.** An earlier draft called the vendor
  row "half-true" and left whether `tools: ["todo_list"]` matches by id
  unverified. Verified: the tag registry (src/tools/tool-tags.ts, bundle
  offsets 4965798-4967100) holds only `read`, `write`, `shell`, `web`,
  `subagent`, `spec`, `context`, `@mcp`, `@powers`, `@builtin`,
  `@subagent`, `@subagent-explicit` (positive controls `read`,
  `subagent`, `@builtin` present; no `todo_list`); TODO_LIST_CONFIG
  (offset 18221970) has tags exactly `[ToolTags.BUILTIN]`;
  `matchesPattern` (src/tools/tool-filter.ts, offset 4972609) runs the
  non-glob branch `if (tool2.id === pattern) return true;` BEFORE tag
  iteration, and no validator rejects non-tag entries (`isValidTag` has
  zero consumers), so `tools: ["todo_list"]` grants the todo tool via id
  equality. grep -boF `"todo_list"` = 4 occurrences, all non-tag;
  `toolPolicyForAgent` maps profile access.tools → allowedTools →
  filterTools. Same conflation applies to the vendor's `knowledge` row
  (also a tool id, not a tag); the vendor table also omits the real tags
  `spec` and `context`.
