# CLIProxyAPI front gate (cpa-gate)

> **Last verified:** 2026-10-22 — opt-in instance wiring splits named client
> keys from independent internal secrets, filters exact provider-side model
> unions, and shares restart triggers; websockets remain refused.

**cpa-gate is NOT a security boundary.** A harness that runs under the same uid
as the gate can read the policy file, which holds every client key and every
internal key, and can read CLIProxyAPI's own config and logins. It becomes a
boundary only once each harness has its own VM or uid. CPA already refuses
upstream credentials outside each client's named routes through its credential
allowlist.

## What it is

A Caddy HTTP handler, `http.handlers.cpa_gate`, meant to sit in front of
CLIProxyAPI (CPA). It admits a request only when it carries exactly one known
client key on an allowed route, and replaces that key with the entry's internal
key, so CPA applies its key allowlist to the principal the gate chose. The Go
module is `src/cpa-gate` (module path `cpagate`, never fetched); the binary is
Caddy's own `main` plus one import.

`lib/gate.nix` renders the Caddyfile from shared pieces. Admitted calls and
filtered listings reach CPA through `reverse_proxy`; a second loopback site
serves `cpa_gate_health`.

## Instance wiring

Set `ai.cliproxyapi.instances.<name>.gate.enable = true` together with
`exactModels = true`. The default is false and preserves the original config and
service units. The gate takes `instance.port`; CPA moves to `gate.internalPort`
(18317), fixed to `127.0.0.1`, and `gate.healthPort` (28317) serves loopback
health. All ports are claimed. `gate.host` defaults to loopback. Multiple
instances need distinct ports.

Each named `clientKeys` entry keeps its external key for Harness selection. Only
the gate's `serviceEntry.files.policy` reads that key. CPA's `api-keys` and
`key-allowlist` instead read an independent 256-bit random internal key per
named client, with exactly the existing route rules. Either service's first
start generates it in `<stateDir>/gate-keys`; a process lock serializes
creation, and an atomic rename publishes the complete 0600 file inside a 0700
directory. Keys persist across restarts, are never derived from client keys, and
never enter evaluation or the store. Both launchers use `redact.command` to read
them. No internal key reaches a Harness. Remove raw access entries: the gate
owns the complete access key lists. CPA debug and request/file logging are
forced off, and its body ceiling matches the gate's 32 MiB.

CPA also logs model names at Info during session affinity and on upstream
failures, with no lower log-level option. For gated instances its exec discards
stdout and stderr; `server.commercial-mode = true` omits the error-request file
logger, and file logging is disabled. This sacrifices CPA's startup and upstream
diagnostics: use its exit status and the gate's health counts/refusal logs.
Redact readers run earlier in the parent service launcher; suppression cannot
consume or alter their secret output. The exact-mode preflight still reports its
value-free refusal before CPA starts.

The policy's model set is the exact union of the routed credentials' selected
provider-side models. G3 refuses a union member excluded from any other routed
credential whose catalog registers it. Comparisons preserve exact bytes; there
are no per-client model overrides here. Upstream `routes[].api` chooses the CPA
credential family; the gate admits Anthropic, Chat and Responses client
protocols because CPA translates them. Hosted tools remain denied and websockets
remain refused. This wiring does not define upstream routing order.

Both services share `restartOnChange`: the config/policy revision and all
file-backed client and upstream credentials. Changing either set restarts both;
command references require an explicit restart. Runtime keys remain solely in
private rendered files; the Caddyfile receives only the policy path.

## Policy file

`CPA_GATE_POLICY` carries the policy file's **path**, never a key. The `*`
matcher is required: Caddy takes a first argument that starts with `/` as a path
matcher. A key in a Caddyfile `{$VAR}` would be spliced in before parsing, an
unset one becomes an empty string, and the adapted config holds the value in
clear. The file is JSON:

```json
{
  "entries": [
    {
      "name": "codex",
      "key": "<client key>",
      "internal": "<internal key>",
      "apis": ["responses"],
      "models": ["gpt-6-sol"],
      "hostedTools": {}
    }
  ]
}
```

`Provision` fails on an empty `entries` list (health would report OK while
serving nothing), empty or duplicate entry names (health is keyed by name),
empty keys, `apis` or `models`, unknown API routes or policy fields, duplicate
client keys, a client key equal to an internal key, and trailing JSON. Errors
name entries and fields, never values; entry names are public metadata, since
`/-/health` returns every one to any loopback caller without a credential.
Client keys remain in memory only as SHA-256 digests, scanned with constant-time
comparisons. Each `hostedTools` type declares implied models inside its entry's
set; an empty map denies every hosted tool.

## Requests

1. **Authentication.** CPA reads a key from `Authorization`, `X-Goog-Api-Key`,
   `X-Api-Key`, `?key=` and `?auth_token=`
   (`internal/access/config_access/provider.go`). The gate counts every value of
   all five: exactly one is allowed, so two carriers, a repeated header and a
   repeated query key are refused. `Authorization` must be `Bearer <key>`, with
   the scheme in any case, one separator space, and then the exact configured
   key. An unparsable query is refused here too.
