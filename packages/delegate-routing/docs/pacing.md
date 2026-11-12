# Allowance ranking preview

Run the standalone inspection CLI with a saved snapshot and an explicit UTC
clock:

```bash
python3 -I packages/delegate-routing/scripts/pacing-list.py \
  --snapshot packages/delegate-routing/checks/pacing/reader-snapshots.json \
  --now 2026-11-12T01:35:00Z
```

The content package installs `bin/delegate-routing-observe`. Home Manager and
devenv install the configured command when a delegate-routing runtime is
enabled; manual callers use
`content.mkObservation { catalog; poolDefinitions; techniques; budgets; pacing; }`.
`catalog` is the checked shared graph, and `poolDefinitions` is the same
`ai.catalog.pools` map, joined by its pool IDs. `techniques` is the existing
effective runtime technique registry; `budgets` is the existing delegate-routing
pool accounting configuration.

For collection, run
`delegate-routing-observe --runtime codex --now 2026-11-12T01:35:00Z`. Each
`ai.catalog.pools.<pool>.usage.<billingKind>` associates an `adapter`, `runtime`
and `technique` with the matching credential kind. Supported associations are
subscription with `claude-subscription`, `codex-subscription`, `opencode-go` or
`zai`, and metered with `anthropic-spend`. The runtime qualifies the existing
technique key; it does not identify the spending pool. The shared graph supplies
runtime reach and canonical model scope. Each unique command is called once,
with a 30-second timeout; safe failure diagnostics retain its pool. Reader
implementations are unchanged. Collected output includes `routes` with canonical
model, maker, billing pool and applicable limit IDs. An offered model whose
maker is unknown retains `maker: null`.

Provider presets supply the exact upstream window keys and gate/pace roles.
Claude's Fable window applies only to reachable canonical Fable models. The API
adapter consumes the existing monthly USD budget `pools.<pool>.window.limit`,
and supplies its existing Reader's `--limit`, `--reset-day`, `--time-zone UTC`
and `--pool` arguments from that same budget and shared pool ID. `--now-ms`
comes from the explicit inspection clock. These appended arguments are
authoritative, so an older value in a registered command cannot drift from
normalization. No new pricing or thresholds are introduced. Independent legacy
Reader registration for the same observed pool is refused; the existing fit
helper remains separate. Multiple allowance billing kinds in one pool are
refused until their observation semantics are delivered.

`--snapshot` bypasses the packaged manifest and executes no Reader. The command
emits `capability: allowance-preview`, normalized limit observations and safe
diagnostics. When the snapshot includes catalog `routes`, it also emits the
complete ranked ordinary-allowance `entries`. Reader-only captures have no route
identities and remain observation-only. Collection always uses the checked
catalog routes. This allowance-only preview cannot substitute for the final
operator list and does not select models. Bank capacity, reset recommendations,
credit availability and costs remain incomplete; those observations remain null.
The existing routing helper is unchanged.

