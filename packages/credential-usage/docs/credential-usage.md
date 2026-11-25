# Credential usage

> **Last verified:** 2026-11-24 — the conformance suite compares direct and CPA
> request traces and version 1 Reader results; Home Manager, devenv and
> standalone construction resolve the same registered Reader.

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
- `modules/common.nix` declares the Reader registry
  `ai.credentialUsage.readers`. Home Manager and devenv import it.
- `lib/default.nix` exposes the Python module builder as
  `lib.ai.credential-usage.pythonModule` and the standalone registry merge as
  `lib.ai.credential-usage.mergeReaders`.

Vendor owners supply their requests and decoders. Consumers own ranking.

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

## Registered Readers

`ai.credentialUsage.readers.<id>` is where a consumer finds a Reader. Each id
has a `package` whose executable prints one envelope per account, the
`transports` it sends through (`direct`, `cpa` or both), and its vendor
`endpoint` as metadata.

A fill owner registers its Reader from its own module at default priority.
Claude's module is `packages/claude-code/modules/usage.nix`. It registers
`claude`, built by `ai.claude-code.usageReader` without a bundled CLI, so the
Reader reads the `claude` on `PATH` for its version. Home Manager and devenv
import that module, so the `claude` Reader exists wherever Claude's module does.

Select a CPA instance and HTTP policy on Claude's registered command:

```nix
ai.credentialUsage.readers.claude.cpa = {
  endpoint = "https://proxy.example";
  managementKeyFile = "/run/secrets/claude-usage-cpa";
  policy = {
    retries = 1;
    timeout = 30;
  };
};
```

The command carries the filename and opens the key file at runtime. The
generated skill references the command. Set `pin` to select an eligible CPA auth
index. When the `cpa` setting is unset, the Reader chooses from the current CPA
environment or local Claude configuration.

To select another Reader, define the leaf at ordinary priority:

```nix
ai.credentialUsage.readers.claude.package = myReader;
```

Conflicting defaults from two owners of the same id fail evaluation.

Outside a module tree, call
`lib.ai.credential-usage.mergeReaders { inherit lib pkgs; }` with
`{ contributions, overrides ? {} }`. Put the owner modules in `contributions`.
The function evaluates the same module file as Home Manager and devenv and
returns the same registry. delegate-routing's content package calls it for its
Claude usage command, and its Home Manager and devenv modules pass
`config.ai.credentialUsage.readers` as `overrides`. A selected Reader therefore
reaches the packaged command from every constructor.

## Conformance suite

Give your fill an importable command entry `main(env, clock) -> int` and one
fixture directory with `input.json` and `expected.json`. Both files list the
same scenarios in the same shape. In each case, the fields beside `extends`
change both transports and `direct` or `cpa` change that transport alone. A full
case (`"extends": null`) is complete on every transport. Any other case names
the full case it `extends` and lists only what differs from it. The suite builds
each case's complete scenario and expectation with one merge rule, which the
module docstring of `checks/conformance/suite.py` states.

`input.json` also supplies a description, the supported transports, a UTC start
time (`now` ending in `Z`), named HTTP replies (status and literal body text),
credential file contents and Bash program bodies in `executables`. A full
scenario supplies `env` and an ordered list of reply names on each transport.
Use `${credentials:name}` for a private file path and `${bin}` for the program
directory. Use `${credentialsDir}` for the directory containing credential
files, including dotfiles such as `.credentials.json`. A scenario can add or
replace a file for one transport by supplying its own `credentials` map.
Credential names can include subdirectories, such as
`.claude/.credentials.json`, and each path must be relative and free of `.` and
`..` components. `PATH` starts with the program directory.

