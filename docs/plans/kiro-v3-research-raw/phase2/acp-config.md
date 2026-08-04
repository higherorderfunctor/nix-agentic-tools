# ACP-C — configuring the v3 ACP arm: settings, env, argv, and gaps G2/G3/G7/G8/G9/G10

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

All byte offsets below are into the pinned KAS bundle (`$B`) unless marked
`[chat]` (offsets into `.kiro-cli-chat-wrapped`, store path
`qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1`) or `[launcher]`
(`.kiro-cli-wrapped`, same store path). Offsets churn per release; the semantic
anchors (function names, error strings, file-path literals) are the durable
handles. Minified names from the embedded client JS (`qCe`, `ABe`, `Kc`, `wa`,
`dQ`, `gn`) churn every build — anchor on the adjacent string literals.

## 0. Argv layer — settled elsewhere, 10-line summary

`private/kiro-acp-and-launcher-argv.md` §1–3, §6 settled: launcher globals
(`--v3`, `--tui`, `--agent`, …) must be PREPENDED (clap global-option
position); the launcher translates global `--v3` into `--agent-engine=v3` on
the dispatched subcommand; a caller-supplied `--agent-engine` cleanly beats an
injected `--v3` (no duplicate-flag error), giving wrappers user-override
semantics for free; on `acp`, `--agent-engine=v3` is declared mutually
exclusive with `--agent`/`--model`/`--effort`/`--trust-all-tools`/
`--trust-tools` (value-specific: v1/v2 accept all five; subcommand-specific:
`chat` under v3 accepts all five); escape hatch: `--agent-engine=v2` on the
subcommand re-enables them under an injected `--v3`.

**G1 is v2-only (does v2 acp honor `--model` at all) — out of scope here; one
line: unresolved, needs a credit-burning prompt-level test.** G4/G5/G6 belong
to sibling agents.

---

## G2 — does the v3 engine read `chat.defaultModel`? (HIGHEST VALUE)

### 1. The question

Settled means: for the string `chat.defaultModel` we can name every consumer,
and for the v3 ACP arm we can state from code how the model a session uses is
chosen, or name the exact unprovable residue.

### 2. Already known

Argv doc §4 ("The settings route"): the setting exists client-side
(`kiro-cli settings all` → `chat.defaultModel = "claude-opus-5"`, re-confirmed
on this machine at capture) and the ACP handshake + `session/new` stream carry
zero model-ish keys. Corpus R-limits-5: the CLI's settings builder forwards 23
`chat.*`/`toolSearch.*`/`compaction.*`/`knowledge.*` keys into
`_meta.kiro.settings` — `chat.defaultModel` is NOT among them.

### 3. The interface, from code

**The engine NEVER reads `chat.defaultModel`.** `grep -cF "chat.defaultModel"
$B` → **0**. Positive controls, same method, same file: `defaultModel` → 17
hits; `chat.enableKnowledge` (a dotted CLI key referenced in the settings
schema doc comments) → 1; `disableAutoCompaction` → 2. The literal is
therefore findable when present, and absent.

Where the model actually comes from, engine-side (all in `$B`):

- `src/platform/model-config.ts` (offset 5040665): a `modelConfigProvider`
  with `getSelectedModelId` / `getAvailableModels`.
- Model catalog: `listAvailableModels` control-plane API call (offset
  13769025), paginated with a `MAX_PAGES` cap; response carries per-model
  `effortLevels` / `effortSchemaPath` / `defaultEffortLevel` /
  `rateMultiplier` and a top-level `response.defaultModel.modelId` (13770411).
  Cached in a registry with `cacheTtlMs` and process-local `selectedModelId`
  (19658154).
- `getEffectiveModelId()` (19662281), doc comment states the precedence:
  "explicit selection → API default → first available → empty string".
- `pinSessionModelId(session)` (20373599): if `session.modelId` unset, pins it
  to registry `defaultModel?.id ?? models[0]?.id`, logs
  `session.model.pinned`, and persists via
  `persistence.updateMetadata(..., { modelId })`. On a cold registry it logs
  `session.model.pin.cold_registry` and returns undefined — callers then apply
  the `'auto'` sentinel (`session.modelId ?? "auto"`, e.g.
  `buildSessionServices` at 20400555, provider namespace
  `Q_CLIENT_NAMESPACE = "qdev"`).
- Call sites of `pinSessionModelId`: session-setup completion (20375084),
  `buildSessionServices` (every turn, 20400555), compaction (20616251).

Who DOES read `chat.defaultModel`: the embedded v3 client JS inside the chat
binary. `[chat]` 396767442, immediately after its own `session/new`:

