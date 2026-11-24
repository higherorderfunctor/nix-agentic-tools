# Credential usage

> **Last verified:** 2026-11-24 — the Reader runner and the transport interface
> moved here from delegate-routing with their behavior unchanged.

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
- `checks/runner` and `checks/transport` hold the process and transport suites.
- `lib/python-module.nix` installs the package for one `python-stack`
  interpreter.

Keep vendor requests and decoders, Nix options and ranking out of this package.

## Consumers

delegate-routing is the consumer today. Its packaged routing helper and `usage`
modules import `credential_usage` from their Python environment. A consumer
lists the result of `lib/python-module.nix` in its own `withPackages`. The
Reader output contract is documented with that consumer in
[pacing.md](../../delegate-routing/docs/pacing.md).

CPA supplies the credential transport today. Airlock will supply one, and its UI
will read the same Reader output. A future `checks/conformance` will run the
same named cases against every Reader.

## Checks

`credential-usage-runner`, `credential-usage-transport` and
`credential-usage-types` (strict Pyright) are the flake checks. The Nix checks
import the installed module. Local runs need `pydantic` and `urllib3` and read
the checkout:

```bash
python3 checks/runner/test_runner.py
python3 checks/transport/test_transport.py
```
