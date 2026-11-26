# Credential usage

> **Last verified:** 2026-11-26 — the usage envelope is a typed pydantic model;
> consumers install it with the runner and transport through
> `lib.ai.credential-usage.pythonModule`.

This package owns the shared parts of reading a credential's usage. A vendor
owns what to ask its API and what the answer means. The credential owner
supplies the transport. The consumer turns Reader output into decisions.

## What lives here

- `python/credential_usage/runner.py` runs registered Reader commands and
  returns one raw capture or safe failure per registration. Registrations that
  share a command share its final outcome and completion time.
- `python/credential_usage/transport.py` defines the request a Reader sends, the
  `Transport` it sends through, and `DirectHttp`, which keeps one bearer token
  on one origin.
- `python/credential_usage/envelope.py` is the contract every Reader prints: one
  `Envelope` per account and capture. See "The envelope" below.
- `checks/runner` holds the process suite.
- `lib/default.nix` exposes the Python module builder as
  `lib.ai.credential-usage.pythonModule`.

Keep vendor requests and decoders, Nix options and ranking out of this package.

## The envelope

A Reader prints one JSON `Envelope` on stdout for one account. Its fields:

- `schemaVersion` (1), `pool`, `account` (`auth_index`, `name`, `plan`),
  `binding` (`transport` is `direct` or `cpa`, and the public `endpoint`) and
  `observedAt`, the capture's completion time in UTC.
- `windows`: required, keyed by the vendor's window id. Report the windows the
  vendor returns; never assume a fixed set. Each is `observed` (used and
  remaining percent, reset, duration, `enforced`), `invalid` (a reason, and a
  measured `remainingPercent: 0` when only the timing is bad) or `missing`.
- Optional inventory: `balances` (credit lots), `bonuses` (reset grants and
  reset lots) and `accountedSpend`. Each has a state in `slotStates`:
  `observed`, `unknown` with a reason, or `unsupported`. Only an observed slot
  can carry entries or claim empty, so a failed read never looks like zero.

The models reject unknown fields, NaN and infinities, and timestamps without an
offset. Types are the contract: a Reader that builds an `Envelope` it can't
validate fails in strict Pyright or at construction, not in a consumer. Reset
and credit policy (spend or hold) belongs to the consumer's configuration, not
the Reader.

## Consumers

Call `lib.ai.credential-usage.pythonModule` with `{ pkgs, python-stack }` and
include its result in that interpreter's `withPackages`. The delegate-routing
helper and CLIProxyAPI transport checks import `credential_usage` this way.
Delegate-routing documents the Reader output contract in
[pacing.md](../../delegate-routing/docs/pacing.md).

CPA supplies the credential transport today, in
`packages/cliproxyapi/usage/transport.py`, and tests it with
`cliproxyapi-usage-transport`. Airlock will supply one, and its UI will read the
same Reader output.

## Checks

`credential-usage-runner` and `credential-usage-types` (strict Pyright, which
also covers `envelope.py`) are the flake checks. The Nix checks import the
installed module. Local runs need `pydantic` and read the checkout:

```bash
python3 checks/runner/test_runner.py
```
