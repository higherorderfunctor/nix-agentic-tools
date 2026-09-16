# Writing rules for FOO, BAR, and BAZ

## 1. The model in one picture

An **element** declares a kind of record, and a **record** is one instance, such
as F2. FOO records have a UID and a Boolean FLAG that says whether they are open
or closed (fragment of examples.nix, lines 12–13):

```nix
  uid = required (str "UID");
  flag = creationDefault false (required (boolean "FLAG"));
```

A **forest** is a collection of trees whose roots need not connect. The picture
shows FOO's hierarchy; `Z0 : BAZ` means that the record named Z0 has element
kind BAZ.

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
M  : BAR (created in bridge examples; not an H-tree node)
```

A line down the tree runs from parent to child. The child owns the relation: F1a
has Parent H targeting F1. Document nesting does not determine these edges. We
will use this picture to check target kinds, visibility through closed F2, and
bridges between two FOO endpoints. Each scenario starts here unless stated
otherwise, and rows do not accumulate changes.

## 2. Elements and fields

Each record has a required string field named UID so other records can address
it. FOO also has the required Boolean FLAG, with a creation default of false.
(fragment of examples.nix, lines 12–13):

```nix
  uid = required (str "UID");
  flag = creationDefault false (required (boolean "FLAG"));
```

Read nested calls from the inside out: `boolean` declares the field, `required`
marks it required, and `creationDefault` records its default. Here **native**
means the stored field encoding; later, native grammar means the underlying
element and Parent/Child declarations. Unquoted `false` is a Nix Boolean; its
native field spelling is the string `"false"`. The complete Boolean spelling set
is `"false"` and `"true"`. A **batch** is an ordered group of operations checked
together after they finish. A default fills final absence only on a newly
created record that survives the batch. It neither replaces an explicit value
nor repairs invalid data. The **stub** is the supplied Nix implementation that
converts declarations into data without evaluating records. It records this
default policy without applying it to records.

An element groups its fields, relations, and constraints. Here is BAZ, whose
only field is UID and whose constraints list is empty. We will read its two
relation declarations in the next chapter. (fragment of examples.nix, lines
47–54):

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

`el` takes the element name, grammar properties, and body in that order. The
empty `{}` supplies no extra properties. Nix uses square brackets for lists and
braces for named attributes. A function takes arguments separated by spaces, so
`str "UID"` supplies one argument.

A **candidate** is the complete proposed state after the batch and applicable
creation defaults. Acceptance requires that state to meet all rules; rejection
keeps the prior state. The **baseline** is an external snapshot of records whose
modeled facts must be preserved. Assume it is successfully acquired, complete,
and empty unless a scenario protects a record. All scenario results below are
specified behavior, not results executed by the stub.

| Situation                            | Change                                                                            | Result                                            | Why                                                                       |
| ------------------------------------ | --------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------------------------------------- |
| I0 is absent before creation.        | Create I0 as FOO and leave FLAG absent at the end of the batch.                   | Accept I0 with FLAG false.                        | The surviving new record has final absence, so the default makes it open. |
| I0 is absent before creation.        | Create I0 with explicit FLAG false, or set it to false later in the batch.        | Accept I0 with its explicit false value.          | A present valid value prevents defaulting; explicit true is retained too. |
| I0 is absent before creation.        | Supply an unknown Boolean spelling, an empty value list, or multiple FLAG values. | Report an input or type error.                    | Invalid supplied data is not absence and cannot become false by default.  |
| Existing I0 lacks its required FLAG. | Edit I0 without supplying a valid FLAG.                                           | Reject the incomplete final record.               | Existing records are never backfilled by this default.                    |
| I0 is absent before the batch.       | Create I0 and then delete it in that batch.                                       | Accept the otherwise valid final tree without I0. | No surviving new record needs a default.                                  |

The reference tables describe the intended check scope. Their “Real today”
column says what the stub actually does.

| Constructor       | Signature                     | Arguments                                                                                       | Checks over                    | Real today                                                                             |
| ----------------- | ----------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------ | -------------------------------------------------------------------------------------- |
| `el`              | `el NAME PROPERTIES BODY`     | Name you choose; grammar properties; body lists named `fields`, `relations`, and `constraints`. | none                           | Wraps native grammar and retains constraints; does not reject unknown body keys.       |
| `str`             | `str NAME`                    | Field name you choose.                                                                          | each record                    | Declares an initially optional native string field; does not establish UID uniqueness. |
| `required`        | `required FIELD`              | Field declaration from `str` or `boolean`, possibly with a default.                             | each record                    | Marks requiredness and retains metadata; does not validate records.                    |
| `boolean`         | `boolean NAME`                | Field name you choose; native choices are exactly `"false"`, `"true"`.                          | each record                    | Emits choices and their mapping to Boolean values.                                     |
| `creationDefault` | `creationDefault VALUE FIELD` | Boolean literal `false` or `true`; Boolean field declaration, optionally through `required`.    | each record (new records only) | Checks literal compatibility and stores the default; does not materialize it.          |

## 3. Relations and the inline rule

A **relation occurrence** is one declaration owned by a record and pointing at
another record. `parent` and `child` declare which kinds of relation an element
may own. BAR declares these two kinds inside its element frame. Read the
`relations` list first; chapters 4–6 explain its constraints and the visibility
view `sight`. (fragment of examples.nix, lines 30–44):

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

The first string names the role, and the second names its reverse display label.
A reverse label does not create another authored relation. The optional third
argument gives an inline rule. **Symbolic** means represented as data for later
evaluation, rather than computed from records now. A **predicate** is a
condition that will be true or false when its operands can be evaluated.
`isNodeType` builds the question “does this endpoint have the FOO element kind?”

`edge: ...` is a callback whose argument is locally named `edge`. A
**reference** identifies a declaration or a bound record or relation without
loading its runtime data. A **binder** supplies symbolic references for the
subject a future evaluator will inspect. This relation binder has exactly two
author-facing properties: `origin`, the owner, and `target`, the declared
endpoint. For M's Parent P targeting F0, `edge.origin` is M and `edge.target` is
F0. Native connectivity still runs from F0 to M because this is a Parent
relation. Native connectivity means the underlying Parent and Child edges
themselves, across every role and element kind, before any semantic rule
applies.

FOO uses the same inline pattern for its own H and R roles (fragment of
examples.nix, lines 19–20):

```nix
      (parent "H" "H_back" (edge: isNodeType edge.target foo))
      (parent "R" "R_back" (edge: isNodeType edge.target foo))
