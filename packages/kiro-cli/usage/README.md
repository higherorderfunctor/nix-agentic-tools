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
export KIRO_USAGE_MAX_BYTES=268435456
mitmdump -s /absolute/path/to/usage/mitm_addon.py --listen-host 127.0.0.1 --listen-port 8080 --set flow_detail=0
```

`KIRO_USAGE_DB` is required. `KIRO_USAGE_MAX_BYTES` defaults to 256 MiB of
retained payload evidence, counting request BLOBs, entity and application
chunks, event frames and parsed event JSON, and retained usage summaries. At the
first budget refusal the running collector stops retaining new payloads. It
continues observations, fingerprints, scalar usage, and loss metadata. Existing
evidence is never rolled over or deleted. On restart the retained bytes are
counted again; an increased budget can resume capture. This is a payload budget,
not a maximum SQLite file size: indexes, metadata, page overhead, and
accumulated records also consume disk. Temporary SQLite journal space is
additional. Stopping capture and deleting an intentionally retired private
database are operator decisions.

Only hosts equal to `kiro.dev` or ending in `.kiro.dev` and the exact paths
`/v1/responses` (CreateResponse, root turns) and `/generateAssistantResponse`
(GenerateAssistantResponse, workflow steps and subagents) are selected.
`metadata_json.api` records `create_response` or `generate_assistant_response`.
Lookalikes such as `not-kiro.dev` are excluded. Query strings are discarded. The
addon stores only the host, method, constant path, request content encoding, the
request `x-amzn-kiro-agent-mode` (as `agent_mode`) and
`x-amzn-kiro-conversation-id` headers, response status, response content type
and encoding, and the upstream `x-amzn-requestid` / `x-request-id`. It never
serializes arbitrary headers, cookies, authorization, or URLs. Full **bodies**
are deliberately retained and may themselves contain secrets.

The response streaming callback returns the same bytes immediately, including
the EOF sentinel. It does not wait for SQLite. One worker writes the database; a
bounded queue holds at most 256 pending payload items and 8 MiB. Queue overflow
logs a warning and records `queue_overflow`, dropped byte/item counters, and an
incomplete capture. Lost request payloads do not disable response decoding; a
response-byte gap does. At most 256 captures can be active; exceeding that limit
rejects only the new request with HTTP 503. An invalid selected request content
encoding receives HTTP 400. Both refusals leave the collector available for
subsequent healthy requests. A fatal writer failure logs an explicit warning and
marks existing recording rows incomplete when the database remains writable.
Otherwise they remain recording, never complete. Existing response streams
continue returning unchanged bytes; further selected requests receive a local
HTTP 503 until the collector restarts. If the database cannot be opened or
initialization fails, the addon stays installed, logs a startup failure, and
refuses selected requests with HTTP 503 until configuration is fixed and the
collector restarts. Other traffic remains outside capture.

Connections use SQLite WAL and a 30-second busy timeout. The worker obtains the
write lock before changing parser state, so transient contention waits without
replaying stream events. Offline indexing parses outside write transactions and
commits batches of at most 128 records, ending once 256 KiB of source lines is
reached (the final complete record may cross that threshold), with each batch's
checkpoint offset committed atomically. JSONL records up to 64 MiB are parsed
transiently, so image-bearing tool results can be ignored without retaining
their contents in the index. Larger complete records are drained in 64 KiB
chunks. Oversized or invalid complete records, including parse memory failures,
do not stop indexing: `disk_omissions` retains only their source path, byte
offset, byte count, and reason. Blank complete lines are ignored. Their usage
coverage remains unknown; index summaries and selected-session queries warn that
totals may be incomplete. Incomplete EOF tails, including oversized tails, are
retried after an append without advancing the checkpoint. Source replacement or
truncation retires both facts and omission metadata. A database write failure
rolls back the batch and its checkpoint; previously committed batches remain
available. Session metadata retains a separate 4 MiB parsing limit. Malformed,
oversized, or unreadable `session.json` files are isolated per session: indexing
continues through messages and later sessions, while `disk_session_omissions`
records the omitted metadata and stale metadata is retired. Successfully
re-indexing repaired metadata clears its omission. Queries report the global
metadata omission count because unknown ancestry can hide descendants; older
indexes without tracking show an unknown count. The index CLI's
`omitted_records` count includes both JSONL record and session metadata
omissions.

Request metadata and fingerprints are extracted once, on the request hook,
before payload queue admission. This adds bounded request-side parsing and
hashing work; response-stream callbacks still enqueue without parsing. The
request extraction limit is 32 MiB. Above that limit `request_metadata_limit`
marks the capture incomplete and session attribution remains unknown. Per-item
fingerprints retain at most 4096 input items, with `fingerprint_item_limit`
signaling any omitted item hashes; the whole input component hash is retained.
Malformed JSON, strings that cannot encode as UTF-8, and JSON nesting beyond 128
levels produce fixed extraction issue categories, preserve available raw
payloads, and allow later captures to proceed. Session queries report
`global_unattributed_observations` so captures lacking a conversation ID remain
visible in coverage.

## Evidence and extraction

`capture_meta` versions the collector schema. `captures`, `chunks`, and `events`
are independent of any other application database. Additional tables, including
the offline indexer's `disk_*` tables, are preserved. One advisory lock prevents
concurrent collector writers to the same database; an independent indexer can
still write its own tables.

- `captures.request_gzip` preserves the complete decompressed application
  request bytes. Its full SHA-256 is over those exact bytes. Component hashes
  use sorted, compact UTF-8 JSON for `input`, individual input items,
  `instructions`, `reasoning`, and `tools`; GenerateAssistantResponse requests
  instead hash `conversationState.currentMessage`, `history`, individual history
  items, top-level `systemPrompt`, and the current message's
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
  remain available within the retention budget.
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
  `conversationState.conversationId` / `rootConversationId`; the conversation
  header applies only when the body lacks an ID. They are observations. No
  own-versus-delegate relationship is inferred from similar IDs.
- `summary_json` includes exact usage objects when observed, an explicit empty
  `estimates` object, terminal status, and output-text byte and character
  counts. Counts use terminal `output_text` parts when available and otherwise
  observed text deltas, avoiding double counting. Reasoning and tool payloads
  remain available as evidence and are excluded from the text count. Usage
  summary memory is limited to 1 MiB per capture; an omission is flagged, while
  events and chunks retain their independent evidence subject to the storage
  budget.

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
when all three are reported; otherwise it stays `NULL`. Output text counts come
from `assistantResponseEvent.content`, and the last `metadataEvent.stopReason`
is the summary `terminal`. Token counters must be integers from zero through
`2**63 - 1`; observed credits and context percentages are normalized to finite
floating-point values. Invalid numeric fields become `NULL` and mark
`invalid_usage_number`; their original payload evidence is preserved. Capture
stores no token estimate, cache split, or context-window conversion; reports
derive `~` estimates at query time. `cache_write_tokens` is known only from a
reported `cacheWriteInputTokens`; `/v1/responses` captures leave it unknown. The
original usage objects are available for later extraction improvements.

`state='complete'` requires transport completion, a `response.completed` event
(or completed JSON response), and no recorded issue. Event streams have no
terminal event: completion is end of stream on a message boundary after at least
one message, with no exception or error message and no framing, decoding, or
byte-gap failure; an exception message sets `terminal` to `exception`.
`response.failed`, incomplete responses, transport errors/cancellation, missing
completion, extraction limits, queue loss, and storage loss remain incomplete. A
process interrupted before finalization leaves a `recording` row; the next
collector startup marks it `incomplete` with `interrupted_capture`. Initial
metadata is persisted before completion. Partial rows must not be treated as
zero usage. `observed_chunks` / `observed_bytes` describe response callbacks;
dropped counters include refused request and response payload items. Omitted
event/summary evidence is also signaled in `issues_json`. A full observed
response hash can exist even when storage is incomplete; use `state` and the
nullable BLOBs to determine replay completeness.

## Token estimates

Reports fill counters a call lacks with `~` estimates; reported counters always
win per call, and a group mixing both sums exact and estimated values with
(known/all) coverage. For a call with a reported context percentage `p` and a
model with a known window `W` (`claude-opus-5.5`: 1,000,000 tokens):

- total `I = p/100 * W`, which includes output tokens once;
- output `O = chars/4`, where chars counts `output_text` plus retained
  `response.function_call_arguments.delta` and `response.reasoning_text.delta`
  deltas, or GenerateAssistantResponse `toolUseEvent.input` and
  `reasoningContentEvent.text`, so tool-only calls are not `O=0`;
- input `I - O`.

Cached tokens need reported credits and fitted rates (`claude-opus-5.5` only):
`cached = clamp((a*(I-O) + o*O + c - credits) / (a - b), 0, I - O)`. The
full-miss rate `a = 74/603/(W/100)` (12.272e-6 credits per token), full-hit rate
`b = 20/603/(W/100)` (3.317e-6), and fixed cost `c = 0.5034/603` (0.000835)
reuse the discount curves below; `o = 270e-6` is the fitted output rate. The
full-hit curve's own intercept (0.5970/603) is not used. Other models get no
cache estimate, and calls without a context percentage or a known window stay
unavailable. Estimated hit percentage counts requests whose cached value is
above zero.

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
commands also print model totals and a pooled credit/token summary to standard
error after Kiro exits. A local proxy marker links the invocation's captures to
their recorded session identities. Kiro uses inherited terminal input and output
directly; no screen parsing or process-ID guess selects the session. Standard
output, exit status, and signals are preserved. Tracked chat runs as a child of
the summary supervisor, retaining the terminal descriptors with its own process
ID. Explicit help, version, login, and administrative commands skip the summary,
including after recognized global options. Other commands have no automatic Kiro
summary.

These are full root-linked session totals and can include earlier work from a
resumed session. Explicit root conversation IDs include related captures without
requiring an on-disk index. Root-linked lineage may include forks as well as
subagents. Captured requests and credits are counted once; disk credits never
enter the total. Root conversation matches the selected root ID; Other linked
conversations have another ID; Unknown lacks a conversation ID. These groups do
not identify caller roles: workflow steps and subagents carry their own
conversation IDs and land in other linked conversations, which may also include
helpers or forks. Tables group requests, credits, and tokens by model and pool
rather than listing individual delegates. Exact counters are used when observed;
cells that add estimates for calls lacking the exact counter carry `~`, and
missing values show an em dash (see [Token estimates](#token-estimates)). Hit
percentage is cache-hit requests divided by requests with a reported or
estimated cached value; partial coverage remains visible. No captured
conversation identity means an explicit unavailable summary. Before reporting,
the outer launch incrementally indexes `~/.kiro/sessions` if present, using the
existing database and checkpoints. It reads only capture-linked sessions whose
`session.json` or `messages.jsonl` changed since the launch (less one second for
coarse file timestamps) and never prunes; already indexed sessions still link
their new descendants. The explicit `index` command is the full capture-scoped
pass: it prunes `disk_*` rows for sessions no longer linked to captures and runs
`VACUUM` plus a WAL checkpoint when free pages remain. Lineage comes from
`parentSessionId`, `rootSessionId`, `rootConversationId`, and
`_meta.kiro.serverSession.ownerSessionId`; the serverSession `role` and workflow
`workflowId` and `nodeId` are retained as identifiers. Index failures warn
without replacing the child exit status, and disk observations may then be
stale. Manual session queries use the last completed index. The exit summary
also waits at most two seconds for the asynchronous capture writer and flags
unfinished calls. Nested `kiro-usage exec` launches reuse the parent's marker;
only the outer launch prints the summary.

Replay writes private response bytes to standard output. Incomplete captures
produce a warning; a missing requested payload exits with an error. Replay of
available partial bytes can precede that error, so callers must check the exit
status. Request evidence can be read with `gzip.decompress` on
`captures.request_gzip` through a read-only SQLite connection.

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
payloads and SQLite replay. Live Kiro and TLS interception remain untested.