In `expected.json`, write each full case's complete `requests` and `result` by
hand. Include the method, URL, headers and body for each HTTP call. Write JSON
request bodies as JSON values. Use `[credential:name]` where the request carries
a credential. The clock advances one second per call. Compare the JSON values
exactly as the Reader prints them, including URL spelling and UTC timestamps.
For a failure, expect empty stdout and one stderr line, written as
`{"failed":"usage: <reason>"}`. Choose a fixed public phrase for the reason. The
suite checks both streams for credentials and failed response bodies. Set
`"private": true` on a named reply when an upstream failure arrives inside a
successful HTTP response. Every non-2xx reply is private automatically. Keep the
whole private body and each of its JSON string values, including strings inside
nested JSON text, out of both streams. The Reader must also load silently.

A failed case prints its name, `trace` or `result`, and a diff of the whole
expected and observed objects. Private strings appear in that diff as
`[credential:name]` or `[private]`. So does any object or array that JSON in a
credential file or in a private or failed reply parses to, even when a Reader
sends it back as a request body. A JSON object that is not a valid envelope, or
whose instant falls outside the run, still fails its case; the diff shows that
object as printed.

From `checks/conformance`, run `python3 run.py <pair> <module>:<function>` with
the fill and both transport modules installed. Append `<scenario>/<transport>`
to select one case. In Nix, call `lib.ai.credential-usage.conformanceCheck` with
`pkgs`, `python-stack`, a check `name`, the fill's `ownerModules`, `pair` and
`entry`. Supply extra command-line tools in `extraPackages`. For mutation
testing, set `READER_PAIR` and `READER_ENTRY` and collect
`test_conformance.py::GoldenCases` with pytest. Each scenario and transport has
its own selectable test.

`python3 standalone.py <pair> <command>` runs the installed executable instead
of an imported entry. Each CPA case gets a local HTTP server that answers with
the scenario's replies in order and records every request. The driver compares
the recorded requests and the printed result with the pair, as the imported run
does, with three differences a real socket needs:

- It repoints the scenario's proxy origin to the server and restores the
  fixture's origin before comparing.
- It drops the framing headers and the header defaults urllib3 adds, so a Reader
  that sends its own `User-Agent` still differs from the pair.
- It accepts `observedAt` as any UTC instant inside the run, because the
  subprocess reads the real clock.

Claude's command check also supplies an offline build of the command. The driver
uses it for direct preflight cases that should send no requests. The imported
suite checks all direct requests with its fake transport.

## Checks

`credential-usage-conformance` exercises the suite against working and broken
Readers. `credential-usage-contract` checks envelope decisions.
`credential-usage-schema` checks the published schema and example.
`credential-usage-registration` checks that Home Manager, devenv and standalone
construction resolve the same Reader, that a second owner can register one and
that two owners of one id fail evaluation. `credential-usage-runner` checks
process behavior, and `credential-usage-types` runs strict Pyright. The Nix
checks import the installed module. Local runs need `pydantic` and read the
checkout:

```bash
python3 checks/runner/test_runner.py
```

## Mutation review

From the repository root, run the manual pass on writable copies of the envelope
and Claude fill with the pinned Python environment:

```bash
env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
  flock -w 600 /tmp/nat-vm-spike.lock \
  systemd-run --user --scope -q -p CPUQuota=200% -p MemoryMax=6G \
  nix build --max-jobs 1 --cores 2 --no-link --print-out-paths --impure --expr '
    let
      repo = builtins.getFlake (toString ./.);
      pkgs = import repo.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ repo.overlays.default ];
      };
    in pkgs.callPackage ./packages/credential-usage/checks/mutation.nix {}'
```

The output directory contains mutmut statuses in `generated.txt`, diffs for
generated survivors in `surviving-diffs.txt`, and named fault outcomes with
their behavior ID in `named.tsv`. Confirm each kill by matching a failed call to
a passing baseline call in `matrix.tsv`. The matrix includes the name of each
contract fixture. Exclude tool-reported kills that lack a failed call. Mutmut
selects generated runs by function coverage. Every named fault runs the full
selection.
