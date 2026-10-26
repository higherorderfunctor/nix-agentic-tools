# airlock control listener

> **Last verified:** 2026-10-26 — the bounded WebSocket chart uses exact
> filtered storage, compact tuples and decoded-memory preflight; bundled callers
> share the chart and retain raw request and provider history.

## Control listener

`settings.control.enable` is false by default. An enabled instance requires a
dedicated `control.token` secret-file reference, listens on its own port
(default `8401`), and cannot share the gateway CONNECT port. The module renders
`control.listen` and `control.read_token_file`, claims the port as
`airlock:airlock-main.ports.control`, and passes the package web root to the
launcher only when control is enabled.

The control token is independent of every CONNECT client token. Static routes
serve only the dashboard index and files below `/assets`; responses use explicit
MIME types, `Cache-Control: no-store`, a restrictive CSP with
`frame-ancestors 'none'`, and JSON 404 errors. Directory listing, traversal,
encoded-parent paths, SPA fallback, and unknown API routes are refused.

`GET /api/v1/usage` requires that dedicated bearer token and accepts only the
defined query fields and safe JSON integers. An absent or empty query uses the
report defaults; duplicate, unknown, or unsafe values fail with distinct errors.
`GET /api/v1/live` upgrades only the exact Host, same-origin Origin, and
`airlock.v1` subprotocol. The first frame must authenticate within five seconds;
invalid or non-auth frames close without a hello. Protocol v1 carries sibling
`kind` and `query`, literal rolling windows, sequence numbers, epochs,
cumulative acknowledgements, and fresh subscriptions after reconnect.

Each socket supports at most eight subscriptions, a 1 MiB frame limit, 16
unacknowledged frames, and 2 MiB of unacknowledged data. A 17th unacknowledged
frame emits `slow_consumer`, closes 1013, and leaves other sockets and storage
writers independent. Server pings every 15 seconds and closes after 30 seconds
unless the exact nonce is returned. A reconnect authenticates a replacement
socket and subscribes afresh; it carries over neither prior sequence credit nor
retained frames. The server emits storage and slow-consumer gaps; sequence holes
and restarts are local reducer diagnostics. Client ingress overflow is reported
separately by the web transport. Unsubscribe is idempotent and releases that
subscription's flow credit. Retryable storage gaps use `action: retry`; the next
successful evaluation resets the epoch and sends a fresh sequence-one snapshot
rather than continuing a possibly partial delta chain. Snapshot and delta views
contain every collection permitted by the subscription kind, including empty
collections, and deltas carry only changed or departed rows. Shutdown is
terminal for the control listener and every upgraded socket, including sockets
awaiting their first auth frame. It cancels subscription reads, waits for socket
writers and subscription tasks to finish, then closes the control reader before
the main storage owner tears down SQLite.

## Request chart

`requests.chart` replaces the former request series. A query requires a
canonical alphabetical selection of zero to two `client`, `model` and `provider`
dimensions. Optional filters run before aggregation; omitted client includes all
clients, explicit null selects only unknown clients. Credential, group, outcome
and bucket fields are refused. The raw request table keeps its independent full
filters and pagination. Provider History retains credential quota/balance
observations; the separate credential request-trend route is retired. The CLI
report keeps its own aggregate contract.

Chart windows are rolling positive seconds up to 30 days, fixed positive
half-open endpoints spanning at most 30 days, or `{all: true}`. The server
chooses hourly precision through two days, UTC daily precision for longer finite
ranges, and integer-day multiples targeting about 32 intersecting UTC days for
all history. Exact resolved bounds and global oldest provenance stay in common
metadata; chart metadata adds `{bucket_seconds, dimensions}`. An empty
all-history range uses the prior day clipped at epoch zero. Browser-local
yesterday is an exact absolute interval, including 23/25-hour days; long-range
daily buckets remain UTC.

The `request_chart` collection keeps keyed snapshot/upsert/remove semantics.
Keys are canonical JSON `[bucket_start_unix, ...selected identities]`. Values
are
`[bucket_start_unix, ...selected identities, events, complete_events, error_events, cache_read_tokens, cache_write_tokens, input_tokens, output_tokens]`.
A selected unknown client is null; an unselected dimension has no slot. Token
totals remain null when any included event lacks that token dimension.

The shared decoder validates tuple shape, exact integers, identities and key
equality before constructing narrow domain rows. The reducer validates
active-query dimensions and bounds and the entire resulting row set under new
precision before ACK. Adaptive bucket changes replace affected keys and metadata
in the same atomic delta. Both the server and client enforce the 1 MiB decoded
retained-view accounting in addition to encoded frame limits: compact wire fit
alone does not authorize a larger view.
