> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# F22 — Applied pattern: context-isolating cheap subagents

Motivating case: an MCP tool (gitlab-mcp) echoes its input back in the tool
result, so posting a large feedback batch pays for the payload twice in the
parent context, forever. Question: can Kiro v3 express "run this call inside a
disposable child on a cheap model, keep only a one-line receipt"?

Short answer: **yes, fully expressible — but only through an external ACP
client at 2.15.1.** The per-dispatch model/effort knob (`inlineAgent`) is gated
on an initialize-time setting the stock TUI never sends. Under the stock TUI
the same effect needs a named agent profile carrying `model` + `effortLevel`
frontmatter, dispatched as an `orchestrate_subagent` stage.

## 1. The question (testable form)

1. Does the parent model's transcript receive the child's tool results, or
   only its final message? What exactly flows back, with what size bound?
2. Can model and thinking/effort be pinned per dispatch? Enumerate the full
   dispatch-parameter schema. (Per-dispatch slice of F8 only.)
3. What fixed overhead does one dispatch cost (system prompt, steering,
   hooks, minimum model invocations), and where does the cost land?
4. Rule of thumb: at what echo size does the pattern pay?

## 2. What is already known (not re-derived)

- Corpus `concurrency-and-nesting.md` R-nesting-1/2: depth cap 5 (`>=` before
  increment), depth rejection is a returned tool message, not a throw; child
  depth passed explicitly at the single construction site; concurrency 5
  per-execution (R-concurrency-1/2), sixth dispatch queues.
- Corpus `hooks-dispatch-gate.md` (offsets 18030796, 17712396): the dispatch
  ctx hard-codes `previousMessages: void 0` — a dispatched child always takes
  the first-turn branch; once un-gated it fires SessionStart AND
  UserPromptSubmit; hook nodes short-circuit on `execution.skipHooks` set by
  the dispatch adapter.
- C-9: a child crossing its compaction threshold truncates the PARENT stored
  history — workers must stay short.
- C-10: the default subagent role lacks the delegation tool (no recursion out
  of the box); the depth constant is an engine limit, not the reason.
- F10: pool assembly in `createACPWorkspaceConnection` getTools (~19303469);
  `subagentOrchestration`/`inlineAgents` gated via initialize-time settings
  `{enabled:true}`; invoke/orchestrate consult approval.
- F19: sub-executions/<id>.jsonl carries NO usage records; per-dispatch effort
  is not in the session store anywhere; per-dispatch model only via
  `assistant.reasoningModelId` on reasoning-bearing rows; tool-outputs/
  offload for >=30k-char results of execute_bash/get_process_output/
  web_fetch/remote_web_search/mcp_*.

## 3. The interface, fully enumerated

### 3.1 `invoke_sub_agent` input schema (src/tools/invoke-subagent.ts, section marker 18013526)

`BASE_SCHEMA_SHAPE` (~18016900):

| Field          | Type                                                   | Req | Notes |
| -------------- | ------------------------------------------------------ | --- | ----- |
| `name`         | string min 1                                           | yes | agent id to invoke; display label only when `inlineAgent` set |
| `prompt`       | string                                                 | yes | the child's user prompt |
| `explanation`  | string                                                 | yes | 1–2 sentences why; UI/telemetry only |
| `preset`       | string nullish                                         | no  | selects `customAgentDefinition.presets[preset]` as the child SYSTEM prompt |
| `contextFiles` | array of `{path, startLine?, endLine?}` (abs path, 1-indexed inclusive) | no | read into CHILD context before execution |
| `inlineAgent`  | `INLINE_AGENT_SCHEMA` nullish                          | no  | **field exists only when the `inlineAgents` setting is enabled**; otherwise stripped by the Zod object |

Handler additionally destructures `executionId` (pre-generated child id) —
present in the handler but NOT in the model-facing schema; used by
`orchestrate_subagent` when it drives the same handler internally.

`INLINE_AGENT_SCHEMA` (~18015100):

