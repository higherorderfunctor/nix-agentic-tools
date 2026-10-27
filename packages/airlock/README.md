# Airlock

Airlock is a local egress proxy for coding harnesses, built from the in-tree
Rust workspace.

The server listens only on IP loopback addresses and detects HTTP/1.1 or
cleartext HTTP/2 prior knowledge on the same port. CONNECT opens a TCP tunnel to
a hostname or IP address with an explicit port, forwarding opaque bytes without
TLS interception. Native HTTPS client authentication is unchanged. The listener
currently accepts CONNECT without proxy authentication; domain policy is not
implemented yet.

Cleartext clients choose HTTP/2 by sending its prior-knowledge preface; HTTP/1.1
clients use the same listener automatically. The proxy listener does not yet
offer TLS or ALPN negotiation. TLS inside a CONNECT tunnel remains opaque.
Native Claude traffic through `HTTPS_PROXY` has not been validated to use
HTTP/2; the HTTP/2 tests here select it with a prior-knowledge client.

`GET /health` returns `200 OK` with an `ok` body once the listener is ready.
Other paths return `404`; other methods on `/health` return `405` with
`Allow: GET`. Absolute-form HTTP proxy requests are not supported. Malformed
CONNECT targets return `400`, failed upstream connections return `502`, and a
dial exceeding 10 seconds returns `504`. At most 16 blocking DNS lookups run or
wait in the runtime's blocking queue. A timed-out lookup retains its slot until
the resolver finishes; waiting for a slot shares the dial deadline. IP literals
bypass DNS.

```bash
airlock serve                         # 127.0.0.1:8318
airlock serve --listen 127.0.0.1:9000
curl http://127.0.0.1:9000/health
curl --proxy http://127.0.0.1:9000 https://example.com/
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

## Local CA

`airlock ca init DIRECTORY` creates the local CA material that a later TLS
interception unit can consume: `DIRECTORY` is mode 0700 and owned by the current
user, `ca.key` is a PKCS#8 key with mode 0600, and `ca.pem` is the matching
self-signed CA certificate with mode 0644. The command prints only `ca.pem`'s
path. Re-running it validates and reuses the existing pair, and refuses partial,
expired, non-CA, mismatched, badly signed, symlinked, exposed, or otherwise
unusable material instead of rotating it. It does not install the certificate
into a system or browser trust store, change trust configuration, or alter the
passthrough `serve` behavior.

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

Inside the repository development shell, from `packages/airlock/src`:

```bash
cargo build --locked
cargo run --locked -- serve --listen 127.0.0.1:0
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```

The Nix package uses the repository's locked Rust toolchain. Rust tests cover
HTTP responses, authority validation, byte streaming and half-close in both
directions, HTTP/2 multiplexing and flow control, stream reset isolation,
loopback binding, listener limits, header deadlines, owned tunnel shutdown and
CLI signals. `checks.airlock-package` checks the packaged `--help` and
`--version` entry points.

`checks.airlock-instances` covers module wiring, port claims and native Claude
settings preservation. `checks.airlock-instance-runtime` starts each backend's
generated service launcher and requests `/health` at a configured nondefault
port. Rust protocol tests run through the Nix package's `doCheck`.
