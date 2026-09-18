## The bundle

```json
[
  {
    "check": {
      "kind": "target-type",
      "targetElement": "model:reference/element:FOO"
    },
    "id": "model:reference/element:FOO/relation:parent:H/check:H.target-type",
    "inputs": ["candidate"],
    "name": "H.target-type",
    "origins": ["declaration:model:reference/element:FOO/relation:parent:H"],
    "requires": [],
    "select": {
      "occurrences": { "direction": "parent", "element": "FOO", "role": "H" }
    }
  },
  {
    "check": {
      "all": [
        {
          "kind": "target-type",
          "targetElement": "model:reference/element:FOO"
        },
        {
          "from": "owner",
          "kind": "visible-target",
          "to": "target",
          "view": "model:reference/view:H-visibility"
        }
      ]
    },
    "id": "model:reference/element:FOO/relation:parent:R/check:R.all",
    "inputs": ["candidate"],
    "name": "R.all",
    "origins": ["declaration:model:reference/element:FOO/relation:parent:R"],
    "requires": ["model:reference/check:H-forest"],
    "select": {
      "occurrences": { "direction": "parent", "element": "FOO", "role": "R" }
    }
  },
  {
    "check": {
      "compare": "lte",
      "kind": "count",
      "relation": { "direction": "parent", "role": "H" },
      "value": 1
    },
    "id": "model:reference/element:FOO/check:one-H-parent",
    "inputs": ["candidate"],
    "name": "one-H-parent",
    "origins": ["declaration:model:reference/element:FOO"],
    "requires": [],
    "select": { "records": { "element": "FOO" } }
  },
  {
    "check": {
      "kind": "endpoint-path",
      "lower": { "direction": "child", "role": "Q" },
      "requireSingleton": true,
      "upper": { "direction": "parent", "role": "P" },
      "view": "model:reference/view:H-visibility"
    },
    "id": "model:reference/element:BAR/check:endpoint-path",
    "inputs": ["candidate"],
    "name": "endpoint-path",
    "origins": ["declaration:model:reference/element:BAR"],
    "requires": [
      "model:reference/element:BAR/check:one-P",
      "model:reference/element:BAR/check:one-Q",
      "model:reference/check:H-forest"
    ],
    "select": { "records": { "element": "BAR" } }
  },
  {
    "check": { "kind": "native-dag" },
    "id": "model:reference/check:native-dag",
    "inputs": ["candidate"],
    "name": "native-dag",
    "origins": ["declaration:model:reference"],
    "requires": [],
    "select": { "model": true }
  },
  {
    "check": { "kind": "forest-validity", "view": "model:reference/view:H" },
    "id": "model:reference/check:H-forest",
    "inputs": ["candidate"],
    "name": "H-forest",
    "origins": ["declaration:model:reference"],
    "requires": [],
    "select": { "model": true }
  },
  {
    "check": {
      "baseline": "model:reference/input:baseline",
      "kind": "preserve",
      "projection": "model:reference/projection:modeled-record"
    },
    "id": "model:reference/check:baseline-preserved",
    "inputs": ["candidate", "model:reference/input:baseline"],
    "name": "baseline-preserved",
    "origins": ["declaration:model:reference"],
    "requires": [],
    "select": { "model": true }
  }
]
```

The array above shows complete selector-plus-check rules from `bundle.json`. The
file is one JSON object containing `grammar`, `semanticTypes`, and `bundle`.
`bundle.schema` is `semantic-constraints/v2`. `bundle.id` identifies the model
namespace, here `model:reference`. `bundle.declarations` indexes the model,
elements, fields, and relations. `bundle.views`, `bundle.inputs`, and
`bundle.projections` hold named configurations. `bundle.rules` is the complete
opt-in rule set for this evaluation. A declaration adds no semantic rules unless
it carries checks or receives contributed checks. BAZ's R and Q intentionally
have no target-type, count, or path constraints. They still participate in
explicitly declared model rules such as the native DAG rule. Native field
validation is required independently of these opt-in semantic rules.

Every rule has `id`, `name`, `select`, `check`, `inputs`, `requires`, and
`origins`. `id` identifies the rule; `name` is its authored or derived display
name. `inputs` lists the complete final `candidate` and any external input
declaration IDs. `requires` lists prerequisite rule IDs, distinct from data
inputs. `origins` records authoring provenance and does not affect validity. A
`declaration:` prefix is followed by the selected declaration ID; a
`contribution:` prefix is followed by the contribution's free name.

## Selectors and Boolean checks