2. **Route.** Method and path match the table in `gate/routes.go` exactly, and
   the path must carry no escaping Go would not produce (`RawPath` empty). So
   `//`, dot segments, a trailing slash, case variants and `%2F` miss. The
   entry's `apis` must admit the route, and the query may hold only the route's
   own keys, once each, besides the carriers.
3. **Rewrite.** On every route but the two websocket ones, `Connection` and
   `Upgrade` are deleted, because `reverse_proxy` relays an upgrade on any
   route. Then all five carriers go and `Authorization: Bearer <internal>` is
   set.

| `apis`      | Routes                                                                                                               | Query                        |
| ----------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| any         | `GET /v1/models`, `GET /v1/models/{id}`                                                                              | `client_version` on the list |
| `anthropic` | `POST /v1/messages`, `POST /v1/messages/count_tokens`                                                                | `beta`                       |
| `chat`      | `POST /v1/chat/completions`                                                                                          | none                         |
| `gemini`    | `GET /v1beta/models`, `GET /v1beta/models/{name}`                                                                    | none                         |
| `responses` | `POST` `responses` and `responses/compact`, `GET responses` (websocket), each under `/v1/` and `/backend-api/codex/` | none                         |

Calls forward after a strict body check. The gate caps wire and decoded bodies
at 32 MiB, accepts JSON with absent/`identity`/`gzip`/`zstd` encoding, and
forwards the exact decoded bytes with `Content-Encoding` removed. It checks the
top-level `model` with CPA's gjson version, every model-like name at any depth,
and hosted tools against `hostedTools`. It refuses duplicate or escaped
directive names, invalid UTF-8, lone surrogates, non-ASCII names outside client
data, trailing values and nesting beyond 128 levels. Only schemas at
`tools[].input_schema`, `tools[].parameters`, `tools[].function.parameters`,
`text.format.schema`, `response_format.json_schema.schema`, and
`output_format.schema`, plus client tool arguments at their structural
positions, are exempt from model checks. Websocket routes remain refused with
`"reason": "pending"`.

Listings are parsed by wire shape, never by request header or user agent. Only
exact allowed IDs survive, `first_id`/`last_id` are recomputed, and an object
with a forbidden model directive becomes null (Codex's `upgrade.model`). A
private writer buffers the response, so CPA's interim 1xx headers and trailers
never reach the client. Everything else gets the empty 404: an unknown shape or
envelope field, a paginated listing, non-200, an interrupted or oversized copy,
and a disallowed or missing detail.

`cpa_gate_health` serves `GET /-/health` on a separate loopback site. It starts
failed, then probes each internal principal's `/v1/models` through serving's own
decoder and interpreter, immediately and every 60 seconds. It reports each
entry's `ok` and missing **count**, never model IDs or keys, and refuses any
request carrying a client credential. Logs hold counts only.

## Refusals and logs

- **401**, every authentication failure: `{"error":"Invalid API key"}`, CPA's
  own body for an unknown key (`sdk/access/errors.go`).
- **404**, every route, body, listing, detail or pending websocket refusal: no
  body, as CPA's gin `NoRoute` answers.

The handler writes refusals itself and returns nil. A returned error would make
Caddy log the whole request. Its own line holds the entry name (`-` before
authentication), the route class, the status and the reason, never a key, a
header or the URI.

Caddy's error log copies the request before any handler runs
(`modules/caddyhttp/server.go`). That copy holds the URI with its query and
every header but the four Caddy redacts, so `?key=`, `X-Api-Key` and
`X-Goog-Api-Key` would reach the journal on any 5xx. The global log block
therefore deletes the whole `request>headers` map and `request>uri`.

## Package and updates

`packages/ai/generic/cpa-gate` builds `cmd/cpa-gate` with `buildGoModule` and
nixpkgs' Caddy version and build tags. `gate.json` pins `goFloor` and
`vendorHash`; nixpkgs and direct updates regenerate it, `go.mod` and `go.sum`,
and `cliproxyapi-gate-pins` checks the version.

**Settled, do not relitigate:** the package is not `caddy.withPlugins`.
`withPlugins` takes a plugin only as `module@version`; it vendors everything
into one fixed-output tree whose hash would move on every gate edit; and its
install check needs a version that a local path lacks.

## Checks

- `module-service-instances-gate-*` checks both backend projections and
  default-off config/units, exact-mode and G3 refusals, and shared triggers.
- `module-service-instances-runtime-providers` exercises both named client keys
  through real CPA and gate launchers: exact listings, each model over HTTP and
  incremental SSE, internal-port authentication, uniform refusals with empty
  upstream logs, and no keys or model IDs in daemon logs.
- Go tests run in the package check phase, including a real Caddy copy of
  listings and a test that no log or error carries a key.
- `cliproxyapi-gate-pins`: the Caddy pin, with a wrong-pin control.
- `cliproxyapi-gate-validate`: the real binary validates the rendered Caddyfile
  with a good policy, and refuses a shared key, a missing file and an empty
  path.
- `cliproxyapi-gate-log` (Linux): a running gate, and a site beside it whose
  upstream is down. A key in each carrier reaches neither log. Two controls each
  keep one field and show its unredacted keys; Caddy also redacts Authorization
  itself.