```
let A = wa()[gn.CHAT_DEFAULT_MODEL],
    d = ABe({flagModel: this.initialModel ?? null,
             savedDefaultModel: typeof A === "string" && A ? A : null});
if (d) ... setSessionConfigOption({sessionId, configId: "model", value: d})
```

with `ABe = flagModel || savedDefaultModel || null` (`[chat]` 396379629) — so
`--model` beats `chat.defaultModel`, and the winner is applied THROUGH THE
PROTOCOL (`session/set_config_option`, see G3). The same block first sets
`autopilot` to `"on"` and then applies `--effort` via configId `effortLevel`.
The client also saves a default with `/model` → `dQ(gn.CHAT_DEFAULT_MODEL,
n.id)` (`[chat]` 396413843, "Saved … as default model").

**Engine file-based config intake exists but is a different family.** The
engine reads `.kiro/settings/` FILES — `mcp.json` (home + workspace, watched;
19023416), `permissions.yaml`/`permissions.json` (watched; 20138166),
`knowledge.json` (`indexType` only; 14730683), workspace `lsp.json`
(18411121), `kiroignore` (20122076) — plus the admin policy
`/etc/kiro/managed-settings.json` (`ADMIN_POLICY_PATHS`, 20110228; darwin
`/Library/Application Support/Kiro/managed-settings.json`, win32
`C:\ProgramData\Kiro\managed-settings.json`). The CLI's key-value settings
STORE (`chat.*` keys, `kiro-cli settings`) is not in this family and has no
engine reader. Absence controls for "no store read": `loadSettings` 0,
`readSettings` 0, `settings.toml` 0; `settingsPath` 3 (all three are the
knowledge.json read); `getSettings` 7 (all vendored huggingface-hub library
code, `tenant_handle`).

**Answer to "how do I set the model under v3 ACP":** an external ACP client
must do what the shipped client does — after `session/new`, call
`session/set_config_option` with `configId: "model"`, or pass
`_meta.kiro.modelId` at `session/new` (G3). `chat.defaultModel` only works in
topologies where the SHIPPED client is in the loop (TUI/chat, including
`chat --agent-engine=v3`) — it is client-side sugar over the same protocol
call.

### 4. Activation drivers

- `chat.defaultModel` itself: user-typed (`kiro-cli settings`, `/model` save)
  — consumed only by the shipped client. External-ACP-client topology: inert.
- Engine-side model pinning: automatic (first use), not a caller lever.
- `session/set_config_option "model"`: external-ACP-client; the shipped
  client's flag/setting plumbing rides it.

### 5. Fixture design

No-credit fixture (real auth required, no prompt): script
`initialize` → `session/new` → `session/set_config_option {configId:"model",
value:<id>}` → read
`~/.kiro/sessions/<hash>/sess_<id>/session.json`. PASS: `modelId` equals the
value sent and the response `configOptions` "model" option's `currentValue`
matches. Placeholder-auth variant is expected to show NO model config option
(registry empty → `buildModelConfigOption` returns undefined at 20245579) —
that asymmetry is itself the observable.

Unprovable without a live model call (fixture SPEC only): that the pinned
`session.modelId` is the model actually SERVING the turn (value at call site
vs value at syscall, corpus C-5). Spec: one `session/prompt` after setting a
distinctive model; discriminate on `messages.jsonl` `usage_summary` /
response `ModelIdentifier` (`qdev::<modelId>` baggage at 20385407).

### 6. Cross-interactions

`applyModelId` (20371784) reconciles effort on every model change: clears
`effortLevel` when the new model has none; resets to the model's
`defaultEffortLevel ?? levels[0]` when the current level is unset/invalid.
Setting a model can therefore silently change effort.

---

## G3 — per-session model selection on v3 ACP

### 1. The question

Enumerate every wire path that can set a session's model; state schema
strictness (unknown-key behavior); say what writes `session.json` `modelId`
and what `_kiro/config/template` reads/writes.

### 2. Already known

Argv doc §4: no `model` key anywhere in handshake or `session/new` result
`_meta`. Corpus R-workflow-2 (workflow-surface.md): the workflow step-session
builder passes `_meta.kiro: { modelId, effortLevel }` — proof the channel
exists internally.

### 3. The interface

**Three wire paths, one dead:**