| Field          | Type                  | Req | Semantics |
| -------------- | --------------------- | --- | --------- |
| `systemPrompt` | string min 1          | yes | the entire child system prompt (plus the fixed blocks in 3.4) |
| `model`        | string trim min 1 nullish | no | model id; shorthand auto-corrected via `resolveModelId` (unique case-insensitive substring, or same-stem highest version); unknown/ambiguous → tool error listing all ids; omitted → parent's model |
| `effort`       | string trim min 1 nullish | no | clamped to the model's advertised `effortLevels`; unsupported/omitted → `belowMax` fallback = second-highest level; ignored for models without effort |

`synthesizeInlineAgent` (~18015800): inline agents become
`{id: label, tools: "*", model: spec.model}` — **no `permissions`, no
`dispatchKind`** → they inherit the parent's exact tool surface and policy
engine (the handler skips `withToolPolicy` when `isInlineAgent`), and they
select the default sub-agent adapter (hooks skipped, see 3.5).

Tool description (`generateToolDescription`) lists every registered agent id +
description, and appends `describeAvailableModelIds()` (the full model-id
list, 5039921) only when inline agents are enabled.

### 3.2 Model/effort resolution per dispatch (~18032500)

```
requestedEffort   = inlineSpec?.effort ?? customAgentDefinition.effortLevel ?? undefined
effectiveOverride = correctedInlineModel ?? customAgentDefinition.model
chosenModelId     = effectiveOverride ?? parent.model.modelId
executionModel    = (effectiveOverride || requestedEffort)
                    ? {...parent.model, modelId: chosenModelId,
                       ...resolveEffort(chosenModelId, requestedEffort,
                                        isInlineAgent ? "belowMax" : "default")}
                    : parent.model            // untouched inheritance
```

`resolveEffort` (5037867): `modelId` empty or `"auto"` → no effort fields; a
model without `effortSchemaPath`/`effortLevels`/`defaultEffortLevel` → none;
requested level honored only if in the model's `effortLevels`, else fallback =
second-highest level (`belowMax`, inline) or `defaultEffortLevel` (`default`,
named agents). Precedence facts for F8's per-dispatch slice:

- Inline `effort` beats profile `effortLevel` beats inherit.
- **Changing model resets effort**: a named agent with `model:` but no
  `effortLevel:` gets the TARGET model's default effort, not the parent's
  current effort (the spread replaces both fields together).
- Inline `model` is validated + auto-corrected; a NAMED profile's `model`
  string is used RAW at this site (`customAgentDefinition.model`, no
  `resolveModelId` call) — an invalid profile model goes to the wire as-is.
- With the model catalog EMPTY, `resolveModelId` returns ok for anything
  (`ids.length === 0 ||` short-circuit) — no validation.

### 3.3 What flows back to the parent (the whole answer to Q1)

Adapter fold (`extractSubagentResponse`, ~17713400): scan the child transcript
backwards for the last bot message containing a `subagent_response` toolUse;
return its `args.response` (string) + `args.files`; if none, fall back to the
last bot message's concatenated TEXT entries; else `""`.

`subagent_response` tool (CONFIG13, ~18080600), the child-side contract:
`{response: string (required, may be ""), files?: [{path, startLine?, endLine?}]}`.
The custom-agent graph router (~14513500) short-circuits on a pending
`subagent_response` tool response straight to the AgentStop path — **no
further model invocation after it**.

Into the parent transcript goes, and ONLY this:

1. ONE tool-response message carrying the `response` string
   (`withSyncToolMessage`, def 17118209). **Size bound: NONE.**
   `processToolOutput` (12844089) offloads only
   `HANDLED_TOOLS = [execute_bash, get_process_output, web_fetch, remote_web_search]`
   + the `mcp_` prefix, threshold 30,000 chars, gated on the
   `largeToolOutputHandler` feature flag; `invoke_sub_agent` is not
   allowlisted, so a verbose child pastes its whole response into the parent.
2. Per `files[]` entry: a synthetic `read_file` toolUse/response pair whose
   response is the FULL file (or line-range) content, read fresh by the
   PARENT (~18040300). Careless `files` use re-imports what you isolated.
3. Failure paths return `response: ""` plus a short error tool message
   (depth, rejection, fault, cancel — all non-thrown).