```json
[
  { "records": { "element": "FOO" } },
  { "occurrences": { "element": "FOO", "role": "R", "direction": "parent" } },
  { "model": true }
]
```

`select` has exactly one of `records`, `occurrences`, or `model`, plus optional
`where`. Records selects every record of the named element, including those with
no relations. Occurrences selects each owned occurrence matching element, role,
and direction, preserving duplicates. Model selects the whole candidate model
once. An element's Meta list supplies records; an inline relation check supplies
occurrences; `on SUBJECT CHECK` names the selector explicitly. A model
constraint supplies model. Each existing named-kind rule lowers to one leaf
under `check`, with no authoring spelling change.

```json
{
  "all": [
    { "kind": "target-type", "targetElement": "model:reference/element:FOO" },
    {
      "kind": "visible-target",
      "view": "model:reference/view:H-visibility",
      "from": "owner",
      "to": "target"
    }
  ]
}
```

`all` takes a list of checks and requires every child to hold. This is FOO R's
combined check: both leaves inspect the same selected occurrence. `all []` is
true. Children may themselves be `all`, `any`, or `not`.

```json
{
  "any": [
    {
      "kind": "count",
      "relation": { "direction": "parent", "role": "H" },
      "compare": "eq",
      "value": 0
    },
    {
      "kind": "count",
      "relation": { "direction": "parent", "role": "H" },
      "compare": "eq",
      "value": 1
    }
  ]
}
```

`any` takes a list of checks and requires at least one child to hold; `any []`
is false. This check accepts a selected record with either zero or one H parent.

```json
{
  "not": {
    "kind": "count",
    "relation": { "direction": "parent", "role": "H" },
    "compare": "gt",
    "value": 1
  }
}
```

`not` takes one check and reverses its Boolean result. All three operators are
authoring combinators wherever predicates occur, including inside relation and
record callbacks or a named `check`. `const true` lowers to `all []`,
`const false` to `any []`; the retained `allOf` alias lowers to `all`. Each
check object is exactly one named leaf or one operator key. There is no
expression fallback, no positional argument tree, and no implicit rebinding
within a check.

```json
{
  "occurrences": { "element": "FOO", "role": "R", "direction": "parent" },
  "where": {
    "kind": "target-type",
    "targetElement": "model:reference/element:FOO"
  }
}
```

`where` uses the same check grammar on each initially selected subject. True
includes it; false excludes it without a check finding. A blocked or error
filter produces that status for the subject, never silent exclusion. Nix
`where SUBJECT PREDICATE` adds the filter to a subject used by `on`; the same
binders and allowed leaf kinds apply as in its check. Omitting where selects all
subjects. Input and prerequisite collection also includes every filter leaf.

After input and whole-rule prerequisite checks, evaluate all children without
short-circuiting: an error child makes the expression error; otherwise a blocked
child makes it blocked; otherwise apply the Boolean operator to satisfied/true
and violated/false children. `not` preserves blocked and error. Leaf findings
retain their own status; expression truth determines each selected subject's
status. Thus a violated child can belong to a satisfied `any` or `not`. An empty
selected set is satisfied once inputs and prerequisites are usable.

## Named leaves

| Leaf kind         | Selector    | Fields besides kind                                                                   | Algorithm                                                                                                                           |
| ----------------- | ----------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `target-type`     | occurrences | `targetElement`: element ID                                                           | Resolve target uid and compare its element; wrong element is violated, unresolved uid blocked.                                      |
| `count`           | records     | `relation`: direction and role; `compare`: comparison keyword; `value`: integer       | Count all matching owned occurrences, including duplicates and zero, then compare.                                                  |
| `visible-target`  | occurrences | `view`: visibility ID; `from`: owner; `to`: target                                    | Walk the unique hierarchy path from owner to target, keeping the original origin fixed.                                             |
| `endpoint-path`   | records     | `view`: visibility ID; `upper`, `lower`: direction and role; `requireSingleton`: true | Select each sole endpoint occurrence and walk downward from the upper target to the lower target.                                   |
| `native-dag`      | model       | None                                                                                  | Build all authored Parent/Child edges across every role and element; any directed cycle, including a self-loop, violates.           |
| `forest-validity` | model       | `view`: forest ID                                                                     | Include all view vertices; require resolved in-view endpoints, acyclicity, and at most one incoming selected occurrence per vertex. |
| `preserve`        | model       | `baseline`: input ID; `projection`: projection ID                                     | Compare every baseline-listed uid with the final candidate; missing records and changed projected facts violate.                    |

