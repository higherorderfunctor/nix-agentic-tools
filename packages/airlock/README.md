# Airlock

Airlock is a local egress proxy for coding harnesses, built from the in-tree
Rust workspace.

The server listens only on IP loopback addresses and detects HTTP/1.1 or
cleartext HTTP/2 prior knowledge on the same port. CONNECT opens a TCP tunnel to
a hostname or IP address with an explicit port. By default it forwards opaque
bytes; explicit DNS-and-port selections enable verified TLS interception. Native
HTTPS client authentication is unchanged. Proxy-client authentication is opt-in
through file-backed client tokens; domain policy is not implemented yet.

Cleartext clients choose HTTP/2 by sending its prior-knowledge preface; HTTP/1.1
clients use the same listener automatically. The proxy listener does not yet
offer TLS or ALPN negotiation. Unselected TLS tunnels remain opaque; selected
destinations negotiate inner HTTP/1.1 independently on each TLS leg. Native
Claude traffic through `HTTPS_PROXY` has not been validated to use HTTP/2; the
HTTP/2 tests here select it with a prior-knowledge client.

HTTP/1.1 clients can also send absolute-form `http://` proxy requests. Airlock
streams request and response bodies without buffering a complete body, following
redirects, or imposing a response duration limit. It regenerates HTTP framing
and removes hop headers and proxy credentials while preserving destination
authorization. Transfer codings other than a single `chunked` coding are
rejected: requests receive `400` before dialing, and upstream responses receive
`502` before their headers are forwarded. Upstream responses containing both
Transfer-Encoding and Content-Length also receive `502`.

HTTP/2 on the proxy connection supports CONNECT tunnels and the local health
route; it does not support ordinary HTTP forwarding. HTTP/1.1 forwarding keeps
one upstream authority pool per downstream connection, with at most one idle
socket and a 30-second idle expiry. Changing authorities releases the old pool,
and downstream termination releases its current pool. Requests are not retried.

Origin-form `GET /health` returns `200 OK` with an `ok` body once the listener
is ready. Other origin-form paths return `404`; other methods on `/health`
return `405` with `Allow: GET`. Malformed CONNECT targets return `400`, failed
upstream connections return `502`, and a CONNECT dial exceeding 10 seconds
returns `504`. HTTP forwarding rejects malformed proxy targets with `400`,
HTTP/1.0 proxy requests with `505`, and upstream request failures with `502`.
Both paths limit a dial to 10 seconds, including DNS capacity waits and lookup.
At most 16 blocking DNS lookups run or wait in the runtime's blocking queue
across CONNECT and HTTP forwarding. A timed-out lookup retains its slot until
the resolver finishes. IP literals bypass DNS.

```bash
airlock serve                         # 127.0.0.1:8318
airlock serve --listen 127.0.0.1:9000
curl http://127.0.0.1:9000/health
curl --proxy http://127.0.0.1:9000 https://example.com/
curl --proxy http://127.0.0.1:9000 http://example.com/
curl --http2-prior-knowledge http://127.0.0.1:9000/health
```

`--listen` also accepts IPv6 loopback (`[::1]:9000`) and port `0` to choose a
free port. Startup prints the bound address. The server owns at most 128
accepted connections. Each HTTP/2 connection allows at most 32 concurrent
streams and CONNECT jobs. The connection driver continues processing reset and
flow-control frames while all job slots are occupied. A connection must deliver
its first complete request within 10 seconds, including the HTTP/2 preface;
later HTTP/1 header reads have their own 10-second deadline. Established tunnels
have no lifetime timeout. SIGINT and SIGTERM stop accepting and allow existing
connections up to 3 seconds to finish before closing them. Runtime teardown has
a separate 10-second bound.

HTTP/1 uses Hyper's upgrade support; HTTP/2 owns its stream driver and relay
jobs directly through `h2`. A separate reset observer stays alive after either
side half-closes, so a reset cancels blocked uploads and releases the job slot
while other streams continue. Prefix detection consumes and replays at most 24
bytes under the initial request deadline.

## Configuration

`--config FILE` instead of `--listen` reads a strict JSON object such as
`{"listen":"127.0.0.1:9000"}`. It requires `listen` and rejects unknown or
duplicate fields, non-loopback addresses, and additional arguments.

The same `ai.airlock.instances.<name>` declaration starts an instance through
`ai.services` on Home Manager and devenv. For the explicit Claude opt-in and
rollback procedure, see [HTTPS passthrough](docs/passthrough.md).

## Proxy-client authentication

Configure client names and token paths in strict JSON:

```json
{
  "clients": {
    "codex": { "token_file": "/run/user/1000/codex.token" }
  },
  "listen": "127.0.0.1:9000"
}
```

Omitting `clients` preserves loopback passthrough. A present empty map fails
startup. Names contain 1–64 ASCII letters, digits, underscores, dots or hyphens;
they are labels, not runtime identities. Each token file must be a regular file
owned by the effective user with mode 0400 or 0600; symlinks are refused.
Airlock reads tokens once before binding. Replace the file and restart Airlock
to rotate a token; running processes retain the loaded value.

