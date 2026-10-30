<!-- cspell:words rrggbb -->

# Kiro usage calibration evidence

This collector records selected Kiro application request and response bodies in
a separate, private SQLite database. It has no Airlock database or code
dependency. Capturing is opt-in; installation does not launch Kiro, make
provider calls, or change certificate trust.

Full payloads can contain prompts, repository content, tool inputs and results,
reasoning, identifiers, and other user data. Keep the database outside source
checkouts, synchronization folders, and shared storage. The parent directory
must belong to the current user with mode `0700`; the database is created with
mode `0600`. Existing permissive paths and symlinks are rejected. The database
is unencrypted. Protect backups and replay output accordingly.

## Run the addon

Use an existing, explicitly configured mitmproxy installation and certificate
trust setup. The addon does not install a CA, alter proxy environment variables,
or configure Kiro itself:

```bash
export KIRO_USAGE_DB="$HOME/.local/state/kiro-usage/capture.sqlite3"
export KIRO_USAGE_WARN_BYTES=1073741824
mitmdump -s /absolute/path/to/usage/mitm_addon.py --listen-host 127.0.0.1 --listen-port 8080 --set flow_detail=0
```

`KIRO_USAGE_DB` is required. `KIRO_USAGE_WARN_BYTES` defaults to 1 GiB of
retained payload evidence, counting request BLOBs, entity and application
chunks, event frames and parsed event JSON, and retained usage summaries.
Payloads are always retained: past the threshold the running collector logs one
warning line to standard error and keeps capturing, and captures are not marked
incomplete for it. Each tracked `kiro-usage exec` summary repeats the warning
with the store's size while it stays above the threshold. Existing evidence is
never rolled over or deleted. On restart the retained bytes are counted again.
This counts payloads, not the SQLite file size: indexes, metadata, page
overhead, and accumulated records also consume disk. Temporary SQLite journal
space is additional. Stopping capture and deleting an intentionally retired
private database are operator decisions: stop the service, then archive or
delete `usage.sqlite3` with its `-wal` and `-shm` files; the next start creates
a new store.

Only hosts equal to `kiro.dev` or ending in `.kiro.dev` are considered.
Lookalikes such as `not-kiro.dev` are excluded. Two calls are selected: the
exact path `/v1/responses` (CreateResponse REST, root turns), and
GenerateAssistantResponse (workflow steps, subagents, session titles). The
latter is AWS JSON 1.0 RPC: Kiro sends it as path `/` with the header
`x-amz-target: KiroRuntimeService.GenerateAssistantResponse`. The schema's REST
path `/generateAssistantResponse` is never sent. A request to `/` is selected
only for POST with that header equal to this value exactly, so other
KiroRuntimeService operations on `/` pass through uncaptured. Its response is
always decoded as an AWS event stream, as Kiro's client does, whatever content
type the server labels it with. Query strings are discarded. The addon stores
only the host, method, constant path, the `x-amz-target` value for selected RPC
calls (as `target`), request content encoding, response status, response content
type and encoding, and the upstream `x-amzn-requestid` / `x-request-id`. It
never serializes arbitrary headers, cookies, authorization, or URLs. Full
**bodies** are deliberately retained and may themselves contain secrets.

