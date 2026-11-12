# Frozen quota inspection

Run the standalone inspection CLI with a saved snapshot and an explicit UTC
clock:

```bash
python3 -I packages/delegate-routing/scripts/pacing-list.py \
  --snapshot packages/delegate-routing/checks/pacing/reader-snapshots.json \
  --now 2026-11-12T01:35:00Z
```

The command emits `capability: allowance-preview`, normalized limit observations
and safe diagnostics. It does not produce a ranked operator list. It neither
runs Readers nor selects models. Bank capacity, reset recommendations, credit
availability and costs remain incomplete; those observations remain null. The
existing routing helper is unchanged.

The snapshot contains `runtime`, `pools` and `readers`. Each local billing pool
declares `readerPool` (the Reader's provider/account pool label) and `limits`.
Each explicit limit ID has a `capacity`, `unit` (`percentagePoint` or `USD`),
`role` (`pace` or `gate`), `models` (canonical model IDs) and exact upstream
`window` key. The typed `LimitSpec` parser consumes every declared field
immediately. A rolling gate is declared, never inferred from its duration;
`7d:fable` maps to an explicit model-scoped limit, never to an implicit
pool-wide measurement. Unregistered windows produce diagnostics without changing
other limits. No new Nix option precedes its catalog-to-inspection consumer.

Each `readers` entry is the full saved transport capture: `data` is the stdout
envelope, or `stdout` is its JSON serialization; `exit` and `finishedAt` are
required. `command`, `startedAt` and `stderrBytes` may be retained as capture
evidence but are never executed or emitted. The envelope retains its `account`,
`pool`, `windows`, `balances` and `bonuses` shapes. Account identity is checked
and omitted from output. Several concatenated accounts are refused because their
association is ambiguous.

Observations preserve native capacity/remaining/used units, actual window
seconds, UTC Unix reset/observation seconds, Reader status and nullable
enforcement. Capture fractional-second precision is truncated to integer Unix
seconds. Inactive or unrecognized status retains `enforced: null` and an
`unknown-enforcement` diagnostic. Missing windows retain null quantities;
malformed windows are invalid only at their registered scope. Snapshots older
than 3600 seconds or beyond their natural reset are stale; they are never
assumed refilled. Positive rolling gates may retain a null release time.

`readerMetadata` preserves bonus and balance arrays for inspection; absent
arrays remain null. These projections do not establish real credit lots,
cap/spend completeness or grant eligibility. In particular, Claude's
`extra_usage` remainder is not proof of a wallet balance. Natural weekly reset
instants are preserved; no reset effect is inferred.

Failed captures retain a machine-readable diagnostic `reason` and numeric
`exitStatus`. A structured stdout `diagnostic` (inside `data` or decoded from
`stdout`) with `reason: unpriced-models` and nonnegative integer `count`
preserves that count: the operator can explain how many models lack a price in
CPA Manager. Otherwise failure uses `exit-nonzero`; Safe `refused`, `timeout`
and `invalid-json` codes are also recognized. Reader stderr and arbitrary reason
strings are never copied.

The offline check `delegate-routing-observation-normalize` runs labelled
assertions over all five sanitized production capture shapes, explicit clocks,
scoped inactive limits, missing extras and failed Readers. The fixture uses fake
command names and stable anonymous account symbols; production quantities and
statuses are preserved. CLI output remains diagnostic preview data, without a
stable complete-list schema promise.