```

For F1a's Parent R targeting F2, the binder's origin is F1a and its target is
F2. The later visibility walk starts at that authored origin. The name `edge` is
yours to choose; renaming it does not change the available properties. There is
no `edge.role` accessor. A callback must return a symbolic predicate, not a raw
Nix `true` or `false`.

| Situation                                      | Change                            | Result                                   | Why                                                      |
| ---------------------------------------------- | --------------------------------- | ---------------------------------------- | -------------------------------------------------------- |
| F1a and closed F2 are in the picture.          | Add Parent R on F1a targeting F2. | Accept the relation.                     | F2 has the required FOO kind and is a visible endpoint.  |
| Z0 is the pictured BAZ record.                 | Add Parent R on F1a targeting Z0. | Reject the relation for its target kind. | Z0 resolves, but it is BAZ rather than FOO.              |
| Z0 is outside the H forest and I0 is isolated. | Give Z0 Parent R targeting I0.    | Accept the relation.                     | BAZ's own R has no FOO target or visibility restriction. |

Reusing a role name does not copy another element's rules. BAZ still has to
satisfy endpoint resolution and the model's other rules. An unresolved target is
a prerequisite problem, not a finding that a resolved record has the wrong kind.

| Constructor  | Signature                              | Arguments                                                                                              | Checks over                   | Real today                                                                                        |
| ------------ | -------------------------------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------- | ------------------------------------------------------------------------------------------------- |
| `parent`     | `parent ROLE REVERSE_ROLE [PREDICATE]` | Two names you choose; optional callback receiving `edge.origin` and `edge.target`, or a named `check`. | each relation occurrence      | Declares Parent grammar and retains an inline check; a bare callback gets the name `"predicate"`. |
| `child`      | `child ROLE REVERSE_ROLE [PREDICATE]`  | Two names you choose; optional callback receiving the same edge binder, or a named `check`.            | each relation occurrence      | Declares Child grammar and retains an inline check.                                               |
| `isNodeType` | `isNodeType NODE ELEMENT`              | Node from `edge.origin` or `edge.target`; element reference from `el`.                                 | each relation occurrence here | Emits the type question; inspecting a record remains specified behavior.                          |

## 4. Rules that live on the element

The element's `constraints = [ ... ]` list plays the role of Django's `Meta`: it
keeps rules beside the fields and relations they govern. `check` names a rule,
while its placement supplies the scope. Check names are unique per subject
identity (relation, element, or model), not global: the stub merges equal
definitions for that subject and name, and throws when they differ. FOO's list
contains a count rule and a rule attached to R. sight is the visibility view
built in the next chapter. (fragment of examples.nix, lines 16–27):

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

**Read aloud:** “For each FOO, allow at most one owned H parent. For each FOO
Parent R, require its target to be visible from its owner through `sight`.”

`record` calls its predicate-building function with a record binder, locally
named `node`. That binder exposes exactly `parents ROLE` and `children ROLE`.
Each returns a symbolic collection of matching relations owned by the record.
`node.parents "H"` includes F1a's H targeting F1, but excludes its R and other
records' incoming declarations. The role string is a reference key: a string
that must name something already declared elsewhere in the model. The stub does
not check it today, so a typo is accepted silently.

`record` includes records with zero relations, so the root F0 still gets its
count check. By contrast, `on` checks each occurrence of the selected relation;
no occurrence means no invocation. `parentOf foo "R"` obtains a declaration
reference for FOO's Parent R.

| Situation                       | Change                             | Result                              | Why                                                            |
| ------------------------------- | ---------------------------------- | ----------------------------------- | -------------------------------------------------------------- |
| F0 has no H parent.             | Validate F0 with no H relation.    | Accept under the count rule.        | Zero is at most one.                                           |
| F1a already has H targeting F1. | Add a second H targeting F0.       | Reject the extra relation.          | F1a would own two H parents, even without a cycle.             |
| F2 has H targeting F0.          | Create M with P to F0 and Q to F2. | Accept the bridge and F2's H count. | Connectivity from M does not add an H declaration owned by F2. |

The target-kind rule can also move between the inline position and this list.
The separate `composition.nix` uses a named inline check (fragment of
composition.nix, lines 9–16):

```nix
  targetType = check "target-type" (edge: isNodeType edge.target foo);
  foo = el "FOO" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back" (check "target-type" (edge: isNodeType edge.target foo)))
    ];
    constraints = [];
  };
```

Its alternative FOO declaration puts that same check in the constraints list
(fragment of composition.nix, lines 18–24):

```nix
  baseFoo = el "FOO" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back")
    ];
    constraints = [(on (parentOf baseFoo "R") targetType)];
  };
```

These are alternative declarations of the same element name, not two elements to
register together. The two forms lower identically, and chapter 9 shows the
proof. Both use the same subject and check name, `"target-type"`. A bare inline
callback gets the name `"predicate"`, so it would not match a differently named
check. Either form rejects F1a's R targeting Z0, and neither adds that rule to
Z0's own R.

| Constructor | Signature                 | Arguments                                                                                       | Checks over                                                        | Real today                                                                           |
| ----------- | ------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------ |
| `check`     | `check NAME EXPRESSION`   | Name you choose; symbolic predicate, `record` expression, or callback receiving an edge binder. | each relation occurrence / each record / whole model, by placement | Names and lowers the predicate; rejects raw Boolean predicates.                      |
| `record`    | `record BIND`             | Predicate-building function receiving a binder with `parents ROLE` and `children ROLE`.         | each record                                                        | Calls the function symbolically; rejects use outside record scope.                   |
| `atMost`    | `atMost COUNT COLLECTION` | Integer bound; collection from the record binder's `parents` or `children`.                     | each record                                                        | Emits a count predicate; does not validate the bound or count records.               |
| `on`        | `on SUBJECT CHECK`        | Relation reference from `parentOf` or `childOf`; named predicate from `check`.                  | each relation occurrence                                           | Attaches the check to the selected relation.                                         |
| `parentOf`  | `parentOf ELEMENT ROLE`   | Element reference from `el`; reference key naming its declared Parent role.                     | none                                                               | Builds a reference qualified by owner and direction; normalization checks it exists. |

## 5. Hierarchy and visibility

The hierarchy uses only FOO's Parent H relations. Other roles cannot supply
shortcuts between its nodes. `fieldOf foo flag` selects the field declaration
whose Boolean value controls closed boundaries. (fragment of examples.nix, lines
57–63):

```nix
  h = forest "H" (parentOf foo "H");
  sight = visibility "H-visibility" h {
    closedWhenTrue = fieldOf foo flag;
    ascent = "unrestricted";
    visit = "always";
    expand = "open-or-origin-in-subtree-including-self";
  };
```

The first `"H"` names a view; the second refers to FOO's declared H role. All
FOO records belong to this view, including isolated I0. `forest` declares the
view, and `isForest` asks whether its structure is valid. Specified: no cycles
and at most one H parent. Stub today: neither is detected. (fragment of
examples.nix, lines 92–92):

```nix
    (check "H-forest" (isForest h))
