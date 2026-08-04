# F18 — Approval prompt shapes and their exact trigger conditions

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

Byte offsets below are into the KAS bundle (`$B` = the pinned acp-server.js)
unless marked `chat:` (= `.kiro-cli-chat-wrapped`, 555372744 bytes, from the
kiro-cli 2.15.1 nix store path). Offsets are for THIS bundle only; anchor on
the quoted identifiers, not the numbers.

## 1. The question

Enumerate every approval/permission prompt the v3 stack can surface, the exact
condition selecting each variant, the options each offers, what "always"
options scope to, and where grants persist. Settled means: for any tool call /
hook / workflow step one can predict from config alone whether a prompt fires,
which shape it takes, and what answering each option changes on disk.

## 2. What was already known (corpus + docs)

- `records/hooks-io-contract.md` L1086–1235: PreToolUse hook
  `permissionDecision:"ask"` calls an injected permission handler; unwired →
  deny. Stop-hook `confirm` returns the selected option id as feedback (L178).
- `records/hooks-dispatch-gate.md` L445: the TUI's `prepareKasPermissionRequest`
  with `isSubagentSpawn` / `metadataSubtaskId` (chat binary, embedded-JS region
  ~396 MB).
- `records/limits-and-engine.md` L1545: v2 Rust engine strings
  `needs_approval`, `trust_options_map`, `WaitingForApproval` — v2-only.
- `evidence/machine-state.md` L696–785: upstream #10168/#3582 — v2 sub-agent
  ask stalls. v2 machinery is not further covered here.
- Vendor `private/kiro-v3-docs.md` L171–260 "Permissions" — mostly accurate;
  contradictions listed in §6.

## 3. The interface, fully enumerated

### 3.1 Wire method and options schema

One ACP client method carries every prompt: `session/request_permission`
(agent→client request; SDK `CLIENT_METHODS` at 445977). Schema (SDK zod,
469011): `options: [{ optionId: string, name: string, kind, _meta? }]`, `kind ∈
{allow_once, allow_always, reject_once, reject_always}`. Response:
`{ outcome: {outcome: "selected", optionId} | {outcome: "cancelled"}, _meta? }`.
The TUI (chat: `handlePermissionRequest`, 396726953) renders whatever arrives;
labels come from the wire (its legacy label map is keyed by v2 option ids
`allow_once`/… which never match KAS ids `accept`/…, so the KAS `name` strings
always show).

### 3.2 Variant A — tool policy ask (THE 2/3/4-option prompt)

Producer: `baseAcpToolApproval` (src/acp/acp-workspace-connection.ts, 19298225)
invoked from the policy-eval `onAsk` loop
(src/acp/acp-tool-approval.ts, `MAX_ITERATIONS = 20` at 18677285).

Flow per tool call: `evaluateMostRestrictive` → effect `allow` → silent accept;
`deny` → silent reject with `policyDenial`; `ask` → serialized prompt loop.

Options from `buildPermissionOptions(consent)` (src/acp/permission-options.ts,
18686350), in this order:

| # | optionId        | name         | kind          | present when                       |
| - | --------------- | ------------ | ------------- | ---------------------------------- |
| 1 | `accept`        | Allow        | allow_once    | always                             |
| 2 | `always-accept` | Always allow | allow_always  | consent && askType !== "explicit"  |
| 3 | `reject`        | Deny         | reject_once   | always                             |
| 4 | `always-reject` | Always deny  | reject_always | consent (any askType)              |

`consent` is built (18683347) only when a capability resolves:
`matchedRule.capability ?? getToolCapability(toolId, toolTags)`. So:

- **2 options** (Allow/Deny): capability unresolvable — toolId not in
  `TOOL_CAPABILITY_MAP` (4966294) and no tag in `TOOL_TAG_CAPABILITY_MAP`
  (`@mcp`→mcp, `@powers`→power, `@subagent`→subagent, `context`→context).
- **3 options** (no "Always allow"): `askType: "explicit"` — a rule with
  `effect: ask` matched (`isExplicitAsk`). Explicit ask is deliberately
  un-allowlistable ("the ask rule is intentional").
