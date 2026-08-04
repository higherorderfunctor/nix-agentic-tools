> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# F21 — Cross-Interaction and Conflict Matrix

## 1. The question

When two Kiro v3 levers are pulled together, which one wins, and by what rule?
"Settled" means: for every axis-pair below, each cell names the code that
resolves the conflict (READ, with a bundle offset or corpus/digest citation) or
declares the resolution INFERRED and ships a fixture that would falsify it. The
levers are the ones the F1–F22 items enumerated; F21 does not discover new
surfaces, it composes the known ones.

Bundle path abbreviated `$B` below:
`/home/caubut/.local/share/kiro-cli/kas/2.15.1-e20633b4.../node_modules/@kiro/agent/dist/server/acp-server.js`.

## 2. What is already known (inputs)

- Tool-pool assembly, `filterDenied` fail-open: F10 digest; `getTools` closure
  at `$B` 19314966–19315491 (read here).
- Agent-profile tool policy (`allowedTools`/`excludedTools`/`includeMcpJson`/
  `includePowers`) resolved via `toolPolicyForAgent` → `withToolPolicy` →
  `filterToolsWithFlags`: F14/F10 digests; `$B` 20371162, 4974541, 4990840.
- Permission rule layering (6 scopes, Cedar deny>ask>allow, subagent rules only
  narrow parent, shared parent `PolicySession`): F18 digest; F14 permissions
  block.
- `skipHooks` is the whole hook gate; tool/file hooks are ungated: corpus
  `records/hooks-dispatch-gate.md` R-hooks-3 and R-hooks-6; `$B` 18036348,
  17715087 (read here).
- Steering ⊕ skills ⊕ agent prompt composition (channels A/B, `composeSystemPrompt`,
  profile prompt REPLACES base): F15/F16 digests.
- Progressive-item dedup (skills + auto-steering, `displayName` last-wins,
  registered overrides scanned): F15 digest; `$B` 19374517, 19378803 (read).
- Session `_meta.kiro.settings` feature bridge (per-key, RAW-key-gated,
  per-session save/restore): F17/acp-config digests; `$B` 20294218, 20345048,
  20447576 (read here).
- Per-dispatch model/effort resolution and the full precedence lattice: F8
  framing + F22 digest (`invoke_subagent.starting` log). Not restated here.
- Tags vs capabilities: `getToolCapability` id-first then tag-fallback (`$B`
  4968063); `matchesPattern` id===pattern before glob before tag (F13/f11 digests).

## 3. The interface — the resolution primitives, fully enumerated

Every conflict below reduces to one of these seven resolver primitives. Each is
READ from the bundle at the cited offset.

| # | Primitive | Where | Rule it imposes |
|---|-----------|-------|-----------------|
| P1 | `filterDenied(tools)` | `$B` 19314966 | drop a tool iff `getToolCapability(id,tags)` resolves AND `policySession.isCapabilityDenied(cap)`; **fail-OPEN** on `hasFatalParseError()`. Blanket-deny only — a `match`-scoped deny is NOT blanket so the tool stays visible and is gated at call time. |
| P2 | `filterToolsWithFlags(tools,policy)` | `$B` 4974541 | `allowedTools` (`"*"`=all, `[]`=none) then re-union `includeMcpJson`/`includePowers`/mandatory-MCP, then subtract `excludedTools`, then **re-union `INFRASTRUCTURE_CAPABILITIES` = {skill}** unconditionally. So `disclose_context` cannot be excluded by an agent profile. |
| P3 | connection `filterTools` delegated bypass | `$B` 4994107 | after P2, re-add `report_progress`/`subagent_response`/`user_input` when delegated, and `send_message` when `isWorkflowStepSession` — past any allowlist. |
| P4 | Cedar policy engine | F18; F14 | across the 6 scopes `allow→permit`, `deny`&`ask→forbid` ⇒ **deny > ask > allow**; no matching rule ⇒ implicit ask. `kiro`+`administration` scopes may only deny/ask. |
| P5 | `execution.skipHooks` guard | `$B` 18036348 | the prompt-hooks node and agent-stop node early-return when true; set true ONLY by `DefaultSubAgentAdapter` (`$B` 17715087). Tool/file hooks never read it (R-hooks-6). |
| P6 | `composeSystemPrompt` REPLACE-vs-append | F16 | agent `prompt` REPLACES the builtin base; steering strings + docs are composed AROUND it; `{learnings}` placeholder is replaced-or-appended. msg0 frozen after turn 1. |
| P7 | feature bridge `bridgedIsFeatureEnabled` | `$B` 20294218 (init), 20345048 (new) | for a key present RAW in `_meta.kiro.settings`, `isFeatureEnabled(key)`=`isSettingEnabled(settings,key)`; else falls through to prior provider. Per-session provider save/restore at 20346796/20447576. |

