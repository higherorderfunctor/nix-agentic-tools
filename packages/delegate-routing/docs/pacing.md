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