1. **`session/new` `_meta.kiro.modelId` (+ `.effortLevel`).** `newSession`
   reads `kiroMeta?.modelId, kiroMeta?.effortLevel` and hands both to
   `createSessionState` (20345743). Persisted note (20351356): effort is
   persisted only when explicitly requested; "a seeded model default stays
   unpersisted"; the raw request `_meta` is persisted VERBATIM as
   `requestMeta` (minus the mux's `__callerClientId`).
2. **`session/set_config_option`** (`setSessionConfigOption`, 20434417) —
   the live selection verb. Config ids (literals at 20243725):
   `model`, `mode`, `autopilot`, `contentCollection`, `effortLevel`, plus
   sandbox ids `sandbox` / `sandboxNetworkMode` / `mcpSandboxing`.
   `model` → `applyModelId`; `effortLevel` → validated against
   `getEffortLevelsForModel(session.modelId)`, invalid values silently
   ignored; any of model/mode/autopilot/effortLevel →
   `persistence.updateMetadata({modelId, agentMode, autopilot, effortLevel})`
   — **this is what writes `session.json` `modelId`** (the other writer is
   `pinSessionModelId`, G2). A boolean `value` short-circuits to a no-op
   echo of current options.
3. **`session/set_model` — advertised in the SDK's `AGENT_METHODS` (445581)
   but DEAD on this agent:** the dispatcher guards
   `if (!agent.unstable_setSessionModel) throw RequestError.methodNotFound`
   (520131), and `unstable_setSessionModel` has exactly 2 bundle occurrences,
   both in the SDK dispatcher — KiroAgent never defines it. Same for the
   response-schema `models: zSessionModelState.nullish()` field: the
   `newSession` return (20353647) sets `_meta`, `sessionId`, `modes`,
   `configOptions` — never `models`.

**Schema strictness:** `zNewSessionRequest` (468210) = zod object
`{_meta: record(string, unknown).nullish(), additionalDirectories?, cwd,
mcpServers}`. Zod objects default to STRIP: an unknown top-level key (e.g.
`model`) is silently dropped, not an error. `_meta` is `record(unknown)` —
everything under `_meta.kiro` is unvalidated pass-through (feature-flag keys
inside it get `parseSettings`, which passes unknown keys through untouched —
corpus R-workflow-1). `zPromptRequest` (500000): `_meta`, `messageId?`,
`prompt`, `sessionId` — **no model field on prompt; the prompt handler does
not read `_meta.kiro.modelId`** (kiroMeta model reads exist only in
newSession/loadSession, offsets 20345743/20414778).

**`_kiro/config/template`** (`handleConfigTemplate`, 20320088): reads NOTHING
from the caller (`parseSettings(void 0)`, params ignored), creates no session,
persists nothing; returns default `modes` + `configOptions` built from
defaults. It can neither read nor write a model choice — it is a static
template endpoint.

**Config-option discovery:** `buildSessionConfigOptions` — doc comment "the
canonical, complete config-option set (mode, model, effort, autopilot,
content collection)" (20375084) — returned by `session/new`, `session/load`,
`session/resume`, and every `set_config_option` echo. The "model" option
(`buildModelConfigOption`, 20245579) is a `select` whose options carry
per-model `_meta.kiro` `rateMultiplier`/`rateUnit`/effort metadata, and is
OMITTED entirely when the registry has no models (placeholder auth / cold
registry).

**Precedence lattice for the session model (Kiro side, from code):**
`session/set_config_option "model"` (any time, persisted) >
`_meta.kiro.modelId` at `session/new` > agent-profile `model` field (applied
only `if (!modelId && profile.model)`, 20487855) > engine pin on first use
(control-plane `defaultModel` → `models[0]`) > `'auto'` sentinel on the wire.
Client-side (shipped client only): `--model` flag > `chat.defaultModel`, fed
into rung 1. Workflow definitions add a separate cascade for STEP sessions:
`state.modelId ?? definition.modelId` (18566147) → step session's
`_meta.kiro.modelId`.

### 4. Activation drivers

- `_meta.kiro.modelId` at session/new: external-ACP-client;
  workflow-step-driven (the step-session builder).
- `set_config_option "model"`: external-ACP-client; user-typed (`/model` in
  the shipped TUI; `--model`/`chat.defaultModel` via the shipped client).
- Agent-profile `model`: agent-system-prompt-driven (profile author); fires
  only when no explicit model was given.
- NOT model-elected: no tool exposes model switching to the model itself.

### 5. Fixture design

Same no-credit fixture as G2 §5, plus: (a) `session/new` with
`_meta.kiro.modelId: "<distinctive>"` → `session.json` `modelId` matches
without any config-option call; (b) `session/new` with top-level
`model: "x"` → accepted (strip semantics), `session.json` shows the pinned
default, proving the key was dropped; (c) `session/set_model` → expect JSON-RPC
error `-32601` method not found (discriminates dead-verb claim);
(d) `set_config_option {configId:"effortLevel", value:"bogus"}` → success
response but persisted `effortLevel` unchanged (silent-ignore semantics).

### 6. Cross-interactions

`applyUserModeSwitch` (mode config id) shares `applyModelId`-based effort
reconciliation via `switchMode`; switching mode can change model+effort when
the target profile carries `model`. `autopilot` is a sibling config option
(`value === "on"`), persisted in the same metadata write.

---

## G7 — `kiro-cli-chat --v3 acp` vs the launcher form; which binary is canonical

### 1. The question

Does the chat binary's top-level `--v3` reach `acp` engine selection, and
which binary should docs treat as canonical?

### 2. Already known

Argv doc G7: `kiro-cli-chat --v3 acp --trust-tools=x` does NOT conflict where
`kiro-cli --v3 acp --trust-tools=x` does.

### 3. What the binaries say

- The conflict error string
  `the following arguments are not supported with --agent-engine=v3: ` lives
  ONLY in the chat binary, in its RUST region, adjacent to
  `crates/chat-cli/src/cli/mod.rs` line markers and the token run
  `--agent--model--trust-all-tools--trust-tools` (`[chat]` 397859975). The
  launcher binary has zero hits. The phrasing is hand-rolled, NOT clap's
  native conflict text ("cannot be used with") — a deliberate post-parse
  validation in `chat-cli/src/cli/mod.rs`.
- Parse probe (exits at parse, no engine):
  `kiro-cli-chat acp --agent-engine=v3 --trust-tools=x` → **conflict fires.**
  So the check keys on the acp SUBCOMMAND's explicit `--agent-engine` value.
- The `--v3` → `--agent-engine=v3` translation lives in the LAUNCHER
  (`crates/q_cli/src/cli/mod.rs`): `[launcher]` 3933046–3933149 carries the
  adjacent tokens `kiro-cli-chat`, `--agent-engine`, `acp`, `v3`, `=` in its
  dispatch code. The chat binary has no such translation for its own
  top-level `--v3`; its `--help` describes `--v3` as "Launch the next
  generation Kiro agent" (the bare-launch/TUI path), and `acp` is a HIDDEN
  subcommand there (absent from `kiro-cli-chat --help`'s command list, yet
  `kiro-cli-chat acp --help` works and shows its own
  `--agent-engine <ENGINE>` defaulting to v2).

**Conclusion (one inference, flagged):** on the chat binary, top-level `--v3`
does not propagate into `acp`'s `--agent-engine`, so
`kiro-cli-chat --v3 acp` runs the DEFAULT engine — v2. **The launcher
`kiro-cli` is the canonical entry**: it owns the translation; invoking the
chat binary directly silently drops v3 selection for `acp`. The chat binary
also exposes `serve` ("Start a persistent V3 agent server over WebSocket",
`--port` default 8082) — visible in help, spawns the engine with
`--transport=ws --auth=acp-callback` and suggests
`kiro-cli --remote ws://<host>:<port>` (`[chat]` 397383350 region).

### 4. Activation drivers

User-typed / external-ACP-client (whoever assembles argv). Not reachable from
inside a session.

### 5. Fixture design

Parse-level (done, replayable):
`kiro-cli-chat acp --agent-engine=v3 --trust-tools=x` errors;
`kiro-cli-chat --v3 acp --trust-tools=x` per the argv doc does not. Engine
fingerprint SPEC (spawns engine, so spec only): run `kiro-cli-chat --v3 acp`
with stdin closed and check stderr line 1 — v3 prints the
`--auth=acp-callback` INFO line, v2 is silent (argv doc §4b). That one run
settles the inference in §3.

### 6. Cross-interactions

Any wrapper that resolves `kiro-cli-chat` directly (bypassing the launcher for
"one less exec") silently loses v3-on-acp. The repo's own wrapper must keep
targeting the launcher.

---

## G8 — WHY the v3 acp arm forbids `--model`/`--agent`/`--effort`/`--trust-*`

### 1. The question

Deliberate design or unimplemented plumbing?

### 2. Evidence

- The guard is hand-written (custom error string in `chat-cli/src/cli/mod.rs`,
  G7 §3), value-specific (only `=v3`) and subcommand-specific (only `acp`) —
  someone enumerated exactly the five flags and wrote a bespoke message. Clap
  would have produced different text and shape.
- Under `chat --agent-engine=v3` the SAME five flags work — because there the
  shipped client consumes them and replays them onto the protocol
  (`initialModel`/`initialEffort` → `set_config_option`, G2 §3; `--agent` →
  mode selection; trust flags → client-side permission policy).
- Under `acp --agent-engine=v3` the Rust process is a spawner/bridge: the
  session-owning client is EXTERNAL, and the engine's own argv surface (the
  15 `getCliArg` names, see ENV section) has no model/agent/effort/trust
  args to translate them into. There is NO consumer in that topology.
