# Extracted facts: typed settings and their render

> **Last verified:** 2026-10-21 — `lib/extracted/options.nix` types the
> CLIProxyAPI and CPA Manager Plus node trees with nullable container children
> and `secretFile` nodes, and refuses a refinement row that would apply on a
> node with a secret or secret-file descendant; `render.nix` lifts secrets and
> secret files into `{$NAME}` placeholders and refuses a malformed `_redact`
> marker; `goTest` runs each owner's loader check.

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
  tool's own default applies. Objects are closed submodules; a list is
  `listOf (nullOr T)` for its `[]` node, a map `attrsOf (nullOr T)` for its
  `.<name>` node. Null list elements and map values are accepted and dropped by
  the render.
- `bool`, `int`, `number`, `string` map to the obvious types; `enum` on a node
  gives `types.enum`; `duration` is `strMatching` time.ParseDuration's grammar;
  `any` is a JSON value (the type of `pkgs.formats.json`), and its child nodes
  are consumed by it.
- A node carrying `secret` (the reason an annotations.json row gives, which
  reconcile requires for every classifier hit) is
  `nullOr redact.types.redacted`, including list elements and map values. Its
  non-null type accepts references only. No refinement row widens a secret: a
  row on one is reported stale, and a row that would apply on any node with a
  secret or secret-file descendant fails evaluation, naming both paths, because
  the row returns the whole value type and would replace the redacted
  descendant.
- A node carrying `secretFile` (a reason, like `secret`) is
  `nullOr redact.types.secretFile`, delivered as a file path
  (`dev/fragments/redact/redact.md`, Secret files). It marks a key file the tool
  reads, such as `adminKeyFile`, never a path it writes, such as `dataKeyPath`.
  A node with both fields fails evaluation; a refinement row on one is stale.
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
`sample`, a dummy `redact.file` for a secret or a secret file. An override names
a node path and replaces that value; one naming no node fails.

## The render (`lib/extracted/render.nix`)

`render { prefix; settings; }` returns `{ content; secrets; }`. Nulls are
dropped recursively, inside lists too. Each redact reference becomes the whole
JSON string `"{$<PREFIX>_<PATH>}"`, the env-reference token
`lib/ai/mcpProxy.nix` writes into its Caddyfile, and `secrets` maps that name to
the reference; a secret-file value keeps its tag there, so the launcher fills
its placeholder with a path. Lifting uses `redact.isRedacted` and
`redact.isAsFile`, never a test of its own. Any other set with a `_redact` key
(`redact.isReserved`, after nulls are dropped), even in untyped JSON such as
CLIProxyAPI's `plugins.configs`, is refused through `redact.sealed`. Two paths
that sanitize to one name fail evaluation.

`content` is JSON text for both owners, YAML included: JSON is YAML 1.2, and
CLIProxyAPI's yaml.v3 loader reads it (its loader check proves it). One quoting
means one substitution rule for a launcher: replace the quoted token with the
value encoded as a JSON string. `fill` is that rule in Nix, for checks.

Why not `pkgs.formats.yaml`/`json` (tried 2026-10-18): `generate` yields a
derivation, so the text is only reachable through import-from-derivation, and
its YAML writer single-quotes `'{$NAME}'`, which would give YAML a second escape
rule.

## Loader checks

`goTest { env; name; package; packagePath; postTest; run; sources; }` in
`lib/extracted/default.nix` joins `sources` to a Go package of a buildGoModule
source and runs one test offline; `goTestExtract` is it with the shared
extractor file. Each owner's `<owner>-settings` check evaluates `sample` through
`settingsType`, renders it, fills each placeholder with a dummy that needs JSON
escapes, and runs an in-package `settings_test.go` against the tool's own
loader. `checks.extracted-options` covers the generator and render on fixtures
and requires every owner exporting `settingsType` to report empty.