Only these leaves are supported. Each leaf in a check or filter must be valid
for its selector. Unsupported authoring forms throw during lowering; a backend
rejects unknown leaf kinds, operators, extra check keys, or invalid shapes as
configuration errors. Relation constructors accept a predicate or named check;
record predicates use `record` to obtain owned-relation collections.

`direction` names the authored native type; the graph-building rule is: a parent
occurrence is an edge target→owner, a child occurrence owner→target. Parallel
identical edges do not create a directed cycle, but two selected parent
occurrences violate forest cardinality. An unresolved target uid is an input
error and blocks `native-dag` or `forest-validity`, rather than violating it. A
resolved forest endpoint outside the selected vertex element violates
`forest-validity`. Count checks need occurrence lists but do not need resolved
endpoints. A BAR remains a record between its endpoints in the native graph.

```json
[
  {
    "config": {
      "connected": false,
      "contract": "selected-forest/v1",
      "edges": "model:reference/element:FOO/relation:parent:H",
      "orientation": "parent-to-child",
      "vertices": "model:reference/element:FOO"
    },
    "id": "model:reference/view:H",
    "kind": "view",
    "name": "H"
  },
  {
    "config": {
      "contract": "origin-sensitive-visibility/v1",
      "hierarchy": "model:reference/view:H",
      "policy": {
        "ascent": "unrestricted",
        "closedWhenTrue": "model:reference/element:FOO/field:FLAG",
        "expand": "open-or-origin-in-subtree-including-self",
        "visit": "always"
      }
    },
    "id": "model:reference/view:H-visibility",
    "kind": "view",
    "name": "H-visibility"
  }
]
```

`kind: view` identifies a view declaration; `config.contract` selects its graph
algorithm. `selected-forest/v1` selects vertex records by the `vertices` element
ID and occurrences by the `edges` relation ID. Isolated selected records are
vertices. `orientation` uses the graph-building rule above; `connected: false`
permits multiple roots. `origin-sensitive-visibility/v1` uses the forest named
by `hierarchy`. `policy.closedWhenTrue` identifies the Boolean field used to
decide whether a node is closed. A usable hierarchy requires the entire
forest-validity rule to be satisfied. Both path endpoints must resolve to
hierarchy vertices; otherwise the path occurrence is blocked. A different root
violates a path rule. Visibility ascends to the nearest shared ancestor and then
descends to the target. Endpoint paths require the origin to be an ancestor of
the target; needing ascent violates this rule. `ascent: unrestricted` allows
every upward step without reading FLAG. `visit: always` permits arrival at a
closed node, including the endpoint. Before each downward departure, decode the
departure node's FLAG. `expand: open-or-origin-in-subtree-including-self`
permits departure when that node is open or contains the original origin in its
subtree, including itself. Missing, multiple, or invalid FLAG values at a needed
departure block that occurrence. A closed departure that excludes the origin
violates the path rule and is its boundary. Stop the policy walk at the first
blocked or forbidden departure. The final endpoint needs no expansion. A
zero-step path is satisfied after endpoint and dependency checks; the separate
native DAG rule can still be violated.

```json
{
  "config": {
    "element": true,
    "existence": true,
    "fieldPresence": true,
    "fields": ["model:reference/element:FOO/field:FLAG"],
    "key": "UID",
    "ownedRelations": [
      "model:reference/element:FOO/relation:parent:H",
      "model:reference/element:FOO/relation:parent:R",
      "model:reference/element:BAR/relation:parent:P",
      "model:reference/element:BAR/relation:child:Q",
      "model:reference/element:BAZ/relation:parent:R",
      "model:reference/element:BAZ/relation:child:Q"
    ],
    "relationOrder": "set",
    "relationProjection": ["nativeType", "role", "target"]
  },
  "id": "model:reference/projection:modeled-record",
  "kind": "projection",
  "name": "modeled-record"
}
```

`kind: projection` identifies a record-comparison declaration. `key` names the
identity field; `UID` supplies the same string as the record's `uid`.
`existence: true` requires each baseline-listed record to survive.
`element: true` preserves its element name. `fields` selects field declarations
only on records of their owner element. `fieldPresence: true` distinguishes an
absent key from every present list. Compare present field lists exactly as
native strings, without defaulting or semantic coercion. `ownedRelations`
selects authored occurrences by owner element, direction, and role.
`relationProjection` compares `(nativeType, role, target)`; `nativeType` is the
occurrence's `direction`, and target identity is its target uid.
`relationOrder: set` removes ordering and identical duplicate triples only for
this comparison. Multiplicity still matters to count and forest rules. Incoming
relations owned elsewhere, reverse labels, document placement, and runtime
bookkeeping are excluded. A candidate record absent from the baseline is
unprotected by preserve. A superseding relation grants no preservation
exception.

