# Writing rules for the FOO, BAR, and BAZ model

> Status: This is a proposal for the Gate 2 read. Real today: The evaluated Nix
> stub lowers declarations into data. Wiring today: There is no graph evaluator
> or backend connection. After reading: You can write a rule using the
> constructors shown here. Results below: Every Result column is specified
> behavior, not an executed result.

## The model in one picture

An **element** declares a kind of record. A **record** is one instance of that
kind, such as `F2`. Each record has a required string field named `UID`, which
gives other records a way to address it.

- **FOO** is the kind used for the hierarchy and visibility examples. Its
  required Boolean field `FLAG` says whether it is open or closed. Its Parent
  relation named `H` selects its hierarchy parent. Its Parent relation named `R`
  points at another FOO under the visibility rule.
- **BAR** is a bridge record. It owns a Parent relation named `P` and a Child
  relation named `Q`. Both endpoints must be FOO records. A finished bridge has
  exactly one of each relation.
- **BAZ** provides a record outside the hierarchy. It can own Parent `R` and
  Child `Q` relations. Reusing those names does not give it the FOO visibility
  rule or the BAR bridge rule.

Here is the base forest, which means a collection of trees with no requirement
that their roots connect. All named nodes except `Z0` are FOO records.

```text
F0  FLAG=false (open)
├── F1  FLAG=false (open)
│   └── F1a  FLAG=false (open)
└── F2  FLAG=true (closed)
    ├── F2a  FLAG=false (open)
    └── F2b  FLAG=false (open)

G0  FLAG=false (open)
└── G1  FLAG=false (open)

I0  FLAG=false (open)

Z0 : BAZ (outside the H forest; no FLAG)

M : BAR (created only in bridge examples; not an H-tree node)
```

A line down the tree represents connectivity from parent to child. The
declaration itself lives on the child. So `F1a` owns a Parent `H` relation whose
target is `F1`. Document nesting does not determine these edges.

The two directions matter when reading a bridge:

```text
M owns Parent P targeting F0:  F0 ──→ M
M owns Child  Q targeting F2:        M ──→ F2
Together:                     F0 ──→ M ──→ F2
```

The bridge stays a record between the endpoints. It does not become a new `H`
edge from `F0` to `F2`. A reverse name such as `P_back` is a display label for
the other direction. It does not create another authored declaration.

The semantics answer three questions:

1. **Who may point at whom?** FOO's `H` and `R`, and BAR's `P` and `Q`, must
   target FOO records such as `F1` or `F2`.
2. **What is hidden from whom?** `F1a` may point its `R` at closed `F2`, but it
   may not point through `F2` at `F2a`.
3. **What must a bridge connect?** `M` must connect its `P` endpoint to its `Q`
   endpoint by a permitted downward `H` path.

There is also a rule for the entire native graph. Here, **native** means the
underlying Parent and Child relations, across all roles and all element kinds.
That graph must have no directed cycle. This is what **DAG**, or directed
acyclic graph, means in the code.

Each scenario below starts from this picture unless its Situation cell says
otherwise. Illustrative relations do not accumulate between rows. The external
baseline is successfully acquired, complete, and empty unless a row says that it
protects a record. A **candidate** is the complete proposed state after all
operations in one batch. Acceptance means that this final state meets all
applicable rules. Rejection keeps the prior state. An execution error means that
required input or execution failed, so it is not a verdict that a modeled fact
is false.

## Two places a rule can live

The next two columns quote the corresponding lines of `composition.nix`
verbatim. Read down either column. Both say that each Parent `R` owned by FOO
must target FOO.

<table>
<tr><th>Inline on the relation</th><th>In the element's constraints list</th></tr>
<tr><td><pre><code>  foo = el "FOO" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back" (check "target-type" (edge: isNodeType edge.target foo)))
    ];
    constraints = [];
  };
</code></pre></td><td><pre><code>  baseFoo = el "FOO" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back")
    ];
    constraints = [(on (parentOf baseFoo "R") targetType)];
  };
</code></pre></td></tr>
</table>

The right column uses this declaration, also quoted verbatim:

```nix
  targetType = check "target-type" (edge: isNodeType edge.target foo);
```

`foo` and `baseFoo` are Nix variables holding alternative declarations of the
same element name, `FOO`. They are used in separate versions of the model.
Putting both declarations in one model would duplicate the element identity.

The inline form attaches the check to the relation it follows. The list form
uses `parentOf baseFoo "R"` to find that same kind of relation. Then `on`
attaches `targetType` to it. Here, **Meta** in the source comment means the
element's `constraints` list. It is not another record or an extra call you must
write.

These forms mean the same thing, and the file proves it by comparing their
normalized values:

```nix
  sameNormalized =
    normalize declaration
    == normalize (declaration // {elements = [baseFoo];});
```

`normalize` turns both forms into the same rule with the same subject and
expression. The name `"target-type"` is deliberately identical in both forms. A
bare inline callback receives the automatic name `"predicate"`, so that shortcut
would not prove equality with a differently named check. The comparison is a Nix
equality expression, not a graph validation test.

Prefer the inline form for a short rule that belongs to one relation. Prefer the
constraints list when several rules belong together or when a reusable check
already has a name. Use `record` in that list when you need to count a record's
relations, including a count of zero.

For example, either target rule rejects `F1a` pointing its `R` at `Z0`, because
`Z0` is BAZ. Neither form applies that rule to `Z0`'s own Parent `R`. The owner
kind is part of the selected relation's identity.

## Vocabulary

Nix applies functions by putting arguments after the function name. So
`atMost 1 collection` supplies two arguments to `atMost`. Parentheses group an
expression. Square brackets contain a list. Braces contain named attributes,
such as `fields = [uid];`. An empty pair of braces supplies an empty attribute
set.

`edge: expression` is a function whose argument is locally named `edge`. That
name is yours to choose. The colon does not perform a check. The expression
after it builds the condition to check later. A **predicate** here is a symbolic
condition, which means data describing a question rather than its Boolean
answer. A **reference** identifies a declared element, relation, field, view,
input, or projection.

The entries follow the first appearance of constructor names in `examples.nix`,
including its import lists. `field` and `rel` are groups of constructors, so
they are explained here rather than given constructor entries.
`inherit (field) required str;` makes those two names available without a
`field.` prefix. The two additional constructors used only by `composition.nix`
come last.

The signatures distinguish chosen names, fixed keywords, references, and
predicates. Some arguments are numeric or Boolean literals, or configuration
objects containing several of these kinds. Those are identified explicitly
instead of being called string keywords. The stub does not fully type-check
those kinds. For example, it checks that a referenced identity exists, but it
does not validate every view configuration or every collection role.

For the Checks line, **blocked** means a condition cannot obtain a required
operand. It is different from **failed**, which means an evaluable condition is
false. A missing singleton endpoint is the concrete example below. The stub
emits expressions and throws authoring errors; it does not emit runtime blocked
results. Where a broader prerequisite is missing, the contract does not settle a
complete scheduling or diagnostic protocol.

### `el NAME PROPERTIES BODY`

- `NAME`: A name you choose for the element kind, such as `"FOO"`.
- `PROPERTIES`: A grammar configuration object. The accepted examples use `{}`,
  which supplies no properties. The wrapper forwards this object without
  checking its keys.
- `BODY`: A configuration object with the fixed keys `fields`, `relations`, and
  `constraints`. Their lists contain declarations or predicates obtained from
  the corresponding constructors. The wrapper does not reject other keys.
- Produces: An element declaration that can be stored as `foo`, `bar`, or `baz`.
- Checks: Declares the grammar and checks for every record of this element. It
  evaluates no records itself, and has no blocked outcome.
- Kind: Existing grammar constructor with a new semantic wrapper that marks
  element identity and retains constraints until normalization.

### `model NAME BODY`

- `NAME`: A name you choose for the model, such as `"reference"`. It supplies
  the namespace for declaration identities.
- `BODY`: A configuration object with the fixed keys `elements`, `views`,
  `inputs`, `projections`, `constraints`, and `contributions`. Supply lists of
  references to the corresponding constructed values. Every listed key defaults
  to an empty list.
- Produces: One model declaration containing the supplied values.
- Checks: Collects declarations for the whole model without evaluating them. It
  has no blocked outcome and does not reject unknown body attributes by itself.
- Kind: New semantic constructor.

### `normalize MODEL`

- `MODEL`: A reference value obtained from `model`, possibly with a Nix
  attribute update before normalization.
- Produces: An attribute set with `grammar`, `semanticTypes`, and `bundle`,
  containing serializable declarations and rules.
- Checks: Checks declared identities, referenced identities encountered during
  lowering, predicate shape and binder scope, and conflicting rule identities
  across the whole model. Errors throw during Nix evaluation rather than
  returning failed or blocked graph results.
- Kind: New semantic constructor for lowering, which means turning authoring
  values into data.

### `check NAME EXPRESSION`

- `NAME`: A name you choose for the check, such as `"one-H-parent"`. Together
  with its subject it identifies the rule.
- `EXPRESSION`: A predicate. Supply a symbolic expression, a `record`
  expression, or a relation callback receiving `edge` and returning a symbolic
  predicate.
- Produces: A named check that needs a scope from its placement or from `on`.
- Checks: Applies to every relation occurrence when attached to a relation,
  every record when placed on an element, or the whole model when placed in
  model constraints. A missing required operand blocks the dependent predicate,
  while a raw Nix Boolean is an authoring error.
- Kind: New semantic constructor.

### `on SUBJECT CHECK`

- `SUBJECT`: A relation reference obtained with `parentOf` or `childOf`.
- `CHECK`: A named predicate obtained with `check`.
- Produces: A check explicitly attached to that relation kind.
- Checks: Selects every matching owned relation occurrence. It does not run once
  on an empty relation collection, and blocked behavior belongs to the selected
  check's operands.
- Kind: New semantic constructor.

### `record BIND`

- `BIND`: A predicate-building function receiving a record binder, locally named
  `node` or `bridge`, and returning a symbolic predicate.
- Produces: A record-scoped expression containing that function's symbolic body.
- Checks: Runs once for every record of the owning element, including records
  with no matching relations. Normalization rejects its use outside record
  scope, and operand failures can block its body at runtime.
