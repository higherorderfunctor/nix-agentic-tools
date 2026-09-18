```json
{
  "id": "model:reference/element:FOO/relation:parent:H/check:H.target-type",
  "name": "H.target-type",
  "scope": "relation",
  "subject": { "element": "FOO", "role": "H", "direction": "parent" },
  "kind": "target-type",
  "targetElement": "model:reference/element:FOO",
  "inputs": ["candidate"],
  "origins": ["declaration:model:reference/element:FOO/relation:parent:H"]
}
```

For every owned FOO Parent H occurrence, resolve its declared target and require
the element identified by `targetElement`. A missing or unresolved endpoint
blocks this check; a resolved record of another element fails it.

```json
{
  "id": "model:reference/element:FOO/check:one-H-parent",
  "name": "one-H-parent",
  "scope": "record",
  "subject": { "element": "FOO" },
  "kind": "count",
  "relation": { "role": "H", "direction": "parent" },
  "compare": "lte",
  "value": 1,
  "inputs": ["candidate"],
  "origins": ["declaration:model:reference/element:FOO"]
}
```

For every FOO record, count its owned Parent H occurrences, including a count of
zero. Apply `compare` to that count and the integer `value`; `lt`, `lte`, `gt`,
`gte`, and `eq` mean <, <=, >, >=, and ==.

```json
{
  "id": "model:reference/element:FOO/relation:parent:R/check:visible-R",
  "name": "visible-R",
  "scope": "relation",
  "subject": { "element": "FOO", "role": "R", "direction": "parent" },
  "kind": "visible-target",
  "view": "model:reference/view:H-visibility",
  "from": "owner",
  "to": "target",
  "inputs": ["candidate"],
  "origins": ["declaration:model:reference/element:FOO/relation:parent:R"]
}
```

For every FOO Parent R occurrence, test visibility in `view` from its owning
record to its declared target. Keep the original owner fixed while following the
hierarchy and visibility policy described below.

```json
{
  "id": "model:reference/element:BAR/check:endpoint-path",
  "name": "endpoint-path",
  "scope": "record",
  "subject": { "element": "BAR" },
  "kind": "endpoint-path",
  "view": "model:reference/view:H-visibility",
  "upper": { "role": "P", "direction": "parent" },
  "lower": { "role": "Q", "direction": "child" },
  "requireSingleton": true,
  "inputs": ["candidate"],
  "origins": ["declaration:model:reference/element:BAR"]
}
```

For every BAR record, collect its owned `upper` and `lower` relations;
`requireSingleton: true` requires exactly one occurrence in each before either
endpoint can be selected. Missing or multiple occurrences block this path check
while the separate count rules fail; never choose an arbitrary member. Use the
two declared targets as the upper origin and lower destination, and require a
permitted downward-only path in `view`.

```json
{
  "id": "model:reference/check:native-dag",
  "name": "native-dag",
  "scope": "model",
  "subject": { "model": "reference" },
  "kind": "native-dag",
  "inputs": ["candidate"],
  "origins": ["declaration:model:reference"]
}
```

Build connectivity from every native Parent and Child relation across all roles
and element kinds. A Parent occurrence contributes target → owner and a Child
occurrence contributes owner → target; reject any directed cycle, including a
self-loop.

```json
{
  "id": "model:reference/check:H-forest",
  "name": "H-forest",
  "scope": "model",
  "subject": { "model": "reference" },
  "kind": "forest-validity",
  "view": "model:reference/view:H",
  "inputs": ["candidate"],
  "origins": ["declaration:model:reference"]
}
```

Build the selected forest described by `view`, including all records of its
vertex element and isolated records. Require resolved in-view endpoints, no
cycles, and at most one selected parent per vertex; multiple roots are allowed.