## Candidate input

```json
{
  "model": "reference",
  "records": [
    {
      "uid": "F0",
      "element": "FOO",
      "fields": { "UID": ["F0"], "FLAG": ["false"] },
      "relations": []
    },
    {
      "uid": "F1",
      "element": "FOO",
      "fields": { "UID": ["F1"], "FLAG": ["false"] },
      "relations": [{ "role": "H", "direction": "parent", "target": "F0" }]
    },
    {
      "uid": "F1a",
      "element": "FOO",
      "fields": { "UID": ["F1a"], "FLAG": ["false"] },
      "relations": [{ "role": "H", "direction": "parent", "target": "F1" }]
    },
    {
      "uid": "F2",
      "element": "FOO",
      "fields": { "UID": ["F2"], "FLAG": ["true"] },
      "relations": [{ "role": "H", "direction": "parent", "target": "F0" }]
    },
    {
      "uid": "F2a",
      "element": "FOO",
      "fields": { "UID": ["F2a"], "FLAG": ["false"] },
      "relations": [{ "role": "H", "direction": "parent", "target": "F2" }]
    },
    {
      "uid": "F2b",
      "element": "FOO",
      "fields": { "UID": ["F2b"], "FLAG": ["false"] },
      "relations": [{ "role": "H", "direction": "parent", "target": "F2" }]
    },
    {
      "uid": "G0",
      "element": "FOO",
      "fields": { "UID": ["G0"], "FLAG": ["false"] },
      "relations": []
    },
    {
      "uid": "G1",
      "element": "FOO",
      "fields": { "UID": ["G1"], "FLAG": ["false"] },
      "relations": [{ "role": "H", "direction": "parent", "target": "G0" }]
    },
    {
      "uid": "I0",
      "element": "FOO",
      "fields": { "UID": ["I0"], "FLAG": ["false"] },
      "relations": []
    },
    {
      "uid": "Z0",
      "element": "BAZ",
      "fields": { "UID": ["Z0"] },
      "relations": []
    }
  ],
  "created": []
}
```

`candidate.json` is the drawn base corpus; it has no R occurrences or BAR
records. `model` is the model name and must match the bundle's model
declaration. `records` is the complete final document graph, not a patch or a
list of only changed records. A record has exactly `uid`, `element`, `fields`,
and `relations`. `uid` is a nonempty string unique across the model, regardless
of element. `element` is a declared element name. `fields` maps declared field
names to lists of native strings exactly as authored. An absent field key means
absence; `[]`, `[""]`, and multiple strings are present values. Each declared
field in this profile is scalar, so a present list must contain exactly one
string. `fields.UID` must be the one-item list containing `uid`. `relations` is
an ordered list of OWNED OCCURRENCES. Each occurrence has exactly `role`,
`direction`, and `target`; role and target are nonempty strings. The owner is
the containing record, and `target` is a model-wide uid. The owner element,
direction, and role must resolve to a declared relation. Reverse labels are
never occurrences. Duplicate identical occurrences are stored and counted as
authored. The zero-based array index distinguishes duplicate occurrences in
findings. `created` is a duplicate-free list of uids newly allocated during the
candidate's batch, including allocations deleted before the final state. The
base sample has no newly created records. Unknown elements, fields, relations,
wrong JSON types, and duplicate uids are input errors. Reject duplicate JSON
object keys during decoding rather than selecting one value. A dangling target
remains available for diagnostics and blocks checks that need resolution. Only
the final batch state is evaluated; private intermediate states do not decide
validity.

## Baseline input

```json
{
  "model": "reference",
  "identity": "baseline-I0-open",
  "complete": true,
  "records": [
    {
      "uid": "I0",
      "element": "FOO",
      "fields": { "UID": ["I0"], "FLAG": ["false"] },
      "relations": []
    }
  ]
}
```

`baseline.json` is a complete snapshot protecting I0 with FLAG false. Baseline
records use exactly the candidate record shape; there is no `created` list.
`model` must match the candidate model. `identity` is a nonempty opaque string
supplied by the provider and recorded in the result envelope. `complete: true`
asserts that every protected record and all of its authored facts have been
supplied. The protected set may be a subset of the candidate; a protected
record's target need not itself be protected. Baseline target strings are
compared as uids without requiring baseline-local endpoint records. A baseline
may retain missing or invalid semantic field values for exact comparison; do not
default or repair them. Its JSON structure, declaration names, unique uids, and
UID consistency must still be valid. `kind: input` identifies the input
declaration; its `config.kind: external-snapshot` selects this provider
protocol. `required: true` requires a successful capture, and `complete: true`
requires a complete protected set, not a nonempty set.

