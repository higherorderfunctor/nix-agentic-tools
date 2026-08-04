# F11 — the slash-command surface, mechanically (subsumes F2)

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

Binaries read: engine bundle (`$B` = the KAS `acp-server.js`) and the v3 chat TUI
(`$RC` = `/nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-chat-wrapped`,
555 MB Bun-compiled JS; the store `kiro-cli-chat` is a 218-byte wrapper around it).
`kiro-cli-term` (41 MB) was NOT examined. Byte offsets below are into these exact files.

## 1. The question

Enumerate every slash-command registration in both layers (engine bundle + chat
client), with each gating condition; then per command determine: who can pull the
lever (activation drivers), what executes it (typed method vs text vs local UI),
and what /switch, /plan, /spec, /spawn, /rewind, /goal actually are underneath.
"Settled" = every command name below traces to a registration site read in the
binary, not to docs or guessing.

## 2. What is already known (corpus)

- `records/workflow-surface.md` R-workflow-4: `workflowsEnabled` gates a workflow
  slash-command source; the registration snippet at bundle offset ~20271552 names
  `createWorkflowCommandSource` and `createGoalCommandSource`.
- R-workflow-8: the client's slash-command list filters on an optional per-command
  `feature` field; exactly one command sets it (`feature:"remote_sandbox"`).
- Settled facts: `/workflow-run|resume|status|cancel` are INERT (advertised, no
  client handler, fall to "not yet supported in KAS mode"); `/goal` is the one
  deterministic typed start, gated on `settings.goal` from initialize-time
  clientMeta; mode-F recon: slash text over ACP-direct is inert (except /goal).
  All confirmed below with the exact mechanisms.

## 3. The interface, fully enumerated

### 3.1 Engine layer — advertisement only

`SlashCommandManager` (src marker `src/slash-commands/slash-command-manager.ts`,
class at $B:19418700 region; registration at $B:20270445..20271700) is constructed
with exactly **five** sources (denominator: all `[A-Za-z_]*CommandSource`
identifiers in the bundle — 10 hits = 5 names x def+registration):

| Source | Emits (name → command) | Gate |
| --- | --- | --- |
| `createSteeringCommandSource` | one per steering doc with `config.inclusion` = `manual` or `auto`; type `steering`, `contextQuery: "<scope>:<fsPath>"` | none (doc list itself is trust/loader-gated) |
| `createCustomAgentCommandSource` | one per agent, type `custom-agent`, input hint `task to delegate` | per-agent source: `user-profile`/`workspace-profile`/`client-provided`/`cloud-profile` always; `bundled-profile` never; `builtin-mode` only if in `EXPOSED_BUILTIN_SUBAGENTS` = {`context-gatherer`, `general-task-execution`}; `definition.specOnly` agents only when session `modeId === "spec"` |
| `createSkillCommandSource` | one per progressive-context skill document; type `skill` | none |
| `createWorkflowCommandSource` | `workflow-run`, `workflow-resume`, `workflow-status`, `workflow-cancel`; type `workflow` | per-session `sessionState(id).workflowsEnabled ?? false` (fail-closed; immutable per session) |
| `createGoalCommandSource` | `goal` ("Work toward a goal in a loop until done"); type `workflow` | connection-level `isSettingEnabled(clientMeta.settings, "goal")` (initialize-time) |

Command record shape (`buildCommand`, $B:19423560):
`{name, description, input:{hint}, _meta:{kiro:{type, contextQuery?}}}`.
Aggregation pipeline: `normalizeNames` (kebab-cases the name, keeps
`_meta.kiro.originalName`) then `deduplicateWithinType` (last-wins per
`type::name`). Transport: ACP `session/update` with
`sessionUpdate:"available_commands_update"`. Initial delivery is caller-scoped
(`pushToSession` on session/new + session/load, unconditional emit); live changes
broadcast diff-before-emit per session.

**The engine has NO inbound command executor.** Advertised commands are never
matched against incoming prompt text, with exactly two special cases in the whole
`prompt()` path (read continuously, $B:20378400..20384200):