The response streaming callback returns the same bytes, including the EOF
sentinel, once it has decoded and framed that chunk; it never waits for SQLite.
That synchronous work grows with the chunk: one structurally dense 4 MB event
took about 0.9 s. Usage, completion, and output counts see every response byte;
only the payload copy is queued, and a chunk's event copies stop being staged
the moment they would overflow the queue, so a chunk of many tiny frames holds
no more than the queue budget in copies. One worker writes the database. Its
queue holds at most 40 MiB, charging each item and event 512 bytes of object
overhead beyond its payload: one 32 MiB request (the API limit) plus 8 MiB of
streaming headroom. The worker takes up to 512 queued items or 4 MiB per write
transaction, adding an item only if the batch stays within 4 MiB; an item larger
than that, such as a 32 MiB request, is a batch of its own. It compresses a
batch before taking the write lock; that batch stays charged until it commits,
plus one compressed copy of it in flight. A full queue logs a warning, omits
that payload copy, and records `request_payload_omitted` or
`response_payload_omitted` with the dropped byte/item counters. Omissions leave
usage complete; replay of the omitted bytes fails. Per-capture parser state
keeps its own limits below. At most 256 captures can be active; exceeding that
limit rejects only the new request with HTTP 503. An invalid selected request
content encoding receives HTTP 400. Both refusals leave the collector available
for subsequent healthy requests. A fatal writer failure logs an explicit warning
and marks existing recording rows incomplete when the database remains writable.
Otherwise they remain recording, never complete. Existing response streams
continue returning unchanged bytes; further selected requests receive a local
HTTP 503 until the collector restarts. If the database cannot be opened or
initialization fails, the addon stays installed, logs a startup failure, and
refuses selected requests with HTTP 503 until configuration is fixed and the
collector restarts. Other traffic remains outside capture.

Connections use SQLite WAL with `synchronous=NORMAL` and a 30-second busy
timeout. An ordinary commit does not fsync; the commit that triggers an
automatic WAL checkpoint (every 1,000 WAL pages by default) does, so an
occasional commit still waits for the disk. A power loss or OS crash can drop
the most recent commits but cannot corrupt the database: a recent capture can
revert to `recording`, which restart marks `interrupted_capture`, or disappear.
Payload BLOBs use gzip level 6: level 9 cost 1.8 times the CPU for 0.3% smaller
synthetic requests, and level 1 grew them 16%. Decompression is the same for
every level, so older BLOBs replay unchanged. Stream parsing happens in the
callback; the worker changes parser state only at finalization, after taking the
write lock, so transient contention waits without replaying stream events.
Offline indexing parses outside write transactions and commits batches of at
most 128 records, ending once 256 KiB of source lines is reached (the final
complete record may cross that threshold), with each batch's checkpoint offset
committed atomically. JSONL records up to 64 MiB are parsed transiently, so
image-bearing tool results can be ignored without retaining their contents in
the index. Larger complete records are drained in 64 KiB chunks. Oversized or
invalid complete records, including parse memory failures, do not stop indexing:
`disk_omissions` retains only their source path, byte offset, byte count, and
reason. Blank complete lines are ignored. Their usage coverage remains unknown;
index summaries and selected-session queries warn that totals may be incomplete.
Incomplete EOF tails, including oversized tails, are retried after an append
without advancing the checkpoint. Source replacement or truncation retires both
facts and omission metadata. A database write failure rolls back the batch and
its checkpoint; previously committed batches remain available. Session metadata
retains a separate 4 MiB parsing limit. Malformed, oversized, or unreadable
`session.json` files are isolated per session: indexing continues through
messages and later sessions, while `disk_session_omissions` records the omitted
metadata and stale metadata is retired. Successfully re-indexing repaired
metadata clears its omission. Queries report the global metadata omission count
because unknown ancestry can hide descendants; older indexes without tracking
show an unknown count. The index CLI's `omitted_records` count includes both
JSONL record and session metadata omissions.

Request metadata and fingerprints are extracted once, on the request hook,
before payload queue admission. This adds bounded request-side parsing and
hashing work. The request extraction limit is 32 MiB. Above that limit
`request_metadata_limit` marks the capture incomplete and session attribution
remains unknown. Per-item fingerprints retain at most 4096 input items, with
`fingerprint_item_limit` signaling any omitted item hashes; the whole input
component hash is retained. Malformed JSON, strings that cannot encode as UTF-8,
and JSON nesting beyond 128 levels produce fixed extraction issue categories,
preserve available raw payloads, and allow later captures to proceed. Session
queries report `global_unattributed_observations` so captures lacking a
conversation ID remain visible in coverage.

## Evidence and extraction