- Kind: New semantic constructor.

### `required FIELD`

- `FIELD`: A field declaration obtained from `str` or `boolean`, possibly
  already decorated with a creation default.
- Produces: That field marked as required, retaining semantic type and default
  metadata.
- Checks: Requires a value on every record of the declaring element when the
  final record is validated. Absence is a required-field problem, not an
  automatic default for an existing record, and this constructor has no blocked
  result.
- Kind: Existing grammar constructor with a wrapper that preserves the new
  metadata.

### `str NAME`

- `NAME`: A name you choose for a string field, such as `"UID"`.
- Produces: An initially optional native string-field declaration.
- Checks: Declares string-field grammar for every record using the field. It
  does not check uniqueness or acquire a value, and it has no blocked result.
- Kind: Existing grammar constructor.

### `boolean NAME`

- `NAME`: A name you choose for a Boolean field, such as `"FLAG"`.
- Produces: A native single-choice field with the complete choice set `"false"`,
  `"true"`, plus metadata mapping them to the Nix Boolean values `false` and
  `true`.
- Checks: Specifies one valid Boolean value when the field is present on a
  record. Unknown values and invalid multiplicity are input/type errors, and a
  dependent visibility check cannot use an invalid Boolean as if it meant open.
- Kind: New semantic constructor built on an existing native single-choice
  field.

### `creationDefault VALUE FIELD`

- `VALUE`: A typed literal. The stub accepts exactly the Boolean values `false`
  and `true`, which become the corresponding Boolean field value.
- `FIELD`: A Boolean field declaration obtained from `boolean`, optionally
  through `required`.
- Produces: The field with a literal default recorded in metadata.
- Checks: The stub checks the Boolean literal and Boolean metadata immediately.
  The specified default applies once to surviving newly created records with
  final absence, while invalid supplied data errors and provider-related
  blocking are not implemented here.
- Kind: New semantic constructor.

### `parent ROLE REVERSE_ROLE [PREDICATE]`

- `ROLE`: A name you choose for this Parent relation, such as `"H"` or `"R"`. It
  is not a built-in role enum.
- `REVERSE_ROLE`: A name you choose for the reverse display label, such as
  `"H_back"`.
- `PREDICATE`: Optional predicate. Supply a callback receiving `edge` and
  returning a symbolic condition, or supply a named `check` containing that
  condition.
- Produces: A Parent relation declaration, optionally carrying one inline check.
  A bare callback is named `"predicate"` by the stub.
- Checks: Any inline check applies to every occurrence owned by this element
  with this Parent role. No occurrence means no invocation, and an unresolved
  endpoint prevents dependent endpoint checks rather than demonstrating a wrong
  target type.
- Kind: Existing grammar constructor extended with a new semantic inline-check
  argument.

### `child ROLE REVERSE_ROLE [PREDICATE]`

- `ROLE`: A name you choose for this Child relation, such as `"Q"`.
- `REVERSE_ROLE`: A name you choose for its reverse display label, such as
  `"Q_back"`.
- `PREDICATE`: Optional predicate. Supply a callback receiving `edge` and
  returning a symbolic condition, or a named `check`.
- Produces: A Child relation declaration. Its owner points toward the child in
  native connectivity.
- Checks: Any inline check applies to every owned occurrence of this Child role.
  An empty collection produces no invocation, and an unavailable endpoint
  prevents dependent endpoint evaluation.
- Kind: Existing grammar constructor extended with a new semantic inline-check
  argument.

### `parentOf ELEMENT ROLE`

- `ELEMENT`: A reference to an element declaration obtained from `el`, such as
  `foo`.
- `ROLE`: A reference key naming a Parent role declared on that element, such as
  `"R"`.
- Produces: A relation reference qualified by model, owner element, Parent
  direction, and role.
- Checks: Selects a relation declaration rather than any individual record.
  Normalization rejects an undeclared selected identity, so this is an authoring
  error rather than a blocked predicate.
- Kind: New semantic constructor.

### `childOf ELEMENT ROLE`

- `ELEMENT`: A reference to an element declaration obtained from `el`, such as
  `bar`.
- `ROLE`: A reference key naming a Child role declared on that element, such as
  `"Q"`.
- Produces: A relation reference qualified by model, owner element, Child
  direction, and role.
- Checks: Selects a declaration for later per-occurrence checks or projection.
  Normalization rejects an undeclared selected identity, with no runtime blocked
  result from the selector itself.
- Kind: New semantic constructor.

### `fieldOf ELEMENT FIELD`

- `ELEMENT`: A reference to an element declaration obtained from `el`, such as
  `foo`.
- `FIELD`: A field declaration value obtained from `str` or `boolean` and its
  wrappers, such as `flag`.
- Produces: A reference to that field name under that element, rather than a
  field value from a particular record.
- Checks: Normalization checks that the referenced field identity was declared.
  This selection has no per-record predicate or blocked result.
- Kind: New semantic constructor.

### `isNodeType NODE ELEMENT`

- `NODE`: A symbolic node reference obtained from `edge.origin`, `edge.target`,
  or `(only COLLECTION).target`.
- `ELEMENT`: A reference to an element declaration obtained from `el`.
- Produces: A predicate asking whether the referenced node has that element
  kind.
- Checks: Examines the selected node for each bound relation or record. A
  resolved wrong kind fails, while an unresolved node is a prerequisite problem
  whose detailed result scheduling is not implemented.
- Kind: New semantic constructor.

### `atMost COUNT COLLECTION`

- `COUNT`: An integer bound you supply, such as `1`. It is a numeric literal,
  not a name or string keyword, and the stub does not validate its range or
  type.
- `COLLECTION`: A symbolic collection obtained from a record binder's
  `parents ROLE` or `children ROLE`.
- Produces: A predicate saying that the number of owned matching relations is no
  greater than the bound.
- Checks: Counts the selected collection once for each record. Zero is a valid
  count and does not block the check.
- Kind: New semantic constructor.

### `exactly COUNT COLLECTION`

- `COUNT`: An integer count you supply, such as `1`. The stub stores it without
  validating its range or type.
- `COLLECTION`: A symbolic collection obtained from a record binder's
  `parents ROLE` or `children ROLE`.
- Produces: A predicate saying that the collection has exactly the requested
  number of relations.
- Checks: Counts owned matching relations once for each record. An empty
  collection has count zero, so `exactly 1` fails rather than blocks.
- Kind: New semantic constructor.

### `only COLLECTION`

- `COLLECTION`: A symbolic collection obtained from a record binder's
  `parents ROLE` or `children ROLE`.
- Produces: A symbolic selection of the sole relation, with `.target` exposing
  its declared endpoint as a symbolic node reference.
- Checks: Requires a singleton, which means a collection with exactly one
  member, for each bound record. Zero or multiple members block the dependent
  path check rather than create another cardinality failure.
- Kind: New semantic constructor.

### `forest NAME EDGES`

- `NAME`: A name you choose for the hierarchy view, such as `"H"`. It need not
  equal the selected role's name.
- `EDGES`: A relation reference obtained from `parentOf`, here
  `parentOf foo "H"`.
- Produces: A view declaration selecting all records of the relation's owner
  element and arranging its selected Parent relations from parent to child, with
  disconnected roots allowed.
- Checks: Declares the selected graph for the whole model without validating it;
  `isForest` performs the specified structural check, and an invalid hierarchy
  prevents dependent unique-path reasoning.
- Kind: New semantic constructor.

### `isForest VIEW`

- `VIEW`: A reference to a view declared by `forest`, such as `h`.
- Produces: A predicate asking whether that selected graph is a forest.
- Checks: Examines the entire selected hierarchy for cycles and multiple
  hierarchy parents while permitting isolated records and multiple roots.
  Structural violations fail, and unresolved structural inputs prevent a usable
  hierarchy.
- Kind: New semantic constructor.

### `visibility NAME HIERARCHY POLICY`

- `NAME`: A name you choose for the visibility view, such as `"H-visibility"`.
- `HIERARCHY`: A reference obtained from `forest`, here `h`.
- `POLICY`: A configuration containing a Boolean field reference in
  `closedWhenTrue` and the contract keywords `ascent = "unrestricted"`,
  `visit = "always"`, and `expand = "open-or-origin-in-subtree-including-self"`.
  These are the complete specified string choices for these slots, and their
  step-by-step meanings appear below.
- Produces: A visibility view requiring a shared hierarchy root and a unique
  hierarchy path, with conceptual zero-length paths allowed.
- Checks: Declares behavior for later endpoint predicates across the selected
  hierarchy. It performs no traversal, does not validate the policy keywords,
  and cannot make an invalid hierarchy usable.
- Kind: New semantic constructor.

### `visible VIEW ORIGIN TARGET`

- `VIEW`: A reference obtained from `visibility`, here `sight`.
- `ORIGIN`: A symbolic node reference, usually `edge.origin`, meaning the record
  owning the relation.
- `TARGET`: A symbolic node reference, usually `edge.target`, meaning the
  declared endpoint.
- Produces: A predicate asking whether the target is visible from the original
  origin along the hierarchy path.
- Checks: Applies to each bound relation occurrence in the example. Different
  roots or a forbidden downward expansion fail, while an unusable hierarchy,
  endpoint, or required Boolean prevents the path question from being evaluated.
- Kind: New semantic constructor.

### `canDescend VIEW ORIGIN TARGET`

- `VIEW`: A reference obtained from `visibility`, here `sight`.
- `ORIGIN`: A symbolic node reference, here the target of the bridge's sole
  Parent `P`.
- `TARGET`: A symbolic node reference, here the target of the bridge's sole
  Child `Q`.
- Produces: A predicate asking whether an entirely downward hierarchy path obeys
  the visibility expansion policy.
- Checks: Applies once per bound bridge record. An upward step or forbidden
  expansion fails, and a non-singleton endpoint collection blocks this check
  through `only`.
- Kind: New semantic constructor.

### `nativeDag`

- Arguments: None. This is already a symbolic predicate, so do not call it with
  parentheses containing an argument.