1. `workflowRuntime.tryResumeStepWithMessage` — paused-workflow steering reroute.
2. The `/goal` gate: `isSettingEnabled(clientMeta.settings,"goal")` →
   `parseGoalCommand(userText)` → `launchGoal(...)` → `end_turn` (see §4.6).

Positive controls for the absence: `"/workflow-run"` as quoted text = 0 hits in
$B while bare `workflow-run` = 6 (source + persistence classification);
`parseGoalCommand` = 2. Everything else a slash command does under v3 happens in
the client, mostly via ext methods. The engine's typed capabilityHandlers map
($B:20300400..20304900) is the entire callable surface; `_kiro/help` is NOT in it
(0 hits in $B; control: `_kiro/hooks/list` = 8 by the same `grep -cF`).

### 3.2 Client layer — three registries + one hidden command

The v3 TUI keeps commands in two state arrays (store init at $RC:396843117 region):

**(a) `kasCommands`** — the static builtin catalog `xXe` ($RC:396159700..396166900),
loaded only when `agentEngine === "kas"`, filtered by
`!cmd.feature || featureSet.isEnabled(cmd.feature)` where the set parses
`KIRO_ENABLED_FEATURES` (JSON array). **26 entries** (denominator: literal count
of the array):

| Command | meta highlights | KAS execution path |
| --- | --- | --- |
| `/help` | panel | local panel from kasCommands+locals (`vBe`, $RC:396390575); never calls the engine |
| `/agent` | selection; sub: `create`,`edit`,`swap` | list = panel of `kasAvailableAgents`; `swap <n>` → `setSessionConfigOption(configId:"mode", value:n)`; `create`/`edit` → "not yet implemented in KAS mode" ($RC:396787131) |
| `/chat` | local; sub: `new`,`save`,`load` | `new` → ACP `session/new`; `save`/`load` blocked on cloud; `load` resolves via spawned `kiro-cli chat _ import-session` (v2-store interop) |
| `/sessions` | local, cloudOnly | as /chat, cloud roster variant |
| `/clear` | — | adapter `executeClear` → new session, then RE-APPLIES prior agent via `setConfigOption("mode", agent.name)` |
| `/model` | selection; sub: `set-current-as-default` | `setConfigOption("model", id)` ($RC:396413441) |
| `/effort` | selection; sub: `set-current-as-default` | `setConfigOption("effortLevel", v)`; on model "auto" first chains /model via the `_m` pending-command mechanism ($RC:396789470) |
| `/reply` | — | local $EDITOR quoting last reply → sendMessage |
| `/paste` | — | clipboard image → sendMessage with image block |
| `/prompts` | selection | picker over prompts/skills/steering; execution re-sends `/name` AS PROMPT TEXT ($RC `xBe`) |
| `/usage` | panel | `_kiro/account/getUsage` |
| `/spec` | local; sub: `new`,`run`,`view`,`analyze_requirements` | see §4.3 |
| `/knowledge` | panel | `_kiro/knowledge` |
| `/compact` | — | `_kiro/session/compact` |
| `/context` | panel; sub: `show`,`add`,`remove`,`clear` | `_kiro/session/context` |
| `/code` | panel; sub: `status`,`init`,`overview` | `_kiro/codeIntelligence` |
| `/hooks` | panel | cached hooksList else `_kiro/hooks/list {trigger:"all"}` |
| `/mcp` | panel | local MCP status panel |
| `/tools` | panel | local panel of `toolsList` (tools_update stream) — no engine call ($RC:396394921) |
| `/plan` | — | see §4.2 |
| `/autonomous` | `feature:"remote_sandbox"`, cloudOnly; sub `on`/`off` | ACP `session/set_mode` between autonomous/default agents |
| `/feedback` | selection | local URL/panel |
| `/rewind` | panel | see §4.5 |
| `/upgrade-agent` | selection; sub `run`,`diagnostics` | v2→universal agent-config migration |
| `/repo` | panel, cloudOnly | attach repository to cloud session |
| `/disconnect` | local, cloudOnly | leave cloud session running |