- **4 options**: `askType: "implicit"` — no rule matched (default-ask) with a
  resolvable capability.

Request `_meta.kiro`: `toolId`, `command?` (shell), `agentManagesTrust?`
(MCP/remote wrappers set true, 18826302), `disclosedContext?`, `consent?`
`{capability, resource?, askType, triggeringResource?, workspaceRoot?,` and for
explicit asks `matchedRule, scope, source}`, `consentRound` (1-based loop
iteration). Prompt `title` = `ctx.command ?? ctx.title ?? "@server/tool" (mcp)
?? display title`.

Response handling (`resolvePermissionOutcome`, 18686350):

- `_meta.kiro.editedCommand` + SHELL tag + non-empty + differs → decision
  `"edit"` (command replaced; `execute_bash` consumes it, records
  `user-edited-command`). The 2.15.1 TUI never sends it (0 hits in chat
  binary) — its Tab/"Modify request" path sends reject + feedback text instead;
  `editedCommand` is reachable only from other ACP clients (IDE).
- `allow_once`/`reject_once` → accept / reject, nothing persisted.
- `allow_always`/`reject_always` → build `consentToPersist = {effect,
  scope: _meta.kiro.consent.scope || "session", resource?, capability,
  workspaceRoot?}`. Explicit-ask `allow_always` is never persisted.

Persistence (`PolicySession.persistConsent`, 20140793):

| scope        | target                                                | notes                          |
| ------------ | ----------------------------------------------------- | ------------------------------ |
| `invocation` | nothing                                               | valid no-op                    |
| `session`    | in-memory `sessionRules`                              | dies with the session          |
| `user`       | `~/.kiro/settings/permissions.yaml`                   | via `addUserRule`              |
| `workspace`  | `~/.kiro/workspace-roots/<hash>/permissions.yaml`     | per-user store, NOT in repo    |

Persisted rule = `{capability, effect, match: [resource]}` — i.e. "always"
scopes to **capability × resource pattern**, at the chosen rule scope; never
"this turn". Guards: workspace scope requires the resource inside a matching
workspace root and fs-only capability; failures surface as `_kiro/policy/error`
notifications; success emits `_kiro/policy/changed` and rebuilds the engine.
The loop re-evaluates after every persist (persistence-success is the signal),
up to 20 rounds, then rejects with "Permission flow exceeded 20 approval
rounds…". A multi-resource call (paths array) prompts per most-restrictive
result; one shell command can traverse several rounds (compound commands,
`triggeringResource` per round).

Serialization: `createConsentSerializer` (18672381) — ONE ask at a time per
workspace connection (Sema(1)); after acquiring the mutex the policy is
re-evaluated, so an "Always allow" answered while queued silently clears
queued asks agent-side. Mutex wait times out at 180 s, after which the ask
proceeds unserialized. Errors in `requestPermission` → reject (fail-closed).

### 3.3 Variant B — hook runCommand approval (2 options)

`requestHookCommandApproval` (src/acp/acp-hook-approval.ts, 19316984): options
`accept`/Allow/allow_once, `reject`/Deny/reject_once; title = the raw hook
command. Fires from `executeRunCommandHook` when the hook record's `approved`
flag is false — the flag arrives from the CLIENT via `_kiro/hooks/extractHooks`
(hooks execute client-side via `_kiro/hooks/executeHook`). The
`isCommandAccepted` short-circuit consults a `CommandApprovalProvider` whose
default returns empty lists and which is never reassigned in the bundle
(`setCommandApprovalProvider`: 0 hits) — dead short-circuit at 2.15.1. No
"always" variant; no persistence.

### 3.4 Variant C — PreToolUse hook "ask" decision (2 options)

`requestAskHookPermission` (src/acp/acp-ask-hook-permission.ts, 19548225):
Allow/Deny (`allow_once`/`reject_once`); title = hook's
`permissionDecisionReason` collapsed to ≤200 chars, fallback "Hook permission
required". Wired as the injected permission handler the corpus record left
open: in ACP mode the handler EXISTS (20502490), so `permissionDecision:"ask"`
prompts instead of auto-denying. Deny/cancel/error → tool blocked. Wrapped in
`tool_call` session updates carrying `_meta.kiro.hookAsk {kind:"pre-tool-use",
toolName, reason, decision}`. No persistence.