Child say/reasoning/tool events are forwarded to the CLIENT UI (with
`subExecutionId`) unless the profile sets `hideExecution` (builtin-definition
field, not in the user profile schema) — display only, never parent context.
Intermediate child tool results (the echo!) live solely in the child context
and, on disk, in `sub-executions/<id>.jsonl`.

### 3.4 Child construction — the fixed overhead (Q3)

Per dispatch the handler rebuilds the child from scratch (~18027700–18031000):

- **System prompt** = `preset ?? profile.prompt ?? getBasePrompt(...)`, then
  `processPromptWithContext` (context-provider resolution), then a rendered
  static-steering block, then two hard-coded blocks: `<progress_reporting>`
  (reportProgress every 4–5 turns, ~120 words) and `<response_requirement>`
  (must call subagentResponse, ~90 words). Inline agents: `systemPrompt` is
  the profile prompt — total system prompt is user-controlled + the fixed
  blocks + steering.
- **Steering re-send, not re-load**: parent's `steering`, `repositories`,
  `knowledgeListing` are passed by reference into the child definition
  (deliberate, "Phase 3" comment ~17711600) — no disk I/O, but the bytes are
  re-sent to the model in every child request.
- **contextFiles** are read via the read-file pipeline with
  `skipTruncation: true` (formatter cap bypassed) into synthetic
  toolUse/response pairs in the CHILD context; each read passes
  `acpToolApproval` for `read_file` individually.
- **Hooks**: adapter-dependent (3.5). When they fire, both SessionStart and
  UserPromptSubmit fire (first-turn branch, settled), plus AgentStop at end.
- **Minimum model invocations: 1** — a child whose first response is the
  `subagent_response` call terminates without another invocation (router
  short-circuit). No title generation is wired for dispatched children (no
  `titlePrompt` in `buildDispatchedCustomAgentDefinition`) and recap is
  depth-gated off (corpus R-nesting-3).
- **Approval**: one `acpToolApproval` for the dispatch itself, with
  `toolId: invoke_sub_agent`, `path: <agent name>` (policy can allow-list
  specific agent names), title `Sub-agent: <name>`.

### 3.5 Dispatch adapters — hooks and history per kind (~17716500)

`selectAdapter(definition)`: `definition.dispatchKind ?? "sub-agent"`.

| dispatchKind     | Who gets it | previousMessages | skipHooks |
| ---------------- | ----------- | ---------------- | --------- |
| `"sub-agent"`    | DEFAULT: all 7 builtin subagents (`context-gatherer`, `general-task-execution`, `custom-agent-creator`, `spec-task-execution`, `feature-design-first-workflow`, `feature-requirements-first-workflow`, `bugfix-workflow`), inline agents, and any user profile that does not set the field | excluded | **true — child fires NO hooks** |
| `"custom-agent"` | hard-coded on bundled shared agents (`semantic_reviewer`, `functional_task_alignment`, `Explore`, 17988728) and autonomous profiles (17991423); user profiles may opt in via frontmatter | included (but ctx value is `void 0` anyway, settled) | unset — SessionStart + UserPromptSubmit + AgentStop fire in the child |
| `"spec"`         | spec pipeline | n/a (SpecAdapter builds spec input) | unset |

`dispatchKind` is a USER-AUTHORABLE profile field:
`enum(["sub-agent", "custom-agent", "spec"]).optional()` in both the markdown
frontmatter schema (17210272) and JSON agent schema (17212889), passed through
both loaders (17223221 md, 17224771 json). The profile schema also carries
`model` (string, "model override") and `effortLevel` (string, plain — no enum)
— the named-agent halves of the per-dispatch knob. `responseNag` resolves as
`profile.responseNag ?? profile.specOnly`; inline agents never nag (empty
response accepted).

### 3.6 `orchestrate_subagent` — the stock-TUI reality

Chat-surface registration (~19308900): `subagentOrchestration` enabled →
`orchestrate_subagent` registered INSTEAD of `invoke_sub_agent` (mutually
exclusive at the chat surface; spec/sub-agent tool pools keep
`invoke_sub_agent` regardless). Input schema (buildSchema, 18054203):

