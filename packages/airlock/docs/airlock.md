# airlock

> **Last verified:** 2026-10-25 — Airlock scope, security boundary, and
> integration links reflect the M08 usage collector and CLI.

## Scope

airlock is becoming the sandboxed harness's egress gateway for providers, MCP,
gh/glab, guarded web and git+ssh. CLIProxyAPI coexists for now.

## Transport and routing

The CONNECT, TLS, model routing, quota-header, and response forwarding contracts
live in `docs/routing.md`.

## Not a security boundary yet

airlock runs as the harness's uid. `ai.jail` binds `/` into the jail, so the
harness can read airlock's runtime directory, its CA key, its state and the
secret files the launcher writes there. Until airlock runs under a separate uid
or outside the harness's VM, it keeps real credentials out of the harness's
environment and config, not out of its reach.

## Configuration and Claude integration

The configuration, launcher, and primary OAuth contracts live in
`docs/integration.md`. SQLite's durable-state contract lives in
`docs/storage.md`, including provider history and the read-only usage report.

## Settled — do not relitigate

- **A unix socket with Claude Code's `ANTHROPIC_UNIX_SOCKET` placeholder mode is
  not the main path.** Its runtime path is unknown at evaluation and it serves
  only Claude; CONNECT serves every client honouring `HTTPS_PROXY`.
- **Base-URL mode is not the main path.** Claude Code drops `cch` behind
  `ANTHROPIC_BASE_URL`, so a subscription request would have to be forged.
- **No Postgres for now.** Home Manager has no user-level Postgres module, so it
  would break Home Manager and devenv parity. The SQLite state contract lives in
  `docs/storage.md`.