### 3.5 Variant D — Stop-hook confirm (N options, hook-defined)

`requestHookConfirmChoice` (same file): options map 1:1 from the hook's
`options: [{id, label, allow}]` → `{optionId: id, name: label, kind: allow ?
allow_once : reject_once}`. Selected id returns to the hook as structured
feedback (corpus hooks-io-contract L178). `_meta.kiro.hookConfirm
{kind:"stop", hookName, question, decision}`. No persistence.

### 3.6 Variant E — infrastructure-safety override (2 options, Deny-first)

`requestSafetyOverridePermission` (src/acp/acp-safety-override-permission.ts,
19553120): option ORDER reversed by design — `reject`/"Keep blocked"/
reject_once first, `accept`/"Allow anyway"/allow_once second. Title = block
reason, fallback "Infrastructure safety block". Trigger: the infra-safety gate
in ENFORCE mode returns BLOCKED (20578184). Enablement =
client capability `infrastructureSafety` && feature flag `infraSafetyEnforce`
(monitor-only `infraSafetyMonitor` never prompts). Fails closed.
`_meta.kiro.safetyOverride {kind:"infra-safety", toolName, reason,
blockedProperties, decision}`. No persistence.

### 3.7 Variant F — turn approval / "Review changes" (2 options, FAIL-OPEN)

`requestTurnApproval` (src/acp/turn-approval-request.ts, 19555644): title
"Review changes"; options `accept`/"Accept changes"/allow_once,
`reject`/"Reject changes"/reject_once. Request `_meta.kiro = {type:
"turn_approval", executionId, files: [...]}`; response may carry
`_meta.kiro.fileDecisions` (per-actionId boolean map) for per-file
accept/reject — accepted pending changes are applied, the rest reverted.
Wired as `executionLogger.awaitApproval` at session creation (20489288);
consumed from the pending-file-actions flow (13911994). **Unique property:
if `requestPermission` throws, it resolves approved (logged
`turnApproval.requestPermission.failOpen`)** — every other variant fails
closed. Pending/resolved states are persisted to the session store as
`pending_interaction` / `interaction_resolved` messages so the prompt
survives close/reopen.

### 3.8 Variant G — user_input / analyze_requirements bridge (N options)

When the model elects the `user_input` tool (or `analyze_requirements`
streams questions) and the client did NOT advertise the `userInput`
capability, questions with options are bridged to `session/request_permission`
with every option `kind: allow_once` (flat labels; subOptions/descriptions
lost) — 19496360, 19500701. Selection → answer routed back; cancel/error →
`next-phase` (execution continues). A free-form question with NO options and
no capability auto-advances — silently, no prompt. Clients WITH the
capability get `_kiro/userInput` (rich schema) instead — the TUI advertises it
and renders `question_request` separately. MCP elicitation uses a distinct
channel: `_kiro/mcp/elicitation` (cancel on error).

### 3.9 The rule layer that decides allow/ask/deny (variant A's selector)

Rule = `{capability, match?: [glob], exclude?: [glob], effect:
allow|ask|deny}`. Capabilities: `fs_read, fs_write, shell, web_fetch,
web_search, mcp, subagent, skill, power, context, diagnostics,
sandbox_network` + metas `all, builtin, filesystem`. Resource per capability:
shell→command string, fs→path, web_fetch→hostname, mcp/subagent/skill/power→
`server/tool`-ish path, web_search/context/diagnostics→`"*"`.

Scopes and sources (`loadPolicy`, 20110087; `SCOPE_ALLOWED_EFFECTS`,
20093442):