- Engine-side intake for every one of the five exists in the protocol
  instead: model/effort → `set_config_option` / `_meta.kiro.modelId`; agent →
  `_meta.kiro.modeId` + `session/set_mode`; trust → the permission policy
  files (`.kiro/settings/permissions.yaml`) + ACP permission flow +
  managed-settings.

### 3. Conclusion

**Deliberate.** Config for the v3 acp topology moved into the protocol and
the `.kiro/settings/` file family; the guard exists to fail loudly rather
than accept flags that would be silently ignored (the v2 acp arm accepts
them because there the Rust process IS the engine). Corollary: do not expect
upstream to "fix" the conflict; route model/effort/trust through the
protocol or files.

### 4–6. Drivers / fixture / interactions

Drivers: user-typed argv only. Fixture: the parse probes of G7 plus argv doc
§3's table already hold it. Interaction: the `--agent-engine=v2` escape hatch
(argv doc §3) is the only way to keep the flags on `acp`.

---

## G9 — session `_meta` feature flags: toggles, writers, consumers; what FTA is

### 1. The question

For each of `workflowsEnabled` / `ftaEnabled` / `specPlanEnabled` /
`semanticReviewEnabled` / `specWorkflow` / `specSkipClarificationEnabled`
(+ observed `agentMode`, `autopilot`): who toggles it, who consumes it.

