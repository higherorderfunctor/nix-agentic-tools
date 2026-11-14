# Allowance preview

Run the source CLI with a saved snapshot and an explicit UTC clock:

```bash
python3 -I -B packages/delegate-routing/scripts/pacing-list.py \
  --snapshot packages/delegate-routing/checks/pacing/reader-snapshots.json \
  --now 2026-11-12T01:35:00Z
```

Snapshot mode emits deterministic `allowance-preview` JSON. It executes no
Reader or capture command and needs no configured installation. The preview
ranks observed allowance but does not infer prices, recommend resets or promise
a versioned list schema. The installed routing helper is separate. When
`scripts/delegate-routing-plan.py` switches to ranking from the normalized usage
list, delete its `measure` and `window_pace` validators so
`scripts/usage-normalize.py` owns Reader-envelope validation.

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

## Configured collection

Home Manager and devenv install `delegate-routing-allowance-preview` whenever a
delegate-routing runtime is enabled with a non-null CPA routes entry. Run it
with `--runtime codex`. Collection uses the wall clock and records each actual
finish time; `--now` is reserved for snapshot replay. This explicitly named
preview leaves the routing helper, its configured family pool attribution,
ranking and skill unchanged. The source CLI accepts `--manifest <path>` for the
same runtime-indexed registrations. `--snapshot` bypasses even an installed
default manifest and stays transport-free.

The existing `ai.programs.delegate-routing.pools` registry supplies the Reader.
For preview, its key is `<instance>/<credential>` from CPA's computed client
credentials, never a vendor label. Existing native/helper registrations remain
separate unless explicitly configured for preview. Add `usage.readerPool` and
`limits` to that same registration:

```nix
ai.programs.delegate-routing.pools."service/subscription" = {
  limits = {
    fable = {
      capacity = 100;
      models = ["synthetic-fable"];
      role = "pace";
      unit = "percentagePoint";
      window = "7d:fable";
    };
    weekly = {
      capacity = 100;
      models = null;
      role = "pace";
      unit = "percentagePoint";
      window = "7d";
    };
  };
  usage = {
    readerPool = "claude";
    runtime = "claude";
    technique = "usage";
  };
};
```

This example assumes a configured CPA instance/credential and synthetic catalog
identity. Production callers supply their actual canonical IDs. `models = null`
expands the credential's actual offers for each selected client; explicit
nonempty IDs must belong to that credential and are intersected with the current
client's offers. Duplicate windows are refused. `limits` defaults to empty and
`usage.readerPool` to null; missing registrations or labels leave observations
unmeasured while retaining all offers, including unknown makers and overlapping
credentials. No first-credential attribution is inferred. Pin a separate command
for each credential (for example with `--auth-index`): commands shared between
registrations share a capture, and `account.auth_index` is not an attribution
check.

USD limits consume the existing `window` budget: unit `USD` and exact `monthly`
window. Omit `capacity` to derive it from `window.limit`. Only the
`anthropic-api-usage` accounted technique accepts these limits; it receives that
budget's `--limit`, `--reset-day`, `--time-zone UTC`, expected `--pool` label
and explicit `--now-ms` clock. The consumer environment must supply
`MANAGER_URL` and `MANAGER_KEY_FILE` for this accounted USD Reader; the preview
does not derive Manager+ credentials from CPA metadata. Running it from a bare
terminal without those variables fails loudly and leaves the observation
unmeasured. No new pricing source or transport is introduced.

The installed wrapper bakes in the same CPA URL and management-key file paths as
runtime environments, using the shared `usageEnvironment` source; it never reads
secret contents while building. Credential preview registrations require a CPA
management secret-key file reference; a missing reference is refused at
evaluation rather than allowing the Reader to measure a direct login. Credential
preview registrations stay out of the routing helper's Reader inventory.

Manual callers use
`content.mkObservation { cpaRoutes; pools; techniques; environment; }`, passing
the same direct CPA projection and effective technique registry as module
callers, including the Reader environment. Each distinct command uses the
routing helper's 10-second timeout and process-group cleanup. Execution errors,
timeouts and nonzero exits share one retry after two seconds; successful invalid
JSON or envelopes are never retried. Failure preserves routes and emits
`exit-nonzero` with numeric status (124 for timeout, 127 for launch failure, 65
for invalid output encoding); it does not certify inference availability.

`delegate-routing-observation-command` tests collection using fake executables
and all five saved production envelope shapes, with scratch under its output
directory. Synthetic CPA properties test credential identity, scope refusal and
USD budget reuse. Both backend `observation-command` checks execute their
installed package, including its CPA management metadata. These checks make no
provider request. Preview output has no stable schema promise.

## Allowance ranking

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
