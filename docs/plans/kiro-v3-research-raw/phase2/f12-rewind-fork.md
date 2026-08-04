# F12 — /rewind as a context-forking primitive

> Verified against: KAS
> 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc
> (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date:
> 2026-07-30.

Sources: KAS bundle (`acp-server.js`, line refs below are its pretty-printed
lines), the v3 TUI bundle `~/.local/share/kiro-cli/tui.js` (12.7 MB minified,
byte-offset refs), the Rust launcher ELF (strings only). No engine was
launched; no prompt was sent.

## 1. The question

Settled means each of these has a source-anchored answer:

- What does `/rewind` fork — transcript, session, on-disk state?
- Is it the same code path as ACP `session/fork`?
- Who can pull the lever (user / skill / agent prompt / model / hook /
  workflow step / external ACP client)?
- Is the fork durable or ephemeral, and can anything flow BACK?
- How do `checkpoints:true`, `sessionCapabilities.fork`, and
  `replayMarking:true` in the handshake relate?

**Headline answers:** `/rewind` in the v3 TUI IS `session/fork` (plus a
session switch) — a durable, on-disk, transcript-prefix copy into a brand-new
session; it restores NO files. File restore is a *separate*, unadvertised
ext-method pair (`_kiro/checkpoint/revert`, `_kiro/checkpoint/revertMultiple`)
that the TUI never calls. Only the user (TUI) and external ACP clients can
drive any of it; the model cannot. Nothing flows back automatically.

## 2. What is already known

- Corpus has ZERO records on rewind/fork (grep `rewind|fork|checkpoint` over
  `fixtures/kiro-primitives/`): only the settings-key list showing
  `["chat.enableCheckpoint","checkpoint"]` and
  `["chat.enableTangentMode","tangentMode"]` in the feature-resolution map
  (records/workflow-surface.md:491,546; records/limits-and-engine.md:1221,
  1302,1306). This item is net-new territory.
- private/kiro-acp-and-launcher-argv.md section 4 (measured):
  `sessionCapabilities` = `list`, `fork` (fork carries `messageId`);
  `checkpoints` / `sessionList` / `policyNotifications` all true;
  `replayMarking: true`; the 7 advertised `extensionMethods` include NO
  checkpoint method.
- private/kiro-v3-docs.md: zero `/rewind` or fork content. The only
  "checkpoint" mention (line 19) is the *spec task* checkpoint — a different
  concept (see section 6).
- Settled corpus fact reused: v3 session store layout
  `~/.kiro/sessions/<workspaceHash>/sess_<id>/` with `messages.jsonl`,
  `sub-executions/`, and (now confirmed) `snapshots/`.

## 3. The interface, fully enumerated

### 3a. Disambiguation: four unrelated "checkpoint" concepts in this stack

1. **File checkpoints** — per-session `snapshots/` content snapshots + the
   revert ext-methods. This item. Advertised as `_meta.kiro.checkpoints: true`
   in `initialize` (KAS 485130).
2. **langgraph checkpointer** — workflow graph state internals
   (`checkpoint_ns`, `_putCheckpoint`, KAS ~300k–318k). Not session-related.
3. **Spec task checkpoints** — per-feature task-completion resume records
   (`saveCheckpoint`/`loadCheckpoint`, KAS 370167ff; "Resume from checkpoint:
   tasks [...]" 490575). Vendor docs' "task plans with checkpoints" means
   THIS.
4. **`chat.enableCheckpoint` setting** — resolves to a `checkpoint` feature
   record; no consumer found in KAS (section 6).

### 3b. ACP `session/fork` (core verb, not an ext method)

- Wire name from the method map: `session_fork: "session/fork"` (KAS 11685).
  Dispatch (13197-13202): validates with `zForkSessionRequest`, then calls
  `agent.unstable_forkSession`; if the agent object lacked that method the
  dispatcher would answer method-not-found (it is always present here).
- A comment at 484184 confirms: standard ACP verbs (`session/set_mode`,
  `session/set_config_option`, `session/fork`) are NOT ext methods and do
  their own relayed-residency check.
- Advertised in `initialize` as
  `sessionCapabilities.fork = { _meta: { kiro: { messageId: true } } }`
  (KAS 485121-485128) — matching the argv doc measurement.

**Request schema** `zForkSessionRequest` (KAS 12393):

| field | type | notes |
| --- | --- | --- |
| `sessionId` | string, required | parent session |
| `cwd` | string, required | new workspace root for the fork |
| `additionalDirectories` | string[], optional | joins `cwd` in workspacePaths |
| `mcpServers` | array, optional | accepted by schema; unused by the handler |
| `_meta` | record, optional | Kiro extension payload below |

**`_meta.kiro` fields read by `unstable_forkSession`** (KAS 487887-487924):

| field | validation | effect |
| --- | --- | --- |
| `messageId` | raw `typeof === "string"` (NOT schema) | fork point |
| `title` | raw `typeof === "string"` (NOT schema) | fork's title |
| `modeId` | via `KiroSessionMetaSchema` | fork's `agentMode` + response mode |
| `createdReason` | `CreatedReasonSchema.safeParse`; invalid → dropped | persisted tag |
| `isEmptyWorkspace` | schema, `=== true` | ignore `cwd`, workspacePaths `[]` |

`CreatedReasonSchema = enum(["human","rewind","subagent","tangent"])`
(KAS 22487). The same field is also accepted on `session/new`
(KAS 483699, 486205) — `createdReason` marks lineage on ANY create, it does
not imply fork.

**Handler behavior** (KAS 487887-487924):

- Relayed (cloud-sandbox) parent → `RemoteSessionUnsupportedError("session/fork")`.
- Parent need NOT be resident: `this.sessionState(id)` may be undefined; the
  fork service then loads it cold from disk (`loadParentSession`,
  KAS 470420-470436; `SESSION_NOT_FOUND` if truly absent). When resident, the
  message store captures in-flight state. **No mid-turn guard** — forking a
  session whose turn is running is allowed (contrast revert, 3d).
- Response:
  `{ sessionId, configOptions, modes: { availableModes, currentModeId }, _meta: { kiro: { parentSessionId } } }`.
  Mode falls back `_meta.kiro.modeId` → parent's `modeId` → `"vibe"`.
- Fork does NOT auto-load the new session — the client must `session/load`
  it. Replayed load updates carry `_meta.kiro.replay: true` (that is all
  `replayMarking: true` means — a client-side stream-labeling promise,
  KAS 485162-165 comment; unrelated to forking).

**`SessionForkService.forkSession`** (KAS 470335-470417),
src/session/session-fork-service.ts:

1. `effectiveMessages = materializeForAgent(parent.messages)` — checkpoint
   and summarization tombstones are APPLIED first, so content already
   reverted or compacted away does NOT cross the fork (KAS 325185).
2. `resolveForkPoint(effectiveMessages, messageId)` (KAS 325031-325056):
   - no `messageId` → fork at tip (whole effective transcript);
   - `messageId` present but not found → `MESSAGE_NOT_FOUND`;
   - zero effective messages → `NO_FORK_POINT`;
   - **turn-completion rule**: if the target is a `user` message, the end
     index extends forward through every following non-user message — the
     fork KEEPS the target user prompt AND its full response block. Copy is
     `messages.slice(0, endIndex + 1)`.
3. New id `sess_<uuidv4>`; metadata written: `schemaVersion`,
   `dataModelVersion`, `id`, `title` (`params.title ?? "Fork of <parent>"`),
   `agentMode`, `workspacePaths`
   (`cwd != null ? [cwd, ...adds] : parentWorkspacePaths ?? []`),
   `createdAt`, `lastModifiedAt`, `parentSessionId`, `createdReason` (if
   valid), `titleSetByUser` ONLY when `createdReason === "tangent"` and a
   title was passed (comment: keeps the first-turn title derivation from
   overwriting a user-chosen tangent name; rewind/subagent forks unaffected).
   **Everything else is DROPPED**: `modelId`, `effortLevel`, `autopilot`,
   `semanticReviewEnabled`, `ftaEnabled`, workflow enablement,
   `executionTarget`, `requestMeta`, and `repositories` (the last is
   deliberate per comment — `session/load` re-derives from actual paths).
4. Copies referenced state into the new session dir:
   - snapshots: ids collected from `tool_call.preSnapshotId` /
     `postSnapshotId` fields only (KAS 325057-325070); `fs.cp` recursive per
     id, ENOENT tolerated with a warn (KAS 470264-470280);
   - sub-executions: ids from top-level `sub_agent_start.subSessionId` only —
     `collectReferencedSubExecutionIds` does NOT recurse into the
     sub-execution files themselves (unlike `expandSubExecutionMessages`,
     which BFSes), so a depth-2 sub-execution file is NOT copied (inferred
     from code shape; flagged).
5. Failure atomicity: any write error → `cleanupPartialFork` deletes the new
   dir, original error propagates (KAS 470438-470448).
6. Because `workspacePaths` can differ from the parent's, a fork can
   RELOCATE a session into a different workspace bucket — and since v3
   `session/load` requires stored workspacePaths == launch cwd (settled
   corpus fact), fork-with-new-cwd is the sanctioned way to make a session
   loadable elsewhere. Snapshot/sub-execution copies honor the target bucket
   (`targetWorkspacePaths` params, KAS 470264, 470290).

Durability: a fork is a full ordinary session directory — durable, listable
(`SessionSummarySchema` carries `parentSessionId` + `createdReason`,
KAS 22650-22663), and subject to the same eviction budget as any session
(`runSessionEviction`, KAS 470455).

**Error surface** (`SessionForkError`, KAS 324976-324991): codes
`SESSION_NOT_FOUND` ("Session not found"), `MESSAGE_NOT_FOUND` ("Message not
found"), `NO_FORK_POINT` ("No fork point available").

### 3c. TUI `/rewind` = fork + switch (client side)

tui.js evidence (byte offsets):

- Command registry: `L.Rewind="/rewind"` and
  `{name:"/rewind",description:"Fork the session at an earlier turn",meta:{inputType:"panel"}}`
  (offsets 11497163, 11500222).
- Handler `qBe` (11729901): cloud session →
  `"/rewind is not available for a cloud session yet."`; bare `/rewind` →
  builds turn list and opens the Rewind Explorer panel (title `/rewind`,
  "Fork from a previous prompt in this session", columns User Prompt /
  Context used, response-snippet preview — 12599996); selection re-issues
  `/rewind <logIndex>` (12604283).
- Turn list `$Be` (11730578): the TUI's local message log filtered to
  `role === "user"`, newest first; each entry's `messageId` is
  `msg.kasMessageId ?? msg.id`, where `kasMessageId` is the persisted KAS
  message id captured from `session/update` user-message chunks during live
  streaming or replay (12192977).
- Numeric arg path: `executeCommand({command:"rewind", args:{turnIndex, messageId}})`.
  The KAS-mode dispatcher (12109093) does exactly:

```
sendExtMethod("session/fork", { sessionId, cwd: process.cwd(),
  _meta: { kiro: { messageId, createdReason: "rewind" } } })
```

  then returns `{sessionId: <fork>, switchSession: true}`. No messageId for
  the turn → `"No KAS message ID for this turn"`; fork rejection surfaces as
  `"Fork failed"` / the error message.
- `rewindAction` result handler (11634730): on `switchSession` delegates to
  the loadSession handler with `resetMessagesBeforeReplay: true` → the TUI
  session-loads the FORK ("Loading rewound session...", last 10 turns
  replayed, earlier turns elided — 11730578 window) and continues there.

Consequences: the parent session is left complete and intact on disk;
`/rewind` performs **no file restore** (`revertMultiple` has ZERO hits in
tui.js; positive controls: `session/fork` 2 hits, `rewind` 17); the working
tree keeps all later edits even though the conversation forgets them. The
fork inherits the parent turn including its response (turn-completion rule,
3b) — "rewind to turn N" = keep through N, drop after.

Tips gating: the rewind tip is `engines:["kas"]` (12396691) — v3-only. The
new TUI's classic-mode help explicitly lists `/tangent` and `/checkpoint` as
v2 (classic) experiments that are NOT available (12543016) — one-line v2
note, not pursued.

### 3d. `_kiro/checkpoint/revertMultiple` — in-place rewind (unadvertised)

Registered unconditionally in `capabilityHandlers` (KAS 485183) but ABSENT
from the advertised `extensionMethods` — the handshake advertisement for this
pair is the boolean `checkpoints: true` (KAS 485130). Same
registered-but-unadvertised pattern as the workflow methods; names must be
hardcoded by the client. Classified `sessionForwarded` for relayed sessions
(KAS 466178ff) and persisted as `metadata` records (KAS 463091ff).

`handleRevertToMessage(params)` (KAS 489840-489891):

| aspect | behavior |
| --- | --- |
| params | `{ sessionId, messageId }`, both required (`InvalidParamsError`) |
| residency | session must be RESIDENT in-process (`SessionNotFoundError`) — unlike fork, no cold path |
| guards | active turn (`session.abortController`) → `CheckpointRevertError` "Cannot revert while the agent is still running…"; concurrent revert → "A revert is already in progress…" via `revertInProgressSessions` set |
| response | `{ success, affectedFiles: string[], totalFiles: number, error? }` |

Core `revertToMessage` (src/session/checkpoint-revert.ts, KAS 325191-325285):

1. Target must be an effective **user** message (revert view = raw messages
   with prior checkpoint tombstones applied). Not found / not user → soft
   failure `{success:false, error}`.
2. Discard set = `revertView.slice(targetIndex)` — the target user message
   and everything after. **Edge asymmetry vs fork**: same `messageId` keeps
   the turn on fork but discards it on revert (you re-type the prompt).
3. Discarded set is expanded through sub-executions (recursive BFS,
   KAS 325086-325113), sorted chronologically, and `detectFileChanges`
   (KAS 325293-325352) computes restore actions per first-touched path:
   - multi-file tools: `tool_result._meta.kiro.checkpoint.fileChanges[]`
     (`{file, original, modified}`, schema KAS 22161-22171);
   - single-file: pre-change snapshot from
     `tool_result._meta.kiro.checkpoint.original` (a `kiro-snapshot://` URI);
   - `create` → delete the file; `move` → restore source AND delete
     destination; `delete|write|fs_write|edit_code|append|replace` → restore
     from pre-snapshot; no pre-snapshot → warn + skip (lenient).
4. Files restored via the session's fs; then ONE tombstone appended to
   `messages.jsonl`:
   `{type:"tombstone", kind:"checkpoint_revert", effectiveFromMessageId: messageId, metadata:{affectedFiles, totalFiles}}`
   (kinds enum: `checkpoint_revert | summarization`, KAS 22384-22389). The
   raw transcript is append-only — revert is logically destructive,
   physically non-destructive.
5. `materializeForAgent` (stack-walk pop to `effectiveFromMessageId`;
   unknown target → warn + skip) rebuilds the effective view; the agent
   context is rebuilt from it; if no effective user prompt remains,
   `hasReceivedPrompt` resets and the title returns to default. The handler
   comment names the intended caller: "The extension then calls
   loadSession() to replay the truncated conversation" — the IDE, not the
   TUI.
6. Repeated reverts stack; `session/load` replay (message-replay.ts imports
   the same materializer, KAS 439320) never replays reverted-away turns.

### 3e. `_kiro/checkpoint/revert` — single-file undo

`handleRevertCheckpoint` (KAS 489717-489806): params
`{ sessionId, filePath (required), snapshotUri?, toolCallId? }`.
`snapshotUri` present → parse (`kiro-snapshot://` with snapshotId +
originalPath, src/acp/snapshot-uri.ts) → restore content. Absent → only a
`create` action (looked up by `toolCallId` in persisted messages, expanded
through sub-executions) may be undone by deleting the file; anything else →
`CheckpointRevertError` "no snapshot is available…". Emits a
`tool_call_update` with `_meta.kiro.reverted: true`, appends
`{type:"tool_revert", toolCallId}` + an `agent_note` message, and records the
path in `session.revertedFilePaths`. Transcript is NOT truncated — this is
file-undo only.

### 3f. Snapshot capture (what makes revert and fork-copy possible)

- `ACPCheckpointProvider` is wired **unconditionally** at session setup
  (KAS 459695) — no feature flag, no client capability gate found.
- Capture point: `writeFileWithStreaming` takes a PRE and POST
  `checkpointFile` around every streaming file write unless the caller sets
  `skipCheckpointing` (KAS 353877-353913); tool paths also checkpoint via
  `workspace.checkpointFile` (KAS 117846-117860, 423578, 458811).
- Store: `snapshotFile` (KAS 470133-470165) —
  `<session>/snapshots/<8-char-id>/<relativePath>` + `.hash` file; sha256
  content-hash dedup across snapshots in the session.
- The pre/post URIs land on the persisted `tool_result` message at
  `_meta.kiro.checkpoint` (`original`/`modified`/`local`/`fileChanges`,
  KiroPersistedMetaSchema KAS 22158-22171). The `tool_call` schema's
  `preSnapshotId`/`postSnapshotId` fields (KAS 22287-22288) are what FORK's
  snapshot collection reads — KAS itself was not observed writing them
  (flagged, section: flagged claims).

## 4. Activation drivers

| lever | user-typed | skill | agent-sys-prompt | model-elected | hook | workflow-step | external ACP client |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `/rewind` (fork+switch) | YES (TUI) | no | no | no | no | no | n/a (TUI construct) |
| `session/fork` | via /rewind only | no | no | **NO** | no | no | **YES** |
| `_kiro/checkpoint/revertMultiple` | no TUI path | no | no | **NO** | no | no | **YES** (IDE is one) |
| `_kiro/checkpoint/revert` | no TUI path | no | no | **NO** | no | no | **YES** |
| snapshot capture | automatic | — | — | model writes trigger it as a side effect | — | file writes in step sessions too | automatic |

Model-elected: **NO** — bounded negative. No tool registration named any of
`revert_checkpoint`, `checkpoint_revert_tool`, `rewind_session`,
`fork_session`, `restore_checkpoint`, `restore_snapshot`, `undo_changes`
(0 hits each) with positive controls `fs_write` (85), `execute_bash` (38),
`validate_workflow` (5) by the same `grep -coF` method. The only model-visible
"rewind" text is user-directed prose: `REFUSAL_FALLBACK_CLI` ("… rewind with
/rewind …", KAS 463405) and an introspection prompt listing `/rewind` as a
slash command (KAS 119798) — and slash commands inside prompt text are inert
(settled Mode-F recon fact). Hooks cannot reach it: v3 hooks are spawned
processes with a stdout/stderr contract, no ACP channel (corpus
hooks-io-contract). Workflow steps have no fork primitive; the workflow
methods namespace (`_kiro/workflow/*`) contains nothing fork-shaped.

**Verdict on the design idea:** the model CANNOT self-fork at 2.15.1 — the
"model forks a branch, does expensive work, folds back a lean result" design
is dead as a model-elected mechanic. It survives only as an
external-orchestrator pattern: an ACP client can `session/fork` (cheap disk
op, no model call), drive the fork with `session/prompt`, harvest the result
(response text, `_kiro/session/export`, or the fork's `messages.jsonl`),
`_kiro/session/delete` the fork, and inject the distilled result into the
parent as a new user/steer message. Nothing flows back automatically —
`parentSessionId` is lineage metadata only; bounded negative on merge-back:
`mergeSession`, `foldBack`, `mergeFork`, `joinSession`, `adoptMessages`,
`importMessages` all 0 hits (positive controls as above).

## 5. Fixture design (no model calls anywhere)

All three fixtures ride the replayable ACP probe from the argv doc
(placeholder token answers `_kiro/auth/getAccessToken`; `initialize` →
optional `session/new` — never `session/prompt`).

**F12-a fork mechanics** (cheapest; settles 3b): seed a schema-valid session
on disk (corpus seeding recipe) whose `messages.jsonl` has ≥2 user turns,
one `tool_call` carrying `preSnapshotId: "aaaaaaaa"` plus a matching
`snapshots/aaaaaaaa/f.txt` + `.hash`, and one `sub_agent_start` whose
`sub-executions/<id>.jsonl` itself references a second sub-execution. Then
over ACP send `session/fork` variants:

1. no `messageId` → expect new `sess_*` dir whose `messages.jsonl` equals
   the parent's effective transcript;
2. `messageId` = first USER message id → expect the copy to INCLUDE that
   user message and its assistant block, exclude the second turn
   (turn-completion rule discriminator);
3. `messageId` = unknown → JSON-RPC error mapping `MESSAGE_NOT_FOUND`;
4. fork of a fresh `session/new` with zero prompts → discriminates whether
   the `session_start` artifact counts as an effective message
   (`NO_FORK_POINT` vs success) — currently unknown;
5. assert `session.json`: `parentSessionId`, `createdReason` echo, title
   `Fork of …`, and ABSENCE of `modelId`/`effortLevel` even when the parent
   has them;
6. assert `snapshots/aaaaaaaa/` copied, depth-1 sub-execution file copied,
   depth-2 file NOT copied (settles the no-recursion inference);
7. fork with `cwd` = a second directory → fork lands in that directory's
   workspace-hash bucket.

Pass/fail observable in every case: a file assertion or the JSON-RPC
response — zero credits.

**F12-b revertMultiple**: same seed + real workspace file matching the
snapshot's `relativePath`, with `tool_result._meta.kiro.checkpoint.original`
set to the seeded `kiro-snapshot://` URI. `initialize` → `session/load` (the
handler needs residency) → `_kiro/checkpoint/revertMultiple {sessionId, messageId:<user2>}`.
Observables: response `affectedFiles`, file content restored on disk,
tombstone appended as last `messages.jsonl` line, raw earlier lines intact.
Negative arms: revert an assistant messageId (soft failure "is not a user
message"), revert with no matching snapshot (warn + skip, file untouched).

**F12-c TUI mapping** (SPEC only — needs the TUI, hence a live engine): type
`/rewind` with two turns of history; expected observables: fork session dir
appears, TUI status shows "Loading rewound session...", parent dir
unmodified, NO file content change. Requires real turns → model credits →
spec, not run.

## 6. Cross-interactions

- **Compaction shares the tombstone machinery**: `summarization` tombstones
  collapse via the same stack-walk (`collapseSummaries`), and
  `materializeForAgent` = reverts-then-summaries. Fork therefore copies the
  post-compaction view — a fork taken after heavy compaction inherits the
  summary, not the original turns; a revert whose target was compacted away
  soft-fails ("not found" path).
- **Fork resets tuning**: dropped `modelId`/`effortLevel`/`autopilot`/
  `semanticReviewEnabled`/`ftaEnabled`/workflow enablement mean a rewound
  session silently reverts to defaults for everything except mode; only
  `modeId`/`title` are re-settable at fork time. A client that wants parity
  must re-apply settings on the fork after load.
- **`chat.enableCheckpoint` / `chat.enableTangentMode` appear unconsumed in
  KAS** (C-11 pattern): both resolve into feature records
  (`checkpoint`, `tangentMode`) but no reader of the resolved key was found
  (methods: `settings.checkpoint` / `features.checkpoint` /
  `isEnabled("checkpoint")` grep variants all 0; the only quoted
  `"checkpoint"` literals are an error string and langgraph debug, KAS
  117852, 316789, 317476). Snapshot capture and both revert handlers are
  gated by NOTHING session-level. Absence rests on grep; flagged.
- **Cloud/relayed sessions**: fork refused agent-side
  (`RemoteSessionUnsupportedError`) AND blocked TUI-side; the checkpoint
  pair instead FORWARDS to the sandbox (`sessionForwarded`, KAS 466178).
- **Concurrent-turn hazard**: revert refuses while a turn runs; fork does
  not — an external client can fork mid-turn and get a prefix that ends
  inside an unfinished turn (in-flight persisted state captured via the
  message store).
- **Eviction**: forks are ordinary sessions; each fork duplicates message +
  snapshot bytes (snapshot dedup is per-session only), so a rewind-heavy
  workflow inflates the eviction budget's numerator and can push old
  sessions out.
- **`createdReason` is shared with `session/new`** — filtering session lists
  by `createdReason:"rewind"` finds rewind forks, but `"subagent"` /
  `"human"` tags arrive via plain creates too; `parentSessionId` (fork +
  metadata only) is the reliable lineage edge, distinct from the
  known-broken `parentExecutionId` (corpus).
- **Tangent**: `createdReason:"tangent"` + `titleSetByUser` special-case
  exist agent-side, but the v3 TUI ships no `/tangent` (classic-mode
  experiment, dropped) — tangent forks are an IDE-client surface at this
  version.
