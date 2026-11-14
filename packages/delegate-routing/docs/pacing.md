# Saved allowance observations

`normalize(snapshot, now)` in `scripts/usage-normalize.py` turns saved Reader
captures into allowance facts. Its current callers are the owner's Python tests.
Pass a snapshot and an explicit ISO 8601 clock with an offset. The result is
repeatable: the library reads no clock and runs no commands.

A snapshot contains `runtime`, `routes`, `pools` and `readers`. Each route has a
canonical model `id`, nullable `maker` and served `model` spelling. Routes
survive failed captures unchanged. They do not establish Reader attribution or
inference availability.

Each pool declares its expected `readerPool` and a `limits` map. A limit has:

- `capacity`: a positive finite amount.
- `models`: a nonempty list of canonical route ids.
- `role`: `gate` or `pace`, chosen by the registration.
- `unit`: `percentagePoint` or `USD`.
- `window`: an exact Reader window key, used once within that pool.

Scope is explicit. A registration for `7d:fable` lists its canonical model ids;
no suffix or family matching expands them. Unregistered windows produce a safe
count and set `scopeResolved` to false. They grant no unrestricted allowance.

Each capture has integer `exit`, ISO 8601 `finishedAt` with an offset, and JSON
text `stdout`. Offline callers can instead supply the decoded envelope as
`data`. If `stdout` is present it takes precedence. Nonzero exits ignore the
payload and report only the exit status. Successful envelopes have `account`
(with nullable string `auth_index`, `name` and `plan`), `pool` exactly matching
`readerPool` (including whitespace), and a `windows` map. Concatenated accounts
and excessive JSON nesting are refused by the JSON parser. Account values and
unknown fields are never copied to output.

Window quantities, timing, status and extras are checked independently. Bad
timing preserves measured zero. Bad extras preserve valid allowance. Missing or
failed captures preserve every registered limit slot. Diagnostics contain local
reason codes, never parser errors or upstream stderr.

Remaining and used amounts retain the registered native unit. Durations retain
the Reader's seconds, including actual monthly lengths. Reset and expiration
timestamps accept ISO 8601 with an offset; output instants are Unix seconds.
Capture fractions are truncated. A reset may exceed the duration from capture by
one second to allow upstream rounding.

Observations older than 3600 seconds or at/past their reset are stale; they are
never assumed refilled. Natural resets remain visible. Only a valid exhausted
`gate` exposes `gateOpensAt`. Positive gates may have no reset. Idle windows (0
used, 100 remaining) may have no reset in either role. Duration never changes a
gate into a pace limit.

Reader status can be a string or null. `active`, `critical`, `estimated`,
`normal`, `ok` and `warning` establish enforcement. Other values leave it
unknown; malformed status values are omitted.

`readerMetadata` contains known balance kind/unit pairs (`credits`/`credits` and
`extra_usage`/`USD`) and whole nonnegative `promo_credits` or `rate_limit_reset`
counts. Missing or malformed arrays stay unknown; valid empty arrays stay empty.
Bad entries are omitted individually. These facts establish neither wallet
credit nor reset eligibility.

Run the owner check `delegate-routing-observation-normalize` to check the
boundary. It uses Pydantic v2 and Hypothesis through its Nix Python environment.
Configured Reader collection, CPA attribution and ranking remain separate.

## Credential collection

`lib/pacing.nix` builds manifests from evaluated module options and existing CPA
routes. `scripts/usage-collect.py` accepts a typed `Manifest` and returns a
normalizer `Snapshot`. Its first callers are owner tests; it installs no
command.

Register a credential under
`ai.programs.delegate-routing.pools."<instance>/<credential>"`. Set
`usage.runtime`, `usage.technique` and `usage.readerPool` to select its Reader
and exact envelope label. Each `limits.<name>` needs a Reader `window`, `role`
(`gate` or `pace`), `unit` and `capacity`. `models = null` covers that
credential's actual offers; a model list scopes the limit explicitly, including
windows such as `7d:fable`.

USD capacity comes from the existing monthly USD `window.limit`; a conflicting
explicit capacity fails. USD collection uses `anthropic-api-usage`, which
receives the budget and reset day. No registration or no Reader label leaves the
credential unmeasured. These registrations are separate from the routing
helper's family-scoped Readers and cannot be selected as `sessionPool`.

Collection shares the helper's timeout and retry policy and executes each
distinct command once, including its retries. It preserves overlapping offers
and all routes after failure. Captures use offset-bearing ISO timestamps; the
caller supplies the observation clock, and tests can substitute the completion
clock. Failure diagnostics contain fixed reasons and status codes, never stderr
or exception text.

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