- Produces: A whole-model predicate over all native Parent and Child roles in
  parent-to-child orientation.
- Checks: Rejects any directed cycle in their combined graph, including cycles
  crossing roles or element kinds. Unresolved graph inputs cannot establish a
  successful cycle check, and the stub has no blocked-result implementation.
- Kind: New semantic predicate expressing the required native graph invariant.

### `input NAME CONFIG`

- `NAME`: A name you choose for an input declaration, such as `"baseline"`.
- `CONFIG`: Input settings. The specified profile uses the sole specified `kind`
  keyword `"external-snapshot"`, plus Boolean `required = true` and
  `complete = true` to require successful acquisition of a full snapshot.
- Produces: An input declaration for later rule references.
- Checks: Specifies an input requirement for evaluation of the whole candidate.
  The stub checks neither these configuration values nor acquisition, and
  missing or failed required acquisition is an execution error that prevents
  preservation evaluation.
- Kind: New semantic constructor.

### `projection NAME CONFIG`

- `NAME`: A name you choose for the comparison description, such as
  `"modeled-record"`.
- `CONFIG`: A comparison description using `key`, `existence`, `element`,
  `fields`, `fieldPresence`, `ownedRelations`, `relationProjection`, and
  `relationOrder`. The complete field-by-field meaning is explained in its
  walkthrough.
- Produces: A declaration describing which parts of each listed record
  preservation compares.
- Checks: Selects facts for each baseline-listed record without comparing them.
  The specified relation-component keywords are `"nativeType"`, `"role"`, and
  `"target"`, and the sole specified order keyword is `"set"`, but the stub
  validates none of these choices.
- Kind: New semantic constructor.

### `preserve BASELINE PROJECTION`

- `BASELINE`: A reference obtained from `input`, here `baseline`.
- `PROJECTION`: A reference obtained from `projection`, here `modeledRecord`.
- Produces: A whole-model predicate requiring every baseline-listed record to
  retain its projected facts.
- Checks: Compares existence and selected authored facts for every listed UID.
  Changes fail, a successful complete empty baseline protects no records, and
  acquisition failure is an execution error rather than a preservation
  violation.
- Kind: New semantic constructor.

### `contribute NAME SUBJECT CHECKS`

- `NAME`: A name you choose for the contribution, such as
  `"extra-target-check"`. It records where the added rules came from.
- `SUBJECT`: A reference to an already declared relation, obtained with
  `parentOf` or `childOf`.
- `CHECKS`: A list of named predicates obtained with `check`.
- Produces: A contribution to place in the model's `contributions` list.
- Checks: Adds checks for every matching relation occurrence. Normalization
  merges equal rules with the same identity and errors on different meanings
  with the same identity, rather than treating either as a blocked graph check.
- Kind: New semantic constructor.

### `const VALUE`

- `VALUE`: A typed Boolean literal. The complete accepted set is `false`,
  meaning an always-false predicate, and `true`, meaning an always-true
  predicate.
- Produces: A symbolic constant predicate accepted by normalization.
- Checks: Gives the same answer for every subject in its placement's scope, with
  no operand that can block. Any non-Boolean argument throws an authoring error.
- Kind: New semantic constructor.

### The callback objects, without hidden properties

A **binder** supplies symbolic references for the subject that a future
evaluator will visit. It does not contain a loaded record during Nix evaluation.
The names `edge`, `node`, and `bridge` are chosen by the callback author. Their
available properties depend on the binder kind, not on those names.

| Object or property                   | Type                                                           | Meaning and how to obtain it                                                      |
| ------------------------------------ | -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| `edge`                               | Attribute set with exactly `origin` and `target`               | Supplied to a relation callback by normalization.                                 |
| `edge.origin`                        | Symbolic node expression                                       | The relation owner, such as `F1a` for its Parent `R`.                             |
| `edge.target`                        | Symbolic node expression                                       | The declared endpoint, such as `F2` for that `R`.                                 |
| `node` or `bridge`                   | Attribute set with exactly `parents` and `children`            | Supplied to the callback inside `record`.                                         |
| `node.parents` or `bridge.parents`   | Function from role-name string to symbolic relation collection | Call it with the reference key for an owned Parent role.                          |
| `node.parents "H"`                   | Symbolic collection of owned Parent relations                  | For `F1a`, contains its Parent `H` targeting `F1`.                                |
| `bridge.parents "P"`                 | Symbolic collection of owned Parent relations                  | For `M`, contains its authored Parent endpoints with role `P`.                    |
| `node.children` or `bridge.children` | Function from role-name string to symbolic relation collection | Call it with the reference key for an owned Child role.                           |
| `bridge.children "Q"`                | Symbolic collection of owned Child relations                   | For `M`, contains its authored Child endpoints with role `Q`.                     |
| `only COLLECTION`                    | Symbolic sole-relation expression with a `target` accessor     | Requires one member before an endpoint can be used.                               |
| `(only COLLECTION).target`           | Symbolic node expression                                       | The selected relation's declared target, regardless of Parent or Child direction. |

These are all the author-facing properties these binders expose. There is no
`node.FLAG`, `edge.role`, `bridge.origin`, or `bridge.UID` accessor in the stub.
`fieldOf foo flag` produces a field reference, so it cannot serve as a missing
field-value getter.

For readers inspecting the Nix values, symbolic expressions also contain `_op`
and `args` implementation attributes. A collection has
`_op = "relationCollection"` and arguments for its binder, native direction, and
role. The sole-relation expression has `_op = "only"`, its collection argument,
and the extra `target` attribute. These are expression-building data, not record
properties that a predicate can query as model facts.

The record collection includes authored relations owned by that record. It does
not collect every graph neighbor. For example, `F2` can have incoming
connectivity from bridge `M` without acquiring a second owned Parent `H`.

A relation callback returning Nix `true` is rejected by normalization. Use a
symbolic predicate such as `isNodeType edge.target foo`. Use `const true` when
you deliberately want a symbolic constant. Do not use Nix Boolean operators as
though these symbolic attribute sets were already Boolean results.

## Walkthroughs

These excerpts follow `examples.nix` in file order. They retain the code
exactly, including indentation. They cover every executable line. The
surrounding catalogue comments are left outside the excerpts because the
scenarios here use the pictured records directly. Each read-aloud item explains
one source line. Closing brackets get their own sentence so that the nesting is
explicit.

### Bring the constructors into scope

The following is `examples.nix`, lines 1–10.

```nix
# field and rel only group constructor imports; all authoring calls are bare.
# No semantic prefix: checks read alongside the fields and relations they govern.
let
  dsl = import ./dsl.nix;
  inherit (dsl) el field rel model normalize check on record;
  inherit (field) required str boolean creationDefault;
  inherit (rel) parent child;
  inherit (dsl) parentOf childOf fieldOf isNodeType atMost exactly only;
  inherit (dsl) forest isForest visibility visible canDescend nativeDag;
  inherit (dsl) input projection preserve;
```

**Read it aloud**

- Line 1: The names `field` and `rel` group imports, while the later calls use
  bare constructor names.
- Line 2: Semantic checks appear beside the fields and relations they govern.
- Line 3: Begin a group of local Nix definitions.
- Line 4: Load the DSL value from the adjacent Nix file.
- Line 5: Bring element, grouping, model, lowering, and check-binding names into
  this scope.
- Line 6: Bring the four field helpers into this scope.
- Line 7: Bring Parent and Child relation constructors into this scope.
- Line 8: Bring references, type predicates, collection counts, and singleton
  selection into this scope.
- Line 9: Bring hierarchy, visibility, traversal, and global cycle helpers into
  this scope.
- Line 10: Bring external-input, comparison-description, and preservation
  helpers into this scope.

This block imports constructors. It does not load `F0` or any other record. Nix
local definitions can refer to other definitions in the same `let`, so `foo` can
refer to `sight` before its textual declaration. The symbolic references let
normalization describe that relationship without traversing a live graph.

**What happens**

| Situation                             | Change                                                                     | Result                                         | Why                                                |
| ------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------- | -------------------------------------------------- |
| F1a and F2 are in the pictured tree.  | Describe a future Parent R from F1a to F2 using the imported constructors. | The proposed rule accepts F1a pointing at F2.  | F2 is a FOO endpoint that F1a may visit.           |
| F1a and F2a are in the pictured tree. | Describe a future Parent R from F1a to F2a using the same constructors.    | The proposed rule rejects F1a pointing at F2a. | The imports do not open the closed boundary at F2. |

### Declare identity and the Boolean flag

The following is `examples.nix`, lines 12–13.

```nix
  uid = required (str "UID");
  flag = creationDefault false (required (boolean "FLAG"));
```

**Read it aloud**

- Line 12: Declare a required string field named UID and keep its declaration in
  `uid`.
- Line 13: Declare a required Boolean field named FLAG with a Boolean false
  creation default and keep its declaration in `flag`.

Read nested calls from the inside out when working out their result.
`boolean "FLAG"` creates the field. `required` adds requiredness.
`creationDefault false` adds default metadata. The unquoted `false` is a Nix
Boolean value. Its eventual native spelling is the string `false`.

The default fills a field only if a newly created record survives the batch and
the field is still absent after explicit operations. It does not repair bad
supplied values. It does not backfill an existing record. The stub records this
policy and literal without applying either to records.

**What happens**

| Situation                                                                   | Change                                                                                       | Result                                                                                 | Why                                                                                  |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| I0 is absent before this creation, while the rest of the tree is unchanged. | Create I0 as FOO with UID I0 and leave FLAG absent at the end of the batch.                  | Accept I0 with one false FLAG value.                                                   | I0 is newly created and survives with final absence, so its default makes it open.   |
| I0 is absent before this creation.                                          | Create I0 with an explicit true FLAG, or explicitly set it to false later in the same batch. | Accept I0 with its final explicit Boolean value.                                       | A present valid FLAG on I0 prevents the creation default from replacing it.          |
| I0 is absent before this creation.                                          | Create I0 with an unknown Boolean spelling, an empty value list, or multiple FLAG values.    | Report an input or type error for I0.                                                  | Invalid supplied data on I0 is not final absence and cannot become false by default. |
| Existing I0 is missing its required FLAG.                                   | Inspect I0 or edit it without supplying a valid FLAG.                                        | Inspection can expose the problem, but the incomplete final I0 cannot pass validation. | An existing I0 is never backfilled by the creation default.                          |
| I0 is absent before this batch.                                             | Create I0 and then delete I0 before the batch finishes.                                      | Accept the otherwise valid final tree without I0.                                      | No surviving new I0 remains to receive a default.                                    |

