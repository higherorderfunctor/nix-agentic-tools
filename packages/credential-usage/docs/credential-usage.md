# Credential usage

> **Last verified:** 2026-11-24 — the conformance suite compares direct and CPA
> request traces and version 1 Reader results.

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
proven zero on an invalid window when the reset fails. Mark an absent window as
missing.

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
window shares total 100, that only an invalid reset can retain a measured zero,
and that an endpoint URL carries no user information, query or fragment.
Timestamps have microsecond precision. The Reader drops finer digits without
rounding.

## Consumers

Call `lib.ai.credential-usage.pythonModule` with `{ pkgs, python-stack }` and
include its result in that interpreter's `withPackages`. The delegate-routing
helper and CLIProxyAPI transport checks import `credential_usage` this way.
Delegate-routing describes how it uses the windows in
[pacing.md](../../delegate-routing/docs/pacing.md).

CPA supplies the credential transport today, in
`packages/cliproxyapi/usage/transport.py`, and tests it with
`cliproxyapi-usage-transport`. Airlock will supply one, and its UI will read the
same Reader output.

## Conformance suite

Give your fill an importable command entry `main(env, clock) -> int` and one
fixture directory. In `input.json`, supply a description, the supported
transports, a UTC start time (`now` ending in `Z`), named HTTP replies (status
and literal body text), credential file contents and Bash program bodies in
`executables`. Each named scenario supplies `env` and an ordered list of reply
names on every declared transport. Use `${credentials:name}` for a private file
path and `${bin}` for the program directory. Use `${credentialsDir}` for the
directory containing credential files, including dotfiles such as
`.credentials.json`. A scenario can add or replace a file for one transport by
supplying its own `credentials` map. Credential names can include
subdirectories, such as `.claude/.credentials.json`, and each path must be
relative and free of `.` and `..` components. `PATH` starts with the program
directory.

In `expected.json`, write each scenario and transport's complete `requests` and
`result` by hand. Include the method, URL, headers and body for each HTTP call.
Write JSON request bodies as JSON values. Use `[credential:name]` where the
request carries a credential. The clock advances one second per call. Compare
the JSON values exactly as the Reader prints them, including URL spelling and
UTC timestamps. For a failure, expect empty stdout and one stderr line, written
as `{"failed":"usage: <reason>"}`. Choose a fixed public phrase for the reason.
The suite checks both streams for credentials and failed response bodies. Set
`"private": true` on a named reply when an upstream failure arrives inside a
successful HTTP response. Every non-2xx reply is private automatically. Keep the
whole private body and each of its JSON string values, including strings inside
nested JSON text, out of both streams. The Reader must also load silently.

From `checks/conformance`, run `python3 run.py <pair> <module>:<function>` with
the fill and both transport modules installed. Append `<scenario>/<transport>`
to select one case. In Nix, call `lib.ai.credential-usage.conformanceCheck` with
`pkgs`, `python-stack`, a check `name`, the fill's `ownerModules`, `pair` and
`entry`. Supply extra command-line tools in `extraPackages`. For mutation
testing, set `READER_PAIR` and `READER_ENTRY` and collect
`test_conformance.py::GoldenCases` with pytest. Each scenario and transport has
its own selectable test.

## Checks

`credential-usage-conformance` exercises the suite against working and broken
Readers. `credential-usage-contract` checks envelope decisions.
`credential-usage-schema` checks the published schema and example.
`credential-usage-runner` checks process behavior, and `credential-usage-types`
runs strict Pyright. The Nix checks import the installed module. Local runs need
`pydantic` and read the checkout:

```bash
python3 checks/runner/test_runner.py
```
