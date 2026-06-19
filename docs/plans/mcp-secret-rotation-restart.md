# MCP shared-service secret rotation → restart

> Status: implemented (HM), 2026-06-19. devenv parity designed, deferred.

## Problem

Long-lived MCP services (`serviceServers` = local package + HTTP mode,
materialised as `systemd.user.services.mcp-<name>` in
`packages/mcp-services/modules/homeManager/default.nix`) read their
credential **once, at `ExecStart`**. The generated wrapper inlines a
credentials snippet (`lib/mcp.nix:mkCredentialsSnippet`) that does
`TOKEN="$(cat <path>)"; export TOKEN`.

When a token is rotated, the secret manager re-renders the **same path**
with new content. The unit's `ExecStart` references that stable path, so
the generated unit is byte-identical — neither home-manager nor systemd
sees anything to restart, and the running process keeps serving with the
stale token. A manual `systemctl --user restart mcp-<name>` fixes it
(the wrapper re-`cat`s on start); nothing was _triggering_ that restart.

stdio servers are unaffected: their wrapper re-`cat`s on every client
spawn, so they pick up rotation on next launch.

## Why not the "obvious" fixes

- **sops-nix `restartUnits`** — exists only in the NixOS sops-nix module,
  not the home-manager one (verified against upstream
  `modules/home-manager/sops.nix`). Also this repo's credential model is
  deliberately secret-manager-agnostic: the module only ever receives a
  _path_, never a sops secret name, so it cannot drive sops internals.
- **`systemd.user.path` watcher** — agnostic, but unreliable precisely
  with sops-nix/agenix, which install secrets via an atomically-swapped
  generation symlink; inotify on the leaf goes stale on the swap. (This
  is _why_ sops-nix added `restartUnits` instead of recommending path
  units.)
- **Hash secret content into the unit (`restartTriggers`)** — impossible
  without reading the secret at eval time, which is forbidden (secrets
  are decrypted after eval).

## Chosen fix — content-fingerprint activation (agnostic, precise)

A Linux-gated home-manager activation entry
(`home.activation.mcpRestartOnSecretRotation`) that, for each enabled
file-credentialed service:

1. hashes the credential file content(s) (`cat | sha256sum`),
2. compares to a stored fingerprint under
   `${XDG_STATE_HOME:-$HOME/.local/state}/nix-agentic-tools/mcp-cred-hashes/<name>`,
3. restarts the unit **only** when the hash changed _and_ the unit is
   active, then records the new fingerprint.

Properties:

- **Restart only on real rotation** (not on every unrelated rebuild).
- **Secret-manager agnostic** — needs only a stable path; works with
  sops-nix, agenix, `ln`, plain files. Reads content, so it dodges the
  inotify-on-symlink-swap flakiness.
- **Ordered `entryAfter [ "writeBoundary" "sops-nix" ]`** so we hash the
  freshly-rendered secret. HM's `topoSort` silently ignores the
  `sops-nix` dep when the consumer doesn't use sops (verified against
  HM `lib/dag.nix`), so the ordering stays agnostic.
- **Activation-safe** — every step is guarded (`if … ; then`, `|| true`)
  so a missing/unreadable secret or a failed restart can never abort the
  rest of HM activation. First activation records a baseline and does not
  restart.
- **Helper-based credentials** (`credentials.helper`) have no stable file
  to fingerprint and are intentionally excluded.

### Code

- `lib/mcp.nix` — `credentialFilePaths credentialVars settings`: the
  file paths backing file-based creds, in declaration order.
- `packages/mcp-services/modules/homeManager/default.nix` —
  `credentialedServiceFiles`, `mkRotationCheck`, `rotationRestartScript`,
  and the `home.activation` entry.
- `checks/module-eval.nix` — three eval tests (entry emitted for file
  creds; skipped for helper creds; absent with no creds).

## devenv parity (designed, deferred)

There is no devenv module for these services yet (they are inherently
systemd user services; devenv would run them under process-compose). The
analog is a pre-`up` hook that fingerprints the same paths and restarts
the matching process-compose process. `credentialFilePaths` is the shared
primitive both backends consume. Build when a devenv mcp-services module
lands.

## Follow-ups

- Consider promoting the gotcha to a dev fragment scoped to
  `packages/mcp-services/**` (register in `dev/generate.nix`
  `devFragmentNames`) so future sessions don't rediscover it.
