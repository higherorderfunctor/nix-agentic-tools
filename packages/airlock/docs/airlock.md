# Airlock development

<!-- cspell:ignore cutover sqlx -->

> **Last verified:** 2026-11-07 — carries the vetted Airlock rebuild decision;
> the code quality bar, extraction rules and stack process for rebuilding the
> Airlock egress proxy as small PRs.

## Architecture decisions

Relocated from the Isolation list, last verified 2026-11-06.

- **Airlock is rebuilt as a stack of small PRs.** The `feat/airlock` branch is
  source material only, never merged, so each behavior arrives small enough to
  review. Transport is loopback TCP CONNECT through `HTTPS_PROXY`, with TLS
  interception for an allowlist, where each TLS leg negotiates ALPN on its own
  and the CA exists before binding; storage is SQLite behind a trait with
  mandatory guards; client identity and auth wait for their own design decision.
  Handlers stay small dispatchers, Cedar only permits or forbids, and Rust owns
  candidate selection, availability and connections. Direction vetted
  2026-10-26. See `packages/airlock/` and `packages/airlock/docs/airlock.md`.

## Basics

- The mandatory storage guards are STRICT tables, CHECK and NOT NULL
  constraints, `foreign_keys`, `quick_check`, sqlx checked queries, round-trip
  tests and no ORM.
- Rust is `rust-overlay` `stable.latest`, on the newest edition.
- Client identity and auth return only once cliproxyapi parity and cutover are
  close, with their own design decision.

## Handlers and TLS interception

- Local-endpoint routing stays separate from destination selection,
  transformations and tunnel execution. No provider-specific branches or long
  conditional chains.
- Axum and Tower come only when local endpoints justify a router. Keep direct
  Hyper connection ownership with explicit HTTP/2 flow control and resets. This
  sets direction; it does not approve the dependency.
- TLS ALPN prefers H2 and falls back to H1, and every pairing of the two legs
  works.
- Leaf certificates get a bounded cache and renewal.
- Outer HTTP/2 keeps watching for resets around the TLS session.

## Code quality bar

1. One concern per module, named for what it does for its caller. Never name a
   module `files`, `util`, `helpers` or `private_file`. A module split into
   several files lives in a directory named for it (`name.rs` plus `name/`, as
   `client.rs` and `client/` do under
   `packages/airlock/packages/ai/airlock/src/`), never as siblings of unrelated
   modules in `src/`. The HTTP/1 and HTTP/2 modules never depend on each other.
2. Code is readable for someone new to Rust and hyper: small functions, plain
   names, no dead code and no shims.
3. Comments follow `src/http/authority.rs` in the same crate: a short module doc
   plus one- to three-line comments that say why.
4. Integration tests live in `tests/`, with shared fixtures in `tests/common`.
   Inline tests are only for private units.
5. Each PR stands alone. A fix goes in the commit that introduced the code.

## Extraction rules

The monolith branch is source material. Its commit order does not matter, and a
contract may be simplified or dropped.

- A PR carries about 500 production lines: usually 250 to 750, never more than
  1,000. Docs, tests and generated output do not count; manifests, config and
  wiring do.
- Tests and docs ship with the behavior. A dependency or option arrives with its
  first consumer.
- No scaffolding-only PRs, no wholesale monolith import and no compatibility
  wrappers.

## Stack process

The next PR in line is marked ready, so it gets its automatic review before
human review. Fix each review finding, or retract it with evidence, before the
PR reaches human review. Before fixing, check that the finding still holds; a
finding that does not reproduce is retracted, never "fixed".
