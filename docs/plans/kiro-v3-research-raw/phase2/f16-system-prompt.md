# F16 — system prompt: extraction and override

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

All byte offsets below are into the pretty-printed KAS bundle (`$B`), read via
`head -c $((OFFSET+N)) "$B" | tail -c M`. esbuild suffixes churn between
releases — re-anchor on the quoted semantics, not the offsets.

## 1. The question

(a) Can the effective (assembled) system prompt be dumped — from the bundle, a
debug flag, or a session artifact? (b) Is there an append/replace override
lever, and at what scope — global setting, agent profile, per-dispatch? (c) What
is the full assembly pipeline: every segment, its order, its conditionality, and
who can pull each lever?

Settled = each segment source named with its composition order and gate, plus a
working extraction recipe and a bounded negative for every claimed absence.

## 2. What is already known

- Dispatch context carries `systemPrompt` and `steering` fields
  (corpus `records/limits-and-engine.md` ~903, `records/hooks-dispatch-gate.md`
  ~857); `previousMessages: void 0` pins dispatched sub-executions to the
  first-turn branch (settled facts).
- `steering_inclusion` is a messages.jsonl event kind — 158 root / 615 sub rows
  in the corpus (`evidence/machine-state.md` ~447).
- Workflow steering append (`workflows_default`, `WORKFLOW_STEP_COMPLETION_PROTOCOL`)
  gated on `workflowsEnabled` / `workflowId` (`records/workflow-surface.md`
  ~717-729).
- Builtin mode ids `vibe|spec|quick-spec|bug-fix|plan|autonomous`; agent loader
  recurses + follows symlinks; workspace profiles trust-gated; frontmatter is
  js-yaml CORE (settled facts).
- Vendor doc claims (private/kiro-v3-docs.md:441-475): md body becomes the
  system prompt; JSON equivalent; line 661: `file-prompt` finding "Absolute or
  `~/` file prompt paths may not resolve". Verified/corrected below.

## 3. The interface, fully enumerated

### 3.1 The composer: `composeSystemPrompt` (offset 14245884)

`src/utils/prompt-building/compose-system-prompt.ts`:

```
composeSystemPrompt(basePrompt, learnings, steering, repositories, knowledgeListing)
  text = basePrompt
  if repositories.length: text += "\n\n<repositories>\n" + join("\n") + "\n</repositories>"
  if learnings.length:    block = "<learnings>\n" + join("\n") + "\n</learnings>"
                          text.includes("{learnings}") ? replace("{learnings}", block)
                                                       : text += "\n\n" + block
  if steering.length:     text += "\n\n<steering-files>\n" + join("\n\n") + "\n</steering-files>"
  if knowledgeListing:    text += "\n\n<knowledge-bases>\n" + it + "\n</knowledge-bases>"
```

The literal `{learnings}` placeholder is checked ONLY here (2 hits in the whole
bundle, both inside this function) — no bundled base prompt contains it, so it
is exclusively an agent-profile authoring lever for learnings placement.

### 3.2 msg0 shape — there is no true system role

Every adapter wraps the composed text as a HUMAN message flagged
`withForcedRole()` (msg0). `insertMsg0Separator` (14149717) splices an AI
message `"I will follow these instructions."` between msg0 and the first real
human message when `messages[0].forcedRole && messages[1].role === "human"`.
Spec/plan adapters build the pair explicitly. `extractReplayMsg0` (14150144)
recognizes msg0 on later turns by `head.forcedRole`.

### 3.3 Per-mode base prompt selection: `createDefinitionForMode` (~20404800)

Runs per prompt turn. First builds the shared `steering` string array:

```
staticSteering = getStaticSteering(agentContext, modeId)      // 18013221
               → renderDynamic(raw, session.promptTemplateContext)   // mustache
baseSteering   = staticSteering ? [...session.globalSteering, staticSteering]
                                : session.globalSteering
steering       = session.workflowId     ? [...baseSteering, WORKFLOW_STEP_COMPLETION_PROTOCOL]
               : session.workflowsEnabled ? [...baseSteering, workflows_default]
               : baseSteering
```

