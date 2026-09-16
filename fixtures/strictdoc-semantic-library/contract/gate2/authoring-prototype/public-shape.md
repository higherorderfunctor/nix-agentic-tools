# Evaluated Gate 2 shapes

The spellings here describe the bounded prototype, not installed exports. `g` is
existing `grammar.dsl`; `s` and `c` are new proposed namespaces.

## Source and result

`recommended.nix` takes `{ grammar, schema, constraint }`.
`schema.grammar id callback` invokes `callback { elements; views; }` and returns
`{ elements; views; normalized; rendered; }`. `elements` and `views` are
authoring handles; serialize **only** `normalized` and `rendered`. `normalized`
contains `grammar` (existing checked native element list), `bundle` and
`semanticTypes`.

A bundle contains `declarations`, `rules` and `views` lists. External/direct
bundles may omit `declarations`. Each element declaration contributes
`{ id; kind = "element-declaration"; native; semanticFields; }`; independent
copies remain list entries until checked composition. Native grammar emission
uses ordered `fields` and stable keyed element/relation traversal. Field handles
use field titles as keys. Duplicate field titles reject before conversion to
keyed handles.

## Types and defaults

`schema.field.boolean name { required ? false; default ? null; }` and
`schema.field.string name { required ? false; default ? null; }` use a distinct
checked Nix option surface. Existing `g.field.*` values remain accepted.
`default = schema.default.literal value` normalizes to `{ literal = value; }`.
`default = schema.default.script { argv; timeoutMs; }` normalizes to
`{ script = { argv; timeoutMs; }; }`. Literal types follow the semantic field
type; script execution/output validation is future integration.

`semanticTypes = { schema = "sdoc-policy.semantic-types/v1"; digest; fields = [ { field = { grammar; element; name; }; native; semantic; default; } ]; }`.
A Boolean `semantic` value contains `type = "boolean"`, `presence = "required"`
or `"optional"`, `multiplicity = "single"`,
`encode = { false = "false"; true = "true"; }`,
`decode = { false = false; true = true; }`, and `invalid = "error"`. The digest
hashes the schema and ordered fields before adding the digest property. Boolean
native encoding is existing `singleChoice`, not an invented native Boolean tag.

## Predicates, identities and lowering

Callbacks must return tagged Boolean expressions. The finite serialized generic
IR is `{ op; args; }`; prototype constructors cover `isNodeType`, `eq` (same
node), `sameNodeType`, `constant`, `allOf`, `anyOf`, and Boolean `fieldValue`.
`canSee` and `canDescend` expressions come from a boundary visibility view. The
specialized retained targets/visible/endpoint-path contracts are emitted for
supported patterns. Other supported combinations use the proposed
`sdoc-policy.predicate/v1` descriptor, with
`{ quantification; subject; expression; }`. Its execution is **not** implemented
by the bounded Python harness. Raw Nix Booleans reject.

`canSee rel.owner rel.target` lowers to the retained visibility contract.
Reversing its operands rejects in this bounded lowering rather than changing
meaning. The supported endpoint-path specialization requires checked
Parent-upper and Child-lower collections owned by the current record. A generic
future interpreter can support other operand arrangements under a defined
contract.

Stable identities derive from keys:

- Element: `reference/element/FOO`.
- Relation: `reference/element/FOO/relation/Parent/R`.
- Named constraint: relation/element ID plus `/constraint/targetType` or
  `/constraint/endpointPath`.
- Cardinality: relation ID plus `/cardinality`.
- Forest: `reference/view/H`; its validity rule adds `/valid`.
- Global constraint: `reference/constraint/nativeDag`.

Renaming a key intentionally changes the exported identity; no implicit alias is
retained. This prototype assumes the shown simple identifier vocabulary;
production must freeze escaping or reject reserved separators. Contextual
selector remains `{ grammar; ownerElement; nativeType; role; }`; runtime
symbolic nodes and element declarations have distinct tags.

