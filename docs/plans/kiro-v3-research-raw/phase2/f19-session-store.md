> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

# F19 — v3 session on-disk specification

Method: bundle read of the persistence layer (byte/line windows only), cross-checked
against the corpus. All line numbers below are into the pretty-printed 2.15.1 bundle
and are for THIS KASID only — re-locate by string anchor, never by line, on any other
build.

## 1. The question

Settled means: (a) every file the v3 engine writes under
`~/.kiro/sessions/` is named, with its writer, format, and full field
schema; (b) the `messages.jsonl` `payload.type` discriminated union is
enumerated exhaustively from the Zod schema, not from observation; (c) the
F8 gating question — is the resolved per-dispatch model/effort observable
anywhere on disk — has an explicit yes/no per granularity.

## 2. What is already known (cited, not re-derived)

- Layout census, `session.json` key union over 212 real sessions, event-kind
  counts, `payload.subExecutionId` discriminator (0/56195 root vs
  29791/29829 sub), flat `sub-executions/`, depth never in the path:
  corpus `evidence/machine-state.md` R-machine-3.
- `schemaVersion` 1.0.0 + `dataModelVersion` 1 on all 212 despite key-set drift —
  version CANNOT gate field availability: R-machine-3 notes, R-machine-4.
- `workflowsEnabled` persisted-only enable path (load passes the persisted
  fallback, new does not): corpus `records/workflow-surface.md` R-workflow-1/2.
- Credits: `usage_summary` → `promptTurnSummaries[].usage` (unit `credit`),
  latency `elapsedTime` ms; sub-execution transcripts carry NO usage rows; raw
  token counts unrecoverable: memory `reference_kiro_session_usage.md`.
- Bucket = `sha256(paths.map(normalize).sort().join("\0")).hex[0:16]` or
  `_global`; stored `workspacePaths` must equal launch cwd; `session/load` of an
  unknown id hydrates fresh + overwrites (`session.load.create_uncreated`);
  schema-invalid seed fails loud (CORRUPTED_DATA): settled recon 2026-07-29/30.
- `sub-executions/<id>.jsonl` files are the v3 sub-agent transcripts; `cli/` bucket
  is v2 (zero v3 ids in `data.sqlite3`): R-machine-3, settled facts.

Everything below is new bundle-read detail on top of that.

## 3. The interface, fully enumerated

### 3.1 Directory inventory

Sessions root = `join(homeDir, ".kiro", "sessions")`. Per bucket
(`<16-hex>` or `_global`), two kinds of children:

```
<bucket>/
  sess_<uuid>/                      one per session (id = "sess_" + crypto.randomUUID(), regex ^[A-Za-z0-9_-]+$, max 128)
    session.json                    metadata; atomic write-then-rename under a FileLock
    messages.jsonl                  root transcript; append-only in steady state
    sub-executions/<uuid>.jsonl     flat, one per sub-execution, append-only
    snapshots/<8-hex>/<relPath>     per-file content snapshots (see 3.5)
    snapshots/<8-hex>/.hash         sha256(content) hex, the dedup index
    publish.cursor                  text "<byteOffset>:<seq>" (see 3.6)
    publish-sub.cursor              JSON { [subExecutionId]: {byteOffset, seq} }
    tool-outputs/<tool>-<8-hex>.txt large-tool-output offload (see 3.7)
  workflows/
    <workflowId>/workflow-state.json        atomic tmp+rename, fenced (see 3.8)
    <workflowId>/workflow-definition.json   same commit mechanics
    generated/                              save_workflow_definition tool output
```

Enumeration method + positive controls: every filename joined under a
session path —
`grep -noE 'join\(sessionPath, "[^"]+"'` yields exactly
`messages.jsonl`, `session.json`, `snapshots`, `sub-executions`
(4 distinct names); cursors and `tool-outputs` are joined via `dir`
/ `outputsDir` variables (found at their `CURSOR_FILE`/`SUB_CURSOR_FILE`
constants, line 465371-465374, and `writeToolOutput`, line 469515).
`workflows/` is bucket-level, joined from `sessionsPath` (lines 441560,
442002, 442484-442511). The corpus census (R-machine-3) saw all of these
except `tool-outputs/` — see flagged claims.