- `task`: string.
- `stages[]` min 1: `{name, role, prompt_template ({task} substitution),
  depends_on?: string[]}` + `inlineAgent?` (same `INLINE_AGENT_SCHEMA`,
  required iff `role === "inline"`, only when inline agents enabled; stage
  inline models validated up front via `resolveModelId`).
- `repeat?`: `{maxIterations int 1–20, stopCondition: {containsText: string},
  onMaxIterations?: "continue"|"abort" nullish}`.

Stage execution (`executeStage`, 18071428) drives the SAME `InvokeSubAgent`
handler with `contextFiles: void 0` (stages cannot pass context files) and
`preset: void 0`. Dependency outputs are inlined into the stage prompt as
markdown. **Fold-back**: `formatResults` concatenates EVERY stage's full
response into one tool message on the parent — again unbounded.
`result.state` from each stage is DISCARDED — a stage's `files[]` never
reaches the parent transcript. **Trap**: stage success is
`response !== ""` — a child legally returning empty response + files is
recorded as a FAILED stage.

### 3.7 Who can actually enable what (measured, stock client)

Client-side settings assembly in the real chat binary
`/nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-chat-wrapped`
(555,372,744 bytes; embedded client JS at offset ~396741415; positive controls
`clientMeta`=2, `session/new`=4, `invoke_sub_agent`=3, `terminal/create`=2):

- Defaults sent: `codeIntelligence`, `knowledge`, `thinking` true;
  `subagentOrchestration` true unless env
  `KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION=1`. **No user config key maps to
  `subagentOrchestration`** — the stock TUI chat surface always has
  `orchestrate_subagent`, never `invoke_sub_agent`.
- `inlineAgents` / `inline_agents` / `inlineAgent`: **0 hits in the client**
  → the stock TUI cannot enable per-dispatch inline model/effort at 2.15.1.
  External-ACP-client-only (initialize `settings.inlineAgents = {enabled:true}`,
  consumed at 19309031).
- Config keys the client DOES map: `chat.enableThinking`, `chat.enableKnowledge`,
  `chat.enableCodeIntelligence`, `chat.enableTodoList`, `chat.enableCheckpoint`,
  `chat.enableTangentMode`, `chat.disableAutoCompaction`,
  `chat.enableSubagent`→`_subagent`, `chat.enableDelegate`→`_delegate`
  (+ conditional infra-safety, c2s, toolSearch, compaction, knowledge tuning).
  `_subagent`/`_delegate` are schema-documented in KAS (~873978) but no
  `isSettingEnabled` consumer was found for either — apparent C-11
  (documented-but-unconsumed) at this surface; the subagent registration gate
  checks only `subagentOrchestration` + registry presence.

### 3.8 Where the cost lands (usage/credits)

Per model response the child emits `AgentExecutionSummarizeUsage` (14093846).
The dispatch controller's skip set (12 entries, ~18018400) does NOT include
it, so it forwards to the parent sink with `executionId` REWRITTEN to the
parent's. The session adapter pushes every entry into one flat
`usageSummaryEntries` list, streams it to the client as session_info_update,
and `aggregateUsageSummary` (19525213) merges by unit into the PARENT turn's
`usage_summary` row (19478099). Consequences:

- Child credits are billed and locally visible — but only as an
  undifferentiated part of the parent turn's total. No per-child usage row
  exists anywhere on disk (F19).
- **New observability (answers the F8 gate for this slice)**: the handler
  logs `invoke_subagent.starting {subagentId, modelId, modelOverride,
  effortLevel, effortOverride}` (~18032886) with the RESOLVED model AND
  effort. KAS file logs live under `~/.kiro/logs/<timestamped-dir>/`
  (FileLogger, 19674566; channels kiro/mcp/powers). Per-dispatch resolved
  values are therefore recoverable from disk without wire capture —
  effort-precedence empirics (F8) can grep the log instead of forcing
  reasoning output.

## 4. Activation drivers