`capture_meta` versions the collector schema. `captures`, `chunks`, and `events`
are independent of any other application database. Additional tables, including
the offline indexer's `disk_*` tables, are preserved. One advisory lock prevents
concurrent collector writers to the same database; an independent indexer can
still write its own tables. Indexers serialize on a second owner-only lock file,
`<db>.index.lock`: the explicit full pass takes it exclusively and waits, and a
tracked launch's exit refresh takes it shared without waiting, skipping with a
warning only during a full pass. Exit refreshes then queue on a third,
`<db>.refresh.lock`, taken exclusively and waiting: `index_messages` reads a
source's offset before its write transaction, so two concurrent refreshes of one
session would insert the same records.

- `captures.request_gzip` preserves the complete decompressed application
  request bytes. Its full SHA-256 is over those exact bytes. Component hashes
  use sorted, compact UTF-8 JSON for `input`, individual input items,
  `instructions`, `reasoning`, and `tools`; GenerateAssistantResponse requests
  (chosen by the selected target, not by body shape) instead hash
  `conversationState.currentMessage`, `history`, individual history items,
  top-level `systemPrompt`, and the current message's
  `userInputMessageContext.tools`. Prefix hashes cover the first 4096, 16384,
  32768, and 49152 application bytes when present. These hashes describe content
  stability; they do not prove provider cache hits.
- `chunks` preserves ordered incoming response entity bytes in `entity_gzip`,
  and the decoded application bytes in `application_gzip`. Each gzip BLOB can be
  decompressed independently; concatenate in `seq` order. Entity bytes still
  carry the upstream content encoding; application bytes do not. UTC and
  monotonic observation timestamps are nanoseconds, recorded before queueing.
  Monotonic timestamps are comparable within the same collector process, not
  across process restarts. SSE bodies are never assembled in a single buffer;
  non-SSE JSON has a bounded parsing buffer.
- Identity, gzip, and zlib-wrapped deflate responses are decoded for extraction.
  Unsupported encodings retain entity bytes and mark extraction incomplete.
  Truncated or invalid compressed streams, trailing compressed members, and
  decoded chunks larger than 16 MiB are flagged. The original encoded bytes
  remain available unless the queue omitted their copy.
- `events` keeps ordered SSE frames, exact frame bytes, parsed JSON including
  unknown fields, the associated chunk sequence, and the chunk's observation
  timestamps. SSE comments, CR/LF/CRLF, multiline data, split frames, and split
  UTF-8 characters are handled. EOF without a blank dispatch delimiter retains
  the final partial frame and marks it unterminated. Events larger than 4 MiB
  stop extraction with an explicit issue; their raw response chunks remain
  available. Non-SSE JSON extraction has the same 4 MiB limit.
- AWS event-stream responses (`application/vnd.amazon.eventstream`) are framed
  incrementally across chunk boundaries. Each message keeps its exact bytes, its
  `:event-type` (or `:exception-type`) as `event_name`, and its parsed JSON
  payload. Prelude and message CRC32 mismatches mark `event_stream_crc`;
  malformed lengths or headers mark `invalid_event_frame`. A valid prelude
  supplies the next boundary; an invalid one stops extraction, keeping its 12
  prelude bytes as the event and the rest in raw chunks. Messages larger than 4
  MiB stop extraction with `event_parse_limit`, and an EOF tail is retained as
  an `unterminated_event`.
- Request model, reasoning effort, conversation ID, continuation ID, and an
  explicit allowlist of session/execution/agent lineage IDs are retained in
  `metadata_json`. For GenerateAssistantResponse, model is
  `conversationState.currentMessage.userInputMessage.modelId`, effort is
  `additionalModelRequestFields.output_config.effort` or `.reasoning.effort`,
  and `kiro:conversation_id` / `kiro:root_conversation_id` are
  `conversationState.conversationId` / `rootConversationId`. They are
  observations. No own-versus-delegate relationship is inferred from similar
  IDs.