## 4. Activation drivers (who can pull each conflicting lever)

| Lever | user-typed | skill | agent-prompt | model-elected | hook | workflow-step | ext-ACP-client |
|-------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| global permission rules (`permissions.yaml`) | ✓ (edit file) | — | — | — | — | — | ✓ (persist via consent) |
| agent-profile permissions/tools | ✓ (author profile) | — | — | — | — | — | ✓ (customAgents in `_meta`) |
| workspace trust gate | ✓ (trust prompt) | — | — | — | — | — | ✓ (`workspaceTrusted`) |
| hook install | ✓ (write hook file) | — | — | model can `create_hook` (fs_write, approval) | — | — | ✓ (`_meta.kiro.hooks`) |
| workflow step (tool policy, steering) | — | — | — | ✓ (`run_workflow`) | — | ✓ | ✓ (`_kiro/workflow/*`) |
| steering docs | ✓ | — | ✓ (resources) | — | — | ✓ (appends) | ✓ (client steering) |
| skill (progressive) | ✓ (slash) | ✓ (`skill://` res) | ✓ (profile res) | ✓ (`disclose_context`) | — | — | ✓ |
| per-dispatch model/effort | — | — | ✓ (profile fields) | ✓ (inline agent) | — | ✓ (step > wf > parent) | ✓ (inline) |
| session `_meta` feature flags | — | — | — | — | — | ✓ (step sets `workflows`) | ✓ (only path) |
| `settings` store (cli.json) | ✓ (`/settings`) | — | — | — | — | — | — (engine never reads it) |
| clientMeta gates (`goal`, `inlineAgents`, `backgroundProcesses`, `hooks.v2`) | — | — | — | — | — | — | ✓ (initialize only) |

## 5. Fixture design (per INFERRED cell — see §6 for the READ ones)

All fixtures are model-free ACP probes unless marked SPEC (needs a model turn).
Cheapest holder named per cell. Common harness: HOME-isolated scratch,
`--transport=stdio --auth=acp-callback`, token refused via JSON-RPC error (per
`acp-live-probe`); observe persisted `_meta`, `configOptions`, or
`~/.kiro/logs/<ts>/kiro.log`.

