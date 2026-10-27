# Airlock

Airlock is a local egress proxy for coding harnesses, built from the in-tree
Rust workspace.

The HTTP/1 server listens only on IP loopback addresses. CONNECT opens a TCP
tunnel to a hostname or IP address with an explicit port, forwarding opaque
bytes without TLS interception. Native HTTPS client authentication is unchanged.
The listener currently accepts CONNECT without proxy authentication;
configuration and domain policy are not implemented yet.

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
directions, loopback binding, listener limits, header deadlines, owned tunnel
shutdown and CLI signals. `checks.airlock-package` checks the packaged `--help`
and `--version` entry points.