### Give FOO its hierarchy and visible references

The following is `examples.nix`, lines 16–27.

```nix
  foo = el "FOO" {} {
    fields = [uid flag];
    relations = [
      (parent "H" "H_back" (edge: isNodeType edge.target foo))
      (parent "R" "R_back" (edge: isNodeType edge.target foo))
    ];
    constraints = [
      (check "one-H-parent" (record (node: atMost 1 (node.parents "H"))))
      (on (parentOf foo "R")
        (check "visible-R" (edge: visible sight edge.origin edge.target)))
    ];
  };
```

**Read it aloud**

- Line 16: Declare the element kind FOO with no extra grammar properties.
- Line 17: Give each FOO record the UID and FLAG fields.
- Line 18: Begin the list of relation kinds that FOO may own.
- Line 19: Declare Parent H with reverse label H_back and require each target to
  be FOO.
- Line 20: Declare Parent R with reverse label R_back and require each target to
  be FOO.
- Line 21: End the relation list.
- Line 22: Begin the checks associated with FOO.
- Line 23: For each FOO record, require at most one owned Parent H relation.
- Line 24: Select the Parent R relation declared on FOO for the following check.
- Line 25: For each selected relation, require its target to be visible from its
  owner through `sight`.
- Line 26: End the check list.
- Line 27: Finish the FOO element declaration.

For `F1a Parent R → F2`, `edge.origin` means `F1a` and `edge.target` means `F2`.
Those names keep their authored meaning even though Parent connectivity points
from `F2` toward `F1a`. The visibility walk starts at the authored owner.

`node.parents "H"` counts the Parent H declarations owned by the bound FOO
record. It does not count Parent R. It also does not count incoming bridge
edges. The `record` binder makes the root `F0` visible to the cardinality check
even though `F0` has zero H parents.

**What happens**

| Situation                               | Change                                     | Result                                                    | Why                                                                         |
| --------------------------------------- | ------------------------------------------ | --------------------------------------------------------- | --------------------------------------------------------------------------- |
| F1a owns its pictured H relation to F1. | Add Parent R on F1a targeting closed F2.   | Accept the new F1a relation.                              | F2 has the required element kind and can be visited as an endpoint.         |
| Z0 is the pictured BAZ record.          | Add Parent R on F1a targeting Z0.          | Reject the F1a relation with a wrong-target-kind finding. | Z0 resolves to a record, but its kind is BAZ rather than the required FOO.  |
| F1a already has F1 as its H parent.     | Add a second Parent H on F1a targeting F0. | Reject the extra H relation on F1a.                       | F1a would own two H parents, even though those edges do not create a cycle. |
| F2 is closed and F2a is open.           | Add Parent R on F1a targeting F2a.         | Reject the F1a relation at F2.                            | Reaching F2a requires expanding F2 from an origin outside its subtree.      |
| F0 has no H parent.                     | Validate F0 without adding any H relation. | Accept the root F0 under the H-parent count rule.         | The empty H collection on F0 has count zero, which is at most one.          |

### Give BAR two endpoints and a path rule

The following is `examples.nix`, lines 30–44.

```nix
  bar = el "BAR" {} {
    fields = [uid];
    relations = [
      (parent "P" "P_back" (edge: isNodeType edge.target foo))
      (child "Q" "Q_back" (edge: isNodeType edge.target foo))
    ];
    constraints = [
      (check "one-P" (record (bridge: exactly 1 (bridge.parents "P"))))
      (check "one-Q" (record (bridge: exactly 1 (bridge.children "Q"))))
      (check "endpoint-path" (record (bridge:
        canDescend sight
        (only (bridge.parents "P")).target
        (only (bridge.children "Q")).target)))
    ];
  };
```

**Read it aloud**

- Line 30: Declare the element kind BAR with no extra grammar properties.
- Line 31: Give each BAR record its required UID field.
- Line 32: Begin the relation kinds that BAR may own.
- Line 33: Declare Parent P and require its declared target to be FOO.
- Line 34: Declare Child Q and require its declared target to be FOO.
- Line 35: End the relation list.
- Line 36: Begin the checks associated with BAR.
- Line 37: For each bridge record, require exactly one owned Parent P relation.
- Line 38: For each bridge record, require exactly one owned Child Q relation.
- Line 39: Start a record check named endpoint-path with the bound record
  locally called `bridge`.
- Line 40: Ask whether the next two endpoints have a permitted downward path
  through `sight`.
- Line 41: Use the target of the bridge’s sole Parent P as the path origin.
- Line 42: Use the target of its sole Child Q as the path target and close the
  nested check expressions.
- Line 43: End the check list.
- Line 44: Finish the BAR element declaration.

A collection contains relation occurrences, not just endpoint nodes. `only`
selects one relation before `.target` extracts its endpoint. For `M` with P
targeting `F0` and Q targeting `F2`, those extracted endpoints are `F0` and
`F2`. The path origin is therefore `F0`, even though `M` owns both declarations.

The two count checks state the prerequisites for using the two singletons. Their
position makes those prerequisites readable. The stub does not implement a
runtime scheduler that enforces an evaluation order.

**What happens**

| Situation                       | Change                                                                 | Result                                                                   | Why                                                                   |
| ------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| M is absent from the base tree. | Create M with Parent P to F0 and Child Q to F2 in one final candidate. | Accept M and both owned declarations.                                    | F0 can descend to the closed endpoint F2 without expanding it.        |
| M is absent from the base tree. | Finish creating M with Parent P to F0 but no Child Q.                  | Reject M for having zero Q relations, and block its endpoint-path check. | M has no sole Q target for the path check to inspect.                 |
| M is absent from the base tree. | Give M Parent P to F0 and two Child Q relations, targeting F1 and F2.  | Reject M for having two Q relations, and block its endpoint-path check.  | The two possible Q targets do not provide a unique endpoint for M.    |
| F2 is closed in the base tree.  | Create M with Parent P to F0 and Child Q to F2a.                       | Reject M with F2 as the blocking boundary.                               | The downward path from F0 to F2a must expand closed F2.               |
| F2 is closed in the base tree.  | Create M with Parent P to F2 and Child Q to F2a.                       | Accept M from closed F2 to F2a.                                          | The original endpoint F2 is inside its own subtree, so it may expand. |

### Reuse role names without copying their rules

The following is `examples.nix`, lines 47–54.

```nix
  baz = el "BAZ" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back")
      (child "Q" "Q_back")
    ];
    constraints = [];
  };
```

**Read it aloud**

- Line 47: Declare the element kind BAZ with no extra grammar properties.
- Line 48: Give each BAZ record its required UID field.
- Line 49: Begin the relation kinds that BAZ may own.
- Line 50: Declare Parent R with no inline semantic check.
- Line 51: Declare Child Q with no inline semantic check.
- Line 52: End the relation list.
- Line 53: Declare no element-specific constraints for BAZ.
- Line 54: Finish the BAZ element declaration.

The identity of a selected relation includes its owner element and native
direction. So FOO Parent R and BAZ Parent R are different selections. BAZ still
belongs to the native graph, so its unrestricted endpoint policy cannot excuse a
cycle. BAZ relations also remain subject to endpoint resolution and any
applicable baseline preservation.

**What happens**

| Situation                                             | Change                                                   | Result                                           | Why                                                                         |
| ----------------------------------------------------- | -------------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------- |
| Z0 is outside the H forest and I0 is an isolated FOO. | Give Z0 Parent R targeting I0.                           | Accept the Z0 relation.                          | The FOO visibility rule does not apply to BAZ-owned Parent R.               |
| F0 and G1 lie in different H trees.                   | Give Z0 Parent R targeting F0 and Child Q targeting G1.  | Accept the native path from F0 through Z0 to G1. | Z0 has no BAR downward-path rule, and these edges do not join the H forest. |
| F1a descends from F1 in the H tree.                   | Give Z0 Parent R targeting F1a and Child Q targeting F1. | Reject the combined graph through Z0.            | The edges form the directed cycle F1 to F1a to Z0 to F1.                    |

### Select the hierarchy and define visibility

The following is `examples.nix`, lines 57–63.

```nix
  h = forest "H" (parentOf foo "H");
  sight = visibility "H-visibility" h {
    closedWhenTrue = fieldOf foo flag;
    ascent = "unrestricted";
    visit = "always";
    expand = "open-or-origin-in-subtree-including-self";
  };
```

**Read it aloud**

- Line 57: Name a forest view H using only the Parent H relations declared on
  FOO.
- Line 58: Name a visibility view H-visibility over that forest.
- Line 59: Read FOO’s FLAG field as the Boolean that makes a node closed when
  true.
- Line 60: Allow every upward hierarchy step regardless of closed flags.
- Line 61: Allow reaching a node itself even when that node is closed.
- Line 62: Allow a downward step out of a node when it is open or contains the
  original origin in its subtree including itself.
- Line 63: Finish the visibility configuration.

The variable `h` holds a hierarchy declaration. The variable `sight` holds a
visibility declaration using it. The view name `"H"` is a chosen label. The role
key `"H"` in `parentOf foo "H"` refers to the earlier relation declaration.
Their identical spelling does not make them the same kind of argument.

Only the three string policies shown here have specified meanings in this
reference profile. The stub copies their values without validating an enum. The
hand-executable algorithm in the next section gives those values their precise
operational meaning.

**What happens**