1. Bind each external input ID to an executable command argument list and a
   positive timeout in backend invocation configuration; the baseline sample can
   be supplied by `cat baseline.json` from the packet directory.
2. Invoke that command once without stdin; stdout must contain exactly one JSON
   snapshot object, with optional surrounding whitespace, and stderr is
   diagnostic text.
3. Nonzero exit, timeout, malformed JSON or shape, missing identity, or
   missing/false `complete` is an execution error for every rule declaring that
   input; a missing command binding is also an execution error.
4. An empty complete snapshot such as
   `{"model":"reference","identity":"baseline-empty","complete":true,"records":[]}`
   is valid and protects nothing.
5. Capture one identified immutable snapshot per evaluation and reuse it
   throughout; a provider change affects the next evaluation, never a later rule
   in this one.

## Results

```json
{
  "evaluation": "base-forest-expected",
  "baseline": "baseline-I0-open",
  "expected": true,
  "status": "satisfied",
  "findings": [],
  "results": [
    {
      "rule": "model:reference/element:FOO/relation:parent:H/check:H.target-type",
      "status": "satisfied",
      "findings": [
        {
          "uid": "F1",
          "occurrence": { "role": "H", "direction": "parent", "target": "F0" },
          "occurrenceIndex": 0,
          "status": "satisfied",
          "code": "target-type",
          "message": "The target is FOO.",
          "evidence": { "expectedElement": "FOO", "actualElement": "FOO" },
          "predicatePath": "/check"
        }
      ],
      "causes": []
    }
  ]
}
```

`results.json` contains the complete handwritten expectations; the envelope
above is an excerpt with one entry and one finding. Neither is executed
evaluator output. `expected` is true for illustrative expectations and false for
an actual evaluator response. `evaluation` is a nonempty invocation ID chosen by
the caller and echoed unchanged. `baseline` is the captured baseline identity,
or null if capture failed or no baseline input exists. The envelope's `results`
contains exactly one entry per bundle rule, identified by `rule`. Missing,
duplicate, or unknown rule entries are result protocol errors. Each entry has
`rule`, `status`, `findings`, and `causes`. `satisfied` means the check
evaluated and holds, including defined vacuous satisfaction. `violated` means
the check evaluated and its condition is false. `blocked` means the check cannot
evaluate because a required input or prerequisite is unusable. `error` means
configuration, input acquisition, or evaluator execution failed. A rule's status
is the worst of its occurrence statuses: error > blocked > violated > satisfied.
Whole-rule input and prerequisite failures take precedence over occurrence
evaluation. With usable inputs and prerequisites, a rule over zero records or
zero selected occurrences returns satisfied with `findings: []`. All BAR rules
and the combined FOO R rule are vacuously satisfied in the base sample. A
satisfied empty preservation comparison also has `findings: []`. `causes` is a
duplicate-free list of blocking prerequisite rule IDs or failed/missing input
IDs, including `candidate` when appropriate. A policy violation alone has no
causes.

Emit a finding for each evaluated leaf on each selected relation occurrence or
record, including satisfied leaves; model leaves retain their graph or
preservation witnesses. Add `predicatePath`, a JSON Pointer from the rule to the
leaf, such as `/check`, `/check/all/1`, or `/select/where`. An operator result
with no leaves uses its operator path when a diagnostic is needed. Input or
prerequisite failures use null. Findings thus identify exactly which composed
leaf failed. Each finding has `uid`, `occurrence`, `occurrenceIndex`,
`predicatePath`, `status`, `code`, `message`, and object `evidence`. `uid` is
the owning record for relation checks and the selected record for record checks.
`occurrence` repeats its exact role, direction, and target; `occurrenceIndex` is
its index in the owner's relations. For record checks, occurrence and
occurrenceIndex are null; evidence carries every selected occurrence with its
index. An indexed occurrence has `index`, `role`, `direction`, and `target`;
graph witnesses also include its owning `uid`. Model checks may have no findings
when satisfied; report each preservation difference or graph witness otherwise.
For preservation, uid is the protected record, including when it is missing from
the candidate. For graph-wide findings, uid may be null and evidence identifies
the involved records and owned occurrences. `code` is a diagnostic string tag;
`message` is explanatory text, not a machine-readable condition. Keep findings
already discovered even when a later blocked or error result dominates
aggregation.