A token contains 1–4096 graphic ASCII bytes (`!` through `~`), optionally
followed by one LF. Spaces, tabs, CRLF, embedded newlines and non-ASCII bytes
are refused. Airlock neither creates nor changes token files. Token values are
never printed. Proxy clients send Basic credentials with the configured name as
username and token as password. If delivering credentials in a proxy URL,
percent-encode token bytes, including punctuation such as `@`, `%`, `#`, `/`,
`?` and `:`. The Nix instance opt-in does not yet configure clients or token URL
delivery.

Every outer HTTP/1 proxy request and HTTP/2 CONNECT stream authenticates before
dialing. Missing, duplicate, malformed or wrong credentials receive the same
`407` and Basic challenge. Successful admission removes proxy credentials and
preserves native destination Authorization. Local readiness `GET /health`
remains unauthenticated; absolute-form HTTP/1 `/health` requests still require
credentials. An accepted CONNECT admits its tunnel without inner authentication;
intercepted HTTP filters inner proxy headers, while opaque tunnels relay client
bytes unchanged.

## Selective TLS interception

Add `interception` to the JSON configuration to select exact DNS names and
ports:

```json
{
  "interception": {
    "ca_directory": "/private/airlock/ca",
    "destinations": ["api.example.test:443"]
  },
  "listen": "127.0.0.1:9000"
}
```

Startup creates or validates the CA before binding the listener. No trust is
installed: the client must explicitly trust the public `ca.pem`. Unselected
names, ports and IP literals retain opaque CONNECT behavior. Both outer HTTP/1.1
and prior-knowledge HTTP/2 support interception. Each inner TLS leg
independently prefers `h2`, then `http/1.1` through ALPN; a peer without ALPN
uses HTTP/1.1. Unsupported-only ALPN offers fail. Airlock translates requests
and responses between all four HTTP/1.1 and HTTP/2 combinations while streaming
bodies.

Airlock parses the ClientHello and requires SNI to match the CONNECT DNS name
before dialing. It verifies the upstream certificate chain, name and validity
before completing the downstream handshake. System certificate roots are the
default; optional `upstream_roots` names a PEM certificate file added to those
roots for private origins. There is no insecure verification mode. Leaves exist
only in memory, with one cache slot per configured name, a seven-day lifetime
capped by CA expiry, and renewal during their final day.

Each selected tunnel owns one verified upstream connection. Inner Host, absolute
URI authority, scheme and effective port must match the CONNECT destination.
HTTP/2 uses its required `:authority` and `https` scheme, and validates Host
when supplied. HTTP/1.1 requires Host. Concurrent inner HTTP/2 requests share
their upstream HTTP/2 connection or serialize on their upstream HTTP/1.1
connection. Nested CONNECT, upgrades and unsupported authorities are refused.
Native destination Authorization and request bodies stream through the existing
HTTP framing and hop-header filters. TLS setup and the first inner request’s
headers have ten-second deadlines; subsequent HTTP/1.1 header reads retain their
own ten-second bound. HTTP/2 permits at most 32 concurrent inner streams. Its
socket, stream and body work share a 128-future session limit, including uploads
that remain open after early responses; exceeding that limit closes the current
tunnel. Session termination synchronously drops queued and active protocol
futures. There is no session duration timer; inference may wait for its first
response header without a duration limit, and response bodies and SSE have no
lifetime timeout. Cancellation releases the owned upstream, while a plain
half-close permits a final response.

## Local CA

`airlock ca init DIRECTORY` creates the same local CA material used by
interception: `DIRECTORY` is mode 0700 and owned by the current user, `ca.key`
is a PKCS#8 key with mode 0600, and `ca.pem` is the matching self-signed CA
certificate with mode 0644. The command prints only `ca.pem`'s path. Re-running
it validates and reuses the existing pair, and refuses partial, expired, non-CA,
mismatched, badly signed, symlinked, exposed, or otherwise unusable material
instead of rotating it. It does not install the certificate into a system or
browser trust store or change trust configuration. Default `serve` behavior
remains opaque.

If publishing the certificate fails after the key was written, init leaves the
partial material for inspection and reports the failure. Inspect the directory
and remove unusable partial material before retrying; init does not delete a key
that another process may have replaced.

## Build and validate

From the repository root:

```bash
nix build .#airlock
nix flake check
```

Inside the repository development shell, from `packages/airlock`:

```bash
cargo build --locked
cargo run --locked -- serve --listen 127.0.0.1:0
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

The overlay exposes Airlock as `pkgs.ai.airlock`. The Nix package uses the
repository's locked Rust toolchain. Rust tests cover HTTP forwarding and framing
rejection, bounded shared DNS, authority validation, byte streaming and
half-close in both directions, client cancellation, HTTP/2 multiplexing and flow
control, stream reset isolation, loopback binding, listener limits, header
deadlines, owned tunnel shutdown and CLI signals. `checks.airlock-package`
checks the packaged `--help` and `--version` entry points.

`checks.airlock-instances` covers module wiring, port claims and native Claude
settings preservation. `checks.airlock-instance-runtime` starts each backend's
generated service launcher and requests `/health` at a configured nondefault
port. Rust protocol tests run through the Nix package's `doCheck`.
