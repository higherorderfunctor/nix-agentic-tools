# airlock transport and routing

> **Last verified:** 2026-10-25 — CONNECT, model and classifier routing,
> ToolSearch, remote-control paths, quota substitution, and M08 primary-header
> observation share the gateway path; the control listener remains a separate
> authenticated surface.

## Transport

A loopback TCP HTTP CONNECT forward proxy, reached through `HTTPS_PROXY`. Every
connection goes through airlock, but only the hosts an upstream lists in
`intercept` are decrypted; any other host is tunnelled or refused per
`unknownHosts`. A client identifies itself with the token in
`Proxy-Authorization: Basic`, so its proxy URL is
`http://<client>:<token>@127.0.0.1:<port>`.

The optional control listener is not a CONNECT proxy and must use a different
port. Its dedicated bearer token never authenticates gateway clients, and no
control route can select an inference credential or bypass model routing.

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
  or duplicate selectors fail before forwarding. Before body inspection, the
  `auto-mode-classifier-` `anthropic-beta` token selects primary routing even
  when its body names a z.ai model. A token other than the pinned
  `auto-mode-classifier-2026-07-16` emits a warning with the fixed reason
  `classifier_fingerprint_drift`; it still routes to primary. Raw header bytes
  detect drift, including obs-text. Other beta values, including
  `dangerous-tool-use-2026-09-03`, leave model routing unchanged. Other methods
  and paths stream. A selected endpoint gets its own verified TLS connection,
  independent ALPN, authority and path prefix. Responses stream without waiting
  for completion; HTTP/1.1, h2 and Upgrade remain supported.
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
- Only an actual primary response contributes a typed header-window observation
  to SQLite. Showing cached primary headers on a non-primary response does not
  create or refresh that observation. A full observation queue or failed write
  increments the shared pending snapshot-loss count without delaying response
  forwarding; recovery or clean shutdown persists it. The source and age remain
  separate from the out-of-band Claude quota fetch in the usage report.
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