### 3.2 session.json — SessionMetadataSchema (bundle lines 22502-22646)

Constants: `SCHEMA_VERSION = "1.0.0"`, `DATA_MODEL_VERSION = 1` (line
469425-469426). `saveSession` stamps both plus `lastModifiedAt` on every
full save; `updateMetadata` merges partial updates under a per-file
`FileLock` and refreshes `lastModifiedAt`; every transcript append also
rewrites `lastModifiedAt` via `updateLastModified`. All metadata writes
are atomic write-then-rename.

| key | type | presence / default | writer |
| --- | --- | --- | --- |
| `schemaVersion` | string | required; always "1.0.0" | saveSession stamp |
| `dataModelVersion` | int >= 0 | optional; engine writes 1; absent = legacy | saveSession stamp |
| `id` | string | required; `sess_<uuid>` | creation |
| `title` | string | required; initial `"New Session"` | creation; first-prompt derivation; `updateSessionInformation` tool; user rename |
| `agentMode` | string | required (plain z.string) | creation; set_mode/set_config batch |
| `workspacePaths` | string[] | required; `[cwd, ...additionalDirectories]`; `[]` when `isEmptyWorkspace` | creation |
| `createdAt` / `lastModifiedAt` | ISO string | required | creation / every write |
| `lastCheckpointId` | string | optional | checkpoint flow |
| `parentSessionId` | string | optional | fork service |
| `parentExecutionId` | string | optional | client-supplied (schema only; no engine writer found) |
| `repositories` | array(string→normalized \| SessionRepository) | optional; legacy bind-strings (`owner/repo`, `gitlab:group/project`) normalized ON READ to `{providerType?, name, url?, branch?}` | creation when non-empty; repo-binding flow |
| `createdReason` | enum `human\|rewind\|subagent\|tangent` | optional | client `_meta.kiro.createdReason` on session/new; fork params (tangent/rewind) |
| `executionTarget` | `{kind:"local"}\|{kind:"cloud-sandbox"}` | optional; absent reads as local; persisted only when NOT local | creation |
| `modelId` | string | optional; doc-comment examples `"opus-4.7"`, `"auto"` | creation when set; cold-registry pinning (`session.model.pinned` resolves default and persists); set_config batch |
| `autopilot` | boolean | optional; NOT written at creation | set_mode/set_config batch |
| `effortLevel` | string (e.g. "high", "xhigh") | optional; model-DEFAULT effort deliberately NOT persisted (doc comment, line 486037-486046) | creation ONLY when request carried explicit `_meta.kiro.effortLevel` (workflow steps inherit parent's this way); set_config batch after validation against `getEffortLevelsForModel` |
| `semanticReviewEnabled` | boolean | optional; absent = default-enabled rule | creation (resolved value) |
| `ftaEnabled` | boolean | optional; default disabled | creation |
| `workflowsEnabled` | boolean | optional; default disabled | creation; the ONLY read that can enable is session/load fallback (R-workflow-2) |
| `specPlanEnabled` | boolean | optional | creation |
| `specWorkflow` | enum `quick\|full` | optional | creation |
| `specSkipClarificationEnabled` | boolean | optional | creation |
| `steeringSupervisorEnabled` | boolean | optional; TRI-STATE: omitted when user never chose (so experiment membership re-resolves on load); only the setting flag, never the experiment contribution | creation |
| `contextFiles` | string[] | optional | `_kiro/session/context` ext method (persistContextFiles) |
| `description` | string | optional; focus-mode progress summary | model via `updateSessionInformation` |
| `status` | enum `in_progress\|waiting_on_user\|completed\|idle\|failed` | optional | engine at turn boundaries + model-declared `waiting_on_user` preserved at turn end |
| `titleSetByUser` | boolean | optional; gates agent-driven title writes off | user rename; named tangent fork |
| `_meta` | `{kiro?: {workflow?: WorkflowPersistedMeta}}` passthrough | optional; session/new persists client `_meta` VERBATIM minus the mux `__callerClientId`; read side is `.catch(undefined)` per level so malformed meta degrades instead of bricking | creation |

`WorkflowPersistedMeta` (line 21975): `{workflowId, workflowName, nodeId,
nodePath: string[], type: "step", iteration?, branchId?}` passthrough —
this is how workflow step sessions are discoverable by `workflowId` from
listings without reading transcripts.

Listing surface: `SessionSummary` = id, title, agentMode, createdAt,
lastModifiedAt, workspacePaths, parentSessionId?, createdReason?,
description?, status?, `_meta`?, executionTarget?, repositories? — all
served from `session.json` alone (cold listing, no transcript read). A
`session.json` that fails schema parse is WARN-logged and silently
dropped from listings (loadSessionSummary returns null) but
`loadSession` on it throws CORRUPTED_DATA — a session can therefore be
loadable-by-id-invisible-in-lists or vice versa only in that one
direction (invisible but still crash-on-load never happens; both use the
same safeParse).

### 3.3 messages.jsonl — envelope and the full payload union

Envelope (`PersistedMessageSchema`, line 22645): `{id: string, timestamp:
ISO string, payload: MessagePayloadSchema}` — one JSON object per line.
Reader (`loadMessages`, line 469853) silently SKIPS any line that fails
JSON.parse or schema-parse (no warning per line) — tooling must not
assume the on-disk line count equals the loadable message count.
Steady-state writes are appends through a per-`(session, file)` ordered
write log (enqueue is synchronous, so call order = disk order even for
fire-and-forget callers). `saveSession` REWRITES `messages.jsonl`
atomically, but its only callers (denominator: 3 `.saveSession(` sites)
are session/new and load-of-unknown-id (both `messages: []`, so no
transcript write) and the fork service — steady-state transcripts are
append-only.

`MessagePayloadSchema` — discriminatedUnion on `type`, EXACTLY 23 members
(lines 22436-22460). Fields: `?` = optional.

| # | `payload.type` | fields beyond `type` | corpus-observed |
| --- | --- | --- | --- |
| 1 | `user` | content, contextItems? (name, description?, content, uri?), source? enum `chat\|hook\|api\|steer`, images? (data,mimeType), documents? (data,name,mimeType), _meta?, kind? (deprecated legacy notification marker) | yes (1006) |
| 2 | `assistant` | content, operationType? enum `Say\|Reasoning\|Print\|Summary`, executionId?, subExecutionId?, reasoningSignature?, reasoningModelId?, reasoningRedactedContent?, _meta? | yes (10951) |
| 3 | `tool_call` | toolCallId, toolName, args (record), status enum `pending\|awaiting_approval\|approved\|denied\|executing\|completed\|failed`, title?, kind? enum `read\|edit\|execute\|search\|delete\|move\|fetch\|think\|switch_mode\|other`, executionId?, actionType?, filePath?, preSnapshotId?, postSnapshotId?, subExecutionId?, _meta? | yes (11136) |
| 4 | `tool_result` | toolCallId, content, success bool, durationMs?, executionId?, metadata? (record), subExecutionId?, _meta? | yes (11136) |
| 5 | `system` | content | no |
| 6 | `agent_note` | content | no |
| 7 | `tool_revert` | toolCallId | no |
| 8 | `error` | message, code?, details? | no |
| 9 | `mode_change` | fromMode, toMode, reason? | no |
| 10 | `session_event` | category enum `session_start\|session_restore\|session_pause\|session_resume`, context? (record) | yes (801) |
| 11 | `sub_agent_start` | parentExecutionId, subSessionId, subAgentName, prompt, explanation | yes (587+19) |
| 12 | `sub_agent_complete` | parentExecutionId, subSessionId, response, status enum `success\|error\|cancelled`, errorMessage? | yes (586+19) |
| 13 | `sub_agent_progress` | parentExecutionId, subSessionId, message | no |
| 14 | `steering_inclusion` | documents: (string \| {id, displayName, content, scope? enum `global\|workspace`})[], executionId?, subExecutionId? | yes (158+615) |
| 15 | `turn_start` | executionId? | yes (807) |
| 16 | `turn_end` | stopReason (min 1 char), stopDetails? {refusal?{category?, explanation?, recommendedModel?}}, executionId? | yes (805) |
| 17 | `tombstone` | kind enum `checkpoint_revert\|summarization`, effectiveFromMessageId, metadata? | yes (8) |
| 18 | `usage_summary` | promptTurnSummaries: {usedTools?[], unit?, unitPlural?, usage? number}[], elapsedTime? (ms), status? enum `success\|failed\|aborted`, executionId?, requestIds? string[] (backend model-service request IDs, call order) | yes (801) |
| 19 | `ContextualHookInvoked` | hookId, operationId, name, hookActionType enum `askAgent\|runCommand`, status enum `running\|completed\|failed\|canceled\|awaiting_approval`, command?, output?, exitCode?, executionId? | yes (453) |
| 20 | `pending_interaction` | interactionType enum `tool_approval\|user_input`, toolCallId, question, options (two shapes: {optionId,name,kind}[] or rich {title,description?,recommended?,subOptionsLabel?,subOptions?}[]), executionId, _meta? | yes (4528) |
| 21 | `interaction_resolved` | toolCallId, outcome, selectedOption?, executionId | yes (4526) |
| 22 | `session_metadata` | key, value (unknown), executionId | yes (7776) |
| 23 | `session_start` | agentType, content, images? (+uri?), documents?, steeringDocuments?, forcedRole bool, messageId | yes (130) |

Denominators: "corpus-observed" is against R-machine-3's event-kind
census (56195 root + 29829 sub rows on one machine, 2026-07-29); 17 of 23
kinds observed there, the 6 marked "no" (`system`, `agent_note`,
`tool_revert`, `error`, `mode_change`, `sub_agent_progress`) are
schema-legal but were never seen — a search index must still accept them.

Engine-written `session_metadata` keys — denominator: 4
`persistSessionMetadata(` hits, 1 is the definition (line 465067), so
exactly 3 producer keys at this KASID: `"displayError"` (465161 area),
`"contextUsage"` (465156), `"recap"` (465222). Readers special-case
`recap` (replay) and `contextUsage` (restore).

Row-id conventions (join keys for an index): turn-completion batch writes
`${executionId}-usage` (usage_summary), `${executionId}-complete`
(session_event category `session_pause`, context
`{executionId, status}`), `${executionId}-turn-end` (turn_end) — one
atomic append batch at every AgentExecutionSuccess/Failed/Aborted, after
draining streaming entries and synthesizing failed `tool_result`-less
tool_calls into terminal events (invariant comment, line 463834-463860).
`session_start` row id is session-stable: `session_start_<sessionId>`
(dedupable across racing first turns). Other rows use fresh UUIDs.
`executionId` stamps ride most root rows; `payload.subExecutionId` is the
root-vs-sub discriminator (R-machine-3).

`usage_summary.promptTurnSummaries` is aggregated PER UNIT, not per
prompt turn despite the name: `aggregateUsageSummary` (line 465095) sums
`usage` and concatenates `usedTools` per distinct `unit` across the
turn's metering entries.

`_meta.kiro` on rows (`KiroPersistedMetaSchema`, line 22159, passthrough):
visibility?, agentSubtaskId? (the sub-execution id on tool rows),
checkpoint? {original?, modified?, local?, fileChanges?[]}, elicitation?
(form|url), serverName?, userMessageId?, toolOrigin? enum
`default|acp|client`, toolId?, disclosedContext? {type skill|steering,
displayName, uri}, streaming? bool (mid-stream flag; replaced in memory,
flushed on flip to false), policyDenial? {capability, resource,
triggeringResource?, effect "deny", matchedRule, scope, source},
workflow? (WorkflowPersistedMeta — stamps every workflow step message
with run/node/iteration/branch), notification? {kind
`system-notification|workflow-progress`, status?, workflowId?,
agentName?, nodeName?, notifyId?, eventType?}, refusal? {category?,
explanation?, recommendedModel?}.

Transcript GAP to know: a prompt sent with `_meta.kiro.agentInitiated:
true` (e.g. the workflow-completion auto-wake) runs a real turn but
persists NO `user` row and echoes no user_message_chunk (line
483753-483754 doc) — turn_start/turn_end appear with no user row
between the previous turn and them.

### 3.4 sub-executions/<subExecutionId>.jsonl

Same `PersistedMessage` envelope, same union. Appended via a per-sub
ordered write log keyed `${sessionId}::sub:${subExecutionId}` (line
469698); directory created on first write; filename is the bare
sub-execution uuid — depth appears nowhere (R-machine-3). Observed kinds
there: assistant, tool_call, tool_result, steering_inclusion, plus nested
sub_agent_start/complete (the 38 rows lacking `subExecutionId`, carrying
`parentExecutionId`+`subSessionId` instead). NO usage_summary rows
(memory ref; corpus). No turn_start/turn_end/session_event rows observed
either — sub transcripts are body-only. Fork copies only the
sub-execution files REFERENCED by the forked message range
(collectReferencedSubExecutionIds).

### 3.5 snapshots/

Written by `snapshotFile` (line 470133): content-addressed dedup — sha256
the content, scan `snapshots/*/.hash` for a match; hit = reuse that
snapshot id (back-filling the file if missing), miss = new id
`crypto.randomUUID().substring(0, 8)` (8 hex chars), write
`snapshots/<id>/<relativePath>` (nested dirs preserved) plus
`snapshots/<id>/.hash`. Join key to the transcript:
`tool_call.preSnapshotId` / `postSnapshotId`, plus `_meta.kiro.checkpoint`
blocks. Fork copies only referenced snapshot ids. `.hash` holds ONE hash
per snapshot id even though the dir layout permits multiple files —
one file per snapshot id in practice (multi-file tools use
`checkpoint.fileChanges` instead).

### 3.6 publish.cursor / publish-sub.cursor — activity upload state

Producer: `ActivityLogPublisher` (line 465382). Constructed ONLY when an
activity endpoint resolves: explicit endpoint or
`https://runtime.<region>.kiro.dev` with region in `{us-east-1,
us-west-2}` (line 484483-484485). Started on BOTH session/new and
session/load; 3 s interval, batches of 25, POST `/agents/activity` to
KRS. Crash-safe incremental tail-read of the transcripts:

- `publish.cursor`: plain text `${byteOffset}:${seq}` for messages.jsonl.
- `publish-sub.cursor`: JSON `{[subExecutionId]: {byteOffset, seq}}`.

`ACTIVITY_TYPE_MAP` (line 465464) maps persisted types → camelCase
activity types; UNMAPPED types are skipped with a debug log. The map has
a key `hook_execution` — but the persisted literal is
`ContextualHookInvoked`, so hook rows are never uploaded; `session_start`,
`agent_note`, `tool_revert` are also absent from the map. Sub rows are
uploaded with the PARENT sessionId plus `subSession` and (misnamed)
`parentAgentId: subExecutionId`. These cursor files are the only
mutable-in-place (non-append, non-atomic) files in the session dir.

### 3.7 tool-outputs/

`writeToolOutput` (line 469512): a tool result >= 30000 chars
(`LARGE_OUTPUT_CONFIG.BASE_THRESHOLD`, line 300184) from an allowlisted
tool — `execute_bash`, `get_process_output`, `web_fetch`,
`remote_web_search`, or any `mcp_`-prefixed tool — is offloaded to
`tool-outputs/<sanitizedToolName>-<8-hex>.txt` and replaced in-band by a
head/tail reference (500 chars each side). Path is returned
synchronously, disk write is async fire-and-forget (a failure is logged
+ metered, the transcript reference then dangles). Cleaned up only by
whole-session deletion.

### 3.8 Bucket-level workflows/ (shared by all sessions of a workspace set)

- `<bucket>/workflows/<workflowId>/workflow-state.json` — run state,
  `WorkflowStateSchema`-parsed on read; atomic
  `tmp.<8-hex>` + rename with an ownership FENCE: a `preCommit` check can
  reject the rename with `WorkflowStatePersistFencedError` when another
  process claimed the run mid-write (line 415057-415080).
- `<bucket>/workflows/<workflowId>/workflow-definition.json` — same
  commit mechanics.
- `<bucket>/workflows/generated/` — `save_workflow_definition` tool
  output; the destination is computed server-side from the session's
  workspace hash, the tool input carries NO path field (line 441994-442006).
- Workspace-side recipe sources are separate: `.kiro/workflows/*.workflow.json`
  under each workspace root (line 433841-433843) — definitions only, never
  run state.
- Lookup order for run state: combined-paths hash dir, then each
  single-path hash dir, then a full scan of every `<hash>/workflows`
  under the sessions root (line 442480-442520).

### 3.9 Eviction (the only auto-delete)

`sessionEviction` agent setting `{enabled, maxBytes}` — DEFAULT DISABLED;
budget default 500 MiB (`DEFAULT_SESSION_EVICTION_BUDGET_BYTES`, line
23121). Checked ONCE per process (`storageChecked` latch), at
session/new, only when the resolved setting says enabled. Evicts oldest
`lastModifiedAt` first (tie: id), never below 5 sessions
(`MIN_PRESERVED_SESSIONS`), aborts entirely if any session's size cannot
be computed. Scope: the CURRENT workspace bucket only (listSessions of
those workspacePaths), not global.

### 3.10 Fork and export

`forkSession` (line 470355): new `sess_<uuid>` in the SAME bucket (or a
caller-supplied cwd's bucket), messages truncated at the fork point
tombstone-aware (`materializeForAgent`), `parentSessionId` set,
`createdReason` from params, referenced snapshots + sub-executions
copied, `titleSetByUser` set for titled tangent forks, `repositories`
deliberately dropped (re-derived on load). Failure cleans up the partial
dir. `_kiro/session/export` zips `session.json` + `messages.jsonl` +
`sub-executions/*` — NOT snapshots, cursors, or tool-outputs.

### 3.11 F8 cross-reference — is resolved per-dispatch model/effort on disk?

**Effort: NO, at any granularity below session metadata.** No payload
schema in the 23-member union carries an effort field (positive
controls: `effortLevel` has 141 bundle hits incl. the metadata schema;
spelling sweep `effort_level`/`reasoningEffort`/`thinkingBudget`/
`effortlevel` = 0 hits each). `session.json.effortLevel` records only an
EXPLICIT choice (set_config, or workflow-step inheritance at creation);
a model-default effort is deliberately never persisted (doc comment,
line 486037) — absent re-derives from the model's CURRENT default on
read, so the historical effective effort of an old session is
unrecoverable once the default changes.

**Model: partially.** Three traces, none per-dispatch-reliable:

1. `session.json.modelId` — session-level selection; cold-registry
   pinning persists a resolved default before the first framed turn
   (`session.model.pinned`), but the schema doc-comment admits `"auto"`
   as a value, and per-call resolution of `auto` is not written back.
2. `assistant.reasoningModelId` — the model that produced that reasoning
   block, persisted on reasoning-bearing assistant rows ONLY (root and
   sub transcripts both, schema-level). Its purpose is replay-safety
   (reasoning from a different model than current is dropped, line
   468387-468389), but it doubles as the single on-disk resolved-model
   stamp at message granularity. Absent on non-reasoning turns.
3. `usage_summary.requestIds` — backend request ids in call order; joins
   to server-side logs, resolves nothing locally.

**Consequence for F8:** disk observation alone cannot falsify an
effort-precedence hypothesis and can only falsify model-precedence when
the model emits persisted reasoning. F8 empirics need the wire: the
`configOptions` broadcast (`buildConfigOptions` computes
`currentValue: effortLevel ?? model default`, line 484029-484041) and
`session_info_update` notifications carry the effective values per
session. A dispatch-level probe additionally needs the sub-agent to emit
reasoning, or nothing is written that distinguishes its model.

## 4. Activation drivers (who can pull each lever)

| lever | drivers |
| --- | --- |
| session dir creation + session.json initial write | external-ACP-client (session/new, session/load of unknown id); workflow-step-driven (step sessions) |
| session.json metadata updates | external-ACP-client (set_mode, set_config, `_kiro/session/rename`, `_kiro/session/context`); model-elected (`updateSessionInformation` → title/description/status); engine-automatic (model pinning, turn-boundary status, lastModifiedAt) |
| messages.jsonl appends | user-typed (user rows, source `chat`); hook-driven (source `hook`); external-ACP-client (source `api`, steer); workflow-step-driven (`_meta.kiro.workflow` stamps, notification rows); model-elected (tool_call/assistant); engine-automatic (turn bookkeeping, session_metadata, steering_inclusion) |
| sub-executions/*.jsonl | model-elected (delegation tool dispatch); workflow-step-driven |
| snapshots/ | engine-automatic on file-mutating tool calls (model-elected indirectly) |
| publish cursors + activity upload | engine-automatic, gated by auth region us-east-1/us-west-2; no user or model lever |
| tool-outputs/ offload | engine-automatic (>= 30k chars, allowlisted tools; model-elected indirectly via tool choice) |
| eviction | external-ACP-client (settings bag at session/new sets enabled+budget); engine-automatic execution, once per process |
| bucket workflows/ state + definitions | external-ACP-client (`_kiro/workflow/new`); workflow-step-driven (state saves); model-elected (`save_workflow_definition`, workflows-enabled sessions only) |
| fork (tangent/rewind) | external-ACP-client (fork/rewind flows; createdReason) |
| export zip | external-ACP-client (`_kiro/session/export`) |
| hidden turns (`agentInitiated`) | workflow-step-driven / external-ACP-client; NOT user-typed |

No lever here is skill-invoked or agent-system-prompt-driven; the model's
only reach into the store is via tools (`updateSessionInformation`,
`save_workflow_definition`, file tools triggering snapshots/offload).

## 5. Fixture design (no model calls; specs where a turn is required)

- **F19.a Schema conformance probe (pure fs, runnable now):** run the
  R-machine-3 census commands, extended with
  `find . -mindepth 3 -maxdepth 3 -name tool-outputs -o -name publish.cursor`
  and a jq pass validating every `session.json` against the field table
  in 3.2 (unknown-key detector: `keys - <list>` non-empty = schema moved).
  Discriminator: any `payload.type` outside the 23-member list, or any
  `session.json` key outside 3.2's table, fails the fixture — that is the
  staleness alarm for this whole record.
- **F19.b Seed + load round-trip (engine, no model):** write a minimal
  valid `session.json` (required keys only) into the right bucket, ACP
  `session/load` it, assert exactly two `[SessionPersistence] Loaded
  session` stderr lines (settled success signature) and that the file
  gained `dataModelVersion: 1` + refreshed `lastModifiedAt` only via a
  later write path — a bare load does NOT rewrite metadata (loadSession
  is read-only; only appends/updates do). Negative arm: corrupt one
  transcript line, assert the load succeeds with N-1 messages (silent
  line skip) — discriminates loader tolerance from metadata strictness
  (CORRUPTED_DATA).
- **F19.c Cursor semantics (fs-only):** append a synthetic valid row to a
  seeded `messages.jsonl`, run a session under a supported-region auth
  vs not (or stub the endpoint), observe `publish.cursor` appear and
  advance as `<bytes>:<seq>`. Discriminator: cursor exists iff publisher
  constructed; format has exactly one colon.
- **F19.d [SPEC — needs one model turn] reasoningModelId presence:** one
  cheap prompt on a reasoning-emitting model; assert the assistant row
  carries `reasoningModelId` equal to the session's resolved model, and
  a same-session non-reasoning turn omits it. This is the F8 disk-side
  observable's existence proof.
- **F19.e [SPEC — needs one dispatch] sub-transcript sterility:** one
  delegation; assert the child file has no usage_summary/turn_* rows and
  every row carries `payload.subExecutionId` except none (no nesting).

## 6. Cross-interactions

- `_meta` verbatim persistence vs settings gating: the client's
  session/new `_meta` (minus `__callerClientId`) lands in
  `session.json._meta`, INCLUDING any `kiro.settings` bag — but gates
  like `/goal` read initialize-time clientMeta and the workflow gate
  reads the RESOLVED `workflowsEnabled` boolean, not the persisted raw
  settings. Reading `_meta` off disk tells you what was asked, never
  what was resolved.
- Version numbers are inert: schemaVersion/dataModelVersion never bumped
  across observed key-set drift (R-machine-4); the `_meta` +
  `workflowsEnabled` co-presence (18/212) dates a field instead.
- Compaction/tombstones: a `tombstone` makes everything before
  `effectiveFromMessageId` invisible to replay while still on disk —
  a credit index must NOT stop at tombstones (usage rows before one are
  still real spend); a context reconstruction MUST. Sub-execution
  compaction writing a parent tombstone (C-9 / issue 10482) means parent
  transcripts can be replay-truncated by a child.
- Cursors vs eviction/fork: cursor files are copied by neither fork nor
  export; a forked session re-publishes from offset 0 (fresh dir, no
  cursor) — server-side dedup is by messageId.
- The write log is per-process memory: two engines on one session dir
  (stale KAS server, R-machine-7) interleave appends at fs granularity
  with no cross-process lock on messages.jsonl (only session.json has
  FileLock, and only in-process).
- Eviction vs the 92 publish.cursor / stale-session reality: eviction is
  bucket-scoped and default-off, so the store grows unboundedly by
  default (212 sessions observed); enabling it in one workspace never
  cleans another bucket.
- `agentMode` is a free string on disk; builtin mode ids load-then-filter
  (settled) — do not validate `agentMode` against the addressable set.

## What is queryable, and what an index must key on

Queryable today, from disk alone: session inventory + listing fields
(3.2) without transcript reads; per-turn credit spend and latency
(`usage_summary` by `executionId`, unit-aggregated); tool activity with
arguments, duration, success, and policy-denial reasons; interaction
stalls (`pending_interaction`/`interaction_resolved` pairing by
`toolCallId`); hook firings (`ContextualHookInvoked` by
hookId/operationId/exitCode); sub-agent forest (dispatch rows'
`parentExecutionId`+`subSessionId` joined to child files by filename);
workflow attribution (`_meta.kiro.workflow` on rows, `_meta.kiro
.workflow` in metadata, bucket `workflows/<id>/workflow-state.json`);
file-change history (snapshot ids on tool_calls joined to `snapshots/`).
NOT queryable: raw tokens, per-dispatch effort, per-dispatch model on
non-reasoning turns, wall-clock inside a turn beyond `durationMs`/
`elapsedTime`, anything about turns that ran with `agentInitiated`
user-side text.

Index keys: `(bucket, sessionId)` primary; `executionId` (turn join:
turn_start/usage/-complete/-turn-end rows share it), `subExecutionId`
(row discriminator + child filename), `subSessionId`+`parentExecutionId`
(dispatch edges), `toolCallId` (call/result/interaction/revert join),
`messageId`/row `id` (dedup, `${executionId}-usage` convention),
`snapshotId`, `workflowId`/`nodeId`/`iteration`/`branchId` (from
`_meta.kiro.workflow`), `requestIds[]` (backend correlation),
`payload.type` (23-value enum), `session_metadata.key` (open vocabulary;
3 engine keys today), `lastModifiedAt` (eviction/list order), and the
`unit` inside promptTurnSummaries (currently `credit`).