```json
{
  "id": "model:reference/check:baseline-preserved",
  "name": "baseline-preserved",
  "scope": "model",
  "subject": { "model": "reference" },
  "kind": "preserve",
  "baseline": "model:reference/input:baseline",
  "projection": "model:reference/projection:modeled-record",
  "inputs": ["candidate", "model:reference/input:baseline"],
  "origins": ["declaration:model:reference"]
}
```

Acquire the declared complete `baseline` snapshot once for the evaluation and
compare every listed record with the final candidate using `projection`. An
empty acquired snapshot protects nothing, and candidate records absent from the
baseline are unrestricted by this rule. Acquisition failure is an execution
error, not a failed preservation comparison.

Every example above is a complete record from `bundle.json`. Dispatch on `kind`;
the seven emitted kinds need no expression interpreter.

| Kind                                  | Scope          | Kind fields                                                                                          |
| ------------------------------------- | -------------- | ---------------------------------------------------------------------------------------------------- |
| `target-type`                         | relation       | `targetElement`: element declaration ID                                                              |
| `count`                               | record         | `relation`: `{role, direction}`; `compare`: `lt/lte/gt/gte/eq`; `value`: integer                     |
| `visible-target`                      | relation       | `view`: visibility view ID; `from`: `owner`; `to`: `target`                                          |
| `endpoint-path`                       | record         | `view`: visibility view ID; `upper`, `lower`: `{role, direction}`; `requireSingleton`: true for both |
| `native-dag`                          | model          | None; all native Parent/Child roles, parent-to-child connectivity                                    |
| `forest-validity`                     | model          | `view`: forest view ID                                                                               |
| `preserve`                            | model          | `baseline`: input ID; `projection`: projection ID                                                    |
| `expression` (fallback; absent above) | supplied scope | `expression`: named-operand symbolic tree                                                            |

**What the backend must compute**

- `target-type`: resolve each selected occurrence’s declared endpoint and
  compare its element identity.
- `count`: collect owned occurrences by role and direction for every subject
  record and compare their count with the bound.
- `visible-target`: validate the hierarchy and needed Boolean values, find the
  owner-to-target path, and check each step against the fixed origin policy.
- `endpoint-path`: establish both singleton collections, resolve their targets,
  check downward ancestry and each expansion with the upper endpoint fixed as
  origin.
- `native-dag`: orient all native occurrences and detect directed cycles across
  the whole candidate.
- `forest-validity`: construct the selected graph, include isolated vertices,
  resolve its endpoints, count selected parents, and detect cycles.
- `preserve`: capture the required snapshot, match listed UIDs, extract the
  named projection in both states, and compare existence, element, field
  presence/value, and relation sets.
- `expression`: support its named operators or report an unsupported rule
  explicitly; never silently accept it.

All rules also carry `id`, `name`, `scope`, `subject`, `inputs`, and `origins`.
A relation subject selects occurrences owned by `element` with its `role` and
`direction`; a record subject selects every record of `element`, including
records with no relations; a model subject selects the complete named model.
`direction` is the authored Parent/Child type, never a traversal instruction.

IDs are deterministic declaration paths with `%` and `/` in names escaped as
`%25` and `%2F`. Explicitly named checks keep their identities; anonymous inline
names derive from role and kind, such as `H.target-type`. Equal records under
one ID merge origins, while differing meanings under that ID throw; origin order
has no validation meaning. `inputs` lists the implicit complete final
`candidate` plus any declared external input IDs.

`bundle.schema` is `semantic-constraints/v2`; the normalized envelope also
contains `grammar` and `semanticTypes`. `declarations` indexes element,
relation, and field IDs: relation/field `owner` is an element ID, relation
`name` is its role, and relation `direction` is its native type. View, input,
and projection IDs resolve in their respective named lists; no consumer needs to
parse IDs to recover configuration.

Views retain named `config` fields. `selected-forest/v1` uses `vertices` and
`edges` IDs; `orientation: parent-to-child` states how owned relations become
graph edges, and `connected: false` permits multiple roots. These retained
fields explicitly define the selected graph and its connectivity requirement.

