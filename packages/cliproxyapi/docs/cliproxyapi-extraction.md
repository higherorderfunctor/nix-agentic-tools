# CLIProxyAPI extraction: the v8 configuration shape

> **Last verified:** 2026-10-21 — CPA 8.0.38 custom YAML decoders are probed
> through yaml.v3; the shared `goTestExtract` runs the extractor over the
> patched `src`.

## Why reflection also needs the v8 tables

`v8Paths` contains relocated paths, not a schema. Fields already at their v8
paths, such as `routing.*` and `models.*`, have no relocation entry. Upstream
key families also change shape through `v8KeyFamilies` and `sharedKeyFields`.
Reading only the relocation table or only the reflected structs loses part of
the configuration.

`extract/config_test.go` is copied into the pinned source's `internal/config`
package so it can read those unexported tables. It reflects every YAML-tagged
`Config` field, rewrites legacy prefixes through `v8Paths` and `v8StructPaths`,
and retains unchanged paths whose roots `v8AllowedRoots()` accepts. Every
relocated current path must appear in the result or extraction fails. Scalar
roots accepted by `v8AllowedRoots()` but absent from the structs, including
`config-version`, take their key and type from the canonical template.

An upstream key family becomes `api-keys.<family>[]` groups holding `name` and
`keys`; `base-url` and `sharedKeyFields` also appear at group level. OpenAI
compatibility keeps its group struct with `api-key-entries` renamed to `keys`.
The v8 group loader does not read `auth-index`, so those fields are omitted.

## Measured data

The package's `passthru.extracted` is `lib/extracted`'s `goTestExtract`: it
copies `package.src`, the `applyPatches` tree, so the facts include what
`patches/key-allowlist.patch` adds to the config schema. It also copies the
package's `goModules`, installs the extractor test beside the shared
`lib/extracted/go/nat_shared_test.go` (node types, the field walk, the output)
and runs it with the package's Go toolchain. `GOPROXY=off`,
`GOFLAGS=-mod=vendor` and `GOTOOLCHAIN=local` keep extraction offline. The
YAML-specific typing (durations, `yaml.Node`, decoder probes) stays here.

Each node holds its measured `type`, its field's Go doc `description` parsed
with `go/parser`, and the `template` comment at the same path in
`config.example.yaml`. Path grammar uses `.` between keys, `[]` for a list
element and `.<name>` for a map value. Every ancestor of a node is a node: v8
sections that no Go struct declares (`server`, `access`, `upstream`, ...) are
`object` nodes carrying the template's section comment. A key the template sets
with no node fails extraction, except below an `any` node. Structs that flatten
into the same mapping join their descriptions; conflicting leaves fail
extraction. A type with a custom YAML decoder is typed by probing that decoder
through yaml.v3: try the scalar `true`, then the sequence `[]`, stopping at the
first success, which makes it `any`. Only if both reject, decode the mapping
`{}`; acceptance makes it an `object` whose reflected fields are its children,
as for a plain struct. Rejection fails extraction with the path, Go type and
probe. `credentials.concurrency` and `oauth.providers.codex.live-media-relay`
decode into plain structs and are `object`;
`multimedia.disable-image-generation` reads `true` and `plugins.configs.<name>`
keeps any YAML subtree, so both are `any`. An `any` struct still retains its
known child fields: the mapping form of `plugins.configs.<name>` has the
measured `enabled` and `priority` fields.

The raw has one `config` tree. `extracted/facts.json` declares it as an opaque
`object` because its keys contain dots, with one Linux measurement because the
configuration shape is host-independent. Shared `lib/extracted` owns loading,
platform carrying and regeneration. The reconciliation reader consumes the
declared object directly.

## Hand annotations

`extract/annotations.json` supplies reasons for credential-bearing config paths.
It contains descriptions of credentials, never credential values.
`extract/rules.nix` reconciles these rows against `config` through the shared
facts loader and `reconcile`.

A `*` pattern matches one key made of letters, digits, `_` or `-`, allowing a
single row such as `api-keys.*[].keys[].api-key` to cover every family. A stale
literal or pattern fails, overlapping rows fail, and a new credential-shaped
string path requires a reason. The shared classifier is
`lib/redact/classify.nix`.

## Checks and updates

`cliproxyapi-extracted` compares the fresh extraction with the committed facts
and checks annotation reconciliation. Regenerate from the repository root:

```bash
nix run .#checks.x86_64-linux.cliproxyapi-extracted.passthru.regenerate
```

The package exposes `passthru.extracted`. Its update script calls the shared
`regenCommand` through `mkGoUpdateExtract.extraAfter`, after repairing the Go
floor and vendor hash, so a release bump carries its new configuration shape
before publication.