| Check or failure        | Required evidence                                                                                                                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| target-type             | `expectedElement` and `actualElement` names; actualElement is null for unresolved targets.                                                                                                                          |
| count                   | `occurrences` as indexed occurrence objects, `count`, `compare`, and integer `value`.                                                                                                                               |
| visible-target          | `origin`, `target`, `path`, `walkedPath`, and `boundary`.                                                                                                                                                           |
| endpoint-path           | Indexed `upper` and `lower` occurrence lists plus `origin`, `target`, `path`, `walkedPath`, and `boundary`; unresolved selections use null endpoints.                                                               |
| graph violation         | `cycle` as a closed uid walk with indexed `edges`, or `parents` as offending incoming indexed occurrences; each occurrence also carries its owner `uid`; wrong endpoints include expectedElement and actualElement. |
| preserve                | `baseline` identity and `differences`, each with `component`, `before`, and `after`; presence differences use objects with `present` and `values`.                                                                  |
| blocked/input/execution | `reason` text, `input` as an input ID or null, `requires` as prerequisite IDs, and any available record, field, or occurrence details.                                                                              |

Preservation difference components are existence (Boolean values), element
(names), a field ID (presence/value objects), or a relation ID (arrays of unique
direction/role/target triples). Path arrays contain uids including the origin
and destination when reached. `path` is the full structural route, while
`walkedPath` is the permitted prefix including the stopping node. Use empty
arrays when endpoints or the hierarchy are unusable or there is no permitted
structural route. `boundary` is the stopping departure node for a closed
boundary or an invalid needed FLAG; otherwise it is null. For whole-rule
blocking, emit blocked findings for all selectable occurrences and include the
prerequisite IDs in evidence. For an empty selected set, the entry status and
causes still record whole-rule blocking. The envelope's `findings` lists
candidate preparation, shape, and native field validation errors using the same
finding shape. Structural errors that prevent candidate indexing block all
candidate-dependent rules with cause `candidate`. Field errors are recorded
there even if no semantic rule reads the field; only occurrences requiring that
field are blocked. An unresolved target also produces a top-level input-error
finding and blocks the resolution-dependent check. Provider failures make each
input-consuming rule error and identify the input in causes. The envelope status
is the worst status across its own findings and all rule entries; an empty set
is satisfied. Protocol and configuration errors produce an error envelope
finding, with null uid and occurrence when no record is implicated. Accept the
complete candidate only when the envelope is satisfied.

```json
[
  {
    "uid": "F1a",
    "occurrence": { "role": "R", "direction": "parent", "target": "F2" },
    "occurrenceIndex": 1,
    "status": "satisfied",
    "code": "visible-target",
    "message": "The closed endpoint can be visited.",
    "evidence": {
      "origin": "F1a",
      "target": "F2",
      "path": ["F1a", "F1", "F0", "F2"],
      "walkedPath": ["F1a", "F1", "F0", "F2"],
      "boundary": null
    },
    "predicatePath": "/check/all/1"
  },
  {
    "uid": "F1a",
    "occurrence": { "role": "R", "direction": "parent", "target": "F2a" },
    "occurrenceIndex": 1,
    "status": "violated",
    "code": "closed-boundary",
    "message": "F2 cannot expand for origin F1a.",
    "evidence": {
      "origin": "F1a",
      "target": "F2a",
      "path": ["F1a", "F1", "F0", "F2", "F2a"],
      "walkedPath": ["F1a", "F1", "F0", "F2"],
      "boundary": "F2"
    },
    "predicatePath": "/check/all/1"
  }
]
```

These are separate expected visibility-leaf findings from the combined R rule
for independent additions to F1a's base relation list. The first walk ascends
through F1 and F0, then visits closed F2 and stops successfully. The second
reaches F2 but cannot depart toward F2a because F1a is outside F2's subtree. An
origin at F2a may reach F2b through closed F2 because that origin is already
inside it.

## Dependencies and blocking

```json
{
  "rule": "model:reference/element:BAR/check:endpoint-path",
  "requires": [
    "model:reference/element:BAR/check:one-P",
    "model:reference/element:BAR/check:one-Q",
    "model:reference/check:H-forest"
  ]
}
```