```

For `visible sight ORIGIN TARGET`, keep the original origin fixed throughout
this algorithm. **Visit** means reach a node; **expand** means leave it by a
downward step to an H child.

1. Resolve both endpoints to FOO records in a usable H forest. Any FLAG needed
   by the walk must be a valid Boolean. Missing endpoints, invalid values, or an
   unusable forest prevent evaluation; they do not prove a target is hidden.
2. Follow each endpoint's H parents to its root. If the roots differ, reject the
   visibility question.
3. Write the unique H path from origin to target, going up to their nearest
   shared ancestor and then down. No other role can replace a step.
4. Visit the current node, starting at the origin. If it is the target, accept
   immediately, including a closed target or a conceptual path of length zero.
5. If the next step is upward, take it and return to step 4. Ascent ignores
   closed flags.
6. If the next step is downward, test whether the current node may expand. It
   may expand if open, or if the original origin is in its subtree, including
   the current node itself.
7. If expansion is allowed, take the step and return to step 4. Otherwise reject
   at this closed boundary, even if the unvisited target is open.

First, add an R owned by F1a targeting F2. Both roots are F0, and the original
origin stays F1a:

```text
F1a → F1 → F0 → F2
```

| Situation                   | Change                      | Result                                                    | Why                                                                               |
| --------------------------- | --------------------------- | --------------------------------------------------------- | --------------------------------------------------------------------------------- |
| The walk is at F1a.         | Visit F1a and ascend to F1. | Continue.                                                 | F1a is not the target, and ascent is unrestricted.                                |
| The walk is at F1.          | Visit F1 and ascend to F0.  | Continue.                                                 | The next step is still upward.                                                    |
| The walk is at F0.          | Visit F0 and descend to F2. | Continue.                                                 | Open F0 may expand.                                                               |
| The walk reaches closed F2. | Visit F2.                   | Accept the visibility question and the proposed relation. | F2 is the target, so no expansion is needed; the native graph also stays acyclic. |

Now aim F1a's R at F2a instead. The roots and original origin are unchanged:

```text
F1a → F1 → F0 → F2 → F2a
```

| Situation               | Change                      | Result                        | Why                                                                                           |
| ----------------------- | --------------------------- | ----------------------------- | --------------------------------------------------------------------------------------------- |
| The walk is at F1a.     | Visit F1a and ascend to F1. | Continue.                     | Ascent is unrestricted.                                                                       |
| The walk is at F1.      | Visit F1 and ascend to F0.  | Continue.                     | Ascent remains unrestricted.                                                                  |
| The walk is at F0.      | Visit F0 and descend to F2. | Continue.                     | F0 is open.                                                                                   |
| The walk reaches F2.    | Try to descend to F2a.      | Reject at F2.                 | Closed F2 does not contain the original origin F1a in its subtree.                            |
| F2a is still unvisited. | Stop before reaching F2a.   | Reject the proposed relation. | F2a's open flag cannot remove the earlier boundary; this relation would otherwise be acyclic. |

The origin test also explains why F2a may reach F2b through their closed parent
F2. F2a is already in F2's subtree. F2a may ascend out of that subtree toward
F1a too. F1a cannot reach G1 because their H roots differ.

The three policy strings are fixed: `ascent = "unrestricted"`,
`visit = "always"`, and `expand = "open-or-origin-in-subtree-including-self"`.
The stub stores these strings without enforcing them. `closedWhenTrue` takes a
Boolean field reference; false means open and true means closed.

The constructor fixes shared-root checking, unique H paths, and conceptual
zero-length reachability. The field reference must exist, but the stub does not
check its Boolean type or its ownership by the hierarchy's element. Prerequisite
handling and traversal remain specified behavior.

| Constructor  | Signature                          | Arguments                                                                                                             | Checks over                   | Real today                                                                                               |
| ------------ | ---------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------- |
| `forest`     | `forest NAME EDGES`                | Name you choose; Parent relation reference from `parentOf`.                                                           | none                          | Emits owner-kind vertices and selected edges in parent-to-child orientation; permits disconnected roots. |
| `isForest`   | `isForest VIEW`                    | View reference from `forest`.                                                                                         | whole model                   | Emits the structural predicate described above; runs no graph check.                                     |
| `fieldOf`    | `fieldOf ELEMENT FIELD`            | Element from `el`; field declaration from `str` or `boolean` and its wrappers.                                        | none                          | Builds a declared field reference, not a record's field value.                                           |
| `visibility` | `visibility NAME HIERARCHY POLICY` | Name you choose; view from `forest`; field reference and fixed keywords listed above.                                 | none                          | Emits policy and path settings; does not validate policy keywords.                                       |
| `visible`    | `visible VIEW ORIGIN TARGET`       | View from `visibility`; the example supplies node expressions from the edge binder (see chapter 10 for scope limits). | each relation occurrence here | Emits the path question; runtime behavior follows the algorithm above.                                   |

## 6. Bridges

A BAR record owns both of its endpoints. `exactly 1` requires one relation in
each endpoint collection. Then `only` selects that sole relation, and `.target`
gives its declared endpoint. (fragment of examples.nix, lines 36–43):

```nix
    constraints = [
      (check "one-P" (record (bridge: exactly 1 (bridge.parents "P"))))
      (check "one-Q" (record (bridge: exactly 1 (bridge.children "Q"))))
      (check "endpoint-path" (record (bridge:
        canDescend sight
        (only (bridge.parents "P")).target
        (only (bridge.children "Q")).target)))
    ];
