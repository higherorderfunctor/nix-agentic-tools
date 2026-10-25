# airlock

> **Last verified:** 2026-10-25 — Airlock scope, control plane, security
> boundary, and web/Rust package composition.

## Scope

airlock is becoming the sandboxed harness's egress gateway for providers, MCP,
gh/glab, guarded web and git+ssh. CLIProxyAPI coexists for now.

## Transport and routing

The CONNECT, TLS, model routing, quota-header, and response forwarding contracts
live in `docs/routing.md`. The separately enabled control listener serves the
static dashboard and authenticated usage APIs; its Nix and protocol contract
lives in `docs/control.md`, with storage query bounds in `docs/storage.md`.

## Not a security boundary yet

airlock runs as the harness's uid. `ai.jail` binds `/` into the jail, so the
harness can read airlock's runtime directory, its CA key, its state and the
secret files the launcher writes there. Until airlock runs under a separate uid
or outside the harness's VM, it keeps real credentials out of the harness's
environment and config, not out of its reach.

## Configuration and Claude integration

The configuration and launcher contracts live in `docs/integration.md`; managed
primary OAuth lives in `docs/oauth.md`. SQLite's durable-state contract lives in
`docs/storage.md`, with provider history and the read-only usage report in
`docs/usage-storage.md`.

## Package composition

The public Nix package joins the Cargo-built `raw` executable and an independent
`frontend` built from `web/package-lock.json` with Node 24. Its launcher
forwards the caller's arguments and defaults `--web-root` to the immutable
frontend store path for `serve` when the caller supplies no root. The two
derivations are exposed as package passthru for checks; changing web assets does
not rebuild Rust. Raw developer builds must pass their own web root when serving
the dashboard.

## Settled — do not relitigate

- **A unix socket with Claude Code's `ANTHROPIC_UNIX_SOCKET` placeholder mode is
  not the main path.** Its runtime path is unknown at evaluation and it serves
  only Claude; CONNECT serves every client honouring `HTTPS_PROXY`.
- **Base-URL mode is not the main path.** Claude Code drops `cch` behind
  `ANTHROPIC_BASE_URL`, so a subscription request would have to be forged.
- **No Postgres for now.** Home Manager has no user-level Postgres module, so it
  would break Home Manager and devenv parity. The SQLite state contract lives in
  `docs/storage.md`.