| Situation                                                      | Change                                                  | Result                                                         | Why                                                                                    |
| -------------------------------------------------------------- | ------------------------------------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| F2a and F2b are both below closed F2.                          | Add Parent R on F2a targeting F2b.                      | Accept the F2a relation.                                       | The original origin F2a is already inside F2, so descent toward F2b is permitted.      |
| F2a is below closed F2, while F1a is in the other branch.      | Add Parent R on F2a targeting F1a.                      | Accept the F2a relation.                                       | Ascent through F2 is unrestricted, and the downward branch toward F1a is open.         |
| F1a and G1 have roots F0 and G0.                               | Add Parent R on F1a targeting G1.                       | Reject the F1a relation for distinct roots.                    | F0 and G0 have no connecting H path.                                                   |
| F2 has first been opened, and F1a already points its R at F2a. | Close F2 while leaving that F1a relation unchanged.     | Reject closing F2, leaving it open.                            | The complete candidate would hide F2a from the existing origin F1a.                    |
| F2 has first been opened, and F1a already points its R at F2a. | Close F2 and remove the F1a relation in the same batch. | Accept the final tree with closed F2 and no such F1a relation. | The final candidate contains no remaining reference through the newly closed boundary. |

### Declare the required external snapshot

The following is `examples.nix`, lines 66–70.

```nix
  baseline = input "baseline" {
    kind = "external-snapshot";
    required = true;
    complete = true;
  };
```

**Read it aloud**

- Line 66: Declare an input named baseline.
- Line 67: Describe its input kind as an external snapshot.
- Line 68: Require this input to be acquired successfully.
- Line 69: Require the acquired snapshot to be complete.
- Line 70: Finish the input declaration.

This declares an input requirement. It supplies no executable, command-line
arguments, wire format, or acquisition code. The runtime contract requires one
identified immutable snapshot to be captured for an evaluation. All checks in
that evaluation must use that captured snapshot. A concurrent source change can
affect the next evaluation. It cannot silently change the snapshot halfway
through this one.

**What happens**

| Situation                                                | Change                                                                                                                     | Result                                           | Why                                                                               |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------- |
| The acquired complete baseline lists I0 with FLAG false. | Propose changing I0 to FLAG true.                                                                                          | Reject the change to I0 under preservation.      | The captured baseline protects I0’s modeled FLAG value.                           |
| The acquired complete baseline lists no records.         | Propose changing I0 to FLAG true.                                                                                          | Accept the otherwise valid change to I0.         | Successful empty input protects no record, including I0.                          |
| The baseline source is needed before changing I0.        | Attempt that change while acquisition times out, exits unsuccessfully, returns malformed data, or returns incomplete data. | Report an execution error and keep I0 unchanged. | An acquisition failure supplies no usable protection decision for I0.             |
| The captured baseline protects I0 with FLAG false.       | Let the source become empty during evaluation of a proposed change of I0 to true.                                          | Reject the I0 change in this evaluation.         | The already captured snapshot continues to protect I0 until this evaluation ends. |

### Describe exactly what preservation compares

The following is `examples.nix`, lines 71–87.

```nix
  modeledRecord = projection "modeled-record" {
    key = "UID";
    existence = true;
    element = true;
    fields = [(fieldOf foo flag)];
    fieldPresence = true;
    ownedRelations = [
      (parentOf foo "H")
      (parentOf foo "R")
      (parentOf bar "P")
      (childOf bar "Q")
      (parentOf baz "R")
      (childOf baz "Q")
    ];
    relationProjection = ["nativeType" "role" "target"];
    relationOrder = "set";
  };
```

**Read it aloud**

- Line 71: Declare a projection named modeled-record.
- Line 72: Match baseline and candidate records by the field key UID.
- Line 73: Preserve the existence of every listed record.
- Line 74: Preserve each listed record’s element kind.
- Line 75: Include FOO’s FLAG field among the compared fields.
- Line 76: Compare whether that selected field is present as well as its value.
- Line 77: Begin the list of owned relation kinds included in the comparison.
- Line 78: Include FOO’s Parent H declarations.
- Line 79: Include FOO’s Parent R declarations.
- Line 80: Include BAR’s Parent P declarations.
- Line 81: Include BAR’s Child Q declarations.
- Line 82: Include BAZ’s Parent R declarations.
- Line 83: Include BAZ’s Child Q declarations.
- Line 84: End the owned-relation selection.
- Line 85: Compare each selected relation by its native direction, role name,
  and target identity.
- Line 86: Compare those relation descriptions as sets so their order does not
  matter.
- Line 87: Finish the projection declaration.

A **projection** is a description of the facts to extract before comparing two
records. It is not a graph traversal. Here `key = "UID"` identifies records
across the two snapshots. `existence = true` prevents a listed UID from
disappearing. `element = true` prevents its record kind from changing.
`fieldPresence = true` keeps absent FLAG distinct from a present FLAG value.

`ownedRelations` lists the relation declarations whose occurrences are part of
the owner's protected record. `nativeType` distinguishes Parent from Child.
`role` distinguishes names such as H and R. `target` identifies the endpoint
record. `relationOrder = "set"` removes declaration-order significance from this
comparison. It does not define how duplicate declarations are counted by
separate cardinality checks.

The projection excludes document location, reverse display labels, and runtime
bookkeeping fields. It also excludes incoming declarations owned by other
records. A protection rule does not automatically freeze everything connected to
the protected node.

**What happens**

| Situation                                                                                 | Change                                                                                         | Result                                       | Why                                                                                                  |
| ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| The complete baseline protects the pictured I0.                                           | Delete I0.                                                                                     | Reject deleting I0.                          | The projection preserves existence for the listed UID I0.                                            |
| The complete baseline protects F1a with its Parent H targeting F1.                        | Replace F1a’s H parent with F0.                                                                | Reject the change to F1a.                    | The owned H declaration is part of F1a’s preserved record even though the new hierarchy is a forest. |
| The complete baseline protects I0 with FLAG false.                                        | Give Z0 Parent R targeting I0 while leaving I0’s own facts unchanged.                          | Accept the added Z0 relation.                | The new incoming connectivity belongs to Z0 rather than to the protected record I0.                  |
| F1a validly owns H targeting F1 and R targeting F2, and its complete record is protected. | Reorder those declarations or move F1a to another document without changing its modeled facts. | Accept the unchanged modeled record for F1a. | Relation ordering and document location are excluded from the protected facts for F1a.               |

### Add checks for the entire model

The following is `examples.nix`, lines 89–94.

```nix
  # The all-role DAG is independent of the selected forest and visibility.
  rules = [
    (check "native-dag" nativeDag)
    (check "H-forest" (isForest h))
    (check "baseline-preserved" (preserve baseline modeledRecord))
  ];
```

**Read it aloud**

- Line 89: Check the native graph independently of the selected hierarchy and
  visibility.
- Line 90: Begin the list of whole-model checks.
- Line 91: Require the combined native Parent and Child graph to have no
  directed cycle.
- Line 92: Require the selected H graph to be a forest.
- Line 93: Require baseline-listed records to match the modeled-record
  projection.
- Line 94: End the whole-model check list.

These rules are placed on the model, so they see more than the record being
edited. `isForest h` allows the roots `F0`, `G0`, and `I0` to coexist.
`nativeDag` also considers relations through `Z0` and `M`. A predicate can
permit a path while the separate cycle rule rejects the resulting native graph.

**What happens**

| Situation                                          | Change                                                     | Result                                           | Why                                                                                                     |
| -------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| The tree has separate roots F0, G0, and I0.        | Validate the pictured hierarchy without joining the roots. | Accept the forest containing F0, G0, and I0.     | A forest does not require the three roots to be connected.                                              |
| F1a is below F1, which is below F0.                | Give F0 a Parent H targeting F1a.                          | Reject the graph containing F0, F1, and F1a.     | It would contain the directed cycle F0 to F1 to F1a to F0.                                              |
| F2 is a closed FOO record.                         | Create M with both its P and Q targeting F2.               | Reject M because of the native cycle through F2. | Even though a zero-length traversal is conceptually allowed, native connectivity becomes F2 to M to F2. |
| The complete baseline protects I0 with FLAG false. | Set I0’s FLAG to true.                                     | Reject the changed I0 under baseline-preserved.  | The native graph and forest can remain valid while I0’s protected field changes.                        |

### Assemble and lower the declarations

The following is `examples.nix`, lines 95–102.

```nix
in
  normalize (model "reference" {
    elements = [foo bar baz];
    views = [h sight];
    inputs = [baseline];
    projections = [modeledRecord];
    constraints = rules;
  })
```

**Read it aloud**

- Line 95: Finish the local definitions and return the following expression.
- Line 96: Construct the model named reference and normalize it.
- Line 97: Register the FOO, BAR, and BAZ element declarations.
- Line 98: Register the hierarchy and visibility views.
- Line 99: Register the required baseline input declaration.
- Line 100: Register the modeled-record projection declaration.
- Line 101: Install the whole-model checks defined in `rules`.
- Line 102: Finish the model and normalization expressions.

Merely assigning `sight` in a `let` does not register it in the model. The
`views` list does that. The corresponding lists register the other declarations
referenced by rules. Normalization reports undeclared references it encounters.

The returned `grammar` contains ordinary native element declarations.
`semanticTypes` contains field type and default metadata. `bundle` contains
declaration identities, views, inputs, projections, and symbolic rules.
Returning those values does not acquire the baseline or validate the pictured
records.

**What happens**

| Situation                                                            | Change                                            | Result                                   | Why                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------- | ---------------------------------------------------------------------------------------- |
| F0, F2, and a new M are evaluated under the complete declared model. | Create M with P targeting F0 and Q targeting F2.  | Accept the final candidate containing M. | M satisfies its endpoint counts and path rule, and the combined graph stays acyclic.     |
| F0, F2a, and a new M are evaluated under the same model.             | Create M with P targeting F0 and Q targeting F2a. | Reject the final candidate containing M. | Registering all the declarations does not remove the closed intermediate boundary at F2. |

## How visibility works

Use this procedure for `visible sight ORIGIN TARGET`. Keep the original origin
written down throughout the walk. Do not replace it with the most recently
visited node.

1. Resolve the origin and target to FOO records in the selected `H` forest. A
   missing endpoint is an input problem, not proof that a valid target is
   hidden. The hierarchy must be a usable forest, and any FLAG values needed by
   the walk must be valid Booleans. The stub does not implement prerequisite
   handling for these conditions.