```

**Read aloud:** “For each bridge, require one P and one Q. From the sole P
target, require a permitted downward H path to the sole Q target.”

The callback name `bridge` supplies the same record binder as `node` did. It has
`parents ROLE` and `children ROLE`, not `bridge.origin`, `bridge.UID`, or a
field-value getter. The collections contain owned relation occurrences, not
every neighboring node. For M with P to F0 and Q to F2, native connectivity is
F0 → M → F2. M remains a record between those endpoints and does not become an H
edge.

The count rule must establish a singleton, a collection with exactly one member,
before `only` can provide an endpoint. With no Q, `exactly 1` is **failed**: its
evaluable count condition is false. The path check is **blocked**: it cannot
obtain the required sole Q endpoint. Two Q relations cause the same distinction;
`only` never chooses an arbitrary member. This is a logical dependency, and the
list puts the count rules first so it is readable. The stub generates neither
scheduling nor prerequisite links between those checks. It also leaves
storage-level treatment of duplicate identical occurrences unspecified.

`canDescend` uses the visibility visit and expansion rules, but every H step
must go downward. A route from F1 to F2 would need ascent through F0 and
therefore fails this path rule. Here is the trace for M with P to closed F2 and
Q to F2a:

```text
M owns Parent P → F2 and Child Q → F2a
Native connectivity: F2 → M → F2a
Selected H path:     F2 → F2a
Original path origin: F2
```

| Situation                              | Change                                                | Result                                               | Why                                                                 |
| -------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------- |
| M owns the pictured P and Q endpoints. | Bind M and count its P and Q collections.             | Both count checks pass with one.                     | Each collection contains one owned declaration.                     |
| Both collections are singletons.       | Select P's target F2 and Q's target F2a.              | Obtain two FOO endpoints in the H tree rooted at F0. | `.target` keeps the authored endpoint meaning for either direction. |
| The walk starts at closed F2.          | Visit F2 and try the downward step to F2a.            | Permit expansion.                                    | The original origin F2 belongs to its own subtree.                  |
| The walk reaches F2a.                  | Visit the target and check the remaining model rules. | Accept M under the empty baseline.                   | The H path is permitted and F2 → M → F2a adds no native cycle.      |

Creating M before its endpoints within a batch is allowed if the final candidate
is complete. Finishing without Q rejects M's count and blocks its path check.
With P at F0, Q at closed F2 is allowed; Q at F2a fails at F2's boundary. A
blocked path due to a missing operand differs from a failed path at a closed
boundary.

| Constructor  | Signature                       | Arguments                                                                                   | Checks over | Real today                                                                         |
| ------------ | ------------------------------- | ------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------- |
| `exactly`    | `exactly COUNT COLLECTION`      | Integer count; collection from a record binder's `parents` or `children`.                   | each record | Emits the comparison without validating the number or counting occurrences.        |
| `only`       | `only COLLECTION`               | Collection from the record binder; `.target` selects the sole relation's declared endpoint. | each record | Emits singleton selection and endpoint access; runtime blocking is specified only. |
| `canDescend` | `canDescend VIEW ORIGIN TARGET` | View from `visibility`; node references from the two singleton `.target` expressions.       | each record | Emits the downward-path predicate; does not traverse the graph.                    |

## 7. Model-wide rules and inputs

Some rules need facts beyond one record. An **input** declares data that runtime
must supply for an evaluation. Here it supplies the external baseline introduced
in chapter 2 (fragment of examples.nix, lines 65–70):

```nix
  # Declare the input; acquisition and capture belong to runtime.
  baseline = input "baseline" {
    kind = "external-snapshot";
    required = true;
    complete = true;
  };
```

Runtime must capture one identified, immutable, complete snapshot for the
evaluation. A source change can affect the next evaluation, but cannot change
this captured input halfway through. A successfully acquired empty snapshot
protects no records. Failed acquisition is an execution error, not evidence that
a preservation condition is false. The declaration supplies no executable,
transport format, or acquisition code.

A **projection** describes which facts to extract before comparing records.
`childOf` selects a declared Child role, just as `parentOf` selects a Parent
role. This projection matches records by UID and includes their existence,
element kind, FLAG presence and value, and selected owned relations (fragment of
examples.nix, lines 71–87):

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

`fieldPresence` keeps an absent FLAG distinct from a present value.
`ownedRelations` selects declarations belonging to the protected record. Each
selected relation is compared by native direction, role, and target identity.
`relationOrder = "set"` ignores declaration order; it does not define duplicate
counting for cardinality rules. Document location, reverse labels, runtime
bookkeeping, and incoming declarations owned elsewhere are excluded.

**Read aloud:** “For every listed UID, keep the record, its kind, its selected
fields, and its owned modeled relations.”

`preserve` compares that projection for every record listed in the baseline
(fragment of examples.nix, lines 93–93):

```nix
    (check "baseline-preserved" (preserve baseline modeledRecord))
```

| Situation                                           | Change                                                                 | Result                                           | Why                                                                                        |
| --------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| The baseline protects I0.                           | Delete I0.                                                             | Reject deletion.                                 | The projection preserves existence for its UID.                                            |
| The baseline protects I0 with FLAG false.           | Revise I0 to FLAG true.                                                | Reject the revision.                             | The captured baseline protects its FLAG value.                                             |
| The baseline protects F1a with H targeting F1.      | Replace its H parent with F0.                                          | Reject the revision.                             | F1a owns the protected H declaration, even though the proposed hierarchy remains a forest. |
| The baseline protects I0 with FLAG false.           | Give Z0 Parent R targeting I0, leaving I0's own facts unchanged.       | Accept the incoming relation.                    | It belongs to Z0 and is outside I0's projection.                                           |
| The baseline protects F1a with H to F1 and R to F2. | Reorder those declarations or move F1a to another document.            | Accept unchanged modeled facts.                  | Declaration order and document location are excluded.                                      |
| The complete acquired baseline is empty.            | Set I0's FLAG to true.                                                 | Accept the otherwise valid change.               | No baseline record protects I0.                                                            |
| A baseline is required before editing I0.           | Acquisition times out, fails, or returns malformed or incomplete data. | Report an execution error and keep I0 unchanged. | No usable snapshot is available for preservation.                                          |
| The captured baseline protects I0 with FLAG false.  | Propose FLAG true while the external source becomes empty.             | Reject this evaluation's revision.               | All checks still use the captured snapshot.                                                |

The **native graph** includes all underlying Parent and Child relations across
every role and element kind. A **DAG**, or directed acyclic graph, is a directed
graph with no cycle. `nativeDag` requires that property independently of the
selected H forest and visibility policy (fragment of examples.nix, lines 91–91):

```nix
    (check "native-dag" nativeDag)
```

| Situation             | Change                                     | Result                     | Why                                                                         |
| --------------------- | ------------------------------------------ | -------------------------- | --------------------------------------------------------------------------- |
| F1a descends from F1. | Give Z0 Parent R to F1a and Child Q to F1. | Reject the combined graph. | F1 → F1a → Z0 → F1 is a native cycle across roles and kinds.                |
| F2 is closed.         | Create M with both P and Q targeting F2.   | Reject M.                  | A conceptual zero-length H path cannot excuse the native cycle F2 → M → F2. |

The same cycle rule rejects a self-targeting R or an ancestor's R targeting its
own H descendant. The complete rules list applies these checks to the model
(fragment of examples.nix, lines 89–94):

```nix
  # The all-role DAG is independent of the selected forest and visibility.
  rules = [
    (check "native-dag" nativeDag)
    (check "H-forest" (isForest h))
    (check "baseline-preserved" (preserve baseline modeledRecord))
  ];
