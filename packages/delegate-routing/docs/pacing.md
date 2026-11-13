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

## Configured collection

Home Manager and devenv install `delegate-routing-allowance-preview` whenever a
delegate-routing runtime is enabled. Run it with
`--runtime codex --now 2026-11-12T01:35:00Z`. This explicitly named preview
leaves the routing helper, its configured family pool attribution, ranking and
skill unchanged. The source CLI accepts `--manifest <path>` for the same
runtime-indexed registrations. `--snapshot` bypasses even an installed default
manifest and stays transport-free.

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
credentials. No first-credential attribution is inferred.

USD limits consume the existing `window` budget: unit `USD`, matching capacity
and exact `monthly` window. The configured accounted Reader receives that
budget's `--limit`, `--reset-day`, `--time-zone UTC`, expected `--pool` label
and explicit `--now-ms` clock. No new pricing source or transport is introduced.

Manual callers use `content.mkObservation { cpaRoutes; pools; techniques; }`,
passing the same direct CPA projection and effective technique registry as
module callers. Each distinct command runs once with a 30-second timeout.
Execution errors, timeouts and nonzero exits share one retry after two seconds;
successful invalid JSON or envelopes are never retried. Failure preserves routes
and emits only the normalizer's safe reason/status/count fields; it does not
certify inference availability.

`delegate-routing-observation-command` tests collection using fake executables
and all five saved production envelope shapes, with scratch under its output
directory. Synthetic CPA properties test credential identity, scope refusal and
USD budget reuse. Both backend `observation-command` checks execute their
installed package and the manual builder and compare results. These checks make
no provider request. Preview output has no stable schema promise.
