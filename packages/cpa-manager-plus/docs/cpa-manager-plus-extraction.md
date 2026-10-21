# CPA Manager Plus extraction: config.json and environment

> **Last verified:** 2026-10-20 — patched Manager Plus 1.14.7 measures 28
> config.json keys, `defaultTheme` with its values, and 33 environment variables
> through the shared Go test extractor.

## Two surfaces

Manager Plus reads `config.json` (from `CPA_MANAGER_CONFIG`, else next to the
binary) and environment variables, which take precedence over it. The raw has
one fact per surface, each declared in `extracted/facts.json` as an opaque
`object` measured on Linux, because the shape is host-independent.

`config` reflects the unexported `fileConfig` struct, which `config.json`
decodes into, over its `json` tags. Node types and the path grammar are the
shared ones from `lib/extracted/go/nat_shared_test.go`. A field whose type has
its own JSON decoder fails extraction: nothing probes such decoders yet.
`defaultTheme`, which `patches/default-theme.patch` adds, also carries `enum`:
the loader's `defaultThemes`, so the option takes only values the server loads.
The extractor names that variable, so a release without the patch fails to
compile it.

`environment` comes from `go/ast` over the non-test files of the
`apps/manager-server` module that the Linux build compiles, functions and
methods alike, because the variable names are string constants passed to
helpers, not struct fields. A function that passes its parameter to `os.Getenv`
or `os.LookupEnv`, or to another such function, forwards it; each call passing a
constant there reads that variable. A non-constant name, and `os.Environ`, fail
extraction. Each node has:

- `type`: `string`, as every environment value is, so the shared classifier sees
  the names.
- `readBy`: the reading functions, which say how the value is parsed
  (`config.envInt` for a positive integer, `config.envBool` for a switch,
  `config.hasEnv` for presence).
- `configKeys`: the `config.json` keys the read falls back to, measured only
  inside the config package. They are the `fileConfig` fields a forwarder call's
  other arguments select, directly or through a local variable assigned from
  them; for a direct read, the arguments callers pass the reading function.
- `description`: the row in the operations guide's environment table
  (`apps/docs/en/operations/manager-server.md`). A row naming a variable no code
  reads fails extraction; a read without a row, `CPAMP_UPDATE_CHECK_ENABLED`,
  has no description.

Not measured: value ranges and defaults (`collectorMode` values,
`usageArchiveRetentionDays` bounds), the derived paths Manager Plus computes
(`usage-archives`, `data.key` under the data directory), and the
`/run/secrets/*` key file defaults.

## Credentials

`config.json` names key files (`managementKeyFile`, `adminKeyFile`,
`dataKeyFile`), never keys. `extract/annotations.json` gives credential reasons
for the three environment variables that carry a key itself, and
`extract/rules.nix` reconciles them through the shared `reconcile`. The config
surface has no rows, so a credential-shaped key added upstream fails until it
gets one.

## Checks and updates

`cpa-manager-plus-extracted` compares the fresh extraction with the committed
facts and checks annotation reconciliation. Regenerate from the repository root:

```bash
nix run .#checks.x86_64-linux.cpa-manager-plus-extracted.passthru.regenerate
```

The package's update script calls the shared `regenCommand` through
`mkGoUpdateExtract.extraAfter`, so a release bump carries its new shape before
publication.