- `STATIC_STEERING_TEMPLATES` (18005942) has exactly ONE client key,
  `"kiro-web"` (mode keys under it incl. `vibe`) — **no static steering for
  kiro-cli** (positive control: the `"kiro-web": {` key found by the same
  quoted-key grep).
- `session.globalSteering` starts `[]` (20491029) and is populated ONLY by
  `fetchGlobalContext` (20450400 region) calling `get_steering_files` on
  `this.remoteMCPClient` (and `get_learnings_for_prompt` limit 50 →
  `session.globalLearnings`). No remote MCP client → both stay empty. Local CLI
  runs have no learnings and no global steering strings.

Then branches on mode:

| modeId | definition | base prompt |
| --- | --- | --- |
| `autonomous` | AutonomousAgentExecutionDefinition (17250637) | `renderDynamic(autonomousDefinition.prompt, wsCtx)` — bundled orchestrator variants (17991824) |
| `plan` | PlanExecuteDefinition (17247266) | `getPlanDefinition().prompt` = `PLAN_SYSTEM_PROMPT` (19989878, `supportsTemplating: true`); executor phase separately uses `getChatPrompt` |
| custom agent set | CustomAgentExecutionDefinition | `session.customAgent.prompt` **raw** — no mustache, no `#[[...]]` expansion (see 3.6) |
| spec-like (`spec`, `quick-spec`, `bug-fix`) | SpecGenerationDefinition (17160541) | `getSystemPrompt(...)` → `getOrchestratorSystemPrompt` (14165635) `.format({machineId})`; msg0 text prefixed `# Additional Instructions` |
| default (`vibe`) | ChatAgentDefinition (17239278) | `getChatPrompt` = `createAgentPrompt` over `getBasePrompt` |

Custom-agent branch also appends profile `resources` content to steering:
`customSteering = [...steering, ...matchedContent]` where matchedContent =
`resolveAgentResourcesForSession` (20596149) — the profile's `file://` globs
expanded per workspace path; unreadable files warn `agent.profile.resource.unresolved`.

### 3.4 The builtin base prompt: `getBasePrompt` (5044447, src/execution/definitions/prompts.ts)

Ordered template (client = `agentContext.client`, one of
`kiro-cli|kiro-ide|kiro-web`):

1. `getIdentity(client)` — kiro-cli: "You are Kiro CLI, an agentic AI software
   engineer that runs in the command line. ..."
2. `<key_kiro_features>`: `getSessionTypes`, `getAutonomyModes`,
   `getChatContext`, hooksBlock (kiro-ide ONLY), `getSteering` (prose about
   steering), `getMcp`, `getSystemAndPlatform(client, isSandboxEnv, workspace,
   shellTypeInfo)`, `<spec>` block (mentions the `#[[file:...]]` reference
   syntax), `<internet_access>` block.
3. `<current_date_and_time>` — rendered at BUILD time via
   `new Date().toLocaleDateString("en-US", ...)`.
4. `getResponseLanguageDirective(agentContext)`.

The vibe layer (`createAgentPrompt`, ~5057968) adds a web-only identity line,
`<goal>`, model-specific goals (`getModelSpecificGoals`), and the delegation
tool name (varies with the `subagentOrchestration` feature). Template key:
`{machineId}` filled by `.format({machineId})`.

### 3.5 Adapter suffixes after `composeSystemPrompt`

- **CustomAgent** (14523272): `+ "\n<current_context>Machine ID: ${workspace.machineId}</current_context>"`,
  then `attachSteeringDocuments`.
- **ChatAgent** (17236100 build → 17233709): opts hardcode
  `includeFileTree: true`; `+ "\nThe current model is <displayName>."` when
  modelId known; `attachSteeringDocuments`; file-tree XML appended to msg0
  text; open-files XML appended to msg0.