2. Follow each endpoint's H parents to find its root. If the roots differ,
   reject the visibility question because no selected path connects them. For
   example, `F1a` reaches `F0`, while `G1` reaches `G0`.
3. Write the unique hierarchy path from origin to target. It goes up to their
   nearest shared ancestor and then down to the target. For `F1a` and `F2a`,
   write `F1a → F1 → F0 → F2 → F2a`. Relations with roles other than H cannot
   shorten or replace this path.
4. Visit the current node, starting with the origin. If it is the target, accept
   the visibility question immediately. This includes reaching a closed target
   and the conceptual case where origin and target are equal.
5. If the next path step goes upward to an H parent, take that step and return
   to step 4. Upward movement ignores closed boundaries because ascent is
   unrestricted.
6. If the next step goes downward to an H child, test whether you may expand the
   current node. An open current node may always expand. A closed current node
   may expand only if the original origin is in its H subtree, counting that
   closed node itself as part of the subtree.
7. If expansion is allowed, take the downward step and return to step 4. If
   expansion is forbidden, reject and identify this closed node as the boundary.
   The unvisited endpoint's open flag cannot remove an earlier closed boundary.

**Visit** means reach the node itself. **Expand** means take a downward step
from that node to one of its H children. Those are separate actions, which is
why a closed endpoint can be visible while its children are hidden.

For `canDescend`, use the same visit and expansion tests with an additional
restriction. The whole path must go downward from its starting endpoint. If
reaching the target would require any upward step, reject the downward-path
question. This makes `F1` to `F2` unsuitable for a bridge even though an R
visibility walk could go up through `F0`.

### Walk from F1a to F2: accept

Propose a Parent R owned by `F1a` targeting `F2`. Both endpoints have root `F0`.
The original origin stays `F1a`.

| Current node | Next action                                  | Reason                                                                   |
| ------------ | -------------------------------------------- | ------------------------------------------------------------------------ |
| F1a          | Visit F1a, then ascend to F1.                | F1a is not the target, and upward steps are unrestricted.                |
| F1           | Visit F1, then ascend to F0.                 | F1 is not the target, and the next step is still upward.                 |
| F0           | Visit F0, then descend to F2.                | F0 is open, so it may expand into its F2 branch.                         |
| F2           | Visit F2 and accept the visibility question. | F2 is the target, so its closed flag does not require an expansion test. |

The native graph also remains acyclic when this relation is added. So the
complete proposed relation can be accepted under the stated empty-baseline
assumption.

### Walk from F1a to F2a: reject

Propose a Parent R owned by `F1a` targeting `F2a`. Both endpoints again have
root `F0`. The original origin again stays `F1a`.

| Current node | Next action                                          | Reason                                                                                    |
| ------------ | ---------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| F1a          | Visit F1a, then ascend to F1.                        | Upward movement is permitted.                                                             |
| F1           | Visit F1, then ascend to F0.                         | Upward movement is still permitted.                                                       |
| F0           | Visit F0, then descend to F2.                        | Open F0 may expand into its F2 branch.                                                    |
| F2           | Visit F2, then reject before taking the step to F2a. | F2 is closed, and original origin F1a is outside the subtree containing F2, F2a, and F2b. |
| F2a          | Do not visit F2a.                                    | The previous expansion was refused at F2, even though F2a itself is open.                 |

This proposed relation would not create a native cycle. Its rejection therefore
demonstrates the visibility boundary independently of the cycle rule.

### The four configuration knobs

The following are the complete choices whose meanings this reference contract
specifies. They are not string enums enforced by the Nix stub. For string-valued
policy slots, the stub will also lower other strings without checking their
meaning. That behavior does not make those other strings supported traversal
policies.

| Knob             | Accepted value under the specified contract                                                                  | What it changes in the numbered steps                                                                                       |
| ---------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `closedWhenTrue` | A reference to the selected nodes' semantic Boolean field, here `fieldOf foo flag`; there is no string enum. | Step 6 reads this field: false means open, and true means closed.                                                           |
| `ascent`         | Complete specified keyword set: `"unrestricted"`.                                                            | Step 5 permits every upward H step regardless of the current or parent node's closed flag.                                  |
| `visit`          | Complete specified keyword set: `"always"`.                                                                  | Step 4 permits visiting a reached node, so reaching a closed target can succeed without expanding it.                       |
| `expand`         | Complete specified keyword set: `"open-or-origin-in-subtree-including-self"`.                                | Step 6 permits downward expansion when the current node is open or the original origin is in its subtree, including itself. |

The stub verifies the identity of the `closedWhenTrue` field reference when
lowering it. It does not verify that the referenced field is Boolean or that it
belongs to the selected hierarchy's node kind. The constructor also fixes
shared-root checking, unique-hierarchy paths, and conceptual zero-length
reachability in its emitted configuration. Those three settings are not
additional policy knobs in the accepted call.

For `F2a` targeting `F2b`, the original origin lies inside `F2`. So reaching
closed `F2` on ascent does not prevent subsequent descent to `F2b`. Deleting
every outgoing edge of every closed node would give the wrong answer for this
example.

A successful visibility question is only one part of total validity. Giving `F2`
a Parent R targeting itself still creates a native self-cycle. Giving `F2` a
Parent R targeting its H child `F2a` creates the cycle `F2 → F2a → F2`. Neither
is an overall acceptance example for zero-length or closed-origin traversal.

## How the bridge check works

`record` binds one BAR record at a time. In the example callback, `bridge`
therefore stands for `M`. The two methods describe collections of declarations
owned by that same record. A **collection** is a group of matching relation
occurrences available for counting and selection. It is empty when the record
owns no matching declarations. It is represented symbolically during Nix
evaluation. The stub does not define storage-level treatment of duplicate
identical occurrences.

For a bridge with P targeting `F0` and Q targeting `F2`, the conceptual contents
are:

```text
bridge means M

bridge.parents "P"
└── one declaration: owner M, direction Parent, role P, target F0

bridge.children "Q"
└── one declaration: owner M, direction Child, role Q, target F2
```

`exactly 1` must establish the count before `only` can yield a usable endpoint.
If there is no Q, the Q count is zero and `one-Q` fails. The endpoint-path check
is then blocked because there is no Q endpoint to inspect. If there are two Q
declarations, the count is two and `one-Q` again fails. The endpoint-path check
is blocked because there is no unique Q endpoint. `only` does not pick an
arbitrary member or add a second false path verdict.

“Before” here is a logical dependency. The two count checks appear before the
path check in the authored list. The stub does not generate a prerequisite link
from the path check to those named checks. It also does not implement a runtime
evaluation schedule. The specified runtime must respect the singleton
requirement without relying on Nix list order as an execution mechanism.

Once a collection has exactly one member, `only` denotes that relation
occurrence. Its `.target` denotes the record named by the authored declaration.
For Parent P targeting `F0`, `.target` is `F0` even though the native
connectivity runs from `F0` to `M`. For Child Q targeting `F2`, `.target` is
`F2` and connectivity runs from `M` to `F2`.

`canDescend` computes whether those two endpoint nodes are connected by an
entirely downward H path that obeys the expansion rule. It does not walk through
the BAR record. It does not use the bridge's native edges as substitute H edges.
It does not search another role for a way around a closed boundary.

Trace a new `M` whose P targets closed `F2` and whose Q targets open `F2a`:

1. Bind `bridge` to `M`.
2. Count M's Parent P declarations and obtain one.
3. Count M's Child Q declarations and obtain one.
4. Select the sole P relation and read its target as `F2`.
5. Select the sole Q relation and read its target as `F2a`.
6. Confirm that both targets are FOO records in the H tree rooted at `F0`.
7. Write the downward H path `F2 → F2a`.
8. Visit `F2`, which is closed and is not yet the target.
9. Permit expansion because the original origin is `F2` itself, which belongs to
   its own subtree.
10. Visit `F2a` and accept the downward-path predicate.
11. Check the remaining rules, including the native graph containing
    `F2 → M → F2a`, which has no cycle.

Under the complete empty baseline, this final bridge is accepted. Creating M
before its two relations within one ordered batch does not make its private
incomplete intermediate state the validation target. Finishing the batch without
Q does make the final candidate invalid.

## Strings, keywords, names

The table below inventories every string literal occurrence in both accepted
example files. Line numbers refer to the source files, not to this README.
Repeated occurrences with the same meaning share a row. A **free name** is
chosen by the author. A **reference key** repeats a declared name or selects a
named field in an input record. A **fixed keyword** has a meaning specified by
the contract for that configuration slot.

The distinction is contextual. For example, the first `"H"` on `examples.nix`
line 57 names a new view. The second `"H"` on that same line selects the Parent
H relation already declared on FOO.

No string-valued policy enum in these two files is validated by the accepted
stub. Its `input`, `projection`, and `visibility` constructors retain their
configuration values. For the policy slots, its actual string acceptance is any
Nix string, including an unrecognized one. The table gives the full _specified_
value sets so that acceptance by lowering is not mistaken for defined runtime
meaning. For references, normalization checks declared identities created by the
reference constructors. It does not validate the UID projection key or role
strings passed to binder collections against declarations.

