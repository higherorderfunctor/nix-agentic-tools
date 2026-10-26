# Airlock

Airlock is the package owner for a local egress proxy for coding harnesses.

The current binary implements an unauthenticated, loopback-only HTTP `CONNECT`
tunnel. `airlock serve` listens on `127.0.0.1:8318` by default; `--listen`
accepts an IP loopback socket address and permits port `0` for tests. After a
valid authority-form target is parsed and the upstream TCP connection succeeds,
Airlock returns HTTP 200 and forwards opaque bytes in both directions. It does
not inspect or modify TLS, so a native HTTPS client’s own client certificate and
authentication behavior remain unchanged.

Use the proxy with clients that send `CONNECT` through an HTTPS proxy setting
such as `HTTPS_PROXY=http://127.0.0.1:8318`. Absolute-form HTTP requests are not
supported: setting only `HTTP_PROXY` to Airlock does not turn it into a forward
HTTP proxy. Malformed and non-`CONNECT` requests are rejected before an upstream
connection is dialed.

The tunnel bounds simultaneous connections, request-header reads, upstream
connect attempts, and shutdown draining. Established tunnels have no arbitrary
idle or total timeout; they remain available until either peer closes them.
SIGINT and SIGTERM stop accepting new connections, drain owned connections for a
bounded period, and cancel any that remain. Hostname resolution uses the
blocking system resolver, so an aborted lookup itself is not cancelable; process
shutdown also uses a bounded runtime wait so such a lookup cannot hang Airlock
indefinitely.

Airlock does not yet read configuration, manage provider credentials, define
domains, intercept traffic, or expose a Home Manager instance. The Nix package
builds the in-tree Cargo workspace with the repository’s locked Rust toolchain,
and `checks.airlock-package` executes the current `--help` and `--version` entry
points.

## Build and validate

From the repository root:

```bash
nix build .#airlock
nix flake check
```

Inside the repository development shell, from `packages/airlock/src`:

```bash
cargo build --locked
cargo run --locked -- --help
cargo run --locked -- serve --listen 127.0.0.1:8318
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
```