| scope            | source                                                      | allowed effects  |
| ---------------- | ----------------------------------------------------------- | ---------------- |
| `kiro`           | hardcoded `KIRO_SCOPE_RULES` (20058415)                     | deny, ask        |
| `administration` | `/etc/kiro/managed-settings.json` (linux; darwin/win32 analogues) | deny, ask  |
| `user`           | `~/.kiro/settings/permissions.{yaml,json}`                  | deny, ask, allow |
| `workspace`      | `~/.kiro/workspace-roots/<hash>/permissions.{yaml,json}`    | deny, ask, allow |
| `agent`          | agent profile `permissions:{rules, policies}` field         | deny, ask, allow |
| `session`        | in-memory (persisted consents, subagent-profile rules)      | deny, ask, allow |

Combination is Cedar (compileToCedar, 20035408): `allow`→`permit`,
`deny`/`ask`→`forbid` (ask annotated `@effect("ask")`, condition
`!(context has "asked" && context.asked)`). Cedar forbid beats permit →
effective precedence **deny > ask > allow regardless of scope**; multi-resource
results take most-restrictive (deny>ask>allow, 20064809). No matching rule →
`{effect:"ask", isExplicitAsk:false}` (implicit ask). I found no setter for
the `asked` context anywhere in the bundle (see flagged claims).

Kiro-scope hard rules: fs_write DENY on `~/.kiro/settings/`,
`.kiro/settings/`, `~/.kiro/workspace-roots/`, `~/.kiro/sandbox-state/`
(self-escalation guard); fs_write DENY on `.kiroignore` (engine-level,
case-insensitive); fs_write ASK on `.git/**`, `.vscode/**`,
`{~/,}.kiro/{agents,hooks}/`, `**/*.code-workspace`, `**/mcp.json` (all with
NTFS-bypass pattern families); untrusted workspace adds fs_write ASK on
`.kiro/{steering,skills,extensions,powers}/` — suppressed when a
user/administration blanket fs_write allow exists. Symlink-escape and
zero-workspace-roots are engine-level hard denies.

Presets (referenceable from agent `permissions.policies`): `allow-all`
(capability all allow — "includes filesystem access outside the workspace"),
`edit-workspace`, `dev-shell`; the default agent policy = `fs_read ./**` allow
+ readonly shell allowlists (git/system/cargo/npm/kubectl/rustup read-only).
Subagent profiles get `SubagentPolicyEngine` (20127308): parent rules × own
rules, combined most-restrictively — a subagent rule can never widen the
parent.

Inspection/eval surfaces (client→agent ext methods, no model):
`_kiro/permissions/list` (loaded rules), `_kiro/permissions/explain`
(simulate: returns effect/isExplicitAsk/matchedRule/scope/source, NO prompt),
`_kiro/policy/check` (runs the FULL approval flow **including the prompt**).

### 3.10 TUI (kiro-cli chat, v3/KAS engine) — client-side shaping

- Widget title: `<tool> requires approval`; keys: `y`=allow_once,
  `n`=reject_once, `t`=trust drill-in, `s`=cycle scope (in scope picker),
  Tab=modify/feedback, Esc=reject_once (chat: 397078131, 397316546).
- Selecting "Always allow" under KAS opens a scope drill-in: `Trust "<exact>"`
  (exact resource) / `Trust "<pattern>"` / `Trust entire tool`, each at scope
  session→workspace→global; "global" maps to wire scope `user`. Whole-tool
  sends `resource: "*"` for the capability (chat: `cBe="*"`, 396377706).
- The TUI attaches `_meta.kiro.consent` on EVERY selection (n7, 396832539):
  scope = drill-in choice, else `allow_always`→`"session"`,
  anything else→`"invocation"`.
- `--trust-all-tools` (chat-only flag; needs in-TUI confirmation →
  `trustAllToolsConfirmed`): auto-selects `allow_always` (else `allow_once`)
  on every permission request, KAS form with whole-capability consent — i.e.
  it self-populates session-scope allow rules per capability as prompts arrive
  (chat: 396859875).
- `autoApproveCrewTools` (TUI store toggle, crew/multi-session view):
  auto-answers `allow_once` for prompts whose sessionId ≠ the focused session.