Resolve `requires` by rule ID and evaluate prerequisites before dependents;
rule-array order is not a schedule. Endpoint-path requires the exactly-one count
rule for each endpoint selector and the forest-validity rule for its visibility
hierarchy. Visible-target requires the forest-validity rule for its visibility
hierarchy. The lowering rejects a missing or ambiguous prerequisite rather than
inventing a check. The lowering step walks every leaf under all, any, and not,
unions their required rule IDs in traversal order, and removes duplicates; no
Boolean branch hides a dependency. It also walks where. Other leaf kinds add no
prerequisite. A prerequisite must be a different, unfiltered rule covering the
same records for a count or the whole model for a forest. Its needed leaf must
be standalone or under only all operators: a satisfied any or not does not
establish that leaf's fact. Missing or ambiguous matches throw; keep endpoint
counts and forest validity in separate prerequisite rules. A violated or blocked
required rule blocks the dependent rule for every occurrence: this is whole-rule
granularity. An error prerequisite also blocks the dependent rule; the original
execution error remains on the prerequisite. Thus an invalid H forest blocks
every visibility and endpoint-path occurrence, even in an otherwise unaffected
tree. A failed endpoint count on any BAR blocks endpoint-path on every BAR.
Missing or multiple endpoints violate the count rule and block endpoint
selection; never select an arbitrary occurrence. Check a rule's own input
acquisition errors before dependencies, so every rule declaring a failed
external input reports error. Missing candidate data or unusable required values
must report cannot-evaluate findings, never satisfied by omission. Independent
rules continue, retaining their own results. Unknown prerequisite IDs and
dependency cycles are configuration errors.

## Keywords

```json
{
  "ascent": ["unrestricted"],
  "visit": ["always"],
  "expand": ["open-or-origin-in-subtree-including-self"],
  "orientation": ["parent-to-child"],
  "connected": [false],
  "relationOrder": ["set"],
  "requireSingleton": [true],
  "from": ["owner"],
  "to": ["target"],
  "compare": ["lt", "lte", "gt", "gte", "eq"],
  "direction": ["parent", "child"],
  "status": ["satisfied", "violated", "blocked", "error"]
}
```

Each array above is the complete allowed value space for its field in this
profile. Booleans are JSON booleans, not quoted strings. `compare` means <,
<=, >, >=, and == in the displayed order. Leaf `kind` is one of target-type,
count, visible-target, endpoint-path, native-dag, forest-validity, preserve. The
closed operator keys are all, any, and not; they are not kinds. Declaration
`kind` is model, element, field, relation, view, input, or projection. Input
`config.kind` has only external-snapshot. View `config.contract` has only
selected-forest/v1 or origin-sensitive-visibility/v1. Input required and
complete, and projection existence, element, and fieldPresence, have only true.
`relationProjection` must be exactly ["nativeType", "role", "target"]. Names,
roles, uids, identities, diagnostic codes, and provenance strings are not enums.
`dsl.nix` validates lowered keyword fields and throws with the field and
rejected value. Its shared `validateKeyword` function also defines the result
status space; results themselves are produced by the backend. A backend must
reject unsupported keyword values in externally supplied bundles and result
envelopes.

## Names and ids

```json
[
  { "id": "model:reference", "kind": "model", "name": "reference" },
  { "id": "model:reference/element:FOO", "kind": "element", "name": "FOO" },
  {
    "id": "model:reference/element:FOO/field:UID",
    "kind": "field",
    "owner": "model:reference/element:FOO",
    "name": "UID"
  },
  {
    "id": "model:reference/element:FOO/relation:parent:H",
    "kind": "relation",
    "owner": "model:reference/element:FOO",
    "direction": "parent",
    "name": "H"
  }
]
```

Element names are unique per model. `select.records.element`,
`select.occurrences.element`, candidate element/model, grammar `tag`, and
projection `key` are names. `select.model: true` refers to the bundle's model.
The declarations index is the name→id map; every declaration has a name. Look up
model and element names by kind and name. Look up a field by owner element ID
and name; look up a relation by owner element ID, direction, and name.
Projection key UID resolves separately on each record's element. Other
references such as targetElement, view, hierarchy, fields, and ownedRelations
are declaration IDs. View, input, and projection IDs resolve in their
corresponding named lists. Treat IDs as opaque after indexing; no parsing is
needed to recover a name or configuration. The producer constructs deterministic
paths, escaping percent and slash in names as %25 and %2F. An explicit check
name keeps its identity; anonymous inline names derive from role and leaf kind
or outer operator, as in R.all. Identical rule definitions with one ID merge
origins; conflicting duplicate identities throw. Distinct rule IDs extend the
rule set; replacement or disabling requires an explicit identity-targeted
operation, which this stub does not supply.