| Lever | Drivers |
| ----- | ------- |
| `invoke_sub_agent` dispatch | model-elected (tool call); reachable only if registered: external-ACP-client (settings) decides which delegation tool the chat surface has; agent-system-prompt and hook-injected text can instruct the model to use it; workflow-step-driven indirectly (a workflow step's agent may carry the tool) |
| `orchestrate_subagent` pipeline | model-elected; registered by default under the stock TUI (client-sent setting); same indirect prompt channels |
| `inlineAgent` (per-dispatch model+effort+system prompt) | external-ACP-client ONLY at 2.15.1 (initialize setting), then model-elected. NOT user-typed, not stock-TUI reachable |
| Named-agent `model`/`effortLevel`/`dispatchKind` pins | user-typed (authoring the profile file), then model-elected at dispatch; home profiles load unconditionally, workspace profiles trust-gated (settled) |
| `contextFiles` payload injection | model-elected, `invoke_sub_agent` only (orchestrate stages hard-code void 0) |
| `preset` | model-elected; requires the profile to define `presets` |
| Child hook firing | profile-author-driven (`dispatchKind: custom-agent`); never for inline/builtin/default profiles |
| Resolved model/effort observability | passive (KAS log file); operator-read |

## 5. Fixture design

All live-model items are SPECS (operator-run), per mission rules. The
no-model observables are runnable now.

**F22-a (no model): schema surface flip.** External ACP client, initialize
with and without `settings.inlineAgents={enabled:true}` and with
`subagentOrchestration` absent/false vs true; list session tools. PASS:
inline case exposes `inlineAgent` in the schema and appends the model-id list
to the tool description; orchestration flag swaps which of the two tools is
registered. Discriminates the gate wiring without any prompt.

**F22-b (SPEC, one cheap turn): fold-back exactness.** Parent prompt:
"dispatch context-gatherer with prompt X". After the turn, diff: parent
messages.jsonl must contain exactly one invoke tool-response message whose
text equals the child's `subagent_response.response` (plus read_file pairs
iff files were returned); child sub-executions/<id>.jsonl contains the tool
echoes; parent transcript contains none of them. PASS = byte-equality of the
folded response, zero child tool results in parent rows.

**F22-c (SPEC): per-dispatch pin observability.** Inline dispatch with
`model: <cheap-id>, effort: low`; then a named-profile dispatch
(`model:` set, no `effortLevel`). Observable:
`grep invoke_subagent.starting ~/.kiro/logs/*/*` shows
`modelId=<cheap-id>, effortLevel=low, effortOverride=true` for the first and
`effortLevel=<target-model-default>, effortOverride=false` for the second —
falsifies/confirms the model-reset-effort rule (3.2) from disk alone.

**F22-d (SPEC): credits attribution.** Single-dispatch turn; compare the
parent turn's `usage_summary.promptTurnSummaries[].usage` against an
otherwise-identical turn without the dispatch. The delta is the child's
credit cost (elapsedTime sanity-checks it). No per-child row will appear —
that absence is the expected result, not a failure.

**F22-e (SPEC): echo-isolation end-to-end (the motivating case).** Parent
writes an N-char feedback file; dispatches a minimal named profile
(`tools: [mcp_gitlab_...]`, `model: <cheap>`, 3-line prompt) with
`contextFiles: [that file]` and instruction "post it, reply DONE <count>".
PASS: parent context growth ≈ invoke args + "DONE n"; the 2×N payload+echo
appears only in sub-executions/<id>.jsonl.

## 6. Cross-interactions

- **Mutual exclusion**: `subagentOrchestration` removes `invoke_sub_agent`
  from the chat surface — an external client wanting `contextFiles` (the
  cheapest payload channel) must NOT enable orchestration, or must accept
  stages-without-contextFiles.
- **Inline agents inherit the parent's FULL tool surface** (`tools: "*"`, no
  policy filter) — every child request re-sends every tool schema at the
  cheap model's rate, and the child can do anything the parent can (approval
  still applies per tool). A named minimal-tools profile is both cheaper per
  request and safer.
- **C-9 hazard**: stuffing a huge payload into the child can cross the
  child's compaction threshold and truncate the PARENT stored history. Keep
  the payload well under the child's window; this is the pattern's hard
  ceiling.
- **`files` fold-back undoes isolation**: each returned file is read in full
  into the parent transcript. For the receipt pattern, instruct the child to
  return NO files.
- **Empty response = failure** in orchestrate stages (3.6) and reads as
  "no work found" from invoke error paths (corpus R-nesting-1) — always
  return a non-empty receipt string.