Compounds retain nested visibility inputs under keys equal to the binding's
`from`, such as `inputs."view:reference/view/H"`, alongside `inputs.candidate`.
Nested validity and singleton prerequisites are lifted into `after`. Repeated
identical view inputs deduplicate; conflicting bindings for the same identity
reject. Disabling a needed forest view or validity rule therefore fails checked
composition even when its only consumer is inside `allOf`/`anyOf`.

## Composition

Prototype `compose.nix` is called with
`{ contributions = [ { origin; bundle; } ]; edits ? []; required ? []; }`. It
returns `{ definitions; provenance; digest; edits; }`. Provenance contains `id`,
all `origins`, original `expect` digest and `effectiveDigest`. Definitions with
equal canonical content deduplicate; differing content errors before applying
edits. This includes independently contributed element declarations, rules and
views.

Edits are `{ action = "disable"; id; expect; reason; }` or
`{ action = "replace"; id; expect; reason; rule; }`. Replacement keeps the
identity. Unknown, stale, competing edits, required-rule removal, missing/cyclic
dependencies and weakening an explicit singleton prerequisite reject. Dependency
compatibility for arbitrary custom contracts remains a later preflight
implementation requirement.

Required definitions originally declaring `sdoc-policy.native-dag/v1` receive an
additional bounded meaning guard: both original and effective definitions must
retain model scope, empty all-role config, the candidate model input and the
`model.resolved-parent-child/v1` and `native.all-role-dag/v1` capabilities.
Additional capability requirements are permitted; dropping required
capabilities, changing inputs/scope/config or substituting another contract
rejects. Equivalent descriptor replacement remains possible. The guard is
selected by the original known contract, not fixture-specific IDs. Other
required IDs get presence checking; an arbitrary required ID does not acquire
native semantics. Unknown custom-contract compatibility remains future preflight
work.

## Bounded local result and reference checks

The synthetic candidate now includes `model`. A shared input prerequisite checks
full `{ model; uid; }` identities, unique NodeRefs (including across grammars),
unique relation occurrence IDs, element identities, and resolved relation owners
and targets. Nodes from another model reject. Resolution proceeds in authored
relation order so a later resolution error retains earlier findings. Both local
target entries use that prerequisite and retain separate
selector/target-membership algorithms. This is not a complete native
ModelSnapshot validator. Count and record path helpers also use qualified
references; only after one-model resolution are endpoint UIDs projected into the
supplied forest fixture.

`validate_results(invoked, results, evaluation_id="probe")` checks the expected
evaluation identity, exact result fields, typed status/ID/list values, and every
Finding before computing an aggregate. Findings require typed
producer/code/rule/ message, matching rule identity, lists of NodeRef subjects
and locations, and a JSON-object evidence value. This bounded local helper
supports NodeRef subjects and integer `{ document; path; start; end; }`
locations; unsupported subject/location shapes reject. It does not claim
production DocumentRef/native-coordinate schema coverage. Null lists, string
causes, scalar findings and numeric identities reject, as do omissions,
duplicate/unknown rule results and invalid evidence values.

## Canonical companions

- `../composition.nix`: external and direct target equivalents; contribution
  list.
- `../native-tailoring.nix`: Parent P/Child Q statement without a hierarchy
  obligation.
- `../field-alternative.nix`: fields with explicit resolver/custom contract and
  virtual union-DAG policy; runtime contract only.
- `evaluate.nix`: strict serialization/native rendering; takes `libPath` and
  `grammarPath`.
- `controls.nix`: forced positive/negative Nix controls; same arguments.
- `probe.py`: target entry parity, count, supplied-forest paths, typed encoding
  and result controls.

The evaluators' publication default `grammarPath` is
`../../../../../packages/strictdoc-grammar/lib` from the eventual
`contract/gate2/authoring-prototype/` location. This isolated worker passes
`--arg grammarPath ./inputs/grammar-lib`; no native implementation copy is
intended for publication. `libPath` is overridable and defaults to the verified
pinned public nixpkgs library store path used in this run.