```

| Situation                                   | Change                                        | Result                 | Why                                                |
| ------------------------------------------- | --------------------------------------------- | ---------------------- | -------------------------------------------------- |
| F0, G0, and I0 are separate roots.          | Validate the pictured hierarchy.              | Accept the forest.     | Roots and isolated records need not connect.       |
| F2 was opened and F1a already has R to F2a. | Close F2 while retaining that R.              | Reject closing F2.     | The whole candidate would hide an existing target. |
| F2 was opened and F1a already has R to F2a. | Close F2 and remove that R in the same batch. | Accept the final tree. | No reference remains through the closed boundary.  |

The complete final candidate is checked after explicit operations and applicable
creation defaults. Inspection may expose existing invalid data, but a repair
must leave the complete candidate valid.

| Constructor  | Signature                      | Arguments                                                                                                                                       | Checks over | Real today                                                                          |
| ------------ | ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------- |
| `nativeDag`  | `nativeDag`                    | No arguments; already a symbolic predicate over all native roles.                                                                               | whole model | Emits a cycle predicate in parent-to-child orientation; runs no cycle detector.     |
| `input`      | `input NAME CONFIG`            | Name you choose; fixed `kind` set: `"external-snapshot"`; this profile requires `required = true` and `complete = true`.                        | none        | Emits configuration without validation, acquisition, or completeness checks.        |
| `projection` | `projection NAME CONFIG`       | Name you choose; UID reference key; field and relation references; fixed component set `"nativeType"`, `"role"`, `"target"`; order set `"set"`. | none        | Emits the comparison description; extracts no record facts.                         |
| `preserve`   | `preserve BASELINE PROJECTION` | Input reference from `input`; comparison reference from `projection`.                                                                           | whole model | Emits preservation and its input dependency; compares no snapshots.                 |
| `childOf`    | `childOf ELEMENT ROLE`         | Element reference from `el`; reference key naming its declared Child role.                                                                      | none        | Builds a qualified Child reference whose existence is checked during normalization. |

## 8. Assemble and lower

`model` gathers the declarations and rules under one chosen name. A Nix variable
holding a view does not register it; the model's `views` list does. The other
lists register the remaining declaration kinds. (fragment of examples.nix, lines
95–102):

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

**Lowered** means converted from Nix authoring values into ordinary data a later
system could read. `normalize` calls callbacks with symbolic binders, never
loaded records such as F1a. It returns native declarations in `grammar`, field
types and default metadata in `semanticTypes`, and declarations and symbolic
rules in `bundle`. The bundle also records references, configurations, input
dependencies, and rule origins.

Today normalization checks declaration identities, declared references it
encounters, predicate shape, binder scope, and conflicting definitions of a
check. It rejects duplicate declaration identities and undeclared selected
references. It is not a complete schema checker: it leaves collection role
strings and most operand types unchecked. It does not build a full runtime
prerequisite graph.

No graph evaluator, baseline acquisition, default application, candidate
publication, or recovery runs in this stub. The runtime contract calls for
discarding rejected candidates and restoring prior state after publication
failure where possible. If restoration fails, it requires reporting recovery and
blocking further writes. Those operations and their crash guarantees need
integration evidence. The accepted stub imports native grammar code outside this
review directory; that import was not followed or reevaluated here.

| Constructor | Signature         | Arguments                                                                                                                      | Checks over                    | Real today                                                                               |
| ----------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------ | ------------------------------ | ---------------------------------------------------------------------------------------- |
| `model`     | `model NAME BODY` | Name you choose; lists `elements`, `views`, `inputs`, `projections`, `constraints`, `contributions`, each defaulting to empty. | none                           | Supplies the model namespace and list defaults; does not reject unknown body keys.       |
| `normalize` | `normalize MODEL` | Declaration obtained from `model`, optionally updated with Nix attributes.                                                     | whole model (authoring checks) | Produces grammar, metadata, and rule data; authoring errors throw during Nix evaluation. |

## 9. Contributing rules from outside

`contribute` adds named checks to a relation already declared by an element. It
takes a contribution name, a relation reference, and a list of checks. The
inline FOO declaration and `targetType` are the ones from chapter 4. First,
`composition.nix` puts that FOO into a model (fragment of composition.nix, lines
25–25):

```nix
  declaration = model "composition" {elements = [foo];};
```

The Nix `//` operator updates an attribute set, with attributes on the right
replacing the same names on the left. This update supplies the model's
contributions before normalization (fragment of composition.nix, lines 27–33):

```nix
  # Contribute to the relation that was already declared above.
  equivalent = normalize (declaration
    // {
      contributions = [
        (contribute "extra-target-check" (parentOf foo "R") [targetType])
      ];
    });
```

The contribution repeats the existing `target-type` check on the same FOO Parent
R subject. After lowering, both expressions have the same meaning. Normalization
keeps one rule and combines its declaration and contribution origins. The
contribution name records where a rule came from; it does not change the
enclosed check's identity. This expression checks that only one rule remains
(fragment of composition.nix, lines 39–39):

```nix
  deduplicated = builtins.length equivalent.bundle.rules == 1;
```

`deduplicated` is true under the stub's lowering logic. Now give the same
subject and check name a different meaning. `const` turns a Boolean literal into
a symbolic predicate, so `const false` describes an always-false condition
(fragment of composition.nix, lines 40–47):

```nix
  conflict = normalize (declaration
    // {
      contributions = [
        (contribute "incompatible-target-check" (parentOf foo "R") [
          (check "target-type" (const false))
        ])
      ];
    });
```

Forcing `conflict` throws an error naming `target-type`: “conflicting
definitions for check”. Nix is lazy, so inspecting another returned attribute
need not force that error. A new independent condition needs a distinct check
name. Changing the contribution name alone cannot replace or disable an existing
check.

Finally, this is chapter 4's proof that the inline FOO and its alternative
`baseFoo` lower identically (fragment of composition.nix, lines 36–38):

```nix
  sameNormalized =
    normalize declaration
    == normalize (declaration // {elements = [baseFoo];});
```

`sameNormalized` is true under this lowering logic because both forms register
the same subject, check name, and expression. Evaluating it returns `true`; the
recorded run is in `transcript.txt` beside this file. These equalities compare
emitted data; they do not evaluate graph predicates. The conclusions here come
from reading the stub, without following its external grammar import.

| Constructor  | Signature                        | Arguments                                                                                                         | Checks over                                                        | Real today                                                                                                  |
| ------------ | -------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `contribute` | `contribute NAME SUBJECT CHECKS` | Name you choose; declared relation reference from `parentOf` or `childOf`; list of named predicates from `check`. | each relation occurrence                                           | Merges identical lowered checks and their origins; throws on conflicting meanings under one check identity. |
| `const`      | `const VALUE`                    | Boolean literal: complete accepted set `false`, `true`.                                                           | each relation occurrence / each record / whole model, by placement | Emits a constant predicate and rejects non-Booleans; it has no operand that can block.                      |