### 2. Already known (corpus — cite, do not re-derive)

workflow-surface.md R-workflow-1/2: the five sibling resolvers in the
type-covenant settings module; create-handler calls them with parsed client
settings only, load-handler adds `persisted?.metadata.<flag>` as fallback;
`session/load` + edited metadata is the only no-patch enable path for
workflows. limits-and-engine.md R-limits-5: the 31-key
`BaseAgentSettingsSchema` (21 stable + 10 experimental underscore keys) with
`catchall`; the CLI forwards 23 keys.

### 3. The interface — completed here

Resolver defaults (867954–868400):

| flag | settings key (`_meta.kiro.settings`) | default | notes |
| --- | --- | --- | --- |
| `semanticReviewEnabled` | `semanticReview.enabled` | **true** | inverse-default by doc'd convention: "absent or invalid resolves to enabled"; consumers must NOT use `isSettingEnabled` |
| `ftaEnabled` | `fta.enabled` | false | |
| `workflowsEnabled` | `workflows.enabled` | false | |
| `specPlanEnabled` + `specWorkflow` + `specSkipClarificationEnabled` | `specPlan.{enabled, workflow, skipClarification}` | `{false, "quick", true}` | `workflow` enum `"quick" \| "full"`; persisted fallback validated back to `"quick"` on bad values |
| (steeringSupervisor) | `steeringSupervisor.enabled` | false | resolved same way; NOT persisted into session `_meta` |

**What FTA is:** schema doc comment (schema region 872016–883684):
"**Functional Task Alignment (FTA) validator sub-agent.** When enabled, the
coder can invoke the FTA subagent after implementation to validate claims."
Sibling comments: `goal` = "/goal command … repeat workflow"; `workflows` =
bundled steering + the four workflow tools; `specPlan` = "spec generation as
a dispatch step"; `steeringSupervisor` = per-tool-call verifier model,
currently SHADOW ("runs non-blocking for evaluation only");
`infraSafetyMonitor`/`infraSafetyEnforce` = tool-call safety gate
warn/block; `_providerPowers` = Powers-based 3P provider profiles (G10).

**Writers.** (a) Client `_meta.kiro.settings` at `session/new`/`session/load`
(the shipped CLI builds it from the fixed 23-key allowlist `[chat]` qCe at
396741449 + env conditionals `KIRO_INFRA_SAFETY_ROLLOUT_ENABLED`,
`KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION`, c2s rollout); note the allowlist
carries NO workflows/fta/goal/specPlan/semanticReview pair — the shipped
client cannot set those five; an external ACP client can. (b) Persisted
metadata (`buildInitialSessionMetadata`, 20340866–20341000, which is exactly
what `session/new` `_meta` echoes and `session.json` stores) with the
comment: "Persist ONLY the setting-flag component — never the experiment
contribution (config presence). Experiment membership is re-resolved" — i.e.
a third contributor exists: `ExperimentConfigService` (20455305), a
control-plane A/B service (ExP) segmented by client origin+version, layered
onto builtin `FEATURES` defaults via a per-session `FeatureConfigRegistry`;
it contributes CONFIG PRESENCE at runtime but is deliberately never
persisted. (c) `agentMode`/`autopilot`/`modelId`/`effortLevel` are re-written
by `setSessionConfigOption` (G3).

