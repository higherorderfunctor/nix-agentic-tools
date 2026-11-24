# Credential usage

> **Last verified:** 2026-11-24 — the version 1 envelope, Reader runner and
> transport share one Python module.

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

## The usage envelope

A Reader emits one version 1 envelope for the account it observed. Supply the
binding, capture time and at least one allowance window. Publish only the
endpoint address. Leave credentials, query parameters and fragments out. Keep a
proven zero on an invalid window when other fields fail. Mark an absent window
as missing.

Declare all four optional slots. An observed slot reports what the Reader
verified, including an empty inventory. An unknown slot gives the reason the
read failed. Map that failure to a public reason code from the schema. An
unsupported slot means the Reader cannot supply it. Only an observed slot can
carry entries or spend. The Claude Reader has no source of reset lots or
accounted spend.

```json
{
  "schemaVersion": 1,
  "binding": {
    "endpoint": "https://reader.example/",
    "transport": "direct"
  },
  "observedAt": "2026-01-01T01:00:00Z",
  "pool": "example",
  "account": {
    "auth_index": null,
    "name": null,
    "plan": null
  },
  "windows": {
    "5h": {
      "state": "observed",
      "enforced": true,
      "remainingPercent": 0,
      "resetsAt": "2026-01-01T03:00:00Z",
      "status": null,
      "usedPercent": 100,
      "windowSeconds": 18000
    },
    "7d": {
      "state": "invalid",
      "reason": "invalid-reset",
      "remainingPercent": 0
    },
    "7d:model": {
      "state": "missing",
      "reason": "meter-unreported"
    }
  },
  "balances": [],
  "bonuses": [],
  "accountedSpend": null,
  "slotStates": {
    "accountedSpend": {
      "state": "unsupported"
    },
    "credits": {
      "state": "observed"
    },
    "grants": {
      "state": "unknown",
      "reason": "grants-unavailable"
    },
    "resetInventory": {
      "state": "unsupported"
    }
  }
}
```

Import `Envelope` from `credential_usage.envelope`. Use `model_validate_json` to
read one result and `model_dump_json` to write it with UTC timestamps. The
[version 1 schema](../schema/usage-envelope.schema.json) lists the public
fields. The model also checks that inventory and spend have observed slots, that
window shares total 100, and that endpoints contain no credentials, query or
fragment. Timestamps have microsecond precision. The Reader drops finer digits
without rounding.

## Consumers

Call `lib.ai.credential-usage.pythonModule` with `{ pkgs, python-stack }` and
include its result in that interpreter's `withPackages`. The delegate-routing
helper and CLIProxyAPI transport checks import `credential_usage` this way.
Delegate-routing describes how it uses the windows in
[pacing.md](../../delegate-routing/docs/pacing.md).

CPA supplies the credential transport today, in
`packages/cliproxyapi/usage/transport.py`, and tests it with
`cliproxyapi-usage-transport`. Airlock will supply one, and its UI will read the
same Reader output. A future `checks/conformance` will run the same named cases
against every Reader.

## Checks

`credential-usage-contract` checks envelope decisions. `credential-usage-schema`
checks the published schema and example. `credential-usage-runner` checks
process behavior, and `credential-usage-types` runs strict Pyright. The Nix
checks import the installed module. Local runs need `pydantic` and read the
checkout:

```bash
python3 checks/runner/test_runner.py
```