- **Spec**: msg0 = `"# Additional Instructions"` + composed text, id
  `SYSTEM_PROMPT_MESSAGE_ID`; `attachSteeringDocuments`.
- **PlanExecute**: msg0 pair built explicitly; on plan→execute handoff,
  `stripStaleSystemPromptMessages` (17242718) removes prior
  `SYSTEM_PROMPT_MESSAGE_ID` heads and installs the executor prompt — the ONLY
  adapter that replaces msg0 mid-session.

### 3.6 Steering documents (the attached-documents channel — distinct from the `<steering-files>` text block)

`attachSteeringDocuments` (14150844) → `workspace.getSteeringDocuments()` →
NodeSteeringProvider (19326723):

- Sources: `<each workspace folder>/.kiro/steering/**/*.md` (recursive),
  `~/.kiro/steering/*.md` (global; cloud replica dir prepended in-sandbox),
  and `AGENTS.md` at each workspace ROOT (loaded as a steering doc with
  inclusion `always`; `AGENTS.md` found elsewhere is skipped unless inside a
  steering dir).
- Front matter schema: `inclusion`, `fileMatchPattern` (19332600). Missing
  `inclusion` ⇒ `always` (`getAlwaysIncludedDocuments`, 19327960). `fileMatch`
  docs join per-turn when open files match (steering node 13835679 — the
  per-turn rows are what `steering_inclusion` records; the msg0 announcement
  row carries ids only, "content is already on msg0"). `auto` ⇒ progressive:
  summary lines live in the `disclose_context` TOOL DESCRIPTION, content is
  model-elected on demand (20603027 doc comment) — never in msg0. Skills
  (`.kiro/skills`, global + workspace) ride the same progressive channel, never
  msg0.
- Trust gate: untrusted workspace ⇒ only `scope === "global"` docs survive
  (19334779) — workspace steering AND AGENTS.md drop.
- Docs are serialized into the model context as
  `[label]\n<steering_content>...</steering_content>` blocks (16649310 region).

### 3.7 Agent profiles — the primary override lever

Loader `loadAgentProfiles` (17228462 region): scans `.kiro/agents/**/*.{md,json}`
recursively; agentId = relative path minus extension, frontmatter `name`
overrides; duplicate id ⇒ warn + overwrite.

