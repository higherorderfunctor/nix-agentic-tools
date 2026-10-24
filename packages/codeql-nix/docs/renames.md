<!-- cspell:ignore targetless -->

# Renamed and aliased options

> **Last verified:** 2026-10-23 — M3r extends the common pinned module-helper
> model and authenticated library-binding path with source rename edges.

## What it answers

M3r recognizes supported source calls to the pinned library's
`mkRenamedOptionModule` and `mkAliasOptionModule`. The first helper forwards an
old option to a new option with a rename warning; the second aliases without
that warning. A rename edge records the helper call and its literal old/new
segment lists. It does not establish that the call executed, became effective or
explains a final value.

`ql/queries/RenamedOptions.ql` returns exactly
`(target, sourceFile, startByte, endByte, helperKind, fromPathJson, toPathJson)`.
Kind is `rename` or `alias`; the byte range identifies the full two-argument
application. Paths are JSON arrays preserving exact segments: `["a.b"]` is one
segment, distinct from `["a","b"]`. Source files must be admitted for that
target. Calls in inactive branches can still be findings.

An empty result is never a complete no-renames answer. Syntax-only extraction,
incompatible models, missing invocation bindings and unsupported source shapes
can all leave recognition unavailable.

## How it fits

`models/modules/properties.nix` probes the two helpers beside M3p's property
helpers. The existing `models/modules/generate.py` verifies source bindings with
the authenticated syntax parser and requires the literal argument names
`from: to:` before recording their positions. Source export/binding evidence,
generator version and the exact library hash remain in
`generated/models/modules.json`. Its mechanical QL projection supplies the same
`ModuleModels::helper` predicate used by properties. The builtin and module
fingerprints still form one shared bundle; changing either model changes that
bundle.

M3r adds no evaluation relation or request facet. It reuses M3p's
`nx_module_lib_bindings`, linking a successful selection request to admitted
function/formal anchors and library/model hashes. The existing adapter imports
the declared pinned library and supplies that actual handle to directly admitted
root module functions. A formal merely named `lib` is insufficient.
`specialArguments.lib` suppresses binding evidence; generated, computed or other
functions without source anchors remain unknown. A fixture requests root
`option-metadata/selection` for `["new"]` to obtain invocation bindings without
module-graph extraction.

`Modules::authenticatedLibraryFormal` checks the common generated fingerprints.
The shared lexical resolver then follows library accesses and proven local
aliases, `inherit (lib) helper;` and outward bare `inherit f;` from a proven
helper alias, while local shadowing blocks recognition. Selections from
arbitrary local or imported records and nested library namespaces remain
unknown; this layer does not resolve record member values.
`Modules::RenamedOption` exposes target, request, helper kind, paths and call
anchor; `Modules::AliasOption` specializes it for aliases. The private syntax
bridge accepts list expressions containing only literal quoted or indented
strings. One shared decoder normalizes quoted escapes and indented-string
indentation and escapes before shared JSON quoting; existing lexical name
consumers retain their fragment-only acceptance guard. Interpolated or computed
path elements, custom `With` helpers and transformed helper paths establish no
edge. This is bounded literal syntax recognition, not a value evaluator.

`rename-models` records exact-pin helper-model availability for each target. A
matching library model is `supported`, a differing pin is `unsupported`, and an
absent model is `unavailable`. This capability can stay supported when a special
library argument prevents recognition. `ExtractionHealth.ql` reports it
separately from authenticated function/formal coverage: positive coverage is
`partial`, never exhaustive; zero coverage is `unavailable`. With no selected
targets it explicitly reports unavailable model and binding evidence.

Existing `Origin.qll` and retained-definition metadata preserve forwarding
origins. An alias edge or equal values do not relocate a destination definition
to the old assignment. The direct oracle independently inspects the
destination's actual `definitionsWithLocations` labels.

## Verification and changes

`checks/step0.nix` registers `checks/fixtures/inc3/renames/test_renames.py`
through the existing nonempty domain-test runner in
`checks.x86_64-linux.codeql-nix-step0`. The suite checks frozen
`RenamedOptions.expected` rows and installed queries, helper aliases and
shadowing, exact dotted and multi-segment paths, UTF-8 byte ranges, quoted and
indented escapes, multiline indentation, deferred paths, inactive source,
special-library substitution, incompatible pins, missing capability facts,
synthetic targetless syntax and generated model evidence. `oracle.nix` imports
only the pinned upstream library, independently obtaining values, warnings and
destination labels. The exact R fixture expects forwarding value `7`, a rename
warning and the forwarding module's label; its alias variant expects the same
value without that warning.

CI evidence is each named `test_... ... ok` result and the runner's
`test_renames.py: N tests, N executed` summary. The absent-capability case also
prints
`M3r absent-capability fixture: removed ... capability rows before import`; the
targetless source-only graph is checked with the existing ABI authority and
prints
`M3r targetless syntax fixture: removed ... evaluation facts before import`. The
Q0 and M3p suites share the installed-query runner and retain their own
executed-count summaries. Successful check evaluation alone proves no runtime
assertion.

Change probes, the common generator and shared QL recognition together;
regenerate both model projections instead of editing generated inventories.
Preserve exact pins, complete arity, authenticated source/target association and
explicit unknown boundaries. Extend independent expected rows and direct Nix
witnesses with any new recognized shape. Reuse the adapter, bindings, lexical
resolver and owner check; do not add a rename registry or evaluator. Format
changed files, run the affected owner check through CI and update this note when
recognition or coverage changes.
