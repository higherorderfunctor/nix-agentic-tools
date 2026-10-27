# Airlock

Airlock is a local egress proxy for coding harnesses, built from the in-tree
Rust workspace.

The HTTP/1 server listens only on IP loopback addresses. `GET /health` returns
`200 OK` with an `ok` body once the listener is ready. Other paths return `404`;
other methods on `/health` return `405` with `Allow: GET`. Proxy forwarding and
configuration are not implemented yet.

```bash
airlock serve                         # 127.0.0.1:8318
airlock serve --listen 127.0.0.1:9000
curl http://127.0.0.1:9000/health
```

`--listen` also accepts IPv6 loopback (`[::1]:9000`) and port `0` to choose a
free port. Startup prints the bound address. The server owns at most 128
accepted connections and closes incomplete request headers after 10 seconds.
SIGINT and SIGTERM stop accepting and allow existing connections up to 3 seconds
to finish before closing them. Runtime teardown has a separate 10-second bound.

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
repository's locked Rust toolchain. Rust tests cover HTTP responses, loopback
binding, listener limits, header deadlines, shutdown and CLI signals.
`checks.airlock-package` checks the packaged `--help` and `--version` entry
points.