`origin-sensitive-visibility/v1` names a `hierarchy` and a `policy`:
`closedWhenTrue` identifies the Boolean field, `ascent: unrestricted` allows
upward steps, `visit: always` permits arrival even at a closed node, and
`expand: open-or-origin-in-subtree-including-self` gates each downward
departure. A closed node permits that departure only when the original origin is
in its subtree, including itself. Reaching the target requires no further
expansion.

`path`, `sameRoot`, and `zeroLength` are omitted: this visibility contract fixes
the unique hierarchy path, requires a shared root, and permits a zero-step path
after prerequisites succeed. Visibility goes up to the nearest shared ancestor
and then down; endpoint paths permit only downward steps, with the upper
endpoint as the fixed original origin. Conceptual self-reachability does not
exempt a native edge from the DAG check.

Inputs retain `config.kind: external-snapshot`, `required`, and `complete`; a
backend must hold one immutable complete snapshot for the evaluation.
Projections retain their named config: `key` selects UID, `existence` and
`element` preserve the record and its element, `fields` selects field IDs, and
`fieldPresence` distinguishes absence from a present value. `ownedRelations`
selects relation declaration IDs; `relationProjection` names the components
`nativeType`, `role`, and `target`, compared as sets when `relationOrder` is
`set` (`nativeType` means the same Parent/Child distinction as `direction`).
Document location, reverse labels, and incoming relations owned elsewhere are
excluded.

`grammar` remains native, with element `tag`, named field-type bodies, and named
Parent/Child relation bodies; reverse roles are display labels, not additional
owned occurrences. `semanticTypes` links each element and field ID to its native
definition, semantic type, codec, and optional default: FOO FLAG maps native
strings `false`/`true` to Booleans. `defaultsApply` permits defaults only for
final absence on surviving new records; invalid present values and old records
are never repaired. `digest` is SHA-256 of Nix’s
`builtins.toJSON { schema; fields; }` for that metadata entry, excluding the
digest itself; it fingerprints metadata, not candidate records.

Only unmatched authoring forms retain `expression`. Its operators have named
operands: `isNodeType {node, element}`, `count {collection}`, comparisons
`{left, right}`, `relations {record, role, direction}`, `only {collection}`,
`endpointTarget {relation}`, `visible`/`canDescend {view, origin, target}`,
`isForest {view}`, `preserve {baseline, projection}`, `const {value}`, and
`allOf {terms}`; `nativeDag` has no operands. The `op` field selects the
operator; `record`, `owner`, and `target` are symbolic tokens, and `terms` is a
conjunction list, not positional operands. Fallback occurrence binding follows
the rule scope; constants and comparisons return Booleans, and singleton
extraction blocks unless exactly one occurrence exists.

All runtime work uses the complete final candidate after explicit changes and
applicable defaults. Missing endpoints, invalid required field values, and an
unusable hierarchy block dependent path checks; a usable path rejected by its
policy fails. A shared-root mismatch or a required ascent in a downward-only
path fails once prerequisites are usable. The rule array supplies no execution
schedule; a backend establishes prerequisites and distinguishes failed checks,
blocked checks, and execution errors. Duplicate occurrence storage semantics are
unspecified; relation-set comparison does not define cardinality counting.

**What is real**

This is an evaluated stub lowering; no backend runs. It checks declaration
identity/reference existence, symbolic shape and binder placement, Boolean
default literals, and deduplication/conflicts, while leaving collection role
strings, many operand types, and policy keywords unchecked. It emits native
grammar and semantic metadata without decoding records, materializing defaults,
acquiring inputs, validating graphs, scheduling prerequisites, or publishing
candidates.

`transcript.txt` records evaluation through a temporary copy with the supplied
native grammar import: `sameNormalized = true`, `deduplicated = true`,
`sugarEqualsLowest = true`, and `conflict` throws naming `target-type`. These
prove lowering properties only.
