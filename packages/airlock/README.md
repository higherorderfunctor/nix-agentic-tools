# Airlock

Airlock is a local egress proxy for coding harnesses, built from the in-tree
Rust workspace.

The server listens only on IP loopback addresses and detects HTTP/1.1 or
cleartext HTTP/2 prior knowledge on the same port. CONNECT opens a TCP tunnel to
a hostname or IP address with an explicit port, forwarding opaque bytes without
TLS interception. Native HTTPS client authentication is unchanged. The listener
currently accepts CONNECT without proxy authentication; configuration and domain
policy are not implemented yet.

Cleartext clients choose HTTP/2 by sending its prior-knowledge preface; HTTP/1.1
clients use the same listener automatically. The proxy listener does not yet
offer TLS or ALPN negotiation. TLS inside a CONNECT tunnel remains opaque.
Native Claude traffic through `HTTPS_PROXY` has not been validated to use
HTTP/2; the HTTP/2 tests here select it with a prior-knowledge client.

`GET /health` returns `200 OK` with an `ok` body once the listener is ready.
Other paths return `404`; other methods on `/health` return `405` with
`Allow: GET`. Absolute-form HTTP proxy requests are not supported. Malformed
CONNECT targets return `400`, failed upstream connections return `502`, and a
connection attempt exceeding 10 seconds returns `504`. At most 16 blocking DNS
lookups run or wait in the runtime's blocking queue. A timed-out lookup retains
its slot until the resolver finishes; waiting for a slot shares the connection
deadline. IP literals bypass DNS.

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

See [Network Proxy](../../dev/fragments/ai-proxy/ai-proxy.md) for runtime
selection, protocol defaults and native overrides.

On Home Manager Linux, start and stop the instance with:

```console
$ systemctl --user start airlock-main.service
$ systemctl --user stop airlock-main.service
```

On devenv, use `devenv processes up` and `devenv processes down`. Restart Claude
and other selected runtimes after changing the selection.

## Local CA

`airlock ca init DIRECTORY` creates the local CA material that a later TLS
interception unit can consume: `DIRECTORY` is created with mode 0700 and must be
owned by the effective user with no group or other permissions, `ca.key` is a
PKCS#8 key created with mode 0600, and `ca.pem` is the matching self-signed CA
certificate with mode 0644. The command prints only `ca.pem`'s path. Re-running
it validates and reuses the existing pair, and refuses partial, expired, non-CA,
mismatched, badly signed, symlinked, exposed, or otherwise unusable material
instead of replacing it. A key or directory mode stricter than 0600 or 0700 is
accepted. It does not install the certificate into a system or browser trust
store, change trust configuration, or alter the passthrough `serve` behavior.

`DIRECTORY`'s parent must be owned by the effective user or root and not
writable by group or others, sticky or not, so no other user can replace
`DIRECTORY`; init refuses another parent before creating anything. A lock on
`DIRECTORY` serializes concurrent runs, and a run that fails while writing the
pair removes the key it wrote. The certificate is valid for one year: a CA
serves the session that uses its directory, and a new directory gets a new CA.

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
repository's locked Rust toolchain. Rust tests cover HTTP responses, authority
validation, byte streaming and half-close in both directions, client
cancellation, HTTP/2 multiplexing and flow control, stream reset isolation,
loopback binding, listener limits, header deadlines, owned tunnel shutdown,
local CA validation and CLI signals. `checks.airlock-package` checks the
packaged `--help` and `--version` entry points.

`checks.airlock-instances` covers module wiring, port and name claims, proxy
registration, selection defaults and overrides, and Claude settings delivery.
`checks.airlock-instance-runtime` starts each backend's generated service
launcher and requests `/health` at a configured nondefault port. Rust protocol
tests run through the Nix package's `doCheck`.