- **FX-1 (permissions × workflow-step tool policy).** INFERRED that a global
  `deny fs_write` still removes `fs_write` from a workflow-step session even
  though the step supplies its own `toolPolicy`. Probe: `_kiro/workflow/new`
  with `parentSessionId` under a session whose `permissions.yaml` blanket-denies
  `fs_write`; inspect the step session's advertised tools via
  `available_commands_update`/tool list. PASS = no `fs_write` tool present
  (P1 runs at pool assembly, before the step's P2). FAIL = present.
- **FX-2 (hook-inject × dispatched sub-agent).** INFERRED-from-READ that a
  `SessionStart` hook does NOT fire in a `DefaultSubAgentAdapter` child but DOES
  fire in a `custom-agent` child. SPEC (needs one dispatch): dispatch a worker
  under a profile with a `SessionStart` hook that writes a sentinel file; run
  once with `dispatchKind` default, once with `dispatchKind:"custom-agent"`.
  Observable = sentinel present only in the custom-agent run. Discriminator is
  `skipHooks` (P5).
- **FX-3 (feature bridge × settings store collision).** INFERRED that the engine
  ignores the cli.json `settings` store entirely and only the `_meta.kiro.settings`
  bridge moves a feature flag. Probe: set `workflows:{enabled:true}` in
  `~/.kiro/settings/cli.json`, create a session with NO `_meta.kiro.settings`;
  read `session/new` `_meta.workflowsEnabled`. PASS = `false` (store ignored,
  P7 never invoked). Then repeat with `_meta.kiro.settings.workflows` → `true`.
- **FX-4 (init bridge × session bridge stacking).** INFERRED that a session/new
  bridge stacks on the initialize-time bridge and is restored to the
  initialize-bridged provider (not the raw default) on dispose. SPEC-ish probe:
  initialize with `_meta.kiro.settings.memoryEnable`, then `session/new` with a
  different key, dispose, open a second session with neither; check whether
  `memoryEnable` still reads bridged. Discriminator = provider chain at 20447576.

## 6. Cross-interaction matrix (one table per axis-pair)

Cells are `RULE — READ/INFERRED (cite)`.

### 6a. Permission layers × tools

| Pair | Resolution rule | State |
|------|-----------------|-------|
| global rules × agent-profile tools (`tools:`/`excludedTools`) | **Compose, permission-deny first.** P1 removes blanket-denied-capability tools at pool assembly; P2 then narrows by the profile allowlist. A profile `tools:["*"]` CANNOT re-add a blanket-denied tool. A profile `excludedTools` CANNOT remove a `skill`-capability tool (P2 re-unions `INFRASTRUCTURE_CAPABILITIES`). | READ (`$B` 19315200, 4976420) |
| global rules × agent-profile permissions block | **Cedar cross-scope, deny>ask>allow.** Agent scope is one of the 6; a profile `allow` cannot override a `user`/`workspace` `deny` (forbid wins). Subagent profile rules only NARROW the parent. | READ (F18; F14 permissions) |
| agent-profile permissions × workspace trust | **Trust gates LOADING of the workspace profile, not the rule merge.** An untrusted workspace drops workspace-scope agents/skills/steering (global survive) and adds ASK rules on `.kiro/*`; a trusted workspace profile's rules then merge normally. Hook LOADING is not trust-gated; hook EXECUTION is. | READ (F14; F15) |
| blanket deny × match-scoped deny (same capability) | **Only blanket deny hides the tool.** P1 uses `isCapabilityDenied` (no resource) — a deny with a `match` is not blanket, so the tool stays visible and is resolved at call-time approval (P4) instead. | READ (`$B` 20135808; f10 approval digest) |
| capability deny × delegated bypass tools | **Bypass loses to capability deny? NO — bypass tools have no denied capability.** `report_progress`/`subagent_response`/`user_input`/`send_message` carry no `TOOL_CAPABILITY_MAP` entry, so P1 never drops them and P3 re-adds them past the allowlist. | READ (`$B` 4994107; capability map has none of these) |

### 6b. Hooks × workflow steps / sub-executions

| Pair | Resolution rule | State |
|------|-----------------|-------|
| session/prompt/stop hooks × dispatched sub-agent | **Suppressed for default sub-agents, fire for custom-agent/spec.** `skipHooks` true only via `DefaultSubAgentAdapter`; nodes are present-and-skipped, not absent. | READ (`$B` 17715087, 18036348; R-hooks-3) |
| tool/file hooks × any delegated execution | **Always fire.** `PreToolUse`/`PostToolUse`/`PostFile*` never read `skipHooks`/depth/identity — only "any installed?". So observation-only hooks work in a default worker with no profile change. | READ (R-hooks-6; hooks-dispatch-gate.md:1185) |
| hooks × workflow STEP session | **Steps are full sessions, not sub-executions, so `skipHooks` is unset → prompt/stop hooks CAN fire.** `createWorkflowStepSession` calls `host.newSession` (`$B` 18643404) — a normal session; no adapter sets `skipHooks`. C-9 truncation does not apply (step = full session). | READ (`$B` 18643404; F20 digest) |
| `UserPromptSubmit` hook × its own blocking-trigger appearance | **Never blocks.** Injected on any exit code via raw stdout/stderr reader; appears in the blocking set but bypasses the decision fn (settled-facts + F14). | READ (settled facts) |
| workflow `send_message` × workflows-disabled gate | **Step sessions keep send_message even though the connection gate is workflows.** `createWorkflowStepSession` sets `settings.workflows.enabled` explicitly, and P3 re-adds `send_message` for step sessions past the allowlist. | READ (`$B` workflow-surface.md:662; 4994107) |
| model-created hook (`create_hook`) × approval | **`create_hook` is `fs_write` capability and approval-gated at call time; F10 notes the write itself has no separate approval.** So a model can install a hook file subject only to the fs_write permission/approval on the target path. | READ (F10 approval list; capability map `create_hook:"fs_write"`) |

### 6c. Steering × skills × agent prompt

| Pair | Resolution rule | State |
|------|-----------------|-------|
| agent `prompt` × builtin base prompt | **REPLACE.** Root path uses `customAgent.prompt` INSTEAD of the base; builtin identity absent. | READ (P6; F16) |
| steering strings/docs × agent prompt | **Compose AROUND.** `composeSystemPrompt` wraps base(or profile prompt) with `<repositories>`/`<learnings>`/`<steering-files>`/`<knowledge-bases>`. Steering never replaces the prompt. | READ (F16 `$B` 14245884) |
| always-steering × invalid-frontmatter steering | **Invalid frontmatter silently DEGRADES to always-included with raw frontmatter left in body** (js-yaml CORE: `no` is a string, not false). A typo upgrades a scoped doc to always-on. | READ (F14/F15) |
| skills × auto-steering in the disclosure pool | **Merged into ONE progressive pool, deduped by `displayName`, last-wins; workspace shadows global; `registeredItems` (profile `skill://`) override scanned.** Untrusted workspace keeps only `scope==="global"`. | READ (`$B` 19378803 dedup, 19374517 register, 19314xxx trust filter) |
| skill name × auto-steering name collision | **Whichever is scanned/registered last for that `displayName` wins the single map slot** — a skill and an auto-steering doc sharing a name cannot both be disclosed. | READ (`$B` 19378803 — one Map keyed on `displayName`) |
| steering `#[[file:...]]` × its own advertised support | **Inert in steering/skill bodies.** The provider-injection regex is applied ONLY to custom-agent system prompts, and no `file` provider is registered; the engine's own prose claiming support is documented-but-unconsumed (C-11). | READ (F15) |
| msg0 freeze × mid-session steering/prompt edit | **Edits reach only NEW sessions.** msg0 computed turn 1, replayed byte-for-byte. Mid-session mode switch likely keeps old msg0 (untested — F16 open). | READ-with-open (F16) |

### 6d. Subagent inheritance × per-dispatch overrides

Precedence lattice itself is F8/F22 — not restated. F21 records only the
compose-vs-override boundaries.

| Pair | Resolution rule | State |
|------|-----------------|-------|
| parent model/effort × per-dispatch override | **Any override REBUILDS both model+effort;** model override w/o effort → target model's default effort (inline fallback = `belowMax`, 2nd-highest), NOT parent's. No override → parent inherited untouched. | READ (F22 digest) |
| parent tool surface × inline agent | **Inline agent inherits parent's FULL tool surface** (`tools:"*"`, no policy filter) — the widest inheritance path. Gated on initialize `settings.inlineAgents`; external-ACP-client only. | READ (F22; F16) |
| parent permission grants × sub-agent | **Workers inherit parent grants** (consent persists into the SHARED parent `PolicySession`); subagent profile rules can only NARROW. | READ (F18) |
| parent hooks × sub-agent hooks | **`dispatchKind` default `sub-agent` → `skipHooks:true` (zero child prompt/stop hooks); `custom-agent` → they fire.** Tool/file hooks fire either way (6b). | READ (P5; F22) |
| parent todo_list × sub-agent todo_list | **SHARED BY REFERENCE** — a subagent allowed `todo_list` mutates the PARENT list (one instance per acp-workspace-connection). | READ (F13 `$B` 19303469) |
| parent context × sub-agent | **No parent conversation history forwarded** (F17 ruled out); child gets only `contextMessages` (contextFiles + spec tree) + its dispatch prompt. | READ (F17) |

### 6e. Tags × capabilities

| Pair | Resolution rule | State |
|------|-----------------|-------|
| `tools:` entry as tag vs as id | **`matchesPattern` checks id===pattern FIRST, then glob, then tag membership.** So `tools:["todo_list"]` selects one tool by id even though `todo_list` is not a tag; `tools:["read"]` selects all fs_read-tagged tools by tag. | READ (`$B` 4972609; f13 verify) |
| tool tag (`@mcp`/`@powers`) × capability for permission | **Different namespaces on the same tool.** `getToolCapability` is id-first then tag-fallback; permission rules key on capability, `tools:` selection keys on id/tag via `matchesPattern`. A tool can be tag-selected yet capability-denied (composes: selected then dropped by P1). | READ (`$B` 4968063) |
| `excludedTools` tag × `INFRASTRUCTURE_CAPABILITIES` | **skill-capability tools survive exclusion.** P2 re-unions them after `excludedTools` subtraction. | READ (`$B` 4976420) |
| invalid tag in `tools:` | **No validator rejects it** (`isValidTag` has zero consumers); a non-tag non-id pattern simply matches nothing → tool absent, no error. | READ (f13 verify) |

### 6f. Session `_meta` feature flags × settings store × clientMeta gates

| Pair | Resolution rule | State |
|------|-----------------|-------|
| `_meta.kiro.settings` bridge × cli.json settings store | **Engine reads ONLY the `_meta` bridge for feature flags; the cli.json store is never read by the engine** (`settings all/list` dump the store for the client). The two do not compose — the store is inert engine-side. | READ (acp-config G-sweep; F17) |
| initialize-time bridge × session/new bridge | **Session/new bridge stacks on whatever provider is current (possibly the init-bridged one) and is saved for restore on dispose;** restore only fires if the current provider is still the one this session installed (`isFeatureEnabled === bridgedIsFeatureEnabled`). | READ (`$B` 20294218, 20345048, 20346796, 20447576) |
| clientMeta gate × `_meta.kiro.settings` | **Different mechanisms, different keys.** clientMeta gates (`goal`, `inlineAgents`, `backgroundProcesses`, `hooks.v2`) are initialize-time connection capabilities read directly; the settings bridge overrides `isFeatureEnabled` names. A key in one is not in the other. clientMeta is immutable per connection. | READ (F10 `$B` 20290997; F1) |
| CLI-forwarded allowlist × external-ACP-client | **The shipped client forwards a fixed 23-key allowlist**, so most bridge keys (workflows/fta/goal/specPlan/semanticReview, and undeclared twins) are reachable ONLY by an external ACP client, not the stock TUI. | READ (acp-config G9; F17) |
| `workflows` KIRO_ENABLED_FEATURES entry × its consumer | **Inert at 2.15.1** — the catalog entry instructs enabling workflows that way but has NO consumer (C-11). The live path is `_meta.kiro.settings.workflows`. | READ (C-11; f09 verify) |

### 6g. Slash/user surfaces × model-elected tools (mode contention)

| Pair | Resolution rule | State |
|------|-----------------|-------|
| `/plan` `/spec` `/agent swap` `/autonomous` `/clear` × each other | **All write the single `mode` configId — last writer wins;** `KIRO_MODE` env presets it at session/new (0 bundle hits → env not consumed by engine; the preset is client-side). `/plan` self-exits (persists back to `vibe` at turn end). | READ (f11 digest; `$B` KIRO_MODE=0, modeId=129) |
| user slash command × model | **No slash command is model-electable** (no tool reaches either router). Model equivalents are TOOLS: `switch_to_execution`, delegation/subagent, `run_workflow` (when enabled), `disclose_context`. | READ (f11 verify) |
| mode switch × frozen msg0 | **A mid-session mode switch does not rebuild the frozen msg0** (only PlanExecute strips stale heads) — the new mode's steering/prompt reaches only new sessions/turns per F16; untested edge. | READ-with-open (F16) |
| `/goal` typed text × workflow-step resume interception | **Inside a workflow-step session, `tryResumeStepWithMessage` eats ANY non-empty prompt text BEFORE `parseGoalCommand`** — a typed `/goal` in a step session is consumed as step steering, not parsed. Ordering, not a second parser. | READ (f11 verify `$B` 20380535 before 20383313) |

## 7. Consolidated conflict-resolution summary

1. **Tool visibility** is a two-stage funnel: P1 (permission blanket-deny, pool
   assembly, fail-open) THEN P2 (agent allow/exclude) THEN P3 (delegated
   re-adds). skill-capability and delegated-coordination tools escape P2.
2. **Permission effect** across scopes is Cedar deny>ask>allow; subagent rules
   only narrow; grants persist into the shared parent PolicySession.
3. **Hooks** split on a single boolean: prompt/stop hooks gated by `skipHooks`
   (only default sub-agents skip); tool/file hooks ungated everywhere; workflow
   steps are full sessions so their prompt/stop hooks CAN fire.
4. **System prompt** = profile prompt REPLACES base, steering composes around,
   msg0 freezes at turn 1.
5. **Progressive context** (skills+auto-steering) is one displayName-keyed pool,
   last-wins, registered-over-scanned, global-only when untrusted.
6. **Feature flags** live only in the per-session `_meta.kiro.settings` bridge
   (cli.json store is engine-inert); clientMeta gates are a separate immutable
   channel; the stock TUI's fixed allowlist means most flags are ext-client-only.
7. **Mode** is a single last-writer-wins configId that many user surfaces
   contend for; no slash command is model-electable.

## 8. Open questions (INFERRED cells needing the §5 fixtures)

- FX-1: does P1 actually run before a workflow-step's own toolPolicy (inferred
  from stage ordering, not run against a step session).
- FX-2: `SessionStart` firing asymmetry across `dispatchKind` (inferred from
  `skipHooks`; needs one dispatch to observe the sentinel).
- FX-3/FX-4: cli.json-store inertness and bridge stacking/restore observed
  statically only; a token-free session/new echo would confirm.
- Mid-session mode switch vs frozen msg0 (F16 open, carried).
