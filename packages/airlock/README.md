# Airlock

Airlock is the package owner for a local egress proxy for coding harnesses.

The current implementation is a minimal Rust binary with `--help` and
`--version` support. It does not yet start a proxy, read configuration, or
manage domains. The Nix package builds the in-tree Cargo workspace with the
repository's locked Rust toolchain, and `checks.airlock-package` executes both
supported CLI entry points.

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
cargo fmt --check
cargo clippy --locked -- -D warnings
```
