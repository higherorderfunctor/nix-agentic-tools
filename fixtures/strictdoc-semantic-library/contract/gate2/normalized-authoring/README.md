# Public normalized grammar surface probe

Verified 2026-09-14. Scope: package public `lib/` (excluding `values.nix` and
`values/`), public modules, and exporter. No semantics implementation, prior
consumer grammar, planning documents, or coordinator scratchpad was consulted.
The original probe edited no repository file. This publication retains its
historical observations and captures; publication verification is recorded in
[publication.json](publication.json).

The current public DSL is already a constructor layer over normalized values,
but it has **no boolean field-type constructor** and **no
functor/raw-constructor unwrapping API**. Its existing boolean conversion
concerns grammar attributes `required` and `isComposite`. It does not establish
boolean-valued document fields. That missing distinction must remain explicit in
any consumer documentation.

## Entry points and evidence

All source citations below are relative to
[the checked-in public grammar package](../../../../../packages/strictdoc-grammar/).
Line numbers refer to the original observation.

| Finding                                                                                                                                                  | Public source evidence                                                                                 | Executable evidence                                                                                                                                  |
| -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Exported factory is `lib.ai.strictdocGrammar { inherit lib; }`.                                                                                          | `lib/default.nix:2`                                                                                    | Probe imports public directory barrel, then calls this factory.                                                                                      |
| Factory exports exactly `check`, `dsl`, `emit`, `normalized`, `render`.                                                                                  | `lib/grammar.nix:30`, `lib/grammar.nix:39`                                                             | `inventory.barrel`                                                                                                                                   |
| DSL writes normalized tagged attrsets. `field.required` modifies `required` inside the field alternative.                                                | `lib/dsl.nix:91`, `lib/dsl.nix:94`, `lib/dsl.nix:113`                                                  | `field` is `{ string = { title = "FLAG"; humanTitle = "Display flag"; required = true; }; }`.                                                        |
| Field constructors are `many`, `mk`, `one`, `raw`, `required`, `str`, `tag`. No `bool` or `boolean`.                                                     | `lib/dsl.nix:93`                                                                                       | `inventory.field`, `inventory.booleanNames = []`                                                                                                     |
| Normalized field kinds are `string`, `singleChoice`, `multipleChoice`, `tag`.                                                                            | `lib/normalized.nix:391`; source alternatives `lib/faithful.nix:324`                                   | `inventory.fieldAlternatives`; invented bool/boolean alternatives both rejected.                                                                     |
| `BooleanChoice` is `types.bool`; it types `required`. `isComposite` independently uses `nullOr types.bool`.                                              | `lib/normalized.nix:318`, `lib/normalized.nix:365`, `lib/normalized.nix:441`, `lib/normalized.nix:458` | Actual Nix booleans accepted; strings `"True"` rejected.                                                                                             |
| The named boolean converter recognizes upstream True/False productions, not user-defined choice lists.                                                   | `lib/normalized.nix:218`, `lib/normalized.nix:60`, `lib/normalized.nix:76`, `lib/normalized.nix:287`   | `metadata.booleanConverter`; encoder `[false true]` gives `["False" "True"]`.                                                                        |
| `one` takes string options, even if spelled false/true.                                                                                                  | `lib/dsl.nix:105`, `lib/normalized.nix:319`, `lib/normalized.nix:432`                                  | `["false" "true"]` accepted; `[false true]` rejected. No document-value bool inference follows from the accepted strings.                            |
| No public grammar functor. Both `raw` functions are identity over normalized values.                                                                     | `lib/dsl.nix:115`, `lib/dsl.nix:126`; complete barrel `lib/grammar.nix:30`                             | `inventory.functors` all false; raw identity true; invalid required string still rejected through raw.                                               |
| Original production records remain inspectable through `normalized.productions`; original metadata keys remain intact with normalization metadata added. | `lib/normalized.nix:56`, `lib/normalized.nix:295`                                                      | `metadata.productionsPreserved`, `metadata.sourcePreserved` true. `normalized.meta` is extended, not byte-identical to the original metadata record. |
| Rendering automatically checks DSL values, fills defaults, encodes, then renders SGRA.                                                                   | `lib/grammar.nix:41`, `lib/check.nix:27`, `lib/check.nix:40`, `lib/emit.nix:26`                        | `renderEqualsCheckThenEmit`; emitted grammar in `rendered.sgra`. No runtime `decompose` consumer API is exported.                                    |
| Supported metadata survives this chain: human title, prefix, view style, relation roles. Arbitrary field metadata is not accepted.                       | `lib/normalized.nix:359`, `lib/normalized.nix:451`; `lib/sgra.nix:118`, `lib/sgra.nix:175`             | Checked and rendered outputs retain supplied metadata; `schemaMetadata = { valueType = "bool"; }` is rejected.                                       |
| Devenv grammar input is normalized and internally rendered through the same `render`.                                                                    | `modules/devenv/default.nix:201`, `modules/devenv/default.nix:227`                                     | Static source verification only; no devenv evaluation or package build claimed.                                                                      |
| Filtered exporter copies the same public grammar files and publishes the same factory/module.                                                            | `lib/toolchainSource.nix:10`, `lib/toolchainSource.nix:61`, `lib/toolchainSource.nix:74`               | Static exporter verification; old store artifact unavailable locally.                                                                                |

