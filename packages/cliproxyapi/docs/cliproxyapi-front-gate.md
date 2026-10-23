# CLIProxyAPI front gate (cpa-gate)

> **Last verified:** 2026-10-22 — the gate checks call bodies, filters five CPA
> listing shapes and detail responses, reports listing health, and checks
> Responses websocket messages; no module option enables it.

**cpa-gate is NOT a security boundary, and nothing wires it in yet.** A harness
that runs under the same uid as the gate can read the policy file, which holds
every client key and every internal key, and can read CLIProxyAPI's own config
and logins. It becomes a boundary only once each harness has its own VM or uid.

A Caddy HTTP handler, `http.handlers.cpa_gate`, meant to sit in front of
CLIProxyAPI (CPA). It admits a request only when it carries exactly one known
client key on an allowed route, and replaces that key with the entry's internal
key, so CPA applies its key allowlist to the principal the gate chose. The Go
module is `src/cpa-gate` (module path `cpagate`, never fetched); the binary is
Caddy's own `main` plus one import.

`lib/gate.nix` renders the Caddyfile from shared pieces. Only the listing paths
have a downstream `reverse_proxy`; a second loopback site serves
`cpa_gate_health`.

## Policy file

`CPA_GATE_POLICY` carries the policy file's **path**, never a key. Caddy splices
environment values before parsing and keeps them in adapted config. The `*`
matcher prevents an absolute policy path becoming a path matcher. The file is
JSON:

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

`Provision` refuses empty entries, duplicate entry names or client keys, empty
keys/APIs/models, unknown API routes or policy fields, client/internal key
collisions and trailing JSON. Errors name fields, never values. Client keys are
SHA-256 digests scanned with constant-time comparisons. Hosted tools declare
implied models inside the entry's set; an empty map denies every hosted tool.
Entry names are public metadata on the loopback health endpoint.

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
positions, are exempt from model checks.

The two Responses websocket routes terminate both connections with
gorilla/websocket v1.5.3 and no compression. Each client text message is
reassembled up to 32 MiB and checked with the same strict gjson v1.18.0 reader.
The first needs a model; later messages may inherit it. Every supplied model is
checked, including interrupt messages. Top-level values with surrounding
whitespace are refused even if literally in the set: CPA trims them. Accepted
bytes, upstream text/binary messages and both directions of ping/pong/close
controls relay unchanged. Application messages with invalid JSON/UTF-8, excess
size, binary data or disallowed models close both connections with fixed code
1008 and `request refused`. Gorilla closes transport protocol errors itself. A
service restart ends hijacked sessions by exiting the process.

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
- **404**, every route, body, listing, detail or websocket handshake refusal: no
  body, as CPA's gin `NoRoute` answers. Message refusals use the fixed websocket
  close above.

The handler writes refusals itself and returns nil. A returned error would make
Caddy log the whole request. Its own line holds the entry name (`-` before
authentication), the route class, the status and the reason, never a key, a
header or the URI.

Caddy copies requests before handlers run, including query strings and
nonstandard key headers. The global log filter therefore deletes both
`request>headers` and `request>uri`. No access log is enabled.

`packages/ai/generic/cpa-gate` builds `cmd/cpa-gate` with `buildGoModule` and
nixpkgs' Caddy version and build tags. `gate.json` pins `goFloor` and
`vendorHash`; nixpkgs and direct updates regenerate it, `go.mod` and `go.sum`,
and `cliproxyapi-gate-pins` checks the version.

## Checks

- Go tests run in the package check phase, including real Caddy listing and
  websocket paths, process-exit socket closure, frame refusal before forwarding,
  and key-free logs.
- `cliproxyapi-gate-pins`: the Caddy pin, with a wrong-pin control.
- `cliproxyapi-gate-validate`: the real binary validates the rendered Caddyfile
  with a good policy, and refuses a shared key, a missing file and an empty
  path.
- `cliproxyapi-gate-log` (Linux): every key carrier stays out of error logs;
  controls retain each deleted field and demonstrate the leak.
