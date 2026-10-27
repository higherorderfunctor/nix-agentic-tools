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

HTTP/1.1 clients can also send absolute-form `http://` proxy requests. Airlock
streams request and response bodies without buffering a complete body, following
redirects, or imposing a response duration limit. It regenerates HTTP framing
and removes hop headers and proxy credentials while preserving destination
authorization. Transfer codings other than a single `chunked` coding are
rejected: requests receive `400` before connecting upstream, and upstream
responses receive `502` before their headers are forwarded. Upstream responses
containing both Transfer-Encoding and Content-Length also receive `502`.

HTTP/2 on the proxy connection supports CONNECT tunnels and the local health
route; it does not support ordinary HTTP forwarding. HTTP/1.1 forwarding keeps
one upstream authority pool per downstream connection, with at most one idle
socket and a 30-second idle expiry. Changing authorities releases the old pool,
and downstream termination releases its current pool. Requests are not retried.

Origin-form `GET /health` returns `200 OK` with an `ok` body once the listener
is ready. Other origin-form paths return `404`; other methods on `/health`
return `405` with `Allow: GET`. Malformed CONNECT targets return `400`, failed
upstream connections return `502`, and a CONNECT connection attempt exceeding 10
seconds returns `504`. HTTP forwarding rejects malformed proxy targets with
`400`, HTTP/1.0 proxy requests with `505`, and upstream request failures with
`502`. Both paths limit an upstream connection attempt to 10 seconds, including
DNS capacity waits and lookup. At most 16 blocking DNS lookups run or wait in
the runtime's blocking queue across CONNECT and HTTP forwarding. A timed-out
lookup retains its slot until the resolver finishes. IP literals bypass DNS.

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

## Configuration

`--config FILE` instead of `--listen` reads a strict JSON object such as
`{"listen":"127.0.0.1:9000"}`. It requires `listen` and rejects unknown or
duplicate fields, non-loopback addresses, and additional arguments.

## Nix instances

An `ai.airlock.instances.<name>` entry runs `airlock-<name>` on its loopback
port (default 8318) through `ai.services`, on Home Manager and devenv alike.
Selecting it defaults both `HTTP_PROXY` and `HTTPS_PROXY` to that listener for
supported runtimes. HTTPS uses CONNECT, preserving credentials and TLS. Plain
HTTP requests through Airlock currently fail; HTTP forwarding comes in a later
stack change.

```nix
ai.airlock.instances.main = {};
ai.proxy.instance = "main"; # both protocols default to "http://127.0.0.1:8318"
```

Use `ai.<runtime>.proxy.instance` for a runtime selection or set it to null to
opt out of the root instance. Explicit `http` and `https` fields, including
null, override only that protocol's instance default. An unset field takes its
instance value first, then an explicitly defined sibling if the instance offers
none. For example, adding `ai.proxy.http = "http://corp:3128";` keeps HTTPS on
Airlock. Claude receives the proxy through settings `env`; Codex, Kimchi and
Kiro v3 use their launcher environment defaults. Native user values win; Kiro v2
and Copilot warn about unsupported delivery. Network proxy names are separate
from inference instance names.

On Home Manager Linux, start and stop the instance with:

```console
$ systemctl --user start airlock-main.service
$ systemctl --user stop airlock-main.service
```

On devenv, use `devenv processes up` and `devenv processes down`. Restart Claude
and other selected runtimes after changing the selection.

## Local CA

`airlock ca init DIRECTORY` creates the local CA material that a later TLS
interception unit can consume: `DIRECTORY` is mode 0700 and owned by the
effective user, `ca.key` is a PKCS#8 key with mode 0600, and `ca.pem` is the
matching self-signed CA certificate with mode 0644. The command prints only
`ca.pem`'s path. Re-running it validates and reuses the existing pair, and
refuses partial, expired, non-CA, mismatched, badly signed, symlinked, exposed,
or otherwise unusable material instead of rotating it. It does not install the
certificate into a system or browser trust store, change trust configuration, or
alter the passthrough `serve` behavior.

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
deadlines, owned tunnel shutdown, local CA validation and CLI signals.
`checks.airlock-package` checks the packaged `--help` and `--version` entry
points.

`checks.airlock-instances` covers module wiring, port and name claims, proxy
registration, selection defaults and overrides, and Claude settings delivery.
`checks.airlock-instance-runtime` starts each backend's generated service
launcher and requests `/health` at a configured nondefault port. Rust protocol
tests run through the Nix package's `doCheck`.