The snapshot contains `runtime`, `pools` and `readers`. Each local billing pool
declares `readerPool` (the Reader's provider/account pool label) and `limits`.
Each explicit limit ID has a `capacity`, `unit` (`percentagePoint` or `USD`),
`role` (`pace` or `gate`), `models` (canonical model IDs) and exact upstream
`window` key. The typed `LimitSpec` parser consumes every declared field
immediately. A rolling gate is declared, never inferred from its duration;
`7d:fable` maps to an explicit model-scoped limit, never to an implicit
pool-wide measurement. Unregistered windows produce diagnostics without changing
other limits. Catalog registrations use these provider presets; saved snapshots
retain explicit limit specifications.

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
arrays remain null. Corrected Readers report actual credit lots and reset
grants, including their amounts, funding, targets, expiry and usability; Claude
grants retain opaque handles. Spend cap headroom is never a wallet balance.
Preview retains this inventory for inspection without inferring cap/spend
completeness or applying reset effects. Natural weekly reset instants are
preserved.

Failed captures retain a machine-readable diagnostic `reason` and numeric
`exitStatus`. A flat stdout document `{"reason":"unpriced-models","count":1}`
(inside `data` or decoded from `stdout`), with exactly those fields and a
positive integer `count`, preserves that count: the operator can explain how
many models lack a price in CPA Manager. Otherwise failure uses `exit-nonzero`;
safe `refused`, `timeout` and `invalid-json` codes are also recognized. Reader
stderr and arbitrary reason strings are never copied.

The offline check `delegate-routing-observation-normalize` runs labelled
assertions over all five sanitized production capture shapes, explicit clocks,
scoped inactive limits, missing extras and failed Readers. The fixture uses fake
command names and stable anonymous account symbols; production quantities and
statuses are preserved. Inventory additions are explicitly labelled
source-shaped synthetic fixtures: Claude lots and grants replace the rejected
cap remainder; Codex reset lots use `remaining`, native `unit`, whole-pool
`scope` and explicit synthetic eligibility. CLI output remains diagnostic
preview data, without a stable complete-list schema promise.

The offline `delegate-routing-observation-command` check exercises catalog
binding, all five full envelopes, shared-command deduplication, the explicit
clock, safe failures and offline snapshot behavior. Its delivery checks execute
both backend commands and the manual content package command. Tests use fake
executables and isolated empty home directories; no provider transport runs.

## Ordinary allowance ranking

`pacing.py` owns pure `rank(snapshot, policy)`, consumed directly by the CLI
after normalization. It reads the explicit `asOf` clock and the route's
registered limit IDs; it calls no Reader, picker or provider. Positive rolling
gates do not enter the paced minimum. A closed gate or exhausted allowance
forces zero. Otherwise pace is the minimum
`remaining / capacity / max(1e-6, (naturalResetAt - asOf) / windowSeconds)`,
with lexical limit IDs breaking binding ties. Known idle windows are calculated
normally and pace is never capped.

Set `ai.programs.delegate-routing.pacing.pools.<pool>.weight` to a positive
number (default 1). Manual callers pass the same `pacing.pools` map to
`mkObservation`; saved route-bearing snapshots carry its per-pool map as
`policy`. Unknown pool references and policy keys are refused. Weight applies
unconditionally: pace 2 gives scores 3 at weight 1.5 and 1 at weight .5, even
without reset or credit backing. Reset and credit policy fields wait for their
observation consumers.

Entries sort by descending score, readiness, then pool/model. This preview emits
only `ready` and `out`; later reset/credit support adds the intervening
`redeem_required` and `last_resort` states. Every configured route stays
present. Unknown allowance has null pace, score 0, state `out`, staleness and an
`uncertain-allowance` diagnostic. A known blocker still proves zero alongside
unknown evidence. Missing conversion leaves cost and headroom null; a known
blocker proves headroom 0. Return time is the maximum known future release
across all blockers, or null when any required time is unknown. Stale measured
quantities remain annotated, never refilled; elapsed reset times are not future
return promises.

`delegate-routing-allowance-ranking` compares the independent ordinary reference
against normalized frozen envelopes and literal expectations: uncapped 84, idle
2, open gate 1, monthly .2, unconditional weights, zero retention and stable
pool/model ties. It also checks scope isolation, all-blocker return time and
byte-identical offline CLI output. Bank capacity, real grants, credit scores and
costs remain incomplete, and no reset executor is included.

The `delegate-routing-allowance-output` check verifies the delivered output
contract through the standalone script, Home Manager, devenv and manual content
package. It rejects dropped zero routes, unknown observations presented as
exhaustion, earliest-blocker return times and unstable route ordering. Saved
route-bearing snapshots emit canonical pool/model route order and sorted limit
IDs as well as ranked entries; input route order does not change JSON bytes.
Missing-capture diagnostics remain pool-level when no limits are registered;
registered unknown limits identify the affected model and limits. A known
blocker alongside an unknown limit preserves zero pace and the known binding
limit, but cannot promise a return time. CLI help and JSON both identify the
allowance preview; null credits/resets do not establish full bank readiness.
