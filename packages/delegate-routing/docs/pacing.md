# Offline allowance inspection

Run the source CLI with a saved snapshot and an explicit UTC clock:

```bash
python3 -I -B packages/delegate-routing/scripts/pacing-list.py \
  --snapshot packages/delegate-routing/checks/pacing/reader-snapshots.json \
  --now 2026-11-12T01:35:00Z
```

The command emits deterministic `allowance-preview` JSON. It executes no Reader
or capture command and needs no configured installation. It ranks observed
allowance but remains an incomplete, source-only preview: it does not infer
prices, recommend resets or promise a versioned list schema. The installed
routing helper is separate. When `scripts/delegate-routing-plan.py` switches to
ranking from the normalized usage list, delete its `measure` and `window_pace`
validators so `scripts/usage-normalize.py` owns Reader-envelope validation.

Snapshots contain `runtime`, `routes`, `pools` and `readers`. Routes are the
existing offer shape `{id, maker, model}`: `id` is the canonical model identity,
`maker` is nullable, and `model` is the served spelling. They survive missing or
failed captures unchanged. Offers establish neither Reader attribution nor
inference availability. Snapshot pool keys identify Reader observations only; no
CPA credential binding is inferred.

Each pool declares its expected envelope `readerPool` and a `limits` map. Each
limit declares positive `capacity`, native `unit` (`percentagePoint` or `USD`),
`role` (`gate` or `pace`), nonempty explicit canonical `models` and an exact
Reader `window` key. Models must match snapshot route `id`s. No suffix or family
heuristic expands `7d:fable`; the fixture explicitly maps it to
`synthetic-fable`, while its weekly limit covers two models. Duplicate window
registrations are refused. Unknown windows set `scopeResolved: false` and emit a
safe count; they establish no unrestricted allowance.

Collector-shaped captures contain `exit`, integer Unix `finishedAt`, and JSON
`stdout`; offline inputs also accept a full `data` envelope. Envelopes validate
`account` (`auth_index`, `name`, `plan`), matching `pool` and `windows`.
Concatenated accounts are refused. Account values and unknown capture fields are
never emitted. `finishedAt` and the CLI clock accept UTC ISO timestamps or
integer Unix seconds; fractional capture seconds are truncated.

Quantity, duration, reset, status and extras validation are independent.
Malformed extras do not erase allowance, and malformed timing does not erase
independently measured zero. Remaining and used values keep their declared
native units; durations use observed seconds, including actual monthly lengths.
A missing or invalid capture retains registered limit slots and routes.
Diagnostic reasons are fixed local codes attached to the snapshot pool key.
Nonzero exits emit `exit-nonzero` and the numeric exit status; stdout is
ignored.

Reader status accepts any string or null. Active, critical, estimated, normal,
ok and warning statuses establish enforcement; other statuses leave it unknown.
Non-string, non-null statuses are invalid and omitted. Observations older than
3600 seconds or past their natural reset are stale, never assumed refilled.
Natural reset instants remain observations. A valid exhausted gate exposes its
observed reset as `gateOpensAt`; stale or invalid gates promise no opening, and
positive gates may have no reset. Consistently idle windows (0 used, 100
remaining) may have a null reset in either role. The reset-duration bound
tolerates one second for upstream rounding and truncated capture seconds. Gate
roles never become pace roles based on duration.

`readerMetadata` projects only known balance kind/unit pairs and `promo_credits`
or `rate_limit_reset` bonus counts with normalized expiration seconds. Missing
or malformed arrays are unknown; valid empty arrays remain empty. Malformed
entries are diagnosed independently and omitted. Arbitrary upstream fields and
invalid timestamp text never enter output. These inspection facts do not
establish wallet credit or reset eligibility; there are no placeholder credit or
reset inventories.

The owner check `delegate-routing-observation-normalize` exercises synthetic
scope and route properties against five sanitized Reader capture shapes. Window
durations and statuses retain production shapes; account values, balances, bonus
expirations, USD capacities and model identities are synthetic. These are
offline boundary fixtures, not production Nix configuration or a rotating
catalog inventory. Tests reject scope expansion, route loss, unsafe metadata,
zero loss on invalid timing, command execution and nondeterministic replay.
Configured Reader collection and CPA attribution are outside this source CLI.

The pure `scripts/pacing.py` engine adds `entries` while preserving `routes` and
normalized observations. Entries match explicit limit `models` to canonical
route `id`, retaining the served `model` separately. Multiple applicable pools
remain inspection alternatives; an offer without applicable evidence has a null
pool and unknown pace. They do not establish credential attribution.

Pace is the minimum of remaining/capacity times windowSeconds/time-to-reset
across applicable paced limits. It is not clipped: half a week remaining with
half the allowance is 1, full allowance halfway through is 2. Each limit uses
its own duration, including monthly periods. Positive valid gates do not lower
pace; closed gates block readiness. Missing, stale, invalid, unresolved-scope or
unknown-enforcement evidence cannot establish readiness. Unknown pace is null
and scores zero; independently observed exhaustion still proves zero. An idle
paced limit with no reset remains unknown; an open gate needs no reset.

Optional snapshot `policy` maps observed pool keys to `{ "weight": 1.5 }`. Only
`weight` is accepted, defaults to 1, and must be finite and nonnegative
(booleans are refused). Every ready allowance score is pace times this weight,
without reserve or reset conditions. Unknown pool keys are refused at the rank
boundary. Weight zero changes preference without changing readiness.

`delegate-routing-allowance-ranking` checks handwritten arithmetic and an
independent rational reference, canonical scope, unknown evidence and policy
validation. Its CLI cases use synthetic current snapshot shapes and an explicit
clock; no production catalog inventory or operator configuration is copied.

Each entry exposes `binding_limit`, the identifier of its smallest observed
paced allowance (lexical identifier breaks equal-pace ties). It remains an
inspection fact when other evidence blocks readiness; gates never become paced
binding limits. `evidence` lists `stale_limits`, `unknown_limits`, and
`scope_resolved`. Unknown limit IDs cover invalid or missing observations,
unknown enforcement, or unusable pacing/release timing. Stale limits also count
as unknown. Existing pool diagnostics explain capture and scope failures once;
ranking does not repeat those diagnostics for every offer.

`available_at` is the explicit clock for ready entries. For blocked entries it
is the latest observed release of all exhausted gates and paced limits, only
when every blocker has valid future timing and the remaining allowance evidence
is complete. Any unresolved blocker, stale observation or unknown scope leaves
it null. This is conditional on the observations, not a refill or inference
availability guarantee; reread before acting. Known zero survives malformed
timing while its availability stays unknown.

All applicable pool/model alternatives survive, including failed and exhausted
entries with score zero. Entries sort by descending score, then ready before
out, then pool and served model, canonical identity and maker (null before any
string). No other readiness states are emitted. Original route and observation
order remains untouched. `delegate-routing-allowance-output` checks these
properties using literal expectations, an independent release-time reference,
and the current offline CLI input shape; it rejects early promises, loss of
failed offers, leaked capture text and unstable ties.
