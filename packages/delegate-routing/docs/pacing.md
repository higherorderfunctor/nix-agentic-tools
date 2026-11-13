# Offline allowance inspection

Run the source CLI with a saved snapshot and an explicit UTC clock:

```bash
python3 -I -B packages/delegate-routing/scripts/pacing-list.py \
  --snapshot packages/delegate-routing/checks/pacing/reader-snapshots.json \
  --now 2026-11-12T01:35:00Z
```

The command emits deterministic `allowance-preview` JSON. It executes no Reader
or capture command and needs no configured installation. It does not rank
models, infer prices, recommend resets or promise a versioned list schema. The
installed routing helper is separate.

Snapshots contain `runtime`, `routes`, `pools` and `readers`. Routes are the
existing offer shape `{model, id, maker}`: canonical model identity, served
spelling and nullable maker. They survive missing or failed captures unchanged.
Offers establish neither Reader attribution nor inference availability. Snapshot
pool keys identify Reader observations only; no CPA credential binding is
inferred.

Each pool declares its expected envelope `readerPool` and a `limits` map. Each
limit declares positive `capacity`, native `unit` (`percentagePoint` or `USD`),
`role` (`gate` or `pace`), nonempty explicit canonical `models` and an exact
Reader `window` key. Models must occur in the snapshot routes. No suffix or
family heuristic expands `7d:fable`; the fixture explicitly maps it to
`synthetic-fable`, while its weekly limit covers two models. Duplicate window
registrations are refused. Unknown windows set `scopeResolved: false` and emit a
safe count; they establish no unrestricted allowance.

Captures contain `exit`, `finishedAt`, and either a full `data` envelope or JSON
`stdout`. Envelopes validate `account` (`auth_index`, `name`, `plan`), matching
`pool` and `windows`. Concatenated accounts are refused. Account values and
optional capture evidence (`command`, `startedAt`, `stderrBytes`, stderr) are
never emitted. `finishedAt` and the CLI clock accept UTC ISO timestamps or
integer Unix seconds; fractional capture seconds are truncated.

Quantity, duration, reset, status and extras validation are independent.
Malformed extras do not erase allowance, and malformed timing does not erase
independently measured zero. Remaining and used values keep their declared
native units; durations use observed seconds, including actual monthly lengths.
A missing or invalid capture retains registered limit slots and routes.
Diagnostic reasons are fixed local codes; failed captures may retain a
nonnegative structured count and numeric exit status, attached to the snapshot
pool key.

Reader status is allowlisted. Null or inactive status leaves enforcement
unknown. Invalid status text is omitted. Observations older than 3600 seconds or
past their natural reset are stale, never assumed refilled. Natural reset
instants remain observations. A valid exhausted gate exposes its observed reset
as `gateOpensAt`; stale or invalid gates promise no opening, and positive gates
may have no reset. Gate roles never become pace roles based on duration.

`readerMetadata` projects only known balance kind/unit pairs and reset bonus
counts with normalized expiration seconds. Missing or malformed arrays are
unknown; valid empty arrays remain empty. Malformed entries are diagnosed
independently and omitted. Arbitrary upstream fields and invalid timestamp text
never enter output. These inspection facts do not establish wallet credit or
reset eligibility; there are no placeholder credit or reset inventories.

The owner check `delegate-routing-observation-normalize` exercises synthetic
scope and route properties against five sanitized Reader capture shapes.
Quantities, durations and statuses retain their observed values; account and
command names are anonymous, and model identities are synthetic. These are
offline boundary fixtures, not production Nix configuration or a rotating
catalog inventory. Tests reject scope expansion, seven-day substitution for
months, route loss, unsafe metadata, zero loss on invalid timing, command
execution and nondeterministic replay. Configured Reader collection and CPA
attribution are outside this source CLI.