## Comparisons and execution qualification

Gate1 and trial have byte-identical `check.nix`, `default.nix`,
`denormalize.nix`, `dsl.nix`, `emit.nix`, `faithful.nix`, `grammar.nix`,
`normalized.nix`, `pjrpc.nix`, `sgra.nix`, and `tsGrammars.nix`. All executable
probe results except the source path are equal between those two public imports.
`comparison.json` records each SHA-256 and each missing path.

Gate1 adds `scribeSource.nix` and `toolchainSource.nix`. Changes in
`mkExtract.nix`, `mkScribe.nix`, and the devenv module concern removing the
local semantics import check and installing or selecting scribe sources. The
normalized grammar input and render declarations are unchanged.

The main checkout has no `packages/strictdoc-grammar/lib` or corresponding
modules. It cannot be treated as an equivalent exported surface. The supplied
filtered store path
`/nix/store/121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source` is
absent in this process filesystem. Thus downstream artifact byte identity was
not measured; only the checked-in exporter copy contract was inspected.

Nix evaluation used an existing local library,
`/nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib`, whose nixpkgs
`.version` is `26.11`. Its library-directory NAR hash is
`sha256-0BFla09+uN4gn70TyZHTa9zWfpzvd5kGgCEWdyD+1qY=`. This is a qualified local
library check, not a claim to have replayed the absent artifact's original
nixpkgs revision. No lock refresh, package download, or build occurred.

## Replay and retained captures

Run from the repository root, with an existing nixpkgs library path supplied
explicitly:

```sh
nix eval --offline --impure --json --expr '(import ./fixtures/strictdoc-semantic-library/contract/gate2/normalized-authoring/probe.nix { libPath = /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib; })'
nix hash path --offline /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib
```

[probe.nix](probe.nix) defaults `grammarDir` to the checked-in public grammar
library relative to this directory. It requires `libPath`; override `grammarDir`
explicitly for another public library. This command checks the current checkout
using the qualified local library. It does not replay the absent filtered
artifact or establish its original dependency pin.

[gate1.json](gate1.json), [trial.json](trial.json),
[comparison.json](comparison.json), [rendered.sgra](rendered.sgra) and
[verification.txt](verification.txt) retain the original observations, including
historical source paths. The original Gate1 and trial evaluations both exited
zero with all 14 controls true. Positive controls force the same `check`
functions as their negative counterparts; `builtins.deepSeq` forces nested
module validation inside `builtins.tryEval`.

[publication.json](publication.json) records original and published SHA-256
checksums and compares the offline publication replay with both original result
objects, excluding only the top-level `source` path record. JSON publication
preserves the original parsed values. Formatting changes, if any, are
distinguished by the byte checksums. No build, network access or lock update is
part of replay.

## Interface brief for the documentation worker

Use the published factory's `dsl` to author grammar elements and `render` (or
the module's typed `elements`) to validate and emit them. Decomposition is
internal; it does not require consumers to author lower-level raw records. Show
actual Nix booleans for `required` and `isComposite`, string option lists for
existing choice constructors, and preserve supported presentation properties
normally.

Do not describe a `field.bool`, callable grammar functor, faithful-constructor
unwrap, or arbitrary metadata carrier as an available API: none is present in
this public version. Do not label `field.one "FLAG" ["false" "true"]` as an
opinionated boolean-valued schema field. The user's requested higher-level
boolean document-field abstraction remains a missing contract in this surface;
this bounded probe has identified the gap and has not invented or implemented
that layer.
