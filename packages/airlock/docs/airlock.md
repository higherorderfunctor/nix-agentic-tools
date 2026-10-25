# airlock

> **Last verified:** 2026-10-25 — Anthropic groups route by model; the z.ai
> preset aliases `ToolSearch` in requests and restores it in JSON and SSE
> responses. Primary quota headers replace non-primary display headers.
> Model-list requests stay on the primary; picker credentials follow Claude's
> CONNECT host. OpenAI and managed OAuth remain gated.

## Scope

airlock is becoming the sandboxed harness's egress gateway for providers, MCP,
gh/glab, guarded web and git+ssh. CLIProxyAPI coexists for now.

## Transport

A loopback TCP HTTP CONNECT forward proxy, reached through `HTTPS_PROXY`. Every
connection goes through airlock, but only the hosts an upstream lists in
`intercept` are decrypted; any other host is tunnelled or refused per
`unknownHosts`. A client identifies itself with the token in
`Proxy-Authorization: Basic`, so its proxy URL is
`http://<client>:<token>@127.0.0.1:<port>`.

Interception follows this order:

- airlock reads the ClientHello and requires its SNI to equal the CONNECT host,
  else it closes (`sni_mismatch`, `sni_missing`, `not_tls`). Otherwise a client
  could CONNECT to one host and speak TLS to another under that host's leaf.
- It opens verified TLS to the real host with the client's ALPN list (system
  store or `SSL_CERT_FILE`), then offers the chosen protocol to the client.
- Startup loads client tokens and every credential in a granted group once,
  collecting unreadable or empty files. Ungranted groups stay inert.
- The original verified upstream chooses client ALPN and carries primary feature
  traffic. Each inference POST to `/v1/messages` is buffered in zeroizing memory
  up to 32 MiB, parsed by serde_json for one top-level model and replayed byte
  for byte. Requests carrying trailers receive 400, and larger bodies receive
  413; no request reaches any upstream in either case. Missing or null models
  retain the original host; unclaimed IDs select the primary endpoint. Malformed
  or duplicate selectors fail before forwarding. Other methods and paths stream.
  A selected endpoint gets its own verified TLS connection, independent ALPN,
  authority and path prefix. Responses stream without waiting for completion;
  HTTP/1.1, h2 and Upgrade remain supported.
- The selected z.ai Anthropic preset aliases `ToolSearch` in declarations,
  choice, history and references inside one tool-result level, then restores
  response tool-use names in JSON and SSE. Deeper tool results are refused.
  Other request bytes remain exact; a declared `ToolSearch_` gets 400. An
  aliased request asks for identity encoding; a compressed success gets 502
  before body forwarding. JSON is capped at 32 MiB; each SSE event at 1 MiB and
  emitted when complete. SSE accepts CR, LF and CRLF line endings and
  case-insensitive `text/event-stream` media type.
- Each upstream response atomically replaces its cached `anthropic-ratelimit-*`
  snapshot, keyed by client, group and credential with an observation time. On a
  successful non-primary response, airlock replaces that header family with the
  primary snapshot before streaming the body. A cold or empty primary snapshot
  leaves that family absent. Non-primary errors keep their own rate-limit
  headers. `retry-after` always belongs to the selected response and is never
  cached or substituted. Status, ordinary headers and body usage remain from the
  selected provider. Each snapshot is limited to 64 header values and 16 KiB; an
  oversized observation clears it.
- Before injection, every request drops client `Authorization` and `x-api-key`
  values plus hop-by-hop fields named by `Connection`. An OAuth credential is
  injected as a sensitive Authorization bearer header; an API key is injected as
  a sensitive x-api-key header. Non-primary routes also remove client cookies.
- A valid HTTP/1 upgrade keeps `Upgrade` and `Connection: Upgrade`, forwards the
  101, and then bridges the two upgraded byte streams. Other upgrades and
  hop-by-hop fields are removed. An upstream send or handshake failure on an
  applicable request becomes 502.
- The CONNECT audit carries `sni`, `alpn` and request count. Each request event
  carries its selected credential and bounded model ID, never body bytes or
  secrets. Byte counters cover completed TLS application writes, including HTTP
  framing, rather than body payload alone. Normal connections retain bounded
  `close_notify` shutdown; an upgraded stream is relayed until one peer closes.