**Consumers.** The flags gate BUNDLED AGENT-PROFILE loading:
`loadFileBasedAgents(workspacePaths, {semanticReviewEnabled, ftaEnabled,
specPlanEnabled})` (20367042) decides which bundled profiles (semantic-review
agent, FTA validator, spec planner) enter the session's agent registry;
`workflowsEnabled` gates workflow steering + the four workflow tools (corpus);
`specWorkflow` selects `"quick-spec"` vs `"spec"` agent mode (corpus
hooks-dispatch-gate.md:1067); `goal` is gated by
`isSettingEnabled(settings,'goal')` from initialize-time clientMeta (settled).
`autopilot` is a config option (`"on"`/off) persisted per session.

### 4. Activation drivers

external-ACP-client (settings at new/load; the only path for the five gated
flags); user-typed via shipped client for the 23 allowlisted keys only;
workflow-step-driven (step-session builder injects
`settings: {workflows: {enabled: true}}`); cloud-driven (experiments) for
config presence, never persisted. Not model-elected, not hook-driven.

### 5. Fixture design

No-credit: `session/new` with
`_meta.kiro.settings: {fta: {enabled: true}, specPlan: {enabled: true,
workflow: "full", skipClarification: false}}` → response `_meta` echoes
`ftaEnabled: true, specPlanEnabled: true, specWorkflow: "full",
specSkipClarificationEnabled: false`; omit `semanticReview` → `true`
(inverse default is the discriminator). Persisted-fallback arm: corpus
R-workflow-2's session/load flow already holds it.

### 6. Cross-interactions

Flags are resolved ONCE per create/load and stored — not toggleable
mid-session (corpus). `session/load` of edited metadata beats client
settings only where the client sends nothing (the `??` chain). Experiments
can make a session behave enabled while its persisted flag says false — a
replay trap when comparing `session.json` against observed behavior.

---

## G10 — the structured log channels (`kiro`, `mcp`, `powers`) and what Powers is

### 1. The question

What writes each channel, the record schema, and the meaning of "powers".

### 2. Already known

Argv doc §4 table row: v3-only structured channels under
`~/.kiro/logs/<UTC-stamp>/`. Corpus R-limits-5 saw
`isFeatureEnabled('_providerPowers')` with no explanation.

### 3. The interface

`src/utils/file-logger.ts` (19672202 region):
`CHANNEL_FILES = {kiro: "kiro.log", mcp: "mcp.log", powers: "powers.log"}`;
`SINGLE_LOG_FILE = "kiro-agent.log"`; `MAX_LOG_DIRS = 10` (stamp-dir
rotation); dir name = ISO timestamp stripped of `-:.Z`. Level from
`KIRO_LOG_LEVEL` (`error|warn|info|debug|trace`, default `info`). Record
schema (`formatLogLine`): one JSON object per line —
`{timestamp, level, message, ...correlationFields, ...contextFields}` where
correlation fields come from baggage (`requestId`, `conversationId`,
`turnId`, `rootTurnId` — the RESERVED_LOG_KEYS set) and message = message +
space-joined JSON-stringified args. Wiring (`initializePlatform`, 20280413):
`setLogger(kiro)` — the default engine logger (all `logger.*` calls,
session lifecycle, model pinning, agent registry);
`setMcpLogger(mcp)` — the MCP subsystem; `setPowersLogger(powers)` — the
Powers subsystem. Under `--execution-environment=sandbox` the logger
collapses to `singleFile: true, flatDirectory: true` → one `kiro-agent.log`.
A separate in-memory `llmLogger` (500-entry ring, 888940 region) never
touches disk.

**What Powers is:** a plugin/packaging primitive.
`_KiroPowersTool` (`kiro_powers`, 18236018), tool description: "Powers
package documentation, workflow guides (steering files), and optionally MCP
servers. When a power includes MCP servers, their tools are accessed through
this interface rather than exposed directly." `PowersManager`
(`src/powers/powers-manager.ts`, 19268369) scans
`<homeDir>/.kiro/powers/installed/` (ConfigFileWatcher), emits
`_kiro/powers/items_changed`, rescans on `_kiro/powers/refresh`. Powers have
a `POWER.md` (`powerMdPath`). Provider routing steering (17808696): a
repository named `<provider>:<owner>/<name>` (e.g. `gitlab:group/project`)
requires activating the matching Power via `kiro_powers` before any work;
the `_providerPowers` experimental setting switches the autonomous
orchestrator to generic profiles with `includePowers: true` instead of
hardcoded provider profiles. The Amazon-internal flavor references an `asbx`
Power and `ASBX_KIRO_MANDATORY_MCPS`. So the `powers` channel logs this
subsystem's discovery/activation traffic; on a machine with no installed
powers it stays near-empty.