- Whole-capability "Always allow" also flushes same-key queued prompts
  client-side (key = capability + workspaceRoot + sessionId).
- v2-only, one line: `_meta.trustOptions`, option id `allow_all_session`,
  `/tools trust|untrust|trust-all|reset`, and the y/n subtask strings are the
  v2 Rust engine's parallel system; none of it is emitted by KAS.

### 3.11 Workflows and sub-executions

There is NO workflow-specific approval prompt: `approval`/`approve` hits in
the workflow tool region (18.10–18.33 MB) all belong to the remote-tool /
powers wrappers. Workflow step sessions are ordinary sessions on the same
connection: a step's tool hitting `ask` raises variant A with the step's
sessionId (TUI re-routes display via `prepareKasPermissionRequest`
subtask mapping; `originSessionId` preserved). Same for `invoke_sub_agent`
sub-executions — prompts surface, and consent persists into the SHARED
parent `PolicySession` (session scope) so an "Always allow" answered for one
worker covers siblings. Headless/ACP-direct workflow runs stall on the first
ask until the client answers — run workflows under explicit allow rules
(`allow-all` preset or scoped rules), or auto-answer in the driving client.

## 4. Activation drivers (who can pull each lever)

- Variant A prompt: **model-elected** (tool call) — via user-typed request,
  skill/steering content, agent-system-prompt, workflow-step-driven or
  hook-driven turns; ultimately any path that makes the model call a tool
  whose policy says ask. Answered by: user (TUI) or **external-ACP-client**.
  Also directly triggerable by an external ACP client via `_kiro/policy/check`
  (no model).
- Suppressing variant A entirely: user-typed (edit permissions.yaml; answer
  "Always allow"), agent-profile author (`permissions` rules/presets),
  admin (managed-settings.json), external-ACP-client (`_meta.kiro.consent` on
  any response; auto-answering), TUI toggles (`--trust-all-tools`,
  `autoApproveCrewTools`). NOT hook-driven (hooks can force ask — 3.4 — but
  cannot grant allow).
- Variant B: hook-driven (agent-hook runCommand) × client-supplied `approved`
  flag; user answers.
- Variant C: hook-driven (PreToolUse hook stdout JSON `permissionDecision:
  "ask"`); user answers.
- Variant D: hook-driven (Stop hook confirm with options); user answers.
- Variant E: feature-flag + client-capability gated; fires on infra-safety
  BLOCKED verdicts (tool-call shaped, so model-elected upstream).
- Variant F: execution-engine-driven (pending file changes review);
  external-ACP-client answers with per-file decisions.
- Variant G: model-elected (`user_input` / `analyze_requirements` tools);
  only in clients lacking the `userInput` capability.

## 5. Fixture design (cheapest holders; no model calls)

All fixtures run on the ACP-direct arm (settled: works with no session seed,
no model): spawn KAS with `--transport=stdio --auth=acp-callback` under an
isolated `HOME`, initialize, `session/new`.

- **F18-a rule lattice (no prompt, no model, RUNNABLE):** write
  `~/.kiro/settings/permissions.yaml` permutations (allow vs explicit ask vs
  deny, exclude, meta-capabilities, workspace store file, agent-profile
  rules), then call `_kiro/permissions/explain` per (capability, resource).
  Observable: `{effect, isExplicitAsk, matchedRule, scope, source}` — directly
  discriminates precedence claims (deny>ask>allow, explicit vs implicit).
- **F18-b prompt shapes (real prompt, no model, RUNNABLE):** call
  `_kiro/policy/check {sessionId, capability, command|paths}` while the client
  answers `session/request_permission`. Observable: the incoming request's
  `options` array — assert 4 options for implicit ask, 3 when an
  `effect: ask` rule matches, 2 when capability cannot classify; assert
  option ids/names/kinds and `_meta.kiro.consent.askType`.