| String literal                               | Classification                              | Meaning or complete specified value set                                                                                                                                              | Source lines                                                                                                              |
| -------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `"UID"`                                      | Free name                                   | Names the required string field used to address records.                                                                                                                             | `examples.nix:12`, `composition.nix:8`                                                                                    |
| `"FLAG"`                                     | Free name                                   | Names the Boolean field used by the visibility policy.                                                                                                                               | `examples.nix:13`                                                                                                         |
| `"FOO"`                                      | Free name                                   | Names the element kind used for the H forest.                                                                                                                                        | `examples.nix:16`, `composition.nix:10`, `composition.nix:18`                                                             |
| `"H"`                                        | Free name                                   | Names a Parent relation role on FOO.                                                                                                                                                 | `examples.nix:19`                                                                                                         |
| `"H_back"`                                   | Free name                                   | Names the reverse display label for Parent H.                                                                                                                                        | `examples.nix:19`                                                                                                         |
| `"R"`                                        | Free name                                   | Names a Parent relation role on its declaring element.                                                                                                                               | `examples.nix:20`, `examples.nix:50`, `composition.nix:13`, `composition.nix:21`                                          |
| `"R_back"`                                   | Free name                                   | Names the reverse display label for Parent R.                                                                                                                                        | `examples.nix:20`, `examples.nix:50`, `composition.nix:13`, `composition.nix:21`                                          |
| `"one-H-parent"`                             | Free name                                   | Names the check that limits each FOO to one H parent.                                                                                                                                | `examples.nix:23`                                                                                                         |
| `"H"`                                        | Reference key                               | Selects the already named H role in the owner and direction supplied by the selector or collection method.                                                                           | `examples.nix:23`, `examples.nix:57` (second literal), `examples.nix:78`                                                  |
| `"R"`                                        | Reference key                               | Selects the already named R role in the owner and direction supplied by the selector or collection method.                                                                           | `examples.nix:24`, `examples.nix:79`, `examples.nix:82`, `composition.nix:23`, `composition.nix:31`, `composition.nix:43` |
| `"visible-R"`                                | Free name                                   | Names the check that requires visibility for FOO Parent R.                                                                                                                           | `examples.nix:25`                                                                                                         |
| `"BAR"`                                      | Free name                                   | Names the bridge element kind.                                                                                                                                                       | `examples.nix:30`                                                                                                         |
| `"P"`                                        | Free name                                   | Names a Parent relation role on BAR.                                                                                                                                                 | `examples.nix:33`                                                                                                         |
| `"P_back"`                                   | Free name                                   | Names the reverse display label for Parent P.                                                                                                                                        | `examples.nix:33`                                                                                                         |
| `"Q"`                                        | Free name                                   | Names a Child relation role on its declaring element.                                                                                                                                | `examples.nix:34`, `examples.nix:51`                                                                                      |
| `"Q_back"`                                   | Free name                                   | Names the reverse display label for Child Q.                                                                                                                                         | `examples.nix:34`, `examples.nix:51`                                                                                      |
| `"one-P"`                                    | Free name                                   | Names the check requiring one P on each BAR.                                                                                                                                         | `examples.nix:37`                                                                                                         |
| `"P"`                                        | Reference key                               | Selects the already named P role in the owner and direction supplied by the selector or collection method.                                                                           | `examples.nix:37`, `examples.nix:41`, `examples.nix:80`                                                                   |
| `"one-Q"`                                    | Free name                                   | Names the check requiring one Q on each BAR.                                                                                                                                         | `examples.nix:38`                                                                                                         |
| `"Q"`                                        | Reference key                               | Selects the already named Q role in the owner and direction supplied by the selector or collection method.                                                                           | `examples.nix:38`, `examples.nix:42`, `examples.nix:81`, `examples.nix:83`                                                |
| `"endpoint-path"`                            | Free name                                   | Names the check requiring a permitted downward path between BAR endpoints.                                                                                                           | `examples.nix:39`                                                                                                         |
| `"BAZ"`                                      | Free name                                   | Names the element kind with independently scoped R and Q roles.                                                                                                                      | `examples.nix:47`                                                                                                         |
| `"H"`                                        | Free name                                   | Names the forest view; sharing the role name H is optional.                                                                                                                          | `examples.nix:57` (first literal)                                                                                         |
| `"H-visibility"`                             | Free name                                   | Names the visibility view, which is later referenced through the variable sight.                                                                                                     | `examples.nix:58`                                                                                                         |
| `"unrestricted"`                             | Fixed keyword (contract; unchecked by stub) | Full specified set for ascent: `"unrestricted"`, permitting every upward H step.                                                                                                     | `examples.nix:60`                                                                                                         |
| `"always"`                                   | Fixed keyword (contract; unchecked by stub) | Full specified set for visit: `"always"`, permitting arrival at closed nodes.                                                                                                        | `examples.nix:61`                                                                                                         |
| `"open-or-origin-in-subtree-including-self"` | Fixed keyword (contract; unchecked by stub) | Full specified set for expand: `"open-or-origin-in-subtree-including-self"`, permitting expansion of an open node or a closed node containing the original origin, including itself. | `examples.nix:62`                                                                                                         |
| `"baseline"`                                 | Free name                                   | Names the external input, which is later referenced through the variable baseline.                                                                                                   | `examples.nix:66`                                                                                                         |
| `"external-snapshot"`                        | Fixed keyword (contract; unchecked by stub) | Full specified set for input kind: `"external-snapshot"`, an acquired complete external snapshot in this profile.                                                                    | `examples.nix:67`                                                                                                         |
| `"modeled-record"`                           | Free name                                   | Names the comparison projection.                                                                                                                                                     | `examples.nix:71`                                                                                                         |
| `"UID"`                                      | Reference key                               | Selects the record identity field for baseline matching; this plain key is not declaration-validated by the stub.                                                                    | `examples.nix:72`                                                                                                         |
| `"nativeType"`                               | Fixed keyword (contract; unchecked by stub) | Full specified relation-component set: `"nativeType"`, `"role"`, `"target"`; nativeType preserves Parent versus Child.                                                               | `examples.nix:85`                                                                                                         |
| `"role"`                                     | Fixed keyword (contract; unchecked by stub) | Full specified relation-component set: `"nativeType"`, `"role"`, `"target"`; role preserves the authored role name.                                                                  | `examples.nix:85`                                                                                                         |
| `"target"`                                   | Fixed keyword (contract; unchecked by stub) | Full specified relation-component set: `"nativeType"`, `"role"`, `"target"`; target preserves the declared endpoint identity.                                                        | `examples.nix:85`                                                                                                         |
| `"set"`                                      | Fixed keyword (contract; unchecked by stub) | Full specified set for relationOrder: `"set"`, ignoring relation declaration order during comparison.                                                                                | `examples.nix:86`                                                                                                         |
| `"native-dag"`                               | Free name                                   | Names the whole-model native cycle check.                                                                                                                                            | `examples.nix:91`                                                                                                         |
| `"H-forest"`                                 | Free name                                   | Names the whole-model selected-forest check.                                                                                                                                         | `examples.nix:92`                                                                                                         |
| `"baseline-preserved"`                       | Free name                                   | Names the whole-model preservation check.                                                                                                                                            | `examples.nix:93`                                                                                                         |
| `"reference"`                                | Free name                                   | Names the model and therefore its declaration namespace.                                                                                                                             | `examples.nix:96`                                                                                                         |
| `"target-type"`                              | Free name                                   | Names the same check identity within the selected relation; repeating it does not authorize replacement.                                                                             | `composition.nix:9`, `composition.nix:13`, `composition.nix:44`                                                           |
| `"composition"`                              | Free name                                   | Names the separate model used to demonstrate rule composition.                                                                                                                       | `composition.nix:25`                                                                                                      |
| `"extra-target-check"`                       | Free name                                   | Names the contribution that repeats the equivalent target check.                                                                                                                     | `composition.nix:31`                                                                                                      |
| `"incompatible-target-check"`                | Free name                                   | Names the contribution that conflicts with the existing target check.                                                                                                                | `composition.nix:43`                                                                                                      |

For `relationProjection`, the contract uses all three components together. It
does not specify the meaning of arbitrary subsets or additional component names.
For configuration Boolean switches such as `existence`, the example supplies
`true`. The stub will retain `false` too, but these source contracts do not
provide an alternate-profile specification for every switch being disabled.

The unquoted tokens `true` and `false` are Nix Boolean literals, so they are not
rows in the string-literal inventory. The attribute names `fields`,
`constraints`, `closedWhenTrue`, and `relationOrder` are not quoted strings in
these files either. The names `foo`, `h`, `sight`, and `baseline` used as
arguments are Nix variables holding declared values. Writing a quoted version of
one of those variable names would not obtain its reference.

## What is real

**Lowered** means converted from the Nix authoring interface into ordinary data
that a later system could read. For a predicate, that data is an operator name
and its operands. For a callback, normalization calls it with symbolic binders
to obtain that data. It never calls it with `F1a`, `F2`, or any other loaded
record.

The stub returns three pieces:

- `grammar` contains native element, field, and relation declarations with
  semantic annotations removed.
- `semanticTypes` contains field types, Boolean codecs, defaults, a schema
  identifier, and a digest of the recorded field metadata.
- `bundle` contains the semantic declaration identities, named rules,
  references, configurations, input dependencies, and rule origins.

No backend runs. No baseline is acquired. No graph traversal, record defaulting,
candidate publication, or recovery runs. The accepted stub imports the native
grammar implementation from outside this review directory. That import was not
followed or reevaluated for this document because this read is restricted to
this directory. The local native-style source and the accepted wrapper describe
the grammar construction used here.

In the table, “lowered by the stub AND semantics specified” means the
construct's authoring or normalization operation is concrete in the stub. It
does not claim that record validation executes. “Lowered by the stub, semantics
specified only in prose” means the stub emits the operation or configuration,
while the behavior on records remains a prose contract.