- **No response size bound** (3.3): a rambling child pastes its ramble into
  the parent. The system prompt must pin the output contract ("reply with
  one line").
- **mcp_ echo >=30k chars is ALREADY offloaded natively** (head500+tail500+
  file pointer) when `largeToolOutputHandler` is on — the subagent pattern's
  savings window is the sub-30k echo, or environments with the flag off.
  Note the offload rewrites only the tool RESULT message; the tool-call ARGS
  (your outbound batch) are never offloaded in either design.
- **Hooks**: a `dispatchKind: custom-agent` cheap worker pays SessionStart +
  UserPromptSubmit + AgentStop hook executions per dispatch (and their
  stdout injections land in the CHILD context — sized into the cheap
  window). Default kind skips all of it.
- **Depth/concurrency budget**: the pattern costs one of 5 nesting levels;
  5 concurrent dispatches per execution, sixth queues (settled).
- **Approval friction**: unattended use needs an allow rule for
  `invoke_sub_agent` (policy resource = agent name) plus `read_file` for
  contextFiles — or trust-all. F18 lists the subagent tools as
  approval-consulting.
- **F8 remainder**: session-level `modelId`/`effortLevel` (session.json,
  F19) and workflow-node-level `effortLevel` (`workflow.effortLevel`
  17255348, `node.effortLevel` 17396031) are the other lattice levels — out
  of scope here; this doc settles only the dispatch level and its
  observability.

## 7. Rule of thumb (break-even)

Definitions: E = payload/echo size (chars), R = receipt size (small), T =
parent model invocations remaining in the session after the call, S = child
fixed input (system prompt + steering + tool schemas + fixed blocks), rho =
cheap-model cost per input token relative to the parent model's. Tokens ≈
chars/4 throughout.

Parent-side context delta per design (the payload composition itself is paid
identically in both and cancels):

- Direct call: +E (tool args) +E (echo) persist → every later invocation
  re-sends 2E.
- Subagent w/ prompt-embedded payload: +E (invoke args) +R persist.
  Saving ≈ T × E − child cost.
- Subagent w/ contextFiles (payload already on disk): +≈0 +R persist.
  Saving ≈ T × 2E − child cost.

Child cost ≈ rho × (S + E + R). Break-even (prompt-embedded variant):

```
T × E  >  rho × (S + E)      =>      E  >  rho × S / (T − rho)
```

With illustrative values rho = 0.1, S = 8,000 tokens, T = 10: E > ~80 tokens
— i.e. the pattern pays almost immediately; the REAL constraints are the
fixed frictions (approval prompt, 1 cheap invocation latency, response
discipline), not token arithmetic. With T = 1 (session about to end) it
never pays. Above E ≈ 30k chars the native mcp_ offload already caps the
echo at ~1.2k chars and the savings collapse to (E − 1.2k chars) of ARGS
only — use contextFiles or don't bother.

Unverifiable terms — fixture specs, not facts: (a) the token→credit
function and any input-caching discount on re-sent context (backend-opaque;
F22-d measures the aggregate); (b) rho for Kiro's model catalog (credit
metering per model unpublished); (c) S for a given setup (measurable from a
child request only via wire/log capture); (d) whether
`largeToolOutputHandler` is enabled in a given deployment (observable:
tool-outputs/ files appearing; F19 left its live status open).

## Bounded negatives / method notes

- `inlineAgents` absent from the stock client: 3 spellings, grep -ac against
  the 555 MB chat binary, positive controls listed in 3.7. First attempts
  against `bin/kiro-cli` and `.kiro-cli-wrapped_` FAILED positive controls
  (they are wrapper scripts / the launcher, not the chat client) — do not
  grep those.
- `_subagent`/`_delegate` unconsumed: based on zero `isSettingEnabled` hits
  for either key plus inspection of the getTools gate; the 20/30 raw string
  hits sampled were operationId templates and section markers. Not an
  exhaustive trace of every hit.
- Counts and their denominators: 12 skippedEventTypes entries (full list
  read); HANDLED_TOOLS = 4 entries + `mcp_` prefix (list read to its
  closing bracket); 7 builtinSubagents; 3 dispatch kinds (enum read).