### 4. Activation drivers

Log channels: not a lever (always on; level via env). `kiro_powers` tool:
model-elected (it is a registered tool), agent-system-prompt-driven (steering
mandates activation for provider-prefixed repos); installation of powers is
user/filesystem-driven; `_providerPowers` flips via settings/experiments
(external-ACP-client or cloud).

### 5. Fixture design

No-model: launch nothing — inspect an existing
`~/.kiro/logs/<stamp>/` dir: exactly the three files (or `kiro-agent.log` for
sandbox runs); every line JSON-parses with `timestamp`/`level`/`message`;
rotation: >10 stamp dirs never observed. Powers: create
`~/.kiro/powers/installed/<name>/POWER.md`, `session/new`, expect
`_kiro/powers/items_changed` notification and a `powers.log` scan entry —
no prompt needed.

### 6. Cross-interactions

`KIRO_CHAT_LOG_FILE` (below) redirects the engine's stderr logger to a file —
a SEPARATE stream from the three channels. Sandbox mode changes the layout —
log-parsing tooling must handle both.

---

## ENV + engine argv — the full enumeration

Methods: `grep -oE 'process\.env\.[A-Za-z_][A-Za-z0-9_]*'`, bracket-literal
(`process.env["X"]` / backtick), bracket-const (each const resolved to its
literal), destructuring (`} = process.env` — 2 hits, both plain assignments
already counted). Denominator: the whole bundle, all occurrence counts from
`sort | uniq -c`.

### Engine bundle (KAS) — Kiro-meaningful vars

| var | consumer (offset) | effect |
| --- | --- | --- |
| `ACP_WS_PORT` | `startWebSocket` (20728068) | ws-transport port, default 8082; the chat binary's `serve --port` sets it |
| `ASBX_KIRO_MANDATORY_MCPS` | 4976793 | comma list of MCP servers force-loaded in the internal sandbox |
| `CLOUD_CONFIG_ENDPOINT` | 20726913 | cloud-config source (or `--cloud-config-endpoint`) |
| `GLOBAL_ENV_FILE` | 14860294 | path to an env file merged into tool env |
| `IS_INTERNAL` | 17991773 | `"true"` = internal environment (autonomous brain selection) |
| `KIRO_API_KEY` | 20725941 | auth provider apiKey mode — bypasses the acp-callback token flow |
| `KIRO_CHAT_LOG_FILE` | 20722569 | redirect engine stderr log stream to a file |
| `KIRO_CONTENT_COLLECTION_ENABLED` | 20726160 | content-collection default (also a config option) |
| `KIRO_CUSTOM_USER_AGENT` | 20726030 | UA override (default `KiroAgent 0.1.0`) |
| `KIRO_DISABLE_RECAP` | 16928201 | `"true"` disables session recap generation |
| `KIRO_DUMP_REQUESTS` / `KIRO_DUMP_REQUESTS_DIR` | 16645477 | dump infra-safety exchanges (default dir `$TMPDIR/kiro-agent-requests`) |
| `KIRO_KNOWLEDGE_MODEL_CACHE_DIR` / `KIRO_KNOWLEDGE_MODEL_REMOTE_HOST` | 16528625 | embedding-model cache dir / download host |
| `KIRO_LOAD_ALL_REMOTE_TOOLS` | 19991538 | bypass remote-tool allowlist |
| `KIRO_LOG_LEVEL` | 19672202 + 884656 | file-logger + stderr-logger level |
| `KIRO_REMOTE_SESSIONS_ENDPOINT` | 20726420 | remote session adapters (or `--remote-sessions-endpoint`) |
| `KIRO_SUPERVISOR_DEBUG` | 17075568 | steering-supervisor stderr debug |
| `KIRO_TOOL_SEARCH_THRESHOLD` | 18205659 | BM25 match threshold, default 1.5 |
| `PRINCIPAL_TYPE` | 19306705 | `MIDWAY_USER` + sandbox drops the web-fetch tool |

Rest of the enumeration is vendored-library noise: AWS SDK credential/region
family (`AWS_*`, `ENV_*` consts), gRPC (`GRPC_*`), OTel
(`OTEL_EXPORTER_*`), yaml (`LOG_TOKENS`, `LOG_STREAM`), minimatch/graceful-fs
test hooks, `HOME`/`USERPROFILE`/`APPDATA`/`XDG_*` (platform dirs; corpus:
HOME is the isolation lever, `KIRO_HOME` has ZERO bundle hits),
`SHELL`/`PATH`/`COMSPEC`/`PATHEXT`, `DEBUG`/`NODE_DEBUG`,
`BRAZIL_PACKAGE_CACHE`, `WS_NO_*`, `CHOKIDAR_*`.