| Construct                                              | Status                                                 | Concrete boundary                                                                                                 |
| ------------------------------------------------------ | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| `el`                                                   | lowered by the stub AND semantics specified            | Wraps the native element declaration and retains constraints for later lowering.                                  |
| `model`                                                | lowered by the stub AND semantics specified            | Supplies declaration-list defaults and the model identity.                                                        |
| `normalize`                                            | lowered by the stub AND semantics specified            | Builds grammar, metadata, and rule data with the authoring checks described below.                                |
| `check`                                                | lowered by the stub AND semantics specified            | Retains the check name and lowers its symbolic expression in the supplied scope.                                  |
| `on`                                                   | lowered by the stub AND semantics specified            | Changes the check subject and scope to the selected relation.                                                     |
| `record`                                               | lowered by the stub AND semantics specified            | Creates a named symbolic record binder and lowers the callback body.                                              |
| `required`                                             | lowered by the stub AND semantics specified            | Sets native requiredness and preserves semantic metadata; this stub does not validate records.                    |
| `str`                                                  | lowered by the stub AND semantics specified            | Delegates native string-field construction; no record values are read.                                            |
| `boolean`                                              | lowered by the stub AND semantics specified            | Emits the two native choices and their Boolean codec metadata; no runtime decoding occurs.                        |
| `creationDefault`                                      | lowered by the stub AND semantics specified            | Checks Boolean literal compatibility and records the default; applying it at final absence remains unimplemented. |
| `parent`                                               | lowered by the stub AND semantics specified            | Retains native Parent grammar and moves optional inline checks into the bundle.                                   |
| `child`                                                | lowered by the stub AND semantics specified            | Retains native Child grammar and moves optional inline checks into the bundle.                                    |
| `parentOf`                                             | lowered by the stub AND semantics specified            | Builds a qualified Parent relation reference whose declared identity is checked during lowering.                  |
| `childOf`                                              | lowered by the stub AND semantics specified            | Builds the corresponding qualified Child reference.                                                               |
| `fieldOf`                                              | lowered by the stub AND semantics specified            | Builds a field identity from the owner tag and the field title.                                                   |
| `isNodeType`                                           | lowered by the stub, semantics specified only in prose | Emits a type-test expression without inspecting any target record.                                                |
| `atMost`                                               | lowered by the stub, semantics specified only in prose | Emits a count comparison without collecting or counting occurrences.                                              |
| `exactly`                                              | lowered by the stub, semantics specified only in prose | Emits an exact-count expression without computing a count.                                                        |
| `only`                                                 | lowered by the stub, semantics specified only in prose | Emits singleton selection and endpoint access; blocked runtime results are not implemented.                       |
| `forest`                                               | lowered by the stub, semantics specified only in prose | Emits selected edges, owner-kind vertices, parent-to-child orientation, and permission for disconnected roots.    |
| `isForest`                                             | lowered by the stub, semantics specified only in prose | Emits the structural predicate without finding cycles or counting hierarchy parents.                              |
| `visibility`                                           | lowered by the stub, semantics specified only in prose | Emits policy values and fixed path settings without validating keyword choices or executing traversal.            |
| `visible`                                              | lowered by the stub, semantics specified only in prose | Emits the view and two endpoints without computing visibility.                                                    |
| `canDescend`                                           | lowered by the stub, semantics specified only in prose | Emits the downward-path question without evaluating a bridge.                                                     |
| `nativeDag`                                            | lowered by the stub, semantics specified only in prose | Emits an all-role native-graph cycle predicate without running a cycle detector.                                  |
| `input`                                                | lowered by the stub, semantics specified only in prose | Emits the input declaration without provider registration, acquisition, or completeness checking.                 |
| `projection`                                           | lowered by the stub, semantics specified only in prose | Emits selected comparison facts without extracting them from records.                                             |
| `preserve`                                             | lowered by the stub, semantics specified only in prose | Emits preservation and records the referenced input dependency without comparing snapshots.                       |
| `contribute`                                           | lowered by the stub AND semantics specified            | Adds relation-scoped checks and retains a contribution origin for composition.                                    |
| `const`                                                | lowered by the stub AND semantics specified            | Accepts exactly Boolean literals and emits their constant predicate representation.                               |
| Relation `edge` binder                                 | lowered by the stub AND semantics specified            | Exposes symbolic origin and target expressions during normalization.                                              |
| Record `node` or `bridge` binder                       | lowered by the stub AND semantics specified            | Exposes symbolic Parent and Child collection functions during normalization.                                      |
| Singleton `.target`                                    | lowered by the stub, semantics specified only in prose | Emits endpoint extraction without resolving a runtime relation.                                                   |
| Runtime graph evaluator                                | not implemented (named)                                | No backend in this stub consumes the predicates to produce graph verdicts.                                        |
| Runtime field-value accessor                           | not implemented (named)                                | No constructor here reads FLAG from an arbitrary bound node for a new predicate.                                  |
| Runtime default materialization                        | not implemented (named)                                | No literal is applied to a candidate, and no script default constructor or execution is provided here.            |
| External snapshot acquisition                          | not implemented (named)                                | No provider command, transport schema, timeout implementation, or snapshot capture runs.                          |
| Prerequisite scheduling and structured blocked results | not implemented (named)                                | No runtime connects a cardinality finding to a blocked singleton-dependent path check.                            |
| Candidate batching, publication, and recovery          | not implemented (named)                                | No private candidate, persistence operation, stale-base refusal, or recovery mechanism is wired here.             |
| Explicit rule replacement or disabling                 | not implemented (named)                                | The contract requires explicit identity-targeted action, but the stub supplies no such authoring constructor.     |

### What normalization actually checks

Declaration identities include the model namespace. A relation identity also
includes its owning element, Parent or Child direction, and role. A check
identity adds its chosen check name to its subject identity. Normalization
rejects duplicate declaration identities. It also rejects undeclared references
it encounters through declared-reference values.

A relation callback receives only the edge binder. A `record` callback receives
only the record binder and must occur at record scope. Returning a raw Boolean
as a predicate produces an authoring error. `const` is the explicit way to
produce a Boolean constant expression.

Normalization compares rules that have the same identity after lowering them. If
their lowered meanings are equal, it keeps one rule and combines their origins.
If their meanings differ, it throws a conflict error. It does not choose
whichever rule happened to appear last.

These checks do not amount to a complete schema checker. The stub does not
validate every operator's operand type. It does not check collection role names
against declarations. It does not turn view references into a complete runtime
dependency or prerequisite graph.

### The composition example, step by step

The separate composition example has this setup, quoted verbatim:

```nix
let
  dsl = import ./dsl.nix;
  inherit (dsl) el field rel model normalize check on contribute isNodeType const;
  inherit (field) required str;
  inherit (rel) parent;
  inherit (dsl) parentOf;

  uid = required (str "UID");
```

Its two FOO declarations and shared `targetType` check were shown side by side
earlier. It registers the inline form in this model:

```nix
  declaration = model "composition" {elements = [foo];};
```

It then adds an equivalent check to the already declared FOO Parent R:

```nix
  equivalent = normalize (declaration
    // {
      contributions = [
        (contribute "extra-target-check" (parentOf foo "R") [targetType])
      ];
    });
```

`declaration // { ... }` is Nix's attribute-set update operation. Here it
supplies a `contributions` list before normalization. The contribution name
identifies where the additional check came from. The check itself still has the
name `"target-type"`. Because both its subject and its lowered meaning match the
inline check, normalization retains one rule with both origins. This proves
deduplication of equivalent authoring, not execution of the target predicate on
`Z0`.

The file returns the following expressions:

```nix
in {
  inherit equivalent;
  sameNormalized =
    normalize declaration
    == normalize (declaration // {elements = [baseFoo];});
  deduplicated = builtins.length equivalent.bundle.rules == 1;
  conflict = normalize (declaration
    // {
      contributions = [
        (contribute "incompatible-target-check" (parentOf foo "R") [
          (check "target-type" (const false))
        ])
      ];
    });
}
```

`sameNormalized` compares the inline model with the model using the
constraints-list form. `deduplicated` asks whether the contributed version
contains exactly one normalized rule. Both follow directly from the
same-subject, same-name, same-expression lowering in this example.

`conflict` supplies a different meaning for that same check identity.
`const false` would reject every bound relation occurrence if evaluated as a
rule. It differs from the existing FOO target-kind predicate. So forcing
normalization of `conflict` throws a conflicting-definition error. Nix is lazy,
so inspecting another returned attribute does not necessarily force this
error-producing attribute.

To extend the model with an independent condition, choose a distinct check name.
Changing only a contribution name does not rename or replace its enclosed
checks. This is why `"incompatible-target-check"` cannot silently replace
`"target-type"`.

### Behavior that remains outside this stub

The contract validates the complete final candidate after explicit operations
and applicable creation defaults. It permits inspection of existing invalid
input. It requires a repair to leave the complete candidate valid before
acceptance. It does not authorize partial repair acceptance while unrelated
violations remain.

Ordinary rejection discards the private candidate. A failure during actual
publication must restore the prior state where possible or report that recovery
is required and block further writes. The exact crash and external-reader
guarantees remain matters for integration evidence. Nothing in this Nix stub
performs those operations.

The contract names required diagnostics such as the owner, target, changed
boundary, path, input identity, and observed count. It does not settle their
full runtime wire format or the complete ordering of dependent findings. The
walkthroughs therefore explain which fact fails without inventing exact error
codes or evaluator output objects.

## Write one yourself

**First exercise:** Give BAZ a rule saying that each record may own at most one
Child Q relation. On the picture, `Z0` may therefore have no Q, or one Q to
`G1`, but not two Q declarations targeting `G1` and `I0`. Put the following
one-line answer in BAZ's `constraints` list:

```nix
(check "at-most-one-Q" (record (node: atMost 1 (node.children "Q"))))
```

`check` names the rule. `record` binds each BAZ record, including `Z0` when it
has no Q. `node.children "Q"` selects the owned Child Q collection. `atMost 1`
supplies the count condition. A relation callback would miss the no-relation
situation because there would be no occurrence to bind.

**Second exercise:** Give BAZ a new rule saying that every Parent R it owns must
target FOO. This is a deliberate extension to BAZ's otherwise unrestricted
target policy. On the picture, a Parent R from `Z0` to `I0` should satisfy this
new target rule. A Parent R from `Z0` to bridge `M` should fail it because M is
BAR. Assume M separately has valid endpoints P at `F0` and Q at `F2` when
considering that second situation. Write the rule in BAZ's `constraints` list
using the existing `baz` and `foo` declarations.

<details>
<summary>Show the answer and read it aloud</summary>

```nix
(on (parentOf baz "R") (check "R-targets-FOO" (edge: isNodeType edge.target foo)))
```

`parentOf baz "R"` selects BAZ's declared Parent R. `on` gives the check that
relation scope. The callback receives each owned occurrence as `edge`.
`edge.target` identifies its declared endpoint. `isNodeType` asks whether that
endpoint has the element kind declared by `foo`. The other model rules,
including the native cycle rule and any baseline protection, still apply.

</details>

These exercises use the actual symbolic accessors provided by the stub. A
different exercise that reads an arbitrary target's FLAG would need a
field-value accessor that this interface does not yet expose. Knowing a field
reference through `fieldOf` is not enough to invent that missing operation.
