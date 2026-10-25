# airlock storage

> **Last verified:** 2026-10-25 — client-owned managed OAuth and bounded request
> usage share the pre-release 0001 SQLite schema.

## Scope

Airlock persists daemon-owned state in SQLite under the configured `stateDir`.
This fragment covers the database contract. Transport, routing, and harness
selection remain in `airlock.md`.

The state directory must be absolute, user-owned, mode 0700, and not a symlink.
The database is `airlock.sqlite3`, created as a regular mode 0600 file owned by
the same user. Existing `-journal`, `-shm`, and `-wal` companions are checked
before SQLite opens the database and again after startup writes; each must be a
regular, user-owned mode 0600 file and not a symlink. Startup refuses a missing
integrity result rather than repairing or resetting state.

SQLite runs in WAL mode with full synchronous writes, `secure_delete=ON`, and
foreign keys enabled. `PRAGMA quick_check` runs before migration, after
migration, and after identity seeding. Any failed privacy or integrity check
prevents a serving handle. Every future connection must enable foreign keys; the
checked startup path must not be bypassed.

## Connection model

Storage owns one `SqliteConnection`, serialized by a Tokio mutex. Durable OAuth
replacement, snapshot, and query operations await that connection. Request-usage
ingestion validates an event, then places it on a bounded one-slot channel. A
worker tries to take the connection; queue or ownership contention returns
`UsageUnavailable` instead of waiting. SQLite's busy timeout is zero, so an
external writer cannot stall response-side telemetry work.

The one-slot channel permits one active write and at most one queued write.
Acknowledgement happens only after SQLite succeeds or fails. The gateway has a
separate bounded 32-event dispatcher: response forwarding only tries to queue an
event, and one worker awaits storage. A full dispatcher, failed write, or closed
worker increments a pending loss count and emits a reason-only warning; the next
durable event carries that count as global, unattributed loss. It is reported
through a lifetime global total, never assigned to that event's provider,
client, model, or time bucket. Gateway shutdown drains connections and the
dispatcher before storage `close` drains its own worker and closes SQLite. A
loss with no later successful write remains visible in the warning, not in a
database aggregate. Dropping a storage handle without `close` releases its
worker asynchronously. The serve caller keeps the sole storage owner and calls
`close` on both normal and error exits before the state directory is reused.

## Data contract

All application tables are SQLite `STRICT` tables. Enum-like values use CHECK
constraints, required scalar values are non-null, foreign keys connect
credentials, groups, memberships, token rows, events, and snapshots, and unknown
usage dimensions remain SQL null rather than becoming zero. Token strings are
bounded and represented by `TokenMaterial`: a zeroizing buffer whose `Debug`
implementation is always `[redacted]`. Storage never logs token values, and SQLx
statement and slow-statement logging are disabled.

OAuth stores one real token pair per credential and a fake mapping keyed by
authenticated client and credential. The active managed route has exactly one
client. Replacement is a transaction guarded by a generation: an absent mapping
requires generation zero, while an existing mapping must match the caller's
expected generation before either half is replaced. Lookup joins the mapping,
credential, real token row, and provider, and refuses a
client/credential/provider mismatch without returning token material. Known
refresh-token expiry is durable. Successful revoke removes both pairs only when
its client, provider, fake refresh token, and generation still match.

Observed request events are separate from provider snapshots. An inference event
records client, group, served credential, bounded model ID, status,
completed/failed/rejected/cancelled outcome, byte counters, latency in
milliseconds from request handling through body completion, completeness and
loss counts, and optional input, output, cache read and cache creation token
counts. It never records request or response bodies, headers, prompts, tool
arguments, or arbitrary provider JSON. The response tee reads `message_start`
and cumulative `message_delta` usage without changing forwarded bytes; gzip SSE
is decoded incrementally in memory, while JSON and gzip JSON observation are
limited to 1 MiB. Unknown encoding, malformed or truncated usage, and an
over-limit body are marked incomplete. Requests rejected before a served
credential is known are only in the request audit, since attributing them to a
provider would invent a serving identity. Rows with an unknown client use SQL
null; a configured client named `legacy-unknown` remains distinct from them.

Aggregation uses caller-selected time buckets and groups by provider, client,
served credential, model, and outcome. It counts HTTP 2xx successes, 4xx/5xx
errors and complete observations, and sums known latency, bytes, and token
dimensions. A token total stays unknown when any included event lacks that
dimension. It fetches at most 10,001 groups and returns `UsageRangeIncomplete`
when a range has more than 10,000 groups, rather than silently truncating the
result.

Provider snapshots are append-only history. A header records fetch time,
provider, account ID, success/gap status, and a bounded gap reason; child rows
represent typed quota pools, credit pools in minor units, and labelled metrics
with units. History is provider-scoped and bounded to 1,000 snapshots, with
children reconstructed with their header. Raw provider responses are not stored.

## Build and verification

Fixed SQL uses compile-checked SQLx macros, committed `.sqlx` metadata, and the
migration under `crates/airlock-core/migrations`. The package builds with
`SQLX_OFFLINE=true`. The `airlock-sqlx-metadata` Nix check migrates a fresh
database, regenerates metadata from source, and requires a clean diff, so
changed SQL, changed types, or an orphan metadata file fail the build.