## 10. Write one yourself

`inherit` brings constructor names into local scope from `dsl`, `field`, or
`rel`. Adding a rule that uses a constructor not already on the `inherit` lines
requires adding it there. These are the imports in `examples.nix` (fragment of
examples.nix, lines 5–10):

```nix
  inherit (dsl) el field rel model normalize check on record;
  inherit (field) required str boolean creationDefault;
  inherit (rel) parent child;
  inherit (dsl) parentOf childOf fieldOf isNodeType atMost exactly only;
  inherit (dsl) forest isForest visibility visible canDescend nativeDag;
  inherit (dsl) input projection preserve;
```

Choose a scope before writing the rule. In this table, **specified** means
supported by the reference contract and examples; **unattested** means they
establish no promise for that placement. Every “stub accepts” entry assumes that
all operands have been supplied and can be lowered. The stub checks symbolic
shape and binder placement, but does not enforce the operators' intended scopes.

| Constructor  | Legal in relation scope   | Legal in record scope               | Legal in model scope      | Where its operands come from                                                                                                                               |
| ------------ | ------------------------- | ----------------------------------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `isNodeType` | Stub accepts; specified.  | Stub accepts; unattested.           | Stub accepts; unattested. | Node: `edge.origin` or `edge.target` in the example; stub also accepts a singleton's `.target`; element: declaration from `el`.                            |
| `atMost`     | Stub accepts; unattested. | Stub accepts; specified.            | Stub accepts; unattested. | Count: integer literal by contract; collection: `parents ROLE` or `children ROLE` supplied by `record`.                                                    |
| `exactly`    | Stub accepts; unattested. | Stub accepts; specified.            | Stub accepts; unattested. | Count: integer literal by contract; collection: the same record binder methods.                                                                            |
| `only`       | Stub accepts; unattested. | Stub accepts; specified as a value. | Stub accepts; unattested. | Collection: a record binder's `parents ROLE` or `children ROLE`; returns the sole relation, whose `.target` supplies a node.                               |
| `visible`    | Stub accepts; specified.  | Stub accepts; unattested.           | Stub accepts; unattested. | View: registered `visibility` declaration; nodes: `edge.origin` and `edge.target` in the example, or singleton `.target` expressions accepted by the stub. |
| `canDescend` | Stub accepts; unattested. | Stub accepts; specified.            | Stub accepts; unattested. | View: registered `visibility` declaration; nodes: singleton `.target` expressions in the example, or edge endpoints accepted by the stub.                  |
| `nativeDag`  | Stub accepts; unattested. | Stub accepts; unattested.           | Stub accepts; specified.  | No author-supplied operands; the constructor fixes all native Parent/Child roles and parent-to-child orientation.                                          |
| `preserve`   | Stub accepts; unattested. | Stub accepts; unattested.           | Stub accepts; specified.  | Registered `input` and `projection` declarations; no binder.                                                                                               |
| `const`      | Stub accepts; specified.  | Stub accepts; specified.            | Stub accepts; specified.  | A Nix Boolean literal; no binder.                                                                                                                          |

For these non-constant operators, the stub rejects direct Boolean operands but
does not otherwise check operand types. A bare callback receives the edge binder
only in relation scope; the stub rejects it in record or model scope. A `record`
callback receives collection methods only in record scope; the stub rejects that
binder elsewhere. Model scope supplies neither binder, so accepting an operator
there does not create its missing node or collection operands. `only` is a value
builder, but the stub even accepts it as a check because it only requires a
symbolic expression shape. Yes, a singleton's `.target` can feed `visible` in a
record check in the stub; it is not restricted to `edge.origin` and
`edge.target`. The contract specifies visibility for FOO R's owner and target,
but no example establishes `visible` in record scope.

**First exercise:** Add a BAZ rule permitting at most one owned Child Q. Z0 may
have no Q or one Q to G1, but not two Q declarations targeting G1 and I0. Use
this FOO count rule as the pattern (fragment of examples.nix, lines 23–23):

```nix
      (check "one-H-parent" (record (node: atMost 1 (node.parents "H"))))
```

<details>
<summary>Show the first answer</summary>

Put a copy in BAZ's constraints list and give the check its own descriptive
name. Keep `record` and the bound of one, but select the binder's children
collection for role Q. `record` includes Z0 even when it has no Q. A relation
callback would have no occurrence to bind when Q is absent.

</details>

**Second exercise:** Require every Parent R owned by BAZ to target FOO. Z0's R
to I0 should satisfy the new rule; its R to M should fail because M is BAR. For
the second situation, assume M has valid endpoints P at F0 and Q at F2. Chapter
4 attached a target-kind check through an element's list using this pattern
(fragment of composition.nix, lines 23–23):

```nix
    constraints = [(on (parentOf baseFoo "R") targetType)];
```

<details>
<summary>Show the second answer</summary>

Put an `on` entry in BAZ's constraints list and select BAZ's declared Parent R
with `parentOf`. Give its check a descriptive name and use a relation callback
that asks `isNodeType` about the edge's target and `foo`. The other model rules
still apply.

</details>

Reading an arbitrary target's FLAG would need a field-value accessor this
interface does not expose. `fieldOf` provides a declaration reference, not that
missing operation.

> **Interface gaps found by a cold reader**
>
> These gaps are for the reviewer's judgement.
>
> - There is no `atLeast`, so “at least one R parent” cannot be written.
> - `visible` in record scope is unattested by any example.
> - `el` grammar properties are never shown non-empty.
> - Counting duplicate identical relation occurrences is unspecified.

## Appendix A — Complete examples.nix

The accepted file follows verbatim, including its comments and imports. `field`
and `rel` group constructors; `inherit` brings their names into local scope.
Definitions in a Nix `let` can refer to later definitions, which is how `foo`
can use `sight`.