- `summary_json` includes exact usage objects when observed, an explicit empty
  `estimates` object, terminal status, and output-text byte and character
  counts. Counts use terminal `output_text` parts when available and otherwise
  observed text deltas, avoiding double counting. Reasoning and tool payloads
  are excluded from the text count; `tool_chars` and `reasoning_chars` count
  them live (see [Token estimates](#token-estimates)). Usage summary memory is
  limited to 1 MiB per capture; an omission is flagged, while events and chunks
  retain their independent evidence unless the queue omitted their copy.

`credits` comes from the `value` in the observed `kiro:credits` envelope, for
example `{"unit":"credit","unit_plural":"credits","value":0.25}`. Extraction
requires `unit="credit"` and a finite, nonnegative numeric `value`; an invalid
or missing unit leaves `credits` as `NULL` and marks `invalid_credit_unit`.
`unit_plural` is retained as evidence. A scalar credit field is invalid.
`context_usage_percentage` comes from the observed scalar
`kiro:context_usage_percentage` field. Exact `input_tokens`, `output_tokens`,
and `input_tokens_details.cached_tokens` are extracted only if explicitly
supplied in a usage object; absent counters remain SQL `NULL`.
GenerateAssistantResponse event streams map `meteringEvent.usage` (with
`unit="credit"`, otherwise `invalid_credit_unit`) to `credits`,
`contextUsageEvent.contextUsagePercentage` to `context_usage_percentage`, and
`metadataEvent.tokenUsage` `outputTokens`, `cacheReadInputTokens`, and
`cacheWriteInputTokens` to the matching columns. To keep cached reads a subset
of input, as on `/v1/responses`, `input_tokens` is the sum of
`uncachedInputTokens`, `cacheReadInputTokens`, and `cacheWriteInputTokens` only
when all three are reported; otherwise it stays `NULL`. A stream carrying more
than one `meteringEvent` keeps the last value in `credits` and records the count
as `summary_json.metering_events`. The count is an observation, not an issue, so
it neither makes the capture incomplete nor removes it from estimates or the
discount diagnostic. Session reports warn when a selected call carried more than
one, because the last value may not be the call's total charge. Output text
counts come from `assistantResponseEvent.content`, and the last
`metadataEvent.stopReason` is the summary `terminal`. Token counters must be
integers from zero through `2**63 - 1`; observed credits and context percentages
are normalized to finite floating-point values. Invalid numeric fields become
`NULL` and mark `invalid_usage_number`; their original payload evidence is
preserved. Capture stores no token estimate, cache split, or context-window
conversion; reports derive `~` estimates at query time. `cache_write_tokens` is
known only from a reported `cacheWriteInputTokens`; `/v1/responses` captures
leave it unknown. The original usage objects are available for later extraction
improvements.

`state='complete'` requires transport completion, a `response.completed` event
(or completed JSON response), and no recorded issue besides
`request_payload_omitted` and `response_payload_omitted`. Event streams have no
terminal event: completion is end of stream on a message boundary after at least
one message, with no exception or error message and no framing, decoding, or
byte-gap failure; an exception message sets `terminal` to `exception`.
`response.failed`, incomplete responses, transport errors/cancellation, missing
completion, and extraction limits remain incomplete; queue omissions of payload
copies alone do not. A process interrupted before finalization leaves a
`recording` row; the next collector startup marks it `incomplete` with
`interrupted_capture`. Initial metadata is persisted before completion. Partial
rows must not be treated as zero usage. `observed_chunks` / `observed_bytes`
describe response callbacks; dropped counters include refused request and
response payload items. Omitted event/summary evidence is also signaled in
`issues_json`. A full observed response hash can exist even when storage is
incomplete. `state` describes usage; payload omission flags, nullable BLOBs, and
chunk rows short of `observed_chunks` describe replay completeness.

## Token estimates

Reports fill counters a call lacks with `~` estimates; reported counters always
win per call, and a group mixing both sums exact and estimated values with
(known/all) coverage. For a call with a reported context percentage `p` and a
model with a known window `W`:

- total `I = p/100 * W`, which includes output tokens once;
- output `O = chars / chars_per_token`, the model's fitted ratio in `rates.json`
  or 4 without one, where chars counts `output_text` plus streamed
  `response.function_call_arguments.delta` and `response.reasoning_text.delta`
  deltas, or GenerateAssistantResponse `toolUseEvent.input` and
  `reasoningContentEvent.text`, so tool-only calls are not `O=0`; a capture with
  no function-call (or reasoning-text) deltas instead counts its terminal
  `response.completed` `function_call.arguments` (or `reasoning` item
  `reasoning_text` content), so neither source is counted twice;
- input `I - O`.

Windows come from `models.json`, a committed snapshot of the free
`kiro-cli chat --list-models --format json` listing (context window and rate
multiplier per model, plus the `kiro-cli --version` that printed it). Router ids
(`auto`) are listed but get no window, since their real model is unknown;
unlisted names such as `simple-task` have none either. Refresh the snapshot from
a checkout with `python3 packages/kiro-cli/usage/calibration.py models`.

When a call reports exact output or input but not every counter, those exact
values replace `O` or `I - O` below, so an estimated cached split never exceeds
the call's exact input.

Cached tokens need reported credits, a known or estimated `O`, and the model's
`rates.json` entry from `calibration.py fit --write` (see
[Run the calibration experiment](../docs/usage-tracking.md#run-the-calibration-experiment)):
`cached = clamp((a*(I-O-K) + o*O + c - credits) / (a - b), 0, I - O - K)`, with
full-miss and full-hit input rates `a` (`miss_input`) and `b` (`hit_input`),
output rate `o` (`output`), fixed cost `c` (`fixed_per_call`) and `K` tokens
that context % counts but the model does not bill (`unbilled_tokens`, 0 unless
fitted). Models with a window but no rates get total, input and output estimates
and no cache split; calls without a context percentage or a known window stay
unavailable. Digit-heavy text reads too few tokens (390 where chars/4 reads
173), and hidden thinking that context % counts but no streamed characters show
is priced as input, so both understate cached. An estimated split counts as a
hit only when cached reaches 1% of input, which keeps fit noise (tens of tokens
on the 1–5 character calibration calls) out of the hit percentage. The collector
counts tool and reasoning characters live, by the same rule, into `summary_json`
`tool_chars` and `reasoning_chars`, so omitted payload copies do not lower `O`.
Captures finalized before those counts existed, and interrupted captures, which
have no summary, fall back to counting retained events; an omitted copy there
still lowers `O`.

## Experimental credit-discount diagnostic

The initial ten-call calibration supports a narrow credit-price diagnostic, not
validated cache-hit detection. Profile `opus-5.5-low-text1to5-context-v1`
requires model `claude-opus-5.5`, effort `low`, retained complete captures, a
completed terminal event proving text-only output of 1–5 characters, no observed
reasoning/tool output, and reported context between 0.87679994% and 3.6423001%.
The curves consume context percent directly: baseline `(74*p + 0.5034)/603`,
discounted `(20*p + 0.5970)/603`. The 0.000001-credit tolerance is numerical,
not a statistical confidence interval. Scores and residuals remain unclamped;
values outside the curve envelope are anomalies.

Five of eight eligible initial calls were discount-like (~62.5%), a band that
includes partial discounts rather than only fully discounted requests; three
were baseline and two longer-output cases were excluded. Cold/warm/delayed
requests had matching delivered context, hooks, and tools after metadata
removal. That comparison does not prove provider caching, establish percentile
accuracy, or validate character-to-token conversion. Token and cached-token
counters stay unknown unless reported. `Discount %` appears separately from the
counter-derived `Hit %`, with classified/all-request coverage and
exclusion/anomaly counts. Structured `credit_discount` objects retain the
profile, assumptions, reasons, and numeric diagnostics per total, model, and
conversation group. No context-window assumption or extrapolation is applied.

## Offline inspection and replay

These commands use only Python's standard library and open the database
read-only:

```bash
python /absolute/path/to/usage/capture.py --db /private/capture.sqlite3 list
python /absolute/path/to/usage/capture.py --db /private/capture.sqlite3 list --json
python /absolute/path/to/usage/capture.py --db /private/capture.sqlite3 replay CAPTURE_ID
python /absolute/path/to/usage/capture.py --db /private/capture.sqlite3 replay CAPTURE_ID --entity
```

Session queries (`query.py --db DB --session sess_ID`) and capture lists show
human-readable tables by default. Existing scripts must add `--json` to retain
the full session JSON report or capture JSON lines. Unknown counters display as
an em dash; observed zeroes remain zero. Session reports keep disk and capture
sums separate and show coverage; warnings use standard error. The indexer also
accepts `--json` for its source, record, and omission counts.

The managed `kiro-usage exec kiro-cli` and `kiro-usage exec kiro-cli-chat`
commands also print a short summary to standard error after Kiro exits: per root
session, a headline with its request count and credits, a model table of
requests, credits to two decimals, rounded input, output and cached token counts
and cache-hit share sorted by credits, and a conversation table splitting the
main conversation from subagents and workflows. One `⚠` line appears only when
totals are suspect: capture unavailable, unknown credits, incomplete or
unfinished calls, calls without a conversation identity, duplicate request IDs,
or calls with several metering events. `kiro-usage session` keeps the full
report. A local proxy marker links the invocation's captures to their recorded
session identities. Kiro uses inherited terminal input and output directly; no
screen parsing or process-ID guess selects the session. Standard output, exit
status, and signals are preserved. Tracked chat runs as a child of the summary
supervisor, retaining the terminal descriptors with its own process ID. Explicit
help, version, login, and administrative commands skip the summary, including
after recognized global options. Other commands have no automatic Kiro summary.

`ai.kiro.cli.usageTracking.summary` styles that summary: the module writes it to
a JSON file and passes it to the runtime's `cli --summary-theme FILE`. Every key
is optional, and with no theme the summary stays plain text:

- `border`: `none` (default), `ascii`, `double`, `heavy`, `rounded` or `single`
  draws one box around the summary; the conversation table's dash rule becomes a
  junction line such as `├──┤`.
- `color`: `auto` (default) styles only when standard error is a terminal and
  `NO_COLOR` is unset or empty; `always` or `never` force it.
- `icons`: `true` prefixes the headline with Nerd Font U+F080 and replaces `⚠`
  with U+F071.
- `styles`: element name to style spec. Elements: `border`, `cached` (Cached
  column), `credits`, `estimate` (every cell carrying `~`, so Cache hit always),
  `header`, `headline`, `label` (conversation row labels), `model`, `muted` (`—`
  cells), `number`, `rule` (the unboxed dash rule), `total` (the Total row,
  under each cell's own style) and `warning` (the `⚠` line). With color on,
  unset elements keep the defaults: bold `header`, `headline` and `total`, dim
  `estimate` and `muted`, yellow `warning`; `""` clears one.

A spec is space-separated tokens: `bold`, `dim`, `italic`, `reverse`,
`underline`, a palette color (`black`, `red`, `green`, `yellow`, `blue`,
`magenta`, `cyan`, `white`, or `bright-` before one), `#rrggbb` for a 24-bit
foreground, and `on-` before a color or `#rrggbb` for a background. Palette
colors follow the terminal's own scheme. An unknown key, value, element or token
makes the summary report itself unavailable, naming it. Widths come from the
plain text, so styles never shift the columns. The Nix option
`ai.kiro.cli.usageTracking.summary` writes this file:

```nix
ai.kiro.cli.usageTracking.summary = {
  border = "rounded";
  icons = true;
  styles = {
    border = "bright-black";
    total = "bold #ffaf00";
  };
};
```

These are full root-linked session totals and can include earlier work from a
resumed session. Explicit root conversation IDs include related captures without
requiring an on-disk index. Root-linked lineage may include forks as well as
subagents. Captured requests and credits are counted once; disk credits never
enter the total. The exit summary has a model table and a conversation table
with the same columns, where In includes Cached. Its Main row is the pool whose
conversation ID matches the selected root ID; Sub/WF is every other linked
conversation; Total closes the table below a rule; an Unknown row, for calls
lacking a conversation ID, appears only when nonzero. The partition does not
prove caller roles: workflow steps and subagents carry their own conversation
IDs and land in other linked conversations, which may also include helpers or
forks. Requests, credits, and tokens are grouped by model and pool rather than
listing individual delegates. Exact counters are used when observed; cells that
add estimates for calls lacking the exact counter carry `~`, and missing values
show an em dash (see [Token estimates](#token-estimates)). Hit percentage is
cache-hit requests divided by requests with a reported or estimated cached
value, where an estimated split counts as a hit only at 1% of input or more. The
full report (`kiro-usage session` or `query`) keeps the Root conversation, Other
linked, and Unknown pool tables and the partial-coverage markers. No captured
conversation identity means an explicit unavailable summary. Before reporting,
the outer launch incrementally indexes `~/.kiro/sessions` if present, using the
existing database and checkpoints. It reads the `session.json` of sessions whose
`session.json` or `messages.jsonl` changed since the launch, and messages only
for those linked to captures (less one second for coarse file timestamps) and
never prunes; already indexed sessions still link their new descendants. The
explicit `index` command is the full capture-scoped pass: it prunes `disk_*`
rows for sessions no longer linked to captures and runs `VACUUM` plus a WAL
checkpoint when free pages remain. Lineage comes from `parentSessionId`,
`rootSessionId`, `rootConversationId`, and
`_meta.kiro.serverSession.ownerSessionId`; the serverSession `role` and workflow
`workflowId` and `nodeId` are retained as identifiers. Index failures warn
without replacing the child exit status, and disk observations may then be
stale; so does a running explicit `index` pass, which the exit refresh skips
rather than interleaving with. Manual session queries use the last completed
index. Before that refresh, which is scoped by persisted captures, the exit path
waits at most two seconds for this launch's captured calls to finish and stay
unchanged for 0.1 s. That quiet period is a heuristic, not a writer
acknowledgement: a call started within a moment of Kiro exiting can persist
after it. A timed-out wait flags unfinished calls in the summary, even if they
finish during the refresh, and reports disk observations as not refreshed.
Nested `kiro-usage exec` launches reuse the parent's marker; only the outer
launch prints the summary.

Replay writes private response bytes to standard output. Incomplete captures
produce a warning; a missing requested payload, including a chunk omitted from
the queue or a capture interrupted before its chunk count was recorded, exits
with an error. Replay of available partial bytes can precede that error, so
callers must check the exit status. Request evidence can be read with
`gzip.decompress` on `captures.request_gzip` through a read-only SQLite
connection.

Persisted session `usage_summary.requestIds` can join the captured upstream
request IDs to turns; `metadata_json["kiro:conversation_id"]` can join the
session directory ID. Turn credits are sums across model calls and can include
delegates. Per-call context percentages do not supply exact input tokens.
Session model metadata can describe a later model selection; prefer the captured
request model for a captured call. A shared conversation ID alone does not
establish whether a request is the parent or a delegate. Missing lineage must
stay unknown.

Run the synthetic offline suite without mitmproxy or provider credentials:

```bash
python -m unittest discover -s packages/kiro-cli/usage -p 'test_*.py' -v
```

The suite uses small temporary fixtures and removes them afterward. It does not
read real transcripts, databases, logs, captured payloads, or credentials.
Fake-flow contracts validate the addon boundary and streaming behavior. The
`kiro-usage-mitm-transport` Nix check also runs the pinned mitmproxy against a
loopback fake upstream, checking immediate first-byte delivery, exact compressed
payloads and SQLite replay for an SSE `/v1/responses` call and an AWS
event-stream GenerateAssistantResponse RPC call (`POST /` with its
`x-amz-target`), including the latter's credits, context, token columns and
stored events, and that a `POST /` with another target is not captured. Live
Kiro and TLS interception remain untested.