- **F18-c persistence scopes (RUNNABLE):** in F18-b answer `always-accept`
  with `_meta.kiro.consent {scope: user|workspace|session|invocation}`.
  Observables: `~/.kiro/settings/permissions.yaml` content;
  `~/.kiro/workspace-roots/<hash>/permissions.yaml`; `_kiro/permissions/list`
  delta (session); `_kiro/policy/changed` notification; second
  `_kiro/policy/check` returning allow with no prompt. Negative arms:
  explicit-ask + always-accept (no persist), workspace scope with
  outside-workspace resource (`_kiro/policy/error`).
- **F18-d hook prompts (RUNNABLE):** client implements
  `_kiro/hooks/extractHooks` returning a runCommand hook with
  `approved: false`, then `_kiro/hooks/triggerHook`. Observable: variant B
  request (title = command, exactly 2 options). PreToolUse-ask (variant C) and
  Stop-confirm (variant D) shapes need a turn → SPEC-only: assert titles
  "Hook permission required" fallback, option kind mapping from
  `options[].allow`.
- **F18-e turn approval (SPEC):** needs pending file changes from a real turn.
  Assert fail-OPEN by making the client throw on `session/request_permission`
  with `_meta.kiro.type == "turn_approval"` → changes must apply anyway.
- **F18-f edited command (SPEC):** answer variant A (shell) with
  `_meta.kiro.editedCommand`; observable: executed command differs +
  `user-edited-command` telemetry. Needs a turn (execute_bash path).

## 6. Cross-interactions and vendor-doc corrections

- **Fail direction is variant-specific:** A/B/C/E fail closed; F fails OPEN;
  G fails "advance" (neither approve nor block). An ACP client that errors on
  unknown prompts silently accepts turn-level file changes.
- **Explicit `ask` rules beat `--trust-all-tools`'s intent:** the TUI
  auto-answer picks allow_always, but explicit-ask consent never persists and
  (3-option shape) has no allow_always at all — so it degrades to allow_once
  per round. An explicit ask rule is the one reliable "always HITL" lever.
- **`autoApprove` (mcp.json per-server tool list) is parsed but unconsumed**:
  6 bundle occurrences — 1 AWS-SDK string table, 4 schema/parse
  (17199896, 17204294, 20007096), 0 readers of the parsed field; chat-binary
  hits are all the unrelated `autoApproveCrewTools`. `alwaysAllow`,
  `auto_approve`, `autoApproved`, `preApproved`: 0 hits each. Positive
  controls: sibling field `disabledTools` 23 hits, `workspaceTrusted` 37.
  C-11 state: documented-but-unconsumed at 2.15.1. Use permissions rules
  (`capability: mcp, match: [server/tool]`) instead.
- **Vendor docs (private/kiro-v3-docs.md) corrections:** L245–248 says
  `.kiroignore` writes "always ask" — the bundle hard-DENIES them
  (`KIROIGNORE_RULE`, engine-level, case-insensitive). The always-deny list
  omits `~/.kiro/sandbox-state/`; the always-ask list omits `.vscode/**`,
  `**/*.code-workspace`, `**/mcp.json`, and the untrusted-workspace autoload
  dirs; the scope table omits the `administration` scope entirely. L31
  "`--trust-all-tools` … replaced by permissions.yaml" — the flag still works
  on `chat` under v3 (TUI auto-answer), it is only refused on `acp`.
- **"Always deny" from the TUI persists nothing:** n7 defaults non-allow_always
  kinds to scope `"invocation"`, which persistConsent no-ops — while a bare
  ACP client omitting `_meta` gets the agent-side default scope `"session"`
  (deny persisted for the session). Same button, different semantics per
  client (flagged).
- **MCP whole-tool trust is wide:** "Trust entire tool" for an MCP prompt
  persists `capability: mcp, match: ["*"]` — all tools on all servers, not
  just that server.
- **Hook ask ≠ policy ask:** variants B/C/D never consult the policy engine
  and offer no "always"; nothing a hook approves is remembered.
- **Sub-execution consent is shared:** session-scope persists into the parent
  `PolicySession`; workers inherit each other's grants (and subagent-profile
  rules can only narrow).
- **Serializer timeout:** after 180 s waiting on another ask, a second prompt
  can go out concurrently — clients must handle overlapping
  `session/request_permission`.