```nix
# Field and rel only group constructor imports; all authoring calls are bare.
# No semantic prefix: checks read alongside the fields and relations they govern.
let
  dsl = import ./dsl.nix;
  inherit (dsl) el field rel model normalize check on record;
  inherit (field) required str boolean creationDefault;
  inherit (rel) parent child;
  inherit (dsl) parentOf childOf fieldOf isNodeType atMost exactly only;
  inherit (dsl) forest isForest visibility visible canDescend nativeDag;
  inherit (dsl) input projection preserve;

  uid = required (str "UID");
  flag = creationDefault false (required (boolean "FLAG"));

  # The element is the model; constraints are its Meta.
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

  # Both endpoints belong to this bridge record.
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

  # The same role spellings carry no FOO/BAR restrictions here.
  baz = el "BAZ" {} {
    fields = [uid];
    relations = [
      (parent "R" "R_back")
      (child "Q" "Q_back")
    ];
    constraints = [];
  };

  # Only FOO Parent H supplies ancestry; multiple roots are valid.
  h = forest "H" (parentOf foo "H");
  sight = visibility "H-visibility" h {
    closedWhenTrue = fieldOf foo flag;
    ascent = "unrestricted";
    visit = "always";
    expand = "open-or-origin-in-subtree-including-self";
  };

  # Declare the input; acquisition and capture belong to runtime.
  baseline = input "baseline" {
    kind = "external-snapshot";
    required = true;
    complete = true;
  };
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

  # The all-role DAG is independent of the selected forest and visibility.
  rules = [
    (check "native-dag" nativeDag)
    (check "H-forest" (isForest h))
    (check "baseline-preserved" (preserve baseline modeledRecord))
  ];
in
  normalize (model "reference" {
    elements = [foo bar baz];
    views = [h sight];
    inputs = [baseline];
    projections = [modeledRecord];
    constraints = rules;
  })
```

## Appendix B — Every string literal

A **free name** is chosen by the author. A **reference key** repeats a declared
name or selects a named input field. A **fixed keyword** has a specified meaning
for its configuration slot. The table covers every literal occurrence in both
accepted files; repeated uses with the same meaning share a row.

The full specified keyword sets are shown below, but the stub does not enforce
any of these string policy enums. It retains even unrecognized strings without
giving them runtime meaning. The forest name `"H"` names a view, while the role
`"H"` names a Parent relation; their matching spelling is optional. The
projection keyword `"target"` selects a comparison component, while `.target`
accesses a symbolic endpoint.

| String literal                               | Classification                              | Meaning or complete specified value set                                                                                                                                              |
| -------------------------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `"UID"`                                      | Free name                                   | Names the required string field used to address records.                                                                                                                             |
| `"FLAG"`                                     | Free name                                   | Names the Boolean field used by the visibility policy.                                                                                                                               |
| `"FOO"`                                      | Free name                                   | Names the element kind used for the H forest.                                                                                                                                        |
| `"H"`                                        | Free name                                   | Names a Parent relation role on FOO.                                                                                                                                                 |
| `"H_back"`                                   | Free name                                   | Names the reverse display label for Parent H.                                                                                                                                        |
| `"R"`                                        | Free name                                   | Names a Parent relation role on its declaring element.                                                                                                                               |
| `"R_back"`                                   | Free name                                   | Names the reverse display label for Parent R.                                                                                                                                        |
| `"one-H-parent"`                             | Free name                                   | Names the check that limits each FOO to one H parent.                                                                                                                                |
| `"H"`                                        | Reference key                               | Selects FOO's Parent H; `parentOf` references are validated, but for binder collection strings the stub does not validate these today, so a typo is silently accepted.               |
| `"R"`                                        | Reference key                               | Selects the named Parent R on its owner; these `parentOf` references are validated when normalized.                                                                                  |
| `"visible-R"`                                | Free name                                   | Names the check that requires visibility for FOO Parent R.                                                                                                                           |
| `"BAR"`                                      | Free name                                   | Names the bridge element kind.                                                                                                                                                       |
| `"P"`                                        | Free name                                   | Names a Parent relation role on BAR.                                                                                                                                                 |
| `"P_back"`                                   | Free name                                   | Names the reverse display label for Parent P.                                                                                                                                        |
| `"Q"`                                        | Free name                                   | Names a Child relation role on its declaring element.                                                                                                                                |
| `"Q_back"`                                   | Free name                                   | Names the reverse display label for Child Q.                                                                                                                                         |
| `"one-P"`                                    | Free name                                   | Names the check requiring one P on each BAR.                                                                                                                                         |
| `"P"`                                        | Reference key                               | Selects BAR's Parent P; `parentOf` references are validated, but for binder collection strings the stub does not validate these today, so a typo is silently accepted.               |
| `"one-Q"`                                    | Free name                                   | Names the check requiring one Q on each BAR.                                                                                                                                         |
| `"Q"`                                        | Reference key                               | Selects the named Child Q; `childOf` references are validated, but for binder collection strings the stub does not validate these today, so a typo is silently accepted.             |
| `"endpoint-path"`                            | Free name                                   | Names the check requiring a permitted downward path between BAR endpoints.                                                                                                           |
| `"BAZ"`                                      | Free name                                   | Names the element kind with independently scoped R and Q roles.                                                                                                                      |
| `"H"`                                        | Free name                                   | Names the forest view; sharing the role name H is optional.                                                                                                                          |
| `"H-visibility"`                             | Free name                                   | Names the visibility view, which is later referenced through the variable sight.                                                                                                     |
| `"unrestricted"`                             | Fixed keyword (contract; unchecked by stub) | Full specified set for ascent: `"unrestricted"`, permitting every upward H step.                                                                                                     |
| `"always"`                                   | Fixed keyword (contract; unchecked by stub) | Full specified set for visit: `"always"`, permitting arrival at closed nodes.                                                                                                        |
| `"open-or-origin-in-subtree-including-self"` | Fixed keyword (contract; unchecked by stub) | Full specified set for expand: `"open-or-origin-in-subtree-including-self"`, permitting expansion of an open node or a closed node containing the original origin, including itself. |
| `"baseline"`                                 | Free name                                   | Names the external input, which is later referenced through the variable baseline.                                                                                                   |
| `"external-snapshot"`                        | Fixed keyword (contract; unchecked by stub) | Full specified set for input kind: `"external-snapshot"`, an acquired complete external snapshot in this profile.                                                                    |
| `"modeled-record"`                           | Free name                                   | Names the comparison projection.                                                                                                                                                     |
| `"UID"`                                      | Reference key                               | Selects the record identity field for baseline matching; for plain projection keys the stub does not validate these today, so a typo is silently accepted.                           |
| `"nativeType"`                               | Fixed keyword (contract; unchecked by stub) | Full specified relation-component set: `"nativeType"`, `"role"`, `"target"`; nativeType preserves Parent versus Child.                                                               |
| `"role"`                                     | Fixed keyword (contract; unchecked by stub) | Full specified relation-component set: `"nativeType"`, `"role"`, `"target"`; role preserves the authored role name.                                                                  |
| `"target"`                                   | Fixed keyword (contract; unchecked by stub) | Full specified relation-component set: `"nativeType"`, `"role"`, `"target"`; target preserves the declared endpoint identity.                                                        |
| `"set"`                                      | Fixed keyword (contract; unchecked by stub) | Full specified set for relationOrder: `"set"`, ignoring relation declaration order during comparison.                                                                                |
| `"native-dag"`                               | Free name                                   | Names the whole-model native cycle check.                                                                                                                                            |
| `"H-forest"`                                 | Free name                                   | Names the whole-model selected-forest check.                                                                                                                                         |
| `"baseline-preserved"`                       | Free name                                   | Names the whole-model preservation check.                                                                                                                                            |
| `"reference"`                                | Free name                                   | Names the model and therefore its declaration namespace.                                                                                                                             |
| `"target-type"`                              | Free name                                   | Names the same check identity within the selected relation; repeating it does not authorize replacement.                                                                             |
| `"composition"`                              | Free name                                   | Names the separate model used to demonstrate rule composition.                                                                                                                       |
| `"extra-target-check"`                       | Free name                                   | Names the contribution that repeats the equivalent target check.                                                                                                                     |
| `"incompatible-target-check"`                | Free name                                   | Names the contribution that conflicts with the existing target check.                                                                                                                |

