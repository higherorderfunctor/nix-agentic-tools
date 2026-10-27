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

Only hosts equal to `kiro.dev` or ending in `.kiro.dev` and the exact path
`/v1/responses` are selected. Lookalikes such as `not-kiro.dev` are excluded.
Query strings are discarded. The addon stores only the host, method, constant
path, request content encoding, response status, response content type and
encoding, and the upstream `x-amzn-requestid` / `x-request-id`. It never
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
available. Session metadata retains a separate 4 MiB parsing limit.

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
  `instructions`, `reasoning`, and `tools`; prefix hashes cover the first 4096,
  16384, 32768, and 49152 application bytes when present. These hashes describe
  content stability; they do not prove provider cache hits.
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
- Request model, reasoning effort, conversation ID, continuation ID, and an
  explicit allowlist of session/execution/agent lineage IDs are retained in
  `metadata_json`. They are observations. No own-versus-delegate relationship is
  inferred from similar IDs.
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
supplied in a usage object; absent counters remain SQL `NULL`. Token counters
must be integers from zero through `2**63 - 1`; observed credits and context
percentages are normalized to finite floating-point values. Invalid numeric
fields become `NULL` and mark `invalid_usage_number`; their original payload
evidence is preserved. No token estimate, cache split, or context-window
conversion is invented. `cache_write_tokens` remains unknown unless a supported,
verified source is added. The original usage objects are available for later
extraction improvements.

`state='complete'` requires transport completion, a `response.completed` event
(or completed JSON response), and no recorded issue. `response.failed`,
incomplete responses, transport errors/cancellation, missing completion,
extraction limits, queue loss, and storage loss remain incomplete. A process
interrupted before finalization leaves a `recording` row; the next collector
startup marks it `incomplete` with `interrupted_capture`. Initial metadata is
persisted before completion. Partial rows must not be treated as zero usage.
`observed_chunks` / `observed_bytes` describe response callbacks; dropped
counters include refused request and response payload items. Omitted
event/summary evidence is also signaled in `issues_json`. A full observed
response hash can exist even when storage is incomplete; use `state` and the
nullable BLOBs to determine replay completeness.

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
commands also print a session summary to standard error after Kiro exits. A
local proxy marker links the invocation's captures to their recorded session
identities. Kiro uses inherited terminal input and output directly; no screen
parsing or process-ID guess selects the session. Standard output, exit status,
and signals are preserved. Tracked chat runs as a child of the summary
supervisor, retaining the terminal descriptors with its own process ID. Explicit
help, version, login, and administrative commands skip the summary, including
after recognized global options. Other commands have no automatic Kiro summary.

These are full-session totals and can include earlier work from a resumed
session. No captured conversation identity means an explicit unavailable
summary. No automatic disk indexing runs; disk observations come from the last
explicit index and may be stale. The exit summary waits at most two seconds for
the asynchronous capture writer and flags unfinished calls. Nested
`kiro-usage exec` launches reuse the parent's marker; only the outer launch
prints the summary.

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
