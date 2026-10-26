# airlock storage

> **Last verified:** 2026-10-26 — migration 0003 backfills daily request
> statistics in one transaction; each usage write commits its raw event and
> daily statistics together. Bounded readers and the read-only report retain
> their existing contracts.

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

Control reads use a separate read-only connection. Every control query installs
a 250 ms SQLite progress deadline and converts an interrupted database query to
retryable `query_budget_exceeded`. Completed attempts remove the progress
handler. Cancellation interrupts the query; the next bounded read replaces its
handler, or closing the connection destroys it. Useful bounded reads must stay
under that budget: migration 0002 adds the covering
`request_events_dropped_cover_idx` used by the global request-loss sum, so a
bounded request table or provider view is not priced by a full request history.
An intentionally exhaustive aggregate may still return the budget gap instead of
truncating. Measured locally with two million request rows and 1,001 snapshots,
a 200-row request page took about 109 ms and a 1,000-snapshot provider view
about 219 ms; those near-budget timings are host-sensitive, while the tests
enforce the query plan and the 250 ms boundary.

Aggregation uses caller-selected time buckets and groups by provider, client,
served credential, model, and outcome. It counts HTTP 2xx successes, 4xx/5xx
errors and complete observations, and sums known latency, bytes, and token
dimensions. A token total stays unknown when any included event lacks that
dimension. It fetches at most 10,001 groups and returns `UsageRangeIncomplete`
when a range has more than 10,000 groups, rather than silently truncating the
result.

Migration 0003 adds chart sufficient statistics keyed by UTC day and actual
provider, client and model. Startup backfills all existing raw events before the
usage worker starts. Each subsequent append inserts the raw event and updates
its daily row in one transaction; acknowledgement follows commit. A failed
update, including integer overflow, rolls back the raw insert. SQLite
interruption rolls back both the migration table and backfill so restart can
retry it.

Daily rows retain event, complete-observation and HTTP-error counts
(`status_code >= 400`, independent of outcome), plus each token dimension's
known sum and unknown-event count. Consumers must return a null token total
whenever its unknown count is nonzero. These counters do not attribute global
dropped events. A private empty client key encodes SQL null; typed client IDs
cannot be empty. Existing series, table and CLI report queries still read raw
events.

Identified usage-series history loads its page and same-filter reset predecessor
in one SQLite transaction. The query applies both `since_unix` and exclusive
`until_unix`, then limits rows; snapshots at or after the window end cannot
crowd the page or become its predecessor. A same-time row from another source or
surface is excluded. The reset detector keys prior quota and credit pools by
credential and surface, so two relevant observations without an intervening
sample are required before a reset is reported.

Provider snapshot and read-only report semantics are documented in
`docs/usage-storage.md`.

## Build and verification

Fixed SQL uses compile-checked SQLx macros, committed `.sqlx` metadata, and the
migration under `crates/airlock-core/migrations`. The package builds with
`SQLX_OFFLINE=true`. The `airlock-sqlx-metadata` Nix check migrates a fresh
database, regenerates metadata from source, and requires a clean diff, so
changed SQL, changed types, or an orphan metadata file fail the build.