The CA lives in `$XDG_RUNTIME_DIR/airlock-<port>/` (0700): `ca.key`
(PKCS#8, 0600) and `ca.pem` (0644), ECDSA P-256 with `pathlen:0` and no name
constraints. Startup requires absolute, user-owned 0700 directories and Linux
tmpfs/ramfs; tmpfs rotates the CA at reboot. It rejects symlinks, incomplete
key/cert pairs, exposed or mismatched keys, and never overwrites an existing
file. Only `ca.pem` leaves airlock for the sandbox trust bundle. Per-host leaves
have separate keys, seven-day validity and stay in memory.

Why CONNECT and not a base URL, measured 2026-10-24 against Claude Code 2.1.309
with a local CONNECT proxy intercepting TLS and a fake token, offline:

- Through `HTTPS_PROXY` with no base URL, the `/v1/messages` body carries the
  first-party billing tag with its signature (`cch=…`), and the request sends
  `Authorization: Bearer <CLAUDE_CODE_OAUTH_TOKEN>`.
- With `ANTHROPIC_BASE_URL` set, the same tag has no `cch=`, and Claude Code
  turns off first-party features. That is why CLIProxyAPI has to re-forge it.
- Every CONNECT carried `Proxy-Authorization` from the userinfo in
  `HTTPS_PROXY`, so one port can tell clients apart.
- All traffic went to `api.anthropic.com`, on many `/api/*` paths besides
  `/v1/messages`. An intercepted host must pass every path through and swap the
  token wherever it appears; an allowlist of paths would break features.

## Not a security boundary yet

airlock runs as the harness's uid. `ai.jail` binds `/` into the jail, so the
harness can read airlock's runtime directory, its CA key, its state and the
secret files the launcher writes there. Until airlock runs under a separate uid
or outside the harness's VM, it keeps real credentials out of the harness's
environment and config, not out of its reach.

## Nix wiring

`modules/instances.nix` is one module for both backends, through
`packages/ai-module/lib/instances.nix`. Each instance is the `ai.services` entry
`airlock-<name>` running `airlock serve --config "$AIRLOCK_CONFIG"`; its port
and service name are claimed by the helper.

`settings` mirrors Rust's `RawConfig`: the render renames `stateDir` →
`state_dir`, `unknownHosts` → `unknown_hosts`, and client `token` →
`token_file`, while omitting null `preset` and managed-OAuth `file`. Rust checks
IDs, references, URLs, protocols, primary and model ownership for direct JSON
and Nix output; `airlock-config-roundtrip` passes a rendered sample to
`check-config`, and raw structs deny unknown fields.

`providers.<id>` holds a `claude` or `zai` preset plus optional protocol-keyed
endpoint overrides. Rust expands the preset once: Claude Anthropic resolves to
`https://api.anthropic.com`; z.ai Anthropic to `https://api.z.ai/api/anthropic`,
and z.ai OpenAI to `https://api.z.ai/api/coding/paas/v4`. No Codex endpoint is
asserted yet. `credentials.<id>` names a provider and auth mode; `groups.<id>`
names one protocol, its first-party intercept hosts, a primary credential and
member credentials with exact model IDs. A client grants whole groups. The
primary owns undeclared models; non-primary members need explicit IDs. A
duplicate ID within a group is invalid.

Client tokens and file-backed credentials use `redact.types.secretFile`; the
launcher writes each value to a 0600 runtime file and renders only its absolute
path. `oauth_managed` has no file and is shape-checked for the future primary
OAuth flow. Active managed OAuth and OpenAI make `serve` fail before secret
loading. Endpoint overrides may include a port for local tests.

## Harness selection

Claude selects an airlock instance through the existing proxy fields,
`ai.claude.proxy = { instance = "<airlock instance>"; clientKey = "<client>"; }`.
CPA and airlock instance names share one claims group, so a name resolves to one
owner, and that owner decides the transport. Only Claude supports airlock; any
other runtime selecting it fails evaluation. On Linux the jail is required;
config-only and non-Linux surfaces warn and get no launcher.

At launch the harness reads its client's `token_file` from the service-rendered
config, exports a percent-encoded `HTTPS_PROXY`, and clears every other proxy
variable. It holds a fake OAuth token, and its route overlay blanks the CPA base
URL and `apiKeyHelper`. Picker IDs come only from the selected client's granted
Anthropic group intercepting `api.anthropic.com`, including explicit primary
declarations. Home Manager writes those rows to user settings, while devenv
passes them in its `--settings` overlay. Only the managed settings scope loads
(user on Home Manager, project on devenv), so no other scope can override the
route; managed admin policy is outside this contract. The jail gets system roots
plus the current `ca.pem` as one read-only bundle over
`/etc/ssl/certs/ca-certificates.crt` through an unlinked descriptor, rebuilt per
launch. A missing token, config, roots or CA fails the launch: no wait, no CPA
or direct fallback.

## Settled — do not relitigate

- **A unix socket with Claude Code's `ANTHROPIC_UNIX_SOCKET` placeholder mode is
  not the main path.** Its runtime path is unknown at evaluation and it serves
  only Claude; CONNECT serves every client honouring `HTTPS_PROXY`.
- **Base-URL mode is not the main path.** Claude Code drops `cch` behind
  `ANTHROPIC_BASE_URL`, so a subscription request would have to be forged.
- **No Postgres for now.** Home Manager has no user-level Postgres module, so it
  would break Home Manager and devenv parity. The SQLite state contract lives in
  `docs/storage.md`.
