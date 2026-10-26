# Airlock

Airlock is the package owner for a local egress proxy for coding harnesses. For
the Claude and devenv opt-in, see [HTTPS passthrough](docs/passthrough.md).

The current binary implements an unauthenticated, loopback-only HTTP `CONNECT`
tunnel. `airlock serve` listens on `127.0.0.1:8318` by default. Use either
`--listen` with an IP loopback socket address or `--config FILE` with a strict
JSON document such as `{"listen":"127.0.0.1:8318"}`. The config requires
`listen`, rejects unknown fields and non-loopback addresses, and cannot be
combined with `--listen` or followed by trailing arguments. After a valid
authority-form target is parsed and the upstream TCP connection succeeds,
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

Airlock does not manage provider credentials, define policy domains, intercept
traffic, or expand proxy selection. The Nix package builds the in-tree Cargo
workspace with the repository’s locked Rust toolchain. `checks.airlock-package`
executes the current `--help` and `--version` entry points, while
`checks.airlock-instance-runtime` runs each generated service launcher against a
loopback-only fake upstream.

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
