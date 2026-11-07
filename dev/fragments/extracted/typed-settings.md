# Extracted facts: typed settings and their render

> **Last verified:** 2026-11-06 — extracted keys become options with no human
> gate and an update fails only on a real conflict; `lib/extracted/options.nix`
> types the CLIProxyAPI and CPA Manager Plus node trees with nullable container
> children and `secretFile` nodes, and refuses a refinement row that would apply
> on a node with a secret or secret-file descendant; a refinement row on a list
> node receives its element type; `render.nix` lifts secrets and secret files
> into `{$NAME}` placeholders and refuses a malformed `_redact` marker; `goTest`
> runs each owner's loader check; kiro-cli types its four `chat`/`acp` launch
> options from `--help` tables through it.

Two owners, CLIProxyAPI and CPA Manager Plus, get typed settings from their
reconciled facts through one generator. The four older generators
(`packages/claude-code/lib/generateSettingsOptions.nix`,
`packages/kimchi/lib/extracted.nix`, `packages/glab/lib/schema.nix`,
`lib/git-tool-settings/`) predate it and each carry their own scalar switch,
null rule and hand tables. Moving them onto it is separate work; do not add a
fifth.

kiro-cli uses the generator for argv, not for a file:
`packages/kiro-cli/lib/cliOptions.nix` builds one node per setting from its
extracted `cli.options` record (`enum` from the possible values, `bool` for a
flag with none) and takes the options as they come. It passes no `exclusions`:
its classification table is the input, so the generator's `staleExclusions` can
find neither an extracted option with no row nor a stale setting row, and
`cliOptions.report` diffs the table against the extraction directly.

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
  are consumed by it. Redact references retain their marker through this JSON
  type's merge and are lifted by the render, including inside lists and maps.
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
the `type` the row was written for; a row on a list node whose `[]` node exists
also receives `elementType`, the generated element type before `nullOr`, so it
can refuse null elements without retyping the element). `report` lists
`staleExclusions`, `staleRefinements`, `untyped` (a type or a list/map with no
element node that nothing maps) and `misplaced` (a node whose parent is missing
or cannot hold it); every list is empty for a current owner.

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
that sanitize to one name fail evaluation. `render.nix` exports the token
(`placeholder`, `placeholderName`) for `packages/ai-module/lib/services.nix`.

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

## Update policy and option surfaces

Extracted keys become options with no human gate: a per-key review ledger would
re-add the manual step extraction exists to remove, and a mis-classified key is
cheap because a secret-capable option always has the reference form. Secret
restriction comes from one classifier in library code,
`lib/redact/classify.nix`, applied when options are generated.

An update fails only on a real conflict: an extracted file or a large extraction
surface disappears, or module code depends on an expected field that would then
fail evaluation. Everything else, new names and individual removed names
included, flows. Per-name `reconcile` classification stays on its current owners
and is not extended to more.

An option surface describing a packaged binary mirrors that binary. Enums (model
ids, hook events, effort levels) are extracted into a committed, drift-checked
sidecar, never hand-curated, and the extractor asserts the captured shape, not
just non-emptiness. The guard must live in the extractor: the update regenerates
the sidecar inside the same PR, so a collapsed extraction becomes the new truth
and the drift check alone stays green. A freeform settings key the binary really
reads is promoted to a typed option, because freeform passthrough accepts a typo
silently while a typed option fails at evaluation.