### Engine argv (all 15 `getCliArg` names, entry module 20723760–20725900)

`--transport` (`stdio`|`ws`, default stdio), `--auth`
(`user`|`machine`|`acp-callback`, default user), `--token-path`, `--region`,
`--endpoint`, `--control-plane-endpoint`, `--execution-environment`
(`local`|`sandbox`, default local), `--home-dir`, `--sandbox`
(`auto`|`seatbelt`|`bubblewrap`|`docker`|`none`), `--sandbox-allow-write`
(csv), `--sandbox-network-mode`
(`default_allowed`|`default_blocked`|`common_dependencies`),
`--sandbox-rootfs`, `--remote-sessions-endpoint`, `--cloud-config-endpoint`,
`--test-traffic`. All `--name=value` form only (empty value = hard exit).
`hasCliFlag` does not exist. The launcher passes exactly
`--transport=stdio --auth=acp-callback` (settled corpus fact).

### Rust client (chat binary) — vars affecting the ACP arm

`KIRO_KAS_NODE_PATH` / `KIRO_KAS_SERVER_PATH` (`[chat]` 158167942): override
the node binary / KAS bundle used to spawn the engine — error strings
"Cannot resolve node binary for KAS: KIRO_KAS_NODE_PATH not set and embedded
node not available" prove they are the override rung above the embedded
extraction (the `.lock`/"extracting KAS bundle" machinery). **This is the
lever for pinning a custom engine build.** `KIRO_MOCK_ACP="true"` (`[chat]`
397344108, embedded JS): swaps in a MockSessionClient — client-side test
mode, no engine. `KIRO_CLI_ACP_CLIENT_NAME` (`[chat]` 5602925): overrides the
ACP client name. `KIRO_ENABLED_FEATURES`: client-side feature catalog —
its `workflows` entry has NO consumer at 2.15.1 (corpus C-11, do not
re-derive). Rollout gates read by the settings builder:
`KIRO_INFRA_SAFETY_ROLLOUT_ENABLED`, `KIRO_C2S_ROLLOUT_ENABLED`,
`KIRO_LITE_ROLLOUT_ENABLED`; test kill switch
`KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION` (R-limits-5). Also present
client-side: `KIRO_HOME`, `KIRO_DATA_DIR`, `KIRO_TEST_*` family
(`KIRO_TEST_SESSIONS_DIR`, `KIRO_TEST_DB_PATH`, `KIRO_TEST_SETTINGS_PATH`,
`KIRO_TEST_MOCK_KAS_SESSIONS`, …), `KAS_BUNDLE_PATH`, `KIRO_NO_AUTO_UPDATE`,
`KIRO_FEED_URL`, `KIRO_VERSION_OVERRIDE`, UI/log vars (`KIRO_TUI_LOG_FILE`,
`KIRO_RENDER_LOG_FILE`, `KIRO_LOG_NO_COLOR`, `KIRO_TERMINAL_*`), telemetry
(`KIRO_TELEMETRY_*`), `KIRO_VOICE_SERVER_URL`, `KIRO_SESSION_ID`,
`KIRO_USER_ID`, `KIRO_MODE`, `KIRO_UI_MODE` — enumerated from
`grep -aoE 'KIRO_[A-Z0-9_]{2,45}'` over both Rust binaries (launcher adds
`KIRO_TEST_MODE`, `KIRO_AUTH_PORTAL_URL`, `KIRO_ROUTER_*`, autosuggest
family); consumers not traced beyond the ones named above (C-11 caution:
presence ≠ consumed).

### Activation drivers

All env/argv levers: user-typed / external-ACP-client (process spawn
environment). `GLOBAL_ENV_FILE` + spawn-env inheritance additionally means
hook-driven and tool-driven processes SEE these vars (corpus C-5: the
process runner merges full `process.env` into hook env).

### Fixture design

Parse-level fixtures for argv validation errors (`--transport=x` exits 1
naming valid options — no engine, no auth). `KIRO_KAS_SERVER_PATH` fixture
SPEC: point it at a copied bundle with a distinctive stderr banner, run any
chat/acp form, observe the banner (spawns engine — spec only).

### Cross-interactions

`KIRO_API_KEY` changes the auth mode selected even under `--auth=acp-callback`
context (selectAuthProvider receives both; precedence not traced — flagged).
`ACP_WS_PORT` only matters under `--transport=ws` (`serve`). Env reaches the
engine through the client spawn, so wrapper-injected vars land in hooks and
tools too.