`/autonomous` is the ONLY feature-gated entry (corpus R-workflow-8 confirmed).

**(b) `slashCommands`** — **15 local entries** seeded with `source:"local"`
($RC:396843117..396846300): `/editor`, `/spawn`, `/switch`, `/copy`,
`/transcript`, `/quit`, `/exit`, `/settings`, `/theme` (moved-to-/settings stub),
`/lite` (dropped unless `KIRO_LITE_ROLLOUT_ENABLED="1"`), `/tui`, `/verbosity`,
`/changelog`, `/session-id`, `/title`. `setSlashCommands` ($RC:396879751) keeps
`source==="local"` and replaces the remainder with engine-advertised leftovers as
`source:"backend"`, prefixing names with `/`.

**(c) hidden:** `/voice` — special-cased in the input router `QM` before any
registry lookup, only when `KIRO_VOICE_SERVER_URL` is set. Not in any catalog.

**Engine-advertised commands are bucketed by `_meta.kiro.type`** on
`available_commands_update` ($RC:396723233..396724258):

- `prompt` → prompts list (scope global/workspace/mcp+serverName, arguments) —
  NOTE: the v3 engine's five sources never emit type `prompt`; this bucket is fed
  by the v2 adapter path. Under pure v3 it stays empty.
- `skill` → skills list; `steering` → steering list, minus the hidden set
  `L0n = {"quick-spec","architecture-selection","bug-fix"}` ($RC:396707784).
- `agent` / `mode` / `custom-agent` → **DROPPED** (`break`). The v3 TUI never
  surfaces engine custom-agent commands; agent selection goes through /agent.
- everything else (i.e. type `workflow`: the four workflow-* plus goal) →
  `commands_update` → `setSlashCommands` backend entries.

