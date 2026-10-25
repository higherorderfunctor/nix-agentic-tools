# airlock storage

> **Last verified:** 2026-10-25 — guarded SQLite state passes the focused
> storage suite, offline workspace tests, Clippy, the Nix package build, the Nix
> Clippy check, and clean SQLx metadata regeneration.

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
Acknowledgement happens only after SQLite succeeds or fails. Request forwarding
does not wait for this worker; M07 must call it from telemetry side-work and
treat `UsageUnavailable` or a write error as visible completeness loss. `close`
drains the worker, takes sole ownership of the connection, and awaits SQLite's
asynchronous close. Dropping a handle without `close` releases the worker
asynchronously and is not the deterministic shutdown path.

## Data contract

All application tables are SQLite `STRICT` tables. Enum-like values use CHECK
constraints, required scalar values are non-null, foreign keys connect
credentials, groups, memberships, token rows, events, and snapshots, and unknown
usage dimensions remain SQL null rather than becoming zero. Token strings are
bounded and represented by `TokenMaterial`: a zeroizing buffer whose `Debug`
implementation is always `[redacted]`. Storage never logs token values, and SQLx
statement and slow-statement logging are disabled.

OAuth stores one real token pair and one fake mapping pair per credential.
Replacement is a transaction guarded by a generation: an absent mapping requires
generation zero, while an existing mapping must match the caller's expected
generation before either half is replaced. Lookup joins the mapping, credential,
real token row, and provider, and refuses a credential/provider mismatch without
returning token material.

Observed request events are separate from provider snapshots. An event records
the group, credential, bounded model ID, completed/failed/rejected outcome,
status, byte counters, latency, and optional token dimensions; it never records
request or response bodies, headers, prompts, tool arguments, or arbitrary
provider JSON. Aggregation groups by credential, model, and outcome over a time
range, sums known dimensions, and preserves an unknown token dimension when any
included event lacks it. It fetches at most 10,001 groups and returns
`UsageRangeIncomplete` when a range has more than 10,000 groups, rather than
silently truncating the result.

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