The reference profile uses all three `relationProjection` components together.
Arbitrary subsets and extra components have no specified meaning here. The
example supplies true for its configuration switches; storing false does not
establish a specified alternate profile. Unquoted `true` and `false` are Boolean
literals, not strings. Attribute names such as `fields` and variables such as
`foo` are not string literals either. Quoting a variable's name would not obtain
its declaration reference.

## Appendix C — What is real

“Lowered by stub + semantics specified” means the authoring or normalization
operation is concrete. “Lowered by stub, semantics prose only” means the
behavior on records remains a contract. Neither status means graph validation
executes.

| Construct                                              | Status                                | Concrete boundary                                                                                                 |
| ------------------------------------------------------ | ------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `el`                                                   | Lowered by stub + semantics specified | Wraps the native element declaration and retains constraints for later lowering.                                  |
| `model`                                                | Lowered by stub + semantics specified | Supplies declaration-list defaults and the model identity.                                                        |
| `normalize`                                            | Lowered by stub + semantics specified | Builds grammar, metadata, and rule data with the authoring checks described below.                                |
| `check`                                                | Lowered by stub + semantics specified | Retains the check name and lowers its symbolic expression in the supplied scope.                                  |
| `on`                                                   | Lowered by stub + semantics specified | Changes the check subject and scope to the selected relation.                                                     |
| `record`                                               | Lowered by stub + semantics specified | Creates a named symbolic record binder and lowers the callback body.                                              |
| `required`                                             | Lowered by stub + semantics specified | Sets native requiredness and preserves semantic metadata; this stub does not validate records.                    |
| `str`                                                  | Lowered by stub + semantics specified | Delegates native string-field construction; no record values are read.                                            |
| `boolean`                                              | Lowered by stub + semantics specified | Emits the two native choices and their Boolean codec metadata; no runtime decoding occurs.                        |
| `creationDefault`                                      | Lowered by stub + semantics specified | Checks Boolean literal compatibility and records the default; applying it at final absence remains unimplemented. |
| `parent`                                               | Lowered by stub + semantics specified | Retains native Parent grammar and moves optional inline checks into the bundle.                                   |
| `child`                                                | Lowered by stub + semantics specified | Retains native Child grammar and moves optional inline checks into the bundle.                                    |
| `parentOf`                                             | Lowered by stub + semantics specified | Builds a qualified Parent relation reference whose declared identity is checked during lowering.                  |
| `childOf`                                              | Lowered by stub + semantics specified | Builds the corresponding qualified Child reference.                                                               |
| `fieldOf`                                              | Lowered by stub + semantics specified | Builds a field identity from the owner tag and the field title.                                                   |
| `isNodeType`                                           | Lowered by stub, semantics prose only | Emits a type-test expression without inspecting any target record.                                                |
| `atMost`                                               | Lowered by stub, semantics prose only | Emits a count comparison without collecting or counting occurrences.                                              |
| `exactly`                                              | Lowered by stub, semantics prose only | Emits an exact-count expression without computing a count.                                                        |
| `only`                                                 | Lowered by stub, semantics prose only | Emits singleton selection and endpoint access; blocked runtime results are not implemented.                       |
| `forest`                                               | Lowered by stub, semantics prose only | Emits selected edges, owner-kind vertices, parent-to-child orientation, and permission for disconnected roots.    |
| `isForest`                                             | Lowered by stub, semantics prose only | Emits the structural predicate without finding cycles or counting hierarchy parents.                              |
| `visibility`                                           | Lowered by stub, semantics prose only | Emits policy values and fixed path settings without validating keyword choices or executing traversal.            |
| `visible`                                              | Lowered by stub, semantics prose only | Emits the view and two endpoints without computing visibility.                                                    |
| `canDescend`                                           | Lowered by stub, semantics prose only | Emits the downward-path question without evaluating a bridge.                                                     |
| `nativeDag`                                            | Lowered by stub, semantics prose only | Emits an all-role native-graph cycle predicate without running a cycle detector.                                  |
| `input`                                                | Lowered by stub, semantics prose only | Emits the input declaration without provider registration, acquisition, or completeness checking.                 |
| `projection`                                           | Lowered by stub, semantics prose only | Emits selected comparison facts without extracting them from records.                                             |
| `preserve`                                             | Lowered by stub, semantics prose only | Emits preservation and records the referenced input dependency without comparing snapshots.                       |
| `contribute`                                           | Lowered by stub + semantics specified | Adds relation-scoped checks and retains a contribution origin for composition.                                    |
| `const`                                                | Lowered by stub + semantics specified | Accepts exactly Boolean literals and emits their constant predicate representation.                               |
| Relation `edge` binder                                 | Lowered by stub + semantics specified | Exposes symbolic origin and target expressions during normalization.                                              |
| Record `node` or `bridge` binder                       | Lowered by stub + semantics specified | Exposes symbolic Parent and Child collection functions during normalization.                                      |
| Singleton `.target`                                    | Lowered by stub, semantics prose only | Emits endpoint extraction without resolving a runtime relation.                                                   |
| Runtime graph evaluator                                | Not implemented                       | No backend in this stub consumes the predicates to produce graph verdicts.                                        |
| Runtime field-value accessor                           | Not implemented                       | No constructor here reads FLAG from an arbitrary bound node for a new predicate.                                  |
| Runtime default materialization                        | Not implemented                       | No literal is applied to a candidate, and no script default constructor or execution is provided here.            |
| External snapshot acquisition                          | Not implemented                       | No provider command, transport schema, timeout implementation, or snapshot capture runs.                          |
| Prerequisite scheduling and structured blocked results | Not implemented                       | No runtime connects a cardinality finding to a blocked singleton-dependent path check.                            |
| Candidate batching, publication, and recovery          | Not implemented                       | No private candidate, persistence operation, stale-base refusal, or recovery mechanism is wired here.             |
| Explicit rule replacement or disabling                 | Not implemented                       | The contract requires explicit identity-targeted action, but the stub supplies no such authoring constructor.     |
