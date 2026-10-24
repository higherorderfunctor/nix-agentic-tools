# Module properties and retained inputs

> **Last verified:** 2026-10-23 — M3p adds selection metadata, authenticated
> library formals and source property structure through the existing adapter,
> model bundle and database contract; M3r reuses its helper identity for literal
> source rename and alias paths.

## What it answers

`ql/queries/ModuleSelection.ql` reports retained inputs for successful
`option-metadata` requests with facet `selection`. Its columns are target,
context path JSON, option path JSON, selected ordinal, origin label, override
priority and order priority JSON. Paths preserve exact segments. Order is a JSON
string containing signed decimal text, or `null` when upstream supplies no order
field. Ordinals preserve distinct occurrences, including repeated labels.

Selected means retained before type merging and option `apply`. It does not
identify the sole cause of the final value, describe discarded definitions or
explain a custom type's merge. Override priority chooses retained inputs; order
priority sorts those inputs. They remain separate numbers. An origin label can
be synthetic; source association never establishes expression causation.

`Modules::PropertyApplication` separately describes supported source wrappers:
`if`, `merge`, `order` and `override`. It exposes content, condition syntax,
known priority text and the enclosing property. `Modules::PropertyGroup` retains
each literal merge element and its zero-based index. These structures can exist
in inactive code. They establish no observed condition truth and are not rows in
the retained-input query. Unsupported expressions supply no inferred argument or
helper identity.

## How it fits

`src/eval/nix/modules.nix` extends the existing adapter with `selection`. It
reads `definitionsWithLocations`, `isDefined` and `highestPrio`, without reading
merged values or `apply`. Only an explicit retained record's `priority` field
supplies `nx_definition_order`; no default order is invented. Selection emits an
observed option and individually observed definitions. A complete undefined
option has its option witness and no definitions or winning priority. Node
limits count the option plus definitions; root-only depth cannot admit child
definitions. Refusals publish no successful selection transaction. The older
`definitions` facet keeps its existing behavior.

`schema/contract.json` owns both new relations. `nx_definition_order` uses the
existing signed-decimal domain and requires an observed definition.
`nx_module_lib_bindings` links a request to source function/formal anchors and
library/model hashes. F1 validation checks successful request scope, source
admission, structural ownership and target/run fingerprints. The existing
protocol and supervisor carry and validate these facts.

The optional `library` descriptor makes the existing evalModules adapter import
the hash-pinned library root and use that handle for evaluation and injection.
Without it, the legacy caller library remains usable but establishes no binding.
The caller checks the descriptor against the target library hash, common model
bundle and admitted root identity before passing binding candidates. The
supervisor derives candidates from authenticated source bytes and the S2 anchor
tree: a top-level literal function with a formal named `lib`.

The adapter currently covers direct root module-file invocations. It matches
those paths to admitted candidates and suppresses bindings when
`specialArguments.lib` is present. Functions returned by expressions or reached
through another module, and other functions without source anchors, remain
unknown. Missing bindings never prove a function did not execute or used a
different library. Completion covers option metadata, not exhaustive function
coverage. The current producer emits bindings on successful `selection`
requests; the ABI also reserves their use by the later `all-definitions`
consumer.

`models/modules/properties.nix` probes helpers and constants from the pinned
library. `models/modules/generate.py` records source export/binding evidence,
helper argument counts, property kinds and priorities, plus the rename argument
roles described in [renames.md](renames.md). Its module fingerprint and the
builtin model fingerprint form one shared bundle identity. `lib/packaging.nix`
installs `models/modules.json` and its mechanical QL projection as
`nix/internal/generated/Modules.qll`.

`Modules::authenticatedLibraryFormal` gates bindings against that generated
bundle. Lexical resolution follows accesses and local aliases from the supplied
formal to modeled exports; local shadowing does not qualify. The single
generated `ModuleModels::helper` predicate binds export identity, kind and
argument specification to both hashes. Source wrappers reuse authenticated AST
nodes; observed selection reuses typed metadata observations. Neither path adds
a second module evaluator or a property fact table.

## Verification and changes

`codeql-nix-step0`, through `checks/step0.nix`, registers
`checks/fixtures/inc3/properties/test_properties.py`. The suite invokes the
installed query, reviewed `ql/test/inc3/properties/ModuleSelection.expected`
rows and direct upstream `oracle.nix` metadata/value witnesses. It covers guard
mutations, repeated merge occurrences, order swaps, override filtering, missing
order and signed endpoints. Separate fixtures exercise aliases, shadowing,
special arguments, the actual injected library, unsupported function shapes,
budget refusals and structural wrapper/group expectations. These are registered
checks, not evidence that a particular run passed. ABI and protocol fixtures
cover relation validation and transport through existing owner checks.

Change helper probes and the shared QL consumer together. Preserve exact pins,
complete application arity, lexical resolution and explicit unknown boundaries.
Extend the existing adapter, contract, transport and supervisor for new
metadata; regenerate schema/model projections with their generators. Keep query
rows independent of structural wrappers and keep real Nix witnesses independent
of the extractor. Format changes with `treefmt`, run affected owner checks
through CI and update this note when recognition or observation boundaries
change.