- `.md`: `parseCustomAgentFile` (17221756) **requires front matter** (throws
  `"No front matter found"` — the file then lands in the loader's errors list);
  `prompt = body.trim()`. Vendor doc claim "system prompt as the body"
  CONFIRMED.
- `.json`: `prompt` may be a `file://` URI — `resolvePromptFileUri` (17228540)
  resolves it against the AGENT FILE's directory; absolute or `~` paths THROW
  (`"Absolute file:// URIs are not allowed in agent prompts"`); realpath must
  stay inside the workspace root (symlink escape rejected). Vendor doc's "may
  not resolve" understates a hard load-time rejection. md prompts are never
  file-resolved (`isJson && parsed2.prompt` guard).
- Parsed fields: `description, tools, excludedTools, prompt, model,
  effortLevel, includeMcpJson, includePowers, mcpServers, permissions,
  welcomeMessage, dispatchKind (sub-agent|custom-agent|spec), hooks, resources`
  (schemes `file://`, `skill://`, knowledge — 17209875 schema comment).
- User profiles get NO `supportsTemplating` and NO `presets` — both exist only
  on bundled/builtin definitions (`parseBundledAgent` 17987900 sets
  `supportsTemplating: true`; plan 19990110; autonomous conversions 17991393).
  So `{{workspaceRoot}}` / `{{kiroConfigDir}}` mustache vars
  (`buildPromptTemplateContext`, 4938162 region: also
  `semanticReviewEnabled, ftaEnabled, specPlanEnabled, specWorkflow,
  specSkipClarificationEnabled`) do NOT render in user-authored profile
  prompts.

**Replace, not append.** Root path: `systemPrompt: session.customAgent.prompt`
(20405032) — the builtin identity/base prompt is absent entirely. Selection is
by MODE: `switchMode` (20378500 region) — an unknown id falls back to `vibe`
and notifies `_kiro/customAgent/not_found`; a valid profile id snapshots
`{agentId, prompt: targetProfile.prompt, ...}` onto the session. Builtin mode
⇒ `customAgent = void 0` ⇒ builtin prompt path.

Edge: an empty md body gives `prompt: ""` — root msg0 then has NO identity
segment (composeSystemPrompt starts from `""`); the sub-agent dispatch path
falls back to `getBasePrompt` because `""` is falsy
(`customAgentDefinition.prompt || getBasePrompt(...)`, 18029100 region).

### 3.8 Sub-agent dispatch assembly (invoke_sub_agent, 18025491 region)

```
rawPromptTemplate  = presets?.[preset] ?? (definition.prompt || getBasePrompt(...))
systemPromptTemplate = definition.supportsTemplating && promptContext
                       ? renderDynamic(rawPromptTemplate, promptContext) : raw
baseSystemPrompt   = await processPromptWithContext(systemPromptTemplate, registry)
envSteering        = getStaticSteering(agentContext, agentMode)  // kiro-web only
systemPrompt       = baseSystemPrompt + envSteering
                   + "<progress_reporting>...(reportProgress every 4-5 turns)...</progress_reporting>"
                   + "<response_requirement>...(MUST call subagentResponse)...</response_requirement>"
```

`processPromptWithContext` (17176364) expands `#[[providerId:query]]`
references (regex `/#\[\[([^\]]+)\]\]/g`) via the context-provider registry —
this call site is the ONLY consumer besides the definition (2 hits total), so
`#[[file:...]]` works in dispatched sub-agent prompts but NOT in the root
session's system prompt (root file inclusion = profile `resources`).

The dispatch ctx then carries this `systemPrompt` plus the PARENT's
`steering`/`globalLearnings`/`repositories`/`knowledgeListing` into the child's
CustomAgent adapter, which composes them around it identically (so a child
msg0 = child prompt + progress/response contracts + parent's steering blocks +
machine id + attached steering docs).

**Inline agents** (18015635 / 18016512): `inlineAgent: {systemPrompt (min 1),
model?}` in the tool schema — a fully model-authored one-off system prompt.
`synthesizeInlineAgent` sets `tools: "*"`, no permissions (inherits parent
policy). Gated: `isSettingEnabled(settings, "inlineAgents")` where
`settings = clientMeta?.settings ?? {}` from initialize (19309009) — same
clientMeta mechanism as `settings.goal`. Off by default.

### 3.9 Segment order in the final msg0 (custom-agent root, the common case)

1. profile prompt body (or builtin base for vibe)
2. `<repositories>` (cloud repo names; local: absent)
3. `<learnings>` (cloud; local: absent) — or at `{learnings}` if authored
4. `<steering-files>` (globalSteering + static [web] + workflow steering +
   profile resources content; local non-workflow: usually absent)
5. `<knowledge-bases>` (knowledge capability only)
6. `<current_context>Machine ID: ...</current_context>` (custom) / model line +
   file tree + open files (chat)
7. attached steering documents (`<steering_content>` blocks: global steering
   files, workspace steering, AGENTS.md)
8. separator AI msg: "I will follow these instructions."

## 4. Extraction — the answer

### 4.1 Session artifact (WORKS, verified on disk)

The first-turn msg0 is persisted VERBATIM as the `session_start` row of
`~/.kiro/sessions/<wsHash>/sess_<id>/messages.jsonl` (persist site 17595255):
`payload = {type: "session_start", agentType, content, images?, documents?,
steeringDocuments?[{id, displayName, content, scope}], forcedRole, messageId}`
with a session-stable row id. Verified on this machine:
`sess_950b7f2d-...` has `payload.content` of 12440 chars beginning
"You are Kiro CLI, an agentic AI software engineer..." (`agentType: "vibe"`).

Recipe (no engine, no credits):

```bash
jq -r 'select(.payload.type=="session_start") | .payload.content' \
  ~/.kiro/sessions/*/sess_<id>/messages.jsonl
jq -c 'select(.payload.type=="session_start") | .payload.steeringDocuments' ...
```

Later steering additions (fileMatch docs): `steering_inclusion` rows
(`{type, documents, executionId, subExecutionId?}`, emit site 17585394). The
msg0-announcement action carries ids only.

`_kiro/session/export` (advertised extension method; handler
`handleExportSession` 20619038) zips `session.json` + `messages.jsonl` +
`sub-executions/*.jsonl` — the same rows, fetchable by an external ACP client
without filesystem access.

**Freeze semantics** (doc comment at 14520000 region): msg0 is computed on the
FIRST turn only; every later turn and every `session/load` replay reuses the
persisted artifact byte-for-byte ("recomputing them would drift the cache
prefix"). So the artifact is not a log of the prompt — it IS the prompt.

### 4.2 Debug flag (DOES NOT dump the prompt — bounded negative)

`KIRO_LOG_LEVEL` levels `error|warn|info|debug|trace` (884671, 19672044,
20722456; `KIRO_CHAT_LOG_FILE` redirects; channels kiro/mcp/powers). Searched:
`logger.{info,debug,trace}` payloads matching `prompt|msg0|steering` (3
spellings, case-insensitive); all 38 `systemPrompt*` occurrences windowed; all
5 `systemPrompt:` assignments read. Nearest misses, which double as positive
controls for the method: `[Steering] Found documents` logs IDS only (13835679);
`supervisorDebug` logs LENGTHS only and is gated on `KIRO_SUPERVISOR_DEBUG`
(17075526); `[SummarizationNode] Sending summarization prompt as new message`
logs no content (14118430). No log call emits the assembled system prompt at
any level.

### 4.3 From the bundle (static)

Builtin segments are plain template literals in
`src/execution/definitions/prompts.ts` (5042079–5072278) and the spec/plan/
autonomous prompt modules — extractable by grepping distinctive prose
("You are Kiro"), but date/model/machine/steering segments are runtime-bound;
the artifact route is authoritative for the EFFECTIVE prompt.

## 5. Activation drivers (per lever)

| Lever | Who can pull it |
| --- | --- |
| Builtin base prompt content | nobody (ships in bundle); varies by client id + clientMeta (external ACP client), date, sandbox env |
| Agent profile prompt (md body / json / file://) | user-typed (authoring); selection user-typed (TUI mode picker) or external-ACP-client (setSessionMode / config option) |
| Profile `resources` → steering block | user-typed (frontmatter authoring) |
| `{learnings}` placement | user-typed (profile authoring); content is cloud-fed |
| Steering files + AGENTS.md (attached docs) | user-typed (file authoring); fileMatch docs additionally model/tool-driven (open files) |
| `inclusion: auto` steering + skills | user-typed (authoring) + model-elected (disclose_context) |
| Workflow steering appends | workflow-step-driven (workflowId) / external-ACP-client (workflowsEnabled at _kiro/workflow/new) |
| globalSteering + learnings + repositories | cloud/remote MCP only — no local driver |
| Sub-agent prompt (named) | agent-system-prompt-driven + model-elected (model picks agent + preset); content user/bundle-authored |
| Inline agent systemPrompt | model-elected; gate external-ACP-client (clientMeta settings.inlineAgents) |
| progress/response contract blocks on sub-agents | nobody (unconditional on dispatch) |
| Hooks (SessionStart/UserPromptSubmit stdout) | hook-driven — but lands as CONTEXT messages, never in msg0 (corpus hooks records) |
| /context add + _kiro/session/context files | user-typed / external-ACP-client — live_context message, never msg0 |

NOT levers (bounded absences, method in 4.2 / §6): no CLI flag, no global
setting, no env var appends or replaces the system prompt; no hook trigger can
touch msg0; `KIRO_LOG_LEVEL` cannot dump it.

## 6. Fixture design

- **F16-X (extraction, runnable now, zero cost):** script over the existing
  store — assert exactly one `session_start` row per root `messages.jsonl`,
  `payload.content` non-empty, and for vibe sessions
  `payload.content startswith "You are Kiro CLI"`. Discriminator: a fixture
  session whose content lacks the identity string ⇒ assembly changed.
- **F16-O (override, SPEC — needs 1 model turn):** author
  `.kiro/agents/probe.md` with front matter + body containing a nonce
  (`F16NONCE`), a steering file `.kiro/steering/probe-steer.md` with a second
  nonce, `AGENTS.md` with a third; switch mode to `probe`; one-word prompt on
  the cheapest model. Pass: `session_start.content` contains F16NONCE and does
  NOT contain "You are Kiro CLI" (replace not append);
  `steeringDocuments[]` contains both steering nonces with correct scopes.
- **F16-F (freeze/mode-switch, SPEC — 2 turns):** turn 1 under `vibe`, switch
  mode to `probe`, turn 2; diff msg0-bearing rows. Expected per code (replay
  branch): msg0 unchanged, new profile prompt absent — confirms the
  switch-takes-effect-next-session hypothesis (flagged claim).
- **F16-I (inline gate, ACP-direct, no model):** initialize with
  `clientMeta.settings.inlineAgents: true/false`; fetch the invoke_sub_agent
  tool schema/description via a session listing surface; discriminator:
  `inlineAgent` property present in schema only when enabled
  (`buildInvokeSchema`, 18018498). If no schema surface is reachable without a
  turn, downgrade to SPEC.

## 7. Cross-interactions

- **msg0 freeze vs edits:** profile/steering/AGENTS.md edits do NOT reach an
  existing session (replay reuses the artifact); only new sessions see them.
  Session/load of an unknown id hydrates fresh (settled) — that fresh session
  WILL recompute msg0 on its first turn.
- **Mode switch mid-session** (inferred, F16-F): custom/chat adapters have no
  `stripStaleSystemPromptMessages` — only PlanExecute strips and replaces msg0.
  A mid-session agent switch likely keeps the OLD system prompt.
- **Steering supervisor:** `runSupervisorModelCall` (17077412) re-reads msg0,
  re-wraps steering as explicitly untrusted DATA and neutralizes embedded
  `<steering-files>` tags with a zero-width space — steering text is
  double-consumed (agent msg0 + verifier prompt).
- **Trust gate:** untrusted workspace silently drops workspace steering AND
  AGENTS.md from msg0 (global-scope docs survive) — compare with the corpus
  loader asymmetries (workspace profiles trust-gated).
- **Compaction:** summarization tombstones truncate history, not the
  session_start row; the C-9 parent-truncation bug does not remove msg0.
- **js-yaml CORE:** profile front matter `yes/no` are strings (corpus) —
  affects any boolean-looking frontmatter fields around the prompt.
- **Sub-agent contract blocks:** the unconditional
  `<progress_reporting>`/`<response_requirement>` appends mean a profile used
  BOTH as root agent and as sub-agent gets a different effective prompt in each
  role; `dispatchKind` selects the adapter but not these appends.
- **Vendor doc corrections:** (1) "file prompt paths may not resolve" → they
  throw at load and the profile fails; (2) resources `skill://` scheme exists
  in the schema (17209875) — vendor example is consistent; (3) "system prompt
  as the body" confirmed, but the doc does not say it REPLACES the builtin
  identity — it does, wholesale.
