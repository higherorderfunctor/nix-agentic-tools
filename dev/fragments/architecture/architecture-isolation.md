# Architecture: Isolation

<!-- cspell:ignore guestfwd virtio -->

> **Last verified:** 2026-11-06 — vetted VM sandbox and Airlock decisions.

This file holds the vetted Isolation decisions and is read together with
`architecture.md`, whose rules for entries apply here.

- **A VM sandbox is a host-side factory.** One factory and module launch one
  process in a NixOS QEMU guest on a host that need not be NixOS; harnesses come
  first, MCP servers and CLI apps may follow. Host configuration stays under
  `ai.*` in the Home Manager and devenv modules. The guest reads the host store
  read-only over an ephemeral writable overlay. The factory takes `exe` (an
  absolute path with string context) and `outName`, which `ai.sandboxes`
  defaults, and rejects other fields; a `pkg` plus `binName` interface does not
  return. Exit status travels on a root-only virtio serial port written by a
  privileged handler, never stdout, so a harness cannot spoof success; guest
  arguments travel as a NUL-delimited firmware-config blob, never the command
  line. See `packages/microvm/lib/mkSandbox.nix` and
  `packages/microvm/docs/sandbox.md`.
- **VM git access is one `ai.sandbox` surface through a relay.** `ai.sandbox` is
  singular and copies down to `ai.<runtime>.sandbox` at default priority; a
  runtime that assigns `identities` replaces the whole set, and Kiro is opt-in
  only. An identity is selected by remote URL host only, and an enabled identity
  matching no remote refuses the launch. Sandbox git options reuse the host
  option types and never copy host git settings; ref policy is pass-through. The
  relay is used only through the VM and ignores global and system git config.
  Harnesses in the VM hold no logins, and doors are explicit `guestfwd` entries,
  never a localhost wildcard. Vetted 2026-11-01, ahead of its implementation.
  This keeps account authority off the guest. The mechanism will live in the
  `packages/microvm/` owner; see `packages/microvm/docs/sandbox.md`, Git access.
- **Airlock is rebuilt as a stack of small PRs.** The `feat/airlock` branch is
  source material only, never merged, so each behavior arrives small enough to
  review. Transport is loopback TCP CONNECT through `HTTPS_PROXY`, with TLS
  interception for an allowlist, where each TLS leg negotiates ALPN on its own
  and the CA exists before binding; storage is SQLite behind a trait with
  mandatory guards; client identity and auth wait for their own design decision.
  Handlers stay small dispatchers, Cedar only permits or forbids, and Rust owns
  candidate selection, availability and connections. Direction vetted
  2026-10-26. See `packages/airlock/` and `packages/airlock/docs/airlock.md`.