## Defaults

```json
{
  "model": "reference",
  "records": [
    {
      "uid": "I0",
      "element": "FOO",
      "fields": { "UID": ["I0"] },
      "relations": []
    }
  ],
  "created": ["I0"]
}
```

This independent candidate creates isolated I0 with final FLAG absence; its
default becomes ["false"]. A new record has its uid in created; an old record
has its uid outside created. A surviving new record is present in both created
and the final records list. A created uid absent from final records was deleted
and receives no default. The caller must list only newly allocated identities;
deleting and recreating an old uid does not make it new. The backend uses the
supplied change set, not baseline membership, to decide newness. After all
explicit batch edits, fill absent defaulted fields on surviving created records
exactly once, before any validation. Never overwrite a present list, even when
it is empty or invalid. Never apply creation defaults to old records or to
baseline records. Preserve compares the defaulted candidate against the
unchanged baseline. If a protected baseline record lacks FLAG, inserting FLAG
through creation defaulting changes its projection and violates preserve. An old
candidate record still lacking required FLAG is invalid even if it matches that
baseline.

```json
{
  "grammar": [
    {
      "fields": [
        { "string": { "required": true, "title": "UID" } },
        {
          "singleChoice": {
            "choices": ["false", "true"],
            "required": true,
            "title": "FLAG"
          }
        }
      ],
      "relations": [
        { "parent": { "reverseRole": "H_back", "role": "H" } },
        { "parent": { "reverseRole": "R_back", "role": "R" } }
      ],
      "tag": "FOO"
    }
  ],
  "semanticTypes": [
    {
      "defaultsApply": "surviving-new-record-final-absence-only",
      "digest": "6afd11b2c263f32dbac801ecfea4f3dd4eee61c1501d5c7263886e5ab78e83a5",
      "element": "model:reference/element:FOO",
      "fields": [
        {
          "default": null,
          "field": "model:reference/element:FOO/field:UID",
          "native": { "string": { "required": true, "title": "UID" } },
          "semantic": { "type": "string" }
        },
        {
          "default": { "literal": false },
          "field": "model:reference/element:FOO/field:FLAG",
          "native": {
            "singleChoice": {
              "choices": ["false", "true"],
              "required": true,
              "title": "FLAG"
            }
          },
          "semantic": {
            "codec": [
              { "native": "false", "semantic": false },
              { "native": "true", "semantic": true }
            ],
            "type": "boolean"
          }
        }
      ],
      "grammar": "model:reference",
      "schema": "semantic-types/v1"
    }
  ]
}
```

`grammar` describes native elements using `tag`, `fields`, and `relations`. A
field body has one type key: string or singleChoice in this packet. `title` is
its field name, `required` controls absence, and `choices` is the closed list of
native strings for singleChoice. A present string field accepts exactly one
string; required singleChoice also needs one listed choice. A relation body has
native key parent or child with role and reverseRole; reverseRole is only a
display label. A null grammar relations list means no declared relations. Each
semanticTypes entry has schema semantic-types/v1, grammar equal to the bundle
model ID, and an element ID. Its fields list maps field IDs to native
definitions, semantic descriptions, and defaults. `semantic.type` is string or
boolean here; other types are unsupported by this profile. A string uses its
single native string directly. A Boolean codec entry maps one `native` string to
one `semantic` Boolean; only "false" and "true" decode. `default: null` means no
default, and `{ "literal": false }` wraps a typed Boolean default that encodes
through that codec. `defaultsApply: surviving-new-record-final-absence-only`
names the lifecycle defined above. `digest` fingerprints metadata, not candidate
or baseline records. It is the hexadecimal SHA-256 of Nix builtins.toJSON
applied to that entry's schema and fields only, with sorted object keys, compact
separators, and UTF-8 encoding for this packet's ASCII values.

## What is real

The stub evaluates Nix declarations into native grammar, semantic metadata,
selectors and Boolean checks over named leaves, dependencies, and
configurations. It checks declaration identities and references, symbolic
predicate shape, binder placement, Boolean defaults, rule conflicts,
prerequisite selection, and keyword values. It is not a complete schema checker;
ordinary collection role strings and many operand types remain unchecked during
authoring. No backend evaluator, field decoder, default materializer, provider
runner, graph validation, result generator, or candidate publication runs here.
The JSON input and result samples specify the backend boundary; all semantic
verdicts are handwritten expectations. `transcript.txt` records the four proofs,
an invalid policy keyword throw, and the combined R check's two lowered leaves.
It supplies no runtime semantic verdicts.