**Input parsing** (`u$`, $RC:396387696): trimmed input must start with `/`; the
first token must not contain `/`, `\`, or `.` (path escape); name = first token,
args = rest. **Resolution** (`QM` → `pEe`, def $RC:396802190) is two-tier and
context-dependent, NOT globally alphabetical. QM does
`pEe(n.kasCommands,a) ?? pEe(n.slashCommands,a)`: within ONE `pEe` call
resolution is exact-match first, then alphabetical-first (localeCompare)
startsWith — but tier 1 (client-native kasCommands = static `xXe` filtered ONLY
by the per-command feature gate, NOT by cloudOnly or ui-mode; `o7` at
$RC:396837946 passes `kasCommands: e.kasCommands` RAW while
`slashCommands: eu(e)` is the merged+filtered list) always beats tier 2
(`eu()`'s merged kas+advertised+prompts+skills+steering list, deduped
first-wins, cloudOnly dropped without a cloud session). Alphabet never spans
tiers, so user prompts/skills/engine-advertised commands can never outrank a
kas-native prefix match. Because tier 1 keeps cloudOnly entries, `/se` outside a
cloud session resolves to `/sessions` (invisible in /help and the menu — `vBe`
applies the cloudOnly+ui-mode filters to the HELP list only) and `nf()` then
silently no-ops via `if(e.meta?.cloudOnly&&!t.cloudSessionActive)return` — the
effective winner differs by cloud-session state and never falls through to
`/spec`. In uiMode "lite" there is no prefix resolution at all: `tf()` requires
an exact name match against `WB(m)`, else the input is sent to the model as
chat. The synthetic dispatch path `vM()` is exact-match-only.

**Dispatch** (`nf`, $RC:396798547), in order:

1. `meta.cloudOnly` and no cloud session → silent no-op.
2. KAS override table `AEe` ($RC:396792702) — **17 entries**: `/chat`,
   `/sessions`, `/disconnect`, `/compact`, `/context`, `/help`, `/hooks`, `/mcp`,
   `/prompts`, `/rewind`, `/tools`, `/upgrade-agent`, `/model`, `/agent`,
   `/autonomous`, `/effort`, `/repo`. Runs TUI-side KAS handler and returns.
3. `/chat` special case (session save/load/new).
4. type `prompt`/`skill`/`steering` → `sendMessage("/name args")` — the slash
   text is re-sent VERBATIM as the prompt. The engine does not intercept it
   (§3.1), so under v3 these are prompt-text conventions the model sees, nothing
   typed. The steering `contextQuery` meta has **0 hits in $RC** — emitted by the
   engine, consumed by no CLI code.
5. `/voice` handling; then no-arg selection/panel option loading
   (`kiro.getCommandOptions` — KAS adapter returns options only for `feedback`).
6. Non-`meta.local` commands → adapter `executeCommand({command, args})`.
7. Post-action: `hre` ($RC:396300879) maps name → action via `Pnn`
   (**37 entries**, $RC:396281900) → `j4` handler (panels, model/agent/effort
   state updates, quit, editors). `Pnn` still carries v2-era names (`stats`,
   `guide`, `issue`-less; `guide:"switchToGuideAgent"`).

**KAS adapter `executeCommand`** ($RC:396770368) — the only client→engine command
bridge; **15 cases + default** (denominator: literal case count): `quit`,
`feedback`, `help` (→ `_kiro/help`, which the engine does NOT implement — dead),
`clear`, `plan`, `paste`, `reply`, `usage` (→ `_kiro/account/getUsage`),
`context`, `prompts`, `knowledge` (→ `_kiro/knowledge`), `hooks`
(→ `_kiro/hooks/list`), `compact` (→ `_kiro/session/compact`), `rewind`
(→ `session/fork`), `code` (→ `_kiro/codeIntelligence`);
`default:` → `` `/${n} is not yet supported in KAS mode` `` — the terminal state
for `/workflow-run|resume|status|cancel`, `/guide`, and anything else that leaks
through. NOT bare `/goal`: it is unregistered, so it never reaches the adapter —
QM falls through and it goes to the model as prompt text (§4.6). This confirms
and mechanizes the corpus finding for the workflow-* commands.

### 3.3 v2-only surfaces (one-line notes, not deep-dived)

The same Bun binary contains the v2 adapter (`kiro.dev/*` ext namespace,
`agentKind:"v2"`) where `/spawn` is real (`kiro.dev/session/spawn`), plus TWO
embedded docs indexes (~$RC:5.9M and ~$RC:397.9M) listing v2-era commands
(`/tangent`, `/issue`, `/experiment`, `/stats`, `/guide`) that have **no v3
registration** — docs, not code. The Rust v2 chat surface lives elsewhere
(corpus C-4) and was not examined.

## 4. Per-command deep reads

### 4.1 /switch — strictly user-driven, empty under pure v3

`switchSession` ($RC:396287576): no arg → selection panel over
`sessions` Map entries with `status!=="pending"` plus a fixed `main` option;
arg `""`/`"main"` → back to main chat; else match by exact name or id-prefix →
alt-screen `session-view`. The Map is populated ONLY by `spawnSession` results
and multi-session/cloud-roster updates — v2/cloud machinery. Under local v3 the
Map is empty → "No active sessions". **No skill can launch multiple roots and
switch:** skills expand to prompt text for the model (§3.2 step 4), the model has
no tool that reaches the TUI command router, and the router (`QM`) runs only on
user input submission. Multi-root under v3 belongs to external ACP clients
(repeated `session/new`) — each root then has its own client-side state; nothing
in the engine "switches".

### 4.2 /plan — a mode switch wearing a trench coat

Client: `executePlan` ($RC:396778521) = `setConfigOption("mode","kiro_planner")`.
The name maps through `dm()` ($RC:396378085): `kiro_planner → plan`,
`default → vibe` (inverse `vl()`), so the wire value is the engine builtin mode
id `plan` (`VALID_MODES = ["vibe","spec","quick-spec","bug-fix","plan","autonomous"]`,
$B:20224800; `kiro_planner` has 0 hits in $B). Engine-side, mode `plan` runs a
Plan→Execute graph: the PLAN phase exposes a **`switch_to_execution` tool**; its
system prompt ($B:19988000 region) instructs requirements → numbered task plan →
"Does this plan look good…" → only call `switch_to_execution` (with the full
`plan` parameter) after user confirmation. The tool writes
`requestedExecutionPlan` onto the mutable execution object ($B:16934303 doc
comment); the graph's `phaseRouter` reads it and transitions to EXECUTE in the
same turn; `didHandoffToExecutor` makes turn-end persist session mode back to
**`vibe`** — plan mode exits itself after handoff. Other exits: any mode/agent
switch (`/agent swap`, `/spec new`, external `session/set_config_option`).
Client-side, leaving `kiro_planner` triggers a plan survey
(`triggerPlanSurvey`, $RC:396872935). So: entry = user slash or any client
setting configId `mode`; exit = model-elected tool call (user-confirmed by
prompt convention only) or another mode switch. Tool availability changes come
from the builtin `plan` profile + phase, not from the client.

### 4.3 /spec — a builtin mode + local file discovery + typed ext methods

Client `runSpec` ($RC:396288655):

- `new <name>` → `setConfigOption("mode","spec")` + `setCurrentAgent("spec")` +
  `setPendingSpecDescription({featureName})`.
- `run <name>` → reads `.kiro/specs/<name>/` locally; requires `tasks.md`
  ("generate it first"); then invokes the run path (Wnn) over
  `_kiro/spec/resolveSession` + `_kiro/spec/invoke`.
- `analyze_requirements [name]` → mode switch to `spec`, then
  **sendMessage of a natural-language instruction telling the model to use the
  `analyze_requirements` tool** — tool elicitation by prompt, not a typed call.
- `view`/bare → local panel over `.kiro/specs/`.
- Per-spec client config: `.kiro/specs/<name>/.config.kiro` (≤64 KiB JSON):
  `workflowType` ∈ requirements-first|design-first, `specType` ∈ feature|bugfix.

Engine: `_kiro/spec/invoke` operations `executeTask`, `runAllTasks`,
`generateDocument`, `analyzeRequirements`, `createSpec` ($B:20543079);
`_kiro/spec/resolveSession` creates/reuses a per-feature spec session
(absolute `workspacePaths` required). Modes `spec`/`quick-spec`/`bug-fix` are
`SPEC_LIKE_MODES`: their sessions serve `getSpecOrchestratorTools()` instead of
the chat pool, and prompting with zero workspacePaths is refused
(`spec.refused.empty_workspace`). So /spec = builtin MODE + spec-session ext
methods; it is not a workflow recipe (the workflow engine is a separate surface).

### 4.4 /spawn — v2 primitive, stubbed under v3 (F20 candidate)

TUI handler parses `--name`; calls `kiro.spawnSession(task, name)`. The KAS
adapter stub ($RC:396781934):
`spawnSession(){ log "spawnSession not yet supported in KAS mode"; return {sessionId:""} }`
→ handler shows "/spawn is not supported in KAS mode". The v2 adapter implements
it via ext method `kiro.dev/session/spawn`. Under v3 there is no engine spawn
ext method; the nearest primitives are ACP `session/new` (client-driven) and the
delegation/subagent tools (model-driven, corpus C-10). Joinability of a v3
"spawn" equivalent is therefore F20's question, not answerable from this surface.

### 4.5 /rewind — registration + gate only (sibling owns the deep dive)

TUI `qBe` ($RC:396392914): blocked on cloud sessions ("/rewind is not available
for a cloud session yet"); bare → local rewind explorer built from the message
log (one entry per user turn, needs `kasMessageId` assigned via
`kas_message_id_assigned` events); `<turnIndex>` → adapter
`executeCommand("rewind",{turnIndex,messageId})` → engine
`session/fork {sessionId, cwd, _meta:{kiro:{messageId, createdReason:"rewind"}}}`
→ returns NEW sessionId; client switches to the fork (reset + replay). Gates:
KAS engine, non-cloud, message must have a KAS message id.

### 4.6 /goal — engine text interception, unreachable from the shipped TUIs

The ONLY slash command the engine executes, and only as prompt text:
`parseGoalCommand` ($B:18595110) requires text `=== "/goal"`-prefixed
(`"/goal "` or exactly `/goal`), body non-empty, optional trailing
`--max <n>` clamped to 1..200, default maxIterations **5**; `launchGoal` runs the
bundled `goal` workflow recipe with the repeat node's maxIterations overridden.
Gate: `isSettingEnabled(clientMeta.settings,"goal")` — initialize-time,
connection-level (same key gates the goal command source). Client routing on the
2.15.1 TUI (stamped engine KASID, see header): `/goal` is UNREGISTERED — the
local catalog `xXe` has no `/goal` entry ($RC:396160422; controls `/help` and
`/disconnect` hit), and the clientMeta builder ($RC:396741336,
`W0n=[["memory","memoryEnable"]]`) never sends `settings.goal`, so the engine
(`isSettingEnabled` at $B:867793 floors absent keys to false) advertises nothing
from `createGoalCommandSource` ($B:19426914). `QM` ($RC:396801262) therefore
falls through for any `/goal` input: bare `/goal` does NOT open the goal panel
and does NOT show any toast — the submit handler ($RC:396905638+3300:
`let v=E.slice(1)…sendMessage(q…)`) sends it to the MODEL as the plain prompt
"goal" (slash stripped), consuming a turn. The slash-stripping means the
engine's `parseGoalCommand` (which needs the literal `/goal` prefix AND the
connection-level setting) is reachable only from external ACP clients (§5), not
from this TUI. The panel-open path becomes reachable only on the 2.15.2 client
(`$RC2` = the 2.15.2 `.kiro-cli-chat-wrapped`) with
`KIRO_ENABLED_FEATURES=workflows`, where `/goal` registers as a LOCAL panel
command ($RC2:396172819,
`{feature:"workflows",meta:{inputType:"panel",local:!0}}`): bare `/goal` then
opens the goal panel via the `showGoalPanel` fallback but shows NO "not yet
supported in KAS mode" toast — `local:true` makes `nf` skip `executeCommand`
entirely (result stays null) and the toast gate
`if(s?.message&&!A&&!(i==="panel"&&!n))` ($RC2:396868871) would suppress the
alert for `inputType:"panel"` anyway. The panel+toast combination is unreachable
in every shipped TUI configuration; a KAS-mode toast for `/goal` would require a
backend-advertised, non-local `/goal` winning resolution, which the
kasCommands-first order (§3.2) precludes. (The panel's `goal_action` set/clear
data path is fed only by the v2 adapter.) Goal progress reaches the TUI as
`goalStatus` stream updates.

## 5. Activation drivers

- **user-typed** — the entire client surface: all 26 kasCommands, 15 locals,
  `/voice`, backend workflow-* entries (never a backend goal entry — the TUI
  cannot send `settings.goal`, so the engine never advertises it; §4.6). The TUI
  router runs only on user input submission.
- **skill-invoked** — none. A skill invocation is itself just prompt text
  (§3.2 step 4); it cannot execute another command. (`/prompts` picker execution
  also reduces to text.)
- **agent-system-prompt-driven** — indirectly for /plan's EXIT only: the builtin
  planner prompt instructs the `switch_to_execution` call. No prompt can invoke
  a slash command.
- **model-elected** — no slash command is model-invokable; there is no tool that
  reaches either command router, and engine prompt handling ignores slash text
  from any source. The model-elected *equivalents* are tools:
  `switch_to_execution` (plan exit), delegation/subagent tools (spawn-like),
  `run_workflow` etc. when `workflowsEnabled`.
- **hook-driven** — none. Hook stdout injects context (corpus hooks-io-contract);
  injected text is not routed through the command parser (it is not user input;
  and even as prompt text the engine ignores slash forms except /goal, which is
  parsed only from the top-level `userText` of a prompt request).
- **workflow-step-driven** — none directly; a workflow step session gets
  `workflowsEnabled` (so its ADVERTISED list includes workflow-*), but execution
  of commands still requires a client.
- **external-ACP-client** — the real programmable surface: everything the TUI
  does is reachable (`session/set_config_option` for mode/model/effort =
  /plan//agent//model//effort; `session/fork` = /rewind; `_kiro/spec/*` = /spec;
  `_kiro/session/compact` = /compact; prompt text `"/goal …"` with
  `clientMeta.settings.goal` = /goal). An ACP client also receives
  `available_commands_update` including the custom-agent commands the TUI drops.

## 6. Fixture design (no model calls; specs where a turn is required)

- **F11-a (run, no model): advertised-set snapshot.** ACP-direct `initialize`
  (with and without `settings:{goal:true}`) + `session/new`; capture the first
  `available_commands_update`. Pass: goal command present iff the setting was
  sent; the four workflow-* present iff `workflowsEnabled`; NO custom-agent
  entries for bundled profiles; a workspace `.kiro/steering/<x>.md` with
  `inclusion: manual` appears kebab-cased with `contextQuery`. Discriminator:
  exact JSON of `availableCommands`.
- **F11-b (run, no model): /goal gate + parse.** Send prompt text `/goal x --max 3`
  on a connection WITHOUT `settings.goal`: expect a normal model dispatch path
  (fixture-abort before the model call by using a bogus auth callback — the
  request must NOT return `end_turn` immediately). With the setting: expect
  immediate `end_turn` and a workflow record created (goal recipe, repeat
  maxIterations 3). Discriminator: `end_turn` latency + `_kiro/workflow/list`.
- **F11-c (run, no model): mode lever parity.** `session/set_config_option`
  `{configId:"mode", value:"plan"}` then `session/set_config_option` read-back;
  verify `currentAgentId` maps via `vl` (client would show `kiro_planner`).
  Then value `spec` with `workspacePaths: []` + a prompt → expect the synthetic
  `SPEC_REQUIRES_WORKSPACE` refusal, no model call.
- **F11-d (SPEC, needs a turn): plan-mode handoff.** In mode `plan`, one turn
  where the model calls `switch_to_execution`; observable: persisted session
  metadata mode flips to `vibe` at turn end (read `sess_*` store), EXECUTE-phase
  activity in the same turn.
- **F11-e (run, no model): TUI stub inventory.** Scripted TUI (PTY) typing
  `/spawn t`, `/workflow-run x`, `/guide`: each must produce its exact
  "not (yet) supported in KAS mode" toast; bare `/goal` must produce NO toast
  and NO panel — it is unregistered and goes out as the plain prompt "goal"
  (fixture-abort before the model call, §4.6); `/switch` → "No active sessions".
  Cheap regression canary for when any of these gain v3 handlers.

## 7. Cross-interactions

- `/plan`, `/spec new`, `/agent swap`, `/clear` (restore), `/autonomous` all
  contend for the SAME lever (session mode / configId `mode`); last write wins.
  `/clear` re-applying the current agent means "clear" does not exit plan/spec.
- `switch_to_execution` persisting `vibe` silently discards a mode the user set
  mid-plan by other means.
- Prefix matching is two-tier (§3.2), not merely alphabetical: `/s` resolves to
  `/sessions` because tier-1 kasCommands (searched before locals like
  `/settings`/`/switch`, and keeping cloudOnly entries) wins — even though
  `/sessions` is invisible in /help and the menu without a cloud session, and
  outside one `nf()` then silently no-ops. The effective behavior differs by
  cloud-session state; in lite ui-mode there is no prefix matching at all (exact
  names only, else the input goes to the model as chat). A UX trap worth knowing
  when scripting a PTY.
- Engine kebab-casing + dedup-within-type: two same-named steering docs collapse
  (last wins); same name across types coexist (`/x` steering + `/x` skill both
  advertised — client buckets them into different lists, but backend
  `commands_update` entries of the same name would shadow in `pEe` matching).
- The `_meta.kiro.type` contract is the real client/engine interface; any new
  engine command type lands in the TUI's generic backend bucket (visible,
  dispatched to `executeCommand`, and — absent a new case — dead-ends in the
  KAS-mode default error. That is exactly the workflow-* story.)
- `KIRO_ENABLED_FEATURES` gates only `/autonomous` (`remote_sandbox`) at this
  version; the catalog's `workflows` entry remains consumer-less (corpus C-11).
- `KIRO_MODE` env (client `newSession`, $RC:396765800) presets the initial mode
  through the same `dm()` mapping — another way to start in `plan`/`spec`.

## Corrections from adversarial verification

Two claims in an earlier draft were refuted on adversarial re-read of the
binaries and are corrected in place above (§3.2 resolution + adapter default,
§4.6, §5 user-typed, §6 F11-e, §7). `$RC2` = the 2.15.2
`.kiro-cli-chat-wrapped`.

1. **REFUTED: "Bare /goal in the v3 TUI opens the local goal panel AND shows
   the 'not yet supported in KAS mode' error toast."** Corrected: on 2.15.1,
   bare `/goal` opens no panel and shows no toast — `/goal` is unregistered, so
   `QM` falls through and the input goes to the MODEL as the plain prompt
   "goal" (slash stripped), consuming a turn. Evidence: the local catalog `xXe`
   ($RC:396160422) has no `/goal` entry (controls `/help` and `/disconnect`
   hit); the clientMeta builder ($RC:396741336,
   `W0n=[["memory","memoryEnable"]]`) never sends `settings.goal`; engine
   `isSettingEnabled` ($B:867793) floors absent keys to false, so
   `createGoalCommandSource` ($B:19426914) advertises nothing; `QM`
   ($RC:396801262) returns false and the submit handler ($RC:396905638+3300:
   `let v=E.slice(1)…sendMessage(q…)`) sends bare `/goal` as plain "goal". On
   2.15.2 with `KIRO_ENABLED_FEATURES=workflows`, `/goal` registers locally
   ($RC2:396172819,
   `{feature:"workflows",meta:{inputType:"panel",local:!0}}`): the panel opens
   via `showGoalPanel`, but `local:!0` makes `nf` skip `executeCommand` (result
   stays null) and the toast gate
   `if(s?.message&&!A&&!(i==="panel"&&!n))` ($RC2:396868871) cannot fire. The
   panel+toast combination is unreachable in every shipped TUI configuration.

2. **REFUTED: "Prefix ambiguity resolves to the first alphabetical startsWith
   match."** Corrected: resolution is two-tier and context-dependent —
   kasCommands (raw, feature-gated only) always beat the merged/filtered
   slashCommands list, cloudOnly matches silently no-op without a cloud
   session, and lite ui-mode does exact-match only. Evidence:
   `head -c $((396802797+20)) "$RC" | tail -c 1400` shows `pEe` (def
   $RC:396802190: exact match, else sort(localeCompare).find(startsWith)) and
   QM's tiering `pEe(n.kasCommands,a)??pEe(n.slashCommands,a)`; `o7`
   ($RC:396837946) builds QM's context with `slashCommands: eu(e)`
   (merged+cloudOnly-filtered) but `kasCommands: e.kasCommands` RAW; `aQ`/`FXe`
   (~$RC:396164011) filter `xXe` only on `feature`, and `xXe` keeps `/sessions`
   and `/disconnect` with `meta.cloudOnly:!0`; `nf` ($RC:396798668 window)
   contains `if(e.meta?.cloudOnly&&!t.cloudSessionActive)return;` (silent no-op
   after the match); the dispatcher ($RC:396907513) short-circuits lite mode to
   exact-only via `tf(E,M)` before any `sendMessage` fallback; `vBe`
   ($RC:396390649) applies the cloudOnly+ui-mode filters to the HELP list only.
   `pEe` has exactly one definition and two call sites, both in QM
   (`grep -a -boF "pEe(" "$RC"` → 396802199/396802711/396802733).
