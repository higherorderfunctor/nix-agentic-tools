# CLIProxyAPI front gate (cpa-gate)

> **Last verified:** 2026-10-22 — the gate checks call bodies, filters five CPA
> listing shapes and detail responses, and reports listing health; websockets
> remain refused, and no module option enables it.

**cpa-gate is NOT a security boundary, and nothing wires it in yet.** A harness
that runs under the same uid as the gate can read the policy file, which holds
every client key and every internal key, and can read CLIProxyAPI's own config
and logins. It becomes a boundary only once each harness has its own VM or uid.

## What it is

A Caddy HTTP handler, `http.handlers.cpa_gate`, meant to sit in front of
CLIProxyAPI (CPA). It admits a request only when it carries exactly one known
client key on an allowed route, and replaces that key with the entry's internal
key, so CPA applies its key allowlist to the principal the gate chose. The Go
module is `src/cpa-gate` (module path `cpagate`, never fetched); the binary is
Caddy's own `main` plus one import.

`lib/gate.nix` renders the Caddyfile from the shared `lib/ai/caddy.nix` pieces.
Only listing routes have a downstream `reverse_proxy` in this PR. Calls still
reach the end of the route after their body check, preserving the prior module
behavior until instance wiring lands.

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

`Provision` loads it and fails `caddy run` and `caddy validate` on an empty
client or internal key, empty `apis` or `models`, an `apis` value no route
names, two entries sharing a client key, a client key equal to any internal key,
and any field this build does not enforce. A second JSON value or trailing junk
is refused. Errors name entries and fields, never values; entry names are public
metadata. In memory a client key is kept only as its SHA-256 digest;
authentication scans all digests with constant-time comparisons. Each
`hostedTools` type declares implied models inside the entry's set; the empty map
denies every hosted tool.

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

Listings are inspected by response shape, independently of the request's user
agent or headers. OpenAI, Anthropic, and Grok use `data[].id`; Codex uses
`models[].slug`; Gemini uses `models[].name` with a `models/` prefix. The gate
keeps only IDs in the entry's exact model set, recomputes `first_id` and
`last_id` when present, and replaces a nested object with `null` if one of its
model-like fields names an out-of-set model. This includes Codex's
`upgrade.model`. Unknown shapes, malformed JSON, non-200 responses, and
oversized or invalid compressed listings get the same empty 404 as a refused
route. A detail path outside the set gets that response before it reaches CPA; a
missing detail upstream gets the same response. The gate sends
`Accept-Encoding: identity`, bounds wire and decoded listings at 32 MiB, and
publishes only rewritten JSON with a new `Content-Length`.

The separate `cpa_gate_health` handler serves `GET /-/health` on a loopback
port. Its policy-path registry starts in a failed state, checks each internal
principal's OpenAI listing immediately and every 60 seconds, and is removed on
Caddy cleanup. It reports each entry's `ok` and missing **count**, with no model
IDs or keys; client credentials cannot call it. The checker logs only status and
counts. The policy refuses duplicate or empty entry names so health cannot
silently combine two principals.

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
the locked Go, at the version and build tags of nixpkgs' `caddy`. It is not
`caddy.withPlugins`, for three reasons:

- `withPlugins` takes a plugin only as `module@version`.
- It vendors everything into one fixed-output tree, whose hash would move on
  every gate edit.
- Its install check needs a version that a local path lacks.

`buildGoModule` vendors only the dependencies, so `vendorHash` moves with
`go.mod`. `gate.json` holds `goFloor` and `vendorHash`, the same sidecar keys
the other Go recipes use.

`src/cpa-gate/go.mod` requires the Caddy version nixpkgs ships. The package
declares `updateFlakeInput = "nixpkgs"` and a `regenerateExtracted` script, so a
nixpkgs update runs the same script as a direct package update and stages
`gate.json`, `go.mod`, and `go.sum`. It runs `go get` for nixpkgs' Caddy, then
`go mod tidy`, then the floor and vendor-hash fixers. `cliproxyapi-gate-pins`
checks the resulting version.

## Checks

- The Go tests run in the package's check phase: an independent route contract,
  call forwarding, strict model parsing and compressed bodies, five CPA listing
  envelopes, nested scrubbing, detail responses, bounded capture and
  decompression, listing health and registry cleanup, refusal controls, complete
  policy loading and the directive. A test fails if any log or error carries a
  key.
- `cliproxyapi-gate-pins`: the Caddy pin, with a wrong-pin control.
- `cliproxyapi-gate-validate`: the real binary validates the rendered Caddyfile
  with a good policy, and refuses a shared key, a missing file and an empty
  path.
- `cliproxyapi-gate-log` (Linux): a running gate, and a site beside it whose
  upstream is down. A key in each carrier reaches neither log. Two controls each
  keep one field and show its unredacted keys; Caddy also redacts Authorization
  itself.
