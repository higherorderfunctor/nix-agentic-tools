# Credential usage

> **Last verified:** 2026-11-24 — consumers install the Reader runner and
> transport through `lib.ai.credential-usage.pythonModule`.

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
- `checks/runner` holds the process suite.
- `lib/default.nix` exposes the Python module builder as
  `lib.ai.credential-usage.pythonModule`.

Keep vendor requests and decoders, Nix options and ranking out of this package.

## Consumers

Call `lib.ai.credential-usage.pythonModule` with `{ pkgs, python-stack }` and
include its result in that interpreter's `withPackages`. The delegate-routing
helper and CLIProxyAPI transport checks import `credential_usage` this way.
Delegate-routing documents the Reader output contract in
[pacing.md](../../delegate-routing/docs/pacing.md).

CPA supplies the credential transport today, in
`packages/cliproxyapi/usage/transport.py`, and tests it with
`cliproxyapi-usage-transport`. Airlock will supply one, and its UI will read the
same Reader output. A future `checks/conformance` will run the same named cases
against every Reader.

## Checks

`credential-usage-runner` and `credential-usage-types` (strict Pyright) are the
flake checks. The Nix checks import the installed module. Local runs need
`pydantic` and read the checkout:

```bash
python3 checks/runner/test_runner.py
```
