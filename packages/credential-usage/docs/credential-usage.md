# Credential usage

> **Last verified:** 2026-11-24 — the Reader runner, the transport interface and
> their two suites moved here from delegate-routing with their behavior
> unchanged; the schema, conformance suite, client and vendor Readers below are
> planned and do not exist yet.

This package owns the shared parts of reading a credential's usage: the Reader
runner, the transport interface and the Reader output contract. A vendor owns
what to ask its API and what the answer means. The credential owner supplies the
transport. delegate-routing consumes the observations and ranks routes.

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
Each vendor fill belongs with its vendor, contributed the way owners contribute
`ai.catalog` entries.

## Consumers

delegate-routing is the consumer today. Its packaged routing helper and the
`usage` modules import `credential_usage` from their Python environment. A
consumer adds the module to its own `withPackages` list:

```nix
credentialUsageModule = import ../credential-usage/lib/python-module.nix {inherit pkgs python-stack;};
python-stack.withPackages (ps: [ps.pydantic ps.urllib3 credentialUsageModule])
```

CPA supplies the credential transport today and Airlock supplies one once it
replaces CPA. Airlock's UI will read the same Reader output. The CPA binding
still lives at `packages/delegate-routing/scripts/usage/cpa.py` and is due to
move to `packages/cliproxyapi`. Until then the transport suite imports it from
delegate-routing, and `credential-usage-transport` passes that directory.

## Planned, not built

- A versioned JSON Schema for the Reader output, published from strict models.
- `checks/conformance`, which runs the same named cases against every Reader.
- A small Python client that turns selected bindings into typed observations.
- The vendor Readers for Claude, Codex, z.ai and OpenCode Go.

## Ownership

The runner and contract sit in a neutral owner because two consumers already
share them and CPA is scheduled for removal. Reconsider CPA ownership if CPA
becomes the permanent credential manager and the only consumer.

## Checks

`credential-usage-runner`, `credential-usage-transport` and
`credential-usage-types` (strict Pyright) are the flake checks. The Nix checks
import the installed module. Local runs need `pydantic` and `urllib3` and read
the checkout:

```bash
python3 checks/runner/test_runner.py
python3 checks/transport/test_transport.py
```
