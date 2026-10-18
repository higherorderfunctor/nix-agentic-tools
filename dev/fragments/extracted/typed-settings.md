# Extracted facts: typed settings and their render

> **Last verified:** 2026-10-18 — `lib/extracted/options.nix` types the
> CLIProxyAPI and CPA Manager Plus node trees; `render.nix` lifts secrets into
> `{$NAME}` placeholders; `goTest` runs each owner's loader check.

Two owners, CLIProxyAPI and CPA Manager Plus, get typed settings from their
reconciled facts through one generator. The four older generators
(`packages/claude-code/lib/generateSettingsOptions.nix`,
`packages/kimchi/lib/extracted.nix`, `packages/glab/lib/schema.nix`,
`lib/git-tool-settings/`) predate it and each carry their own scalar switch,
null rule and hand tables. Moving them onto it is separate work; do not add a
fifth.

## The generator (`lib/extracted/options.nix`)

Input is one surface's reconciled entries, `(reconcile …).<surface>.entries`:
path → node in the Go extractors' grammar (`.` between keys, `[]` for a list
element, `.<name>` for a map value). It needs only `lib`.

- Every option is `nullOr T` with `default = null`; null drops the key, so the
  tool's own default applies. Objects are closed submodules; a list is `listOf`
  its `[]` node's type, a map `attrsOf` its `.<name>` node's type.
- `bool`, `int`, `number`, `string` map to the obvious types; `enum` on a node
  gives `types.enum`; `duration` is `strMatching` time.ParseDuration's grammar;
  `any` is a JSON value (the type of `pkgs.formats.json`), and its child nodes
  are consumed by it.
- A node carrying `secret` (the reason an annotations.json row gives, which
  reconcile requires for every classifier hit) is `redact.types.redacted`. No
  refinement row widens a secret: a row on one is reported stale.
- Node fields it does not read fail evaluation unless the owner lists them in
  `unread`, so an extractor that learns a fact must teach the generator.

Owner tables, keyed by path: `exclusions` (path → reason; no option) and
`refinements` (path → `{ type; refine; }`, applied only while the node still has
the `type` the row was written for). `report` lists `staleExclusions`,
`staleRefinements`, `untyped` (a type or a list/map with no element node that
nothing maps) and `misplaced` (a node whose parent is missing or cannot hold
it); every list is empty for a current owner.

`sample { overrides; }` sets every leaf from its node: `true`, `1`, `1.5`,
`"sample"`, `"1s"`, the first enum value, one list element, one map entry
`sample`, a dummy `redact.file` for a secret. An override names a node path and
replaces that value; one naming no node fails.

## The render (`lib/extracted/render.nix`)

`render { prefix; settings; }` returns `{ content; secrets; }`. Nulls are
dropped recursively, inside lists too. Each redact reference becomes the whole
JSON string `"{$<PREFIX>_<PATH>}"`, the env-reference token
`lib/ai/mcpProxy.nix` writes into its Caddyfile, and `secrets` maps that name to
the reference. Two paths that sanitize to one name fail evaluation.

`content` is JSON text for both owners, YAML included: JSON is YAML 1.2, and
CLIProxyAPI's yaml.v3 loader reads it (its loader check proves it). One quoting
means one substitution rule for a launcher: replace the quoted token with the
value encoded as a JSON string. `fill` is that rule in Nix, for checks.

Why not `pkgs.formats.yaml`/`json` (tried 2026-10-18): `generate` yields a
derivation, so the text is only reachable through import-from-derivation, and
its YAML writer single-quotes `'{$NAME}'`, which would give YAML a second escape
rule.

## Loader checks

`goTest { env; files; name; package; packagePath; postTest; run; }` in
`lib/extracted/default.nix` joins `files` to a Go package of a buildGoModule
source and runs one test offline; `goTestExtract` is it with the shared
extractor file. Each owner's `<owner>-settings` check evaluates `sample` through
`settingsType`, renders it, fills each placeholder with a dummy that needs JSON
escapes, and runs an in-package `settings_test.go` against the tool's own
loader. `checks.extracted-options` covers the generator and render on fixtures
and requires every owner exporting `settingsType` to report empty.
