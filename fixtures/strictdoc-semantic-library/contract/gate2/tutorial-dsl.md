# Seven lessons in semantic constraints

`g` means the existing `grammar.dsl`, which constructs native grammar data. `s`
means a **new proposed schema, semantic type and declaration-reference layer**.
`c` means a **NEW proposed constraint DSL** that builds rule descriptions. It is
neither a Nix builtin nor a renamed old `p` API.

The consumer supplies the existing public grammar library as `grammar`. The
proposed authoring function also takes `schema` and `constraint`; those are
prototype inputs, not installed exports. [Setup](setup.md) shows the current
import and the proposed lowering path. All constructor spellings below follow
the [evaluated canonical source](recommended.nix) and remain reviewable.

Each lesson adds one idea. Fragments in lessons 2–6 belong inside the
`s.grammar` callback introduced in lesson 1. Lesson 7 identifies its separate
companion sources. The [complete assembled reference source](recommended.nix)
includes UID declarations, Boolean FLAG, H/R, BAR P/Q, BAZ controls, views,
preservation and the required all-role DAG check. Early lessons deliberately
isolate fewer rules. Lesson 7's alternative representation is separate from that
reference grammar.

**The model tables and diagnostic sentences below are handwritten expectations,
not executed output.** Node labels such as F0 are declared UID values. Unless a
row says otherwise, start again from its lesson's base; do not accumulate the
rows' relations. For the full reference profile, assume a successfully captured,
complete empty protection baseline except in lesson 6.

## 1. Constrain the target of one relation

The idea: a named constraint belongs to a particular declaration. FOO's Parent R
and BAZ's Parent R have different identities.

This complete minimal authoring expression teaches target restriction without a
hierarchy:

```nix
{ grammar, schema, constraint }:
let
  g = grammar.dsl;
  s = schema;
  c = constraint;
  uid = g.field.required (g.field.str "UID");
in
s.grammar "reference" ({ elements, views }: {
  elements.FOO = self: {
    fields = [ uid ];
    relations.R.parent = {
      reverseRole = "R_back";
      constraints.targetType = rel: c.isNodeType rel.target self;
    };
  };
  elements.BAZ = _self: {
    fields = [ uid ];
    relations.R.parent.reverseRole = "R_back";
  };
  constraints.nativeDag = c.nativeDag;
})
```

`self` identifies the enclosing element type. `rel.owner` and `rel.target`
identify symbolic runtime records. Thus `c.isNodeType rel.target self` means
“this endpoint has type FOO,” not “it is the same record as its owner.” The
generated selector retains grammar, owner element, native type and role.

Small model: FOO records `UID=F1a`, `UID=F2`, `UID=I0`; BAZ record `UID=Z0`. No
initial relations.

| Separate candidate                  | Target rule                            | Why                               |
| ----------------------------------- | -------------------------------------- | --------------------------------- |
| F1a owns Parent R targeting F2      | Satisfied                              | Target is FOO.                    |
| F1a owns Parent R targeting Z0      | Violated                               | Target resolves, but is BAZ.      |
| Z0 owns Parent R targeting I0       | Satisfied with no selected occurrences | BAZ's R is independent.           |
| F1a owns Parent R targeting MISSING | Input error                            | No endpoint exists to type-check. |

Concrete diagnostic: “FOO Parent R `targetType`: owner F1a, target Z0; expected
reference/FOO, found reference/BAZ.” Keep the authored relation location with
that witness. A missing UID does not demonstrate wrong-type rejection.

Parent and Child retain native direction:

| Authored fact                         | Directed native edge |
| ------------------------------------- | -------------------- |
| Owner C declares Parent R targeting P | P → C                |
| Owner P declares Child Q targeting C  | P → C                |

A reverse role is a display label; it creates no reciprocal authored
declaration. `nativeDag` checks the union of every Parent/Child role and
element, including BAZ. A selected relation rule cannot substitute for that
whole-graph check. Today's native integration has a named-role cycle gap;
declaring this proposed rule is not proof of enforcement.

Fields stay in the authored list order. The new layer also exposes keyed handles
such as `elements.FOO.fields.UID`; those handles do not sort the field list. The
complete reference adds `elements.FOO.fields.FLAG` in the same way.

A callback constructs data describing a later check. Write
`rel: c.eq rel.owner rel.target` for a runtime identity comparison.
`rel: rel.owner == rel.target` performs Nix equality immediately and returns a
raw Boolean, which the proposed predicate slot must reject. Use explicit
predicate combinators such as `c.allOf`/`c.anyOf` for runtime combinations.
Ordinary Nix `if` remains useful for choosing declarations from actual
configuration values. Use `c.constant true` for an intentional always-true
predicate. `c.sameNodeType rel.owner rel.target` compares endpoint types; `c.eq`
compares record identity. Boolean field defaults are ordinary typed values and
are not rejected by this callback rule.

## 2. Count a collection, including when it is empty

The idea: checking every existing endpoint cannot detect a missing endpoint.
Cardinality examines every selected owner's collection, even an empty one.

Fragment defining an introductory BAR with one endpoint (lesson 5 adds Q and the
path rule):

```nix
elements.BAR = _self: {
  fields = [ uid ];
  relations.P.parent = {
    reverseRole = "P_back";
    cardinality = c.exactly 1;
    constraints.targetType = rel: c.isNodeType rel.target elements.FOO;
  };
};
```

Small model: FOO UIDs F0 and G0, and BAR UID M, with no other relations.

| M's final P collection | Target predicate                | Exactly-one count |
| ---------------------- | ------------------------------- | ----------------- |
| Empty                  | Satisfied over zero occurrences | Violated: 0       |
| P=F0                   | Satisfied                       | Satisfied: 1      |
| P=F0 and P=G0          | Both targets satisfy            | Violated: 2       |

Concrete diagnostic: “BAR M, Parent P: expected exactly 1 endpoint, observed 0.”
It identifies M even though there is no relation location to quote.

A later `c.only` asks for a checked singleton. It does not secretly add
cardinality. If the explicit count fails, the dependent path check is blocked by
that count failure; it must not pick an arbitrary endpoint or produce a
misleading path violation.

## 3. Select a forest without requiring one root

The idea: a hierarchy is a selected graph. Other native relations remain real
connectivity without becoming hierarchy edges.

Fragments, with UID declared on FOO and BAZ as in lesson 1:

```nix
# Inside FOO's element body:
relations.H.parent = {
  reverseRole = "H_back";
  constraints.targetType = rel: c.isNodeType rel.target self;
};

# Inside the enclosing grammar callback:
views.H = c.forest {
  nodes = elements.FOO;
  edges = [ elements.FOO.relations.H.parent ];
};
```

Small model; all labels on the trees are FOO UIDs. Every drawn edge is owned by
its child as Parent H:

```text
F0                 G0       I0       Z0 : BAZ
├── F1
│   └── F1a
└── F2
```

| Separate candidate  | H forest result                                     |
| ------------------- | --------------------------------------------------- |
| Base unchanged      | Satisfied: F0, G0 and isolated I0 are roots.        |
| Add F1a Parent H=F0 | Violated: F1a now has distinct H parents F1 and F0. |
| Add F2 Parent R=F1  | Satisfied: F2 still has only H parent F0.           |
| Add F0 Parent H=F1a | Violated: selected cycle F0 → F1 → F1a → F0.        |

The R row is acyclic and uses the open-field interpretation introduced next. It
gives F2 two native parents, F0 and F1, while preserving one H parent. Document
nesting or file placement adds no H ancestry.

Concrete diagnostic: “H forest: F1a has conflicting selected parents F1 and F0,”
with both H declarations. A selected endpoint outside FOO also invalidates the
forest. A failed forest blocks views that require it; no helper silently repairs
the graph.

Individual role projections can all be acyclic while their union cycles. For
example, fresh FOO A/B and BAZ Z0 can author `A Parent H=B`, `Z0 Parent R=A`,
`Z0 Child Q=B`. The union is `B → A → Z0 → B`. The complete reference declares
BAZ's Q explicitly and requires the separate all-role DAG check.

## 4. Let a closed boundary be reached without exposing its interior

The idea: arrival at a closed node and descent through it are different
operations.

Fragments extending FOO and the selected H view:

```nix
# FOO's ordered field declaration:
fields = [
  uid
  (s.field.boolean "FLAG" {
    required = true;
    default = s.default.literal false;
  })
];

# Grammar-level view:
views.visibility = c.boundaryVisibility {
  hierarchy = views.H;
  closed = node: c.fieldValue node elements.FOO.fields.FLAG;
};

# Alongside FOO R's targetType constraint:
relations.R.parent.constraints.visibleTarget = rel:
  views.visibility.canSee rel.owner rel.target;
```

FLAG is semantically Boolean: false is open; true is closed. The proposed layer
lowers it to native string choices and retains separate encode/decode metadata.
Native `"false"` is decoded as Boolean false; it is not a truthy string. Missing
required FLAG, multiple values, and unknown spellings are input errors. Even
native-accepted placeholders such as TBD/TBC must fail the Boolean decoder. The
default fills only absent fields on new records; it does not repair an existing
missing FLAG.

Small model, with every label a FOO UID and each edge a child-owned Parent H:

```text
F0 false                 G0 false       I0 false
├── F1 false             └── G1 false
│   └── F1a false
└── F2 true
    ├── F2a false
    └── F2b false
```

The origin and target must share an H root. Visibility follows the unique H
path: ascent is unrestricted. On descent it may reach a closed node, but can
continue through that node only if the **original owner** is inside its subtree,
including the closed node itself. Keep that original owner through every nested
boundary.

| Separate R candidate    | Expected result | Relevant path or reason                       |
| ----------------------- | --------------- | --------------------------------------------- |
| F1a R=F2                | Satisfied       | F1a → F1 → F0 → F2; closed endpoint reached.  |
| F1a R=F2a               | Violated        | Same prefix, then forbidden descent F2 → F2a. |
| F1a R=F2a with F2 false | Satisfied       | Opening F2 permits that descent.              |
| F2a R=F2b               | Satisfied       | Original owner is already inside F2.          |
| F2a R=F1a               | Satisfied       | An owner may leave its closed subtree.        |
| F2 R=F1a                | Satisfied       | Closed origin counts as inside itself.        |
| F1a R=G1                | Violated        | Selected roots F0 and G0 differ.              |

Concrete diagnostic: “FOO R `visibleTarget`: owner/original origin F1a, target
F2a; path F1a,F1,F0,F2,F2a; first blocked descent boundary F2 (`FLAG=true`).”
These relation candidates are individually native-acyclic, so the negative row
isolates visibility.

For nested boundaries, add open F2a1 below F2a. F1a cannot see it because F2
blocks descent. Open F2 and close F2a; now F2a is the first blocker. An open
descendant cannot cancel a closed ancestor.

Start instead with F2 open and the valid unchanged relation F1a R=F2a. Closing
F2 must recheck that relation and reject the candidate. Likewise, moving an
already referenced open X from below F1 to below closed F2 can invalidate the
unchanged reference. Constraint placement beside R does not limit evaluation to
edited R edges.

Do not use F2 R=F2a as an independent visibility test: its Parent direction
closes a native cycle through H. Self-reference also fails the native DAG
independently of traversal.

## 5. Keep the intermediate record and check both endpoints

The idea: a bridge has two collections and a record-level path obligation. Both
counts are visible in the declaration.

Complete BAR element fragment inside the reference grammar, using the
FOO/H/visibility definitions above:

```nix
elements.BAR = _self:
  let
    endpoint = reverseRole: {
      inherit reverseRole;
      cardinality = c.exactly 1;
      constraints.targetType = rel: c.isNodeType rel.target elements.FOO;
    };
  in {
    fields = [ uid ];
    relations.P.parent = endpoint "P_back";
    relations.Q.child = endpoint "Q_back";
    constraints.endpointPath = bridge:
      let
        upper = c.only bridge.relations.P.parent;
        lower = c.only bridge.relations.Q.child;
      in
        views.visibility.canDescend upper.target lower.target;
  };
```

`endpoint` is an ordinary reusable Nix function. Each call declares a separate
exactly-one count and target constraint. The record callback runs for every BAR
after its prerequisites hold.

Use lesson 4's forest and a fresh BAR `UID=M` for each row:

| M's final declarations | P count / Q count | Path and complete outcome                       |
| ---------------------- | ----------------- | ----------------------------------------------- |
| P=F0, Q=F2             | 1 / 1             | Satisfied: downward to a closed endpoint.       |
| P=F0, no Q             | 1 / 0             | Count violated; path blocked.                   |
| P=F0, Q=F1 and Q=F2    | 1 / 2             | Count violated; path blocked.                   |
| P=F0, Q=F2a            | 1 / 1             | Violated: cannot descend through F2.            |
| P=F2, Q=F2a            | 1 / 1             | Satisfied: original origin F2 is inside itself. |
| P=F1, Q=F2             | 1 / 1             | Violated: siblings have no downward H path.     |
| P=F0, Q=G1             | 1 / 1             | Violated: different H roots.                    |
| P=F2, Q=F2             | 1 / 1             | Native cycle; counts cannot make it valid.      |

The first row preserves native connectivity:

```text
Authored by M: Parent P=F0, Child Q=F2
Native edges: F0 ──P──> M ──Q──> F2
Selected H:  F0 ───────────────> F2
```

M is never flattened away. F2 has native parents F0 and M, but only F0 is its H
parent. BAZ's P-free shortcut `Z0 Parent R=F0; Z0 Child Q=G1` would add
connectivity without providing an H path to G1.

Concrete diagnostic for P=F0/Q=F2a: “BAR M `endpointPath`: upper F0, lower F2a;
downward H path F0,F2,F2a; expansion blocked at F2 for original origin F0.”
Preserve both M-owned endpoint locations. Target errors, counts, path checks and
native DAG validity remain conjunctive.

## 6. Preserve a specified projection from an identified baseline

The idea: protection compares explicit old facts with candidate facts. It does
not infer history or identity from author text.

Complete preservation fragment inside the reference grammar:

```nix
constraints.preserve = c.preserve {
  baseline = s.baseline "protected";
  projection = c.projection "authored-record/v1" {
    elementType = true;
    fieldsWhenPresent = [ elements.FOO.fields.FLAG ];
    ownedRelations = "set";
  };
};
```

Existence is required for every listed record. The projection compares
grammar/element identity, selected field presence and values, and owned relation
facts as a set. Relation ordering, incoming relations owned elsewhere, document
location, reverse labels and runtime bookkeeping are excluded. This is a
deliberate projection, not whole-document equality.

Small model: FOO `UID=I0, FLAG=false` and BAZ `UID=Z0`, no relations. Readable
baseline notation, **not a JSON encoding claim**:

```text
S1: complete captured baseline; source=protected; model=reference-model
    projection=authored-record/v1; content identity recorded
    (reference-model, I0): element=(reference, FOO)
                          FLAG=present false
                          owned relations={}
S0: complete captured baseline with its own identity and no protected records
```

| Input and separate candidate                | Preservation result                     |
| ------------------------------------------- | --------------------------------------- |
| S1; unchanged I0                            | Satisfied, with a nonempty baseline.    |
| S1; set I0 FLAG=true                        | Violated: selected field changed.       |
| S1; remove I0                               | Violated: protected UID is absent.      |
| S1; add Z0-owned Parent R=I0                | Satisfied: incoming fact belongs to Z0. |
| S1; move I0's document                      | Satisfied: location is excluded.        |
| S0; change or delete isolated I0            | Satisfied; other rules still apply.     |
| Baseline acquisition fails or is incomplete | Error; never substitute S0.             |

Concrete diagnostic: “`preserve`, baseline S1, projection authored-record/v1,
record (reference-model,I0): FLAG changed from present false to present true,”
with old/new evidence. Absence is not an empty value. Renaming the UID does not
preserve the old identity. Supersession creates no implicit exception.

A later S1 capture can invalidate an I0=true candidate that previously passed
under S0, without any new document edit. Once captured, S1 stays fixed for its
evaluation even if the provider changes. Before-state and the protection
baseline are separate inputs. Backend helpers must report an acquisition error
and blocked dependent comparison rather than inventing a Boolean verdict.

## 7. Reuse a rule and make representation choices explicit

The idea: an external contribution uses the same declaration handle and
predicate as an adjacent rule. A different endpoint representation must state
the semantics it keeps.

This **independently complete teaching expression** composes the adjacent bundle
with the external contribution from [composition.nix](composition.nix). Save it
beside [recommended.nix](recommended.nix); its parameters are the same supplied
libraries plus `lib`. The checked composer is the actual bounded prototype API,
not a proposed installed `c.compose` export:

```nix
{ lib, grammar, schema, constraint }:
let
  c = constraint;
  model = import ./recommended.nix { inherit grammar schema constraint; };
  foo = model.elements.FOO;
  subject = foo.relations.R.parent;
  external = c.on subject {
    targetType = rel: c.isNodeType rel.target foo;
  };
  compose = import ./authoring-prototype/compose.nix { inherit lib; };
in
compose {
  contributions = [
    { origin = "adjacent"; bundle = model.normalized.bundle; }
    { origin = "external"; bundle = external; }
  ];
  required = [ "reference/constraint/nativeDag" ];
}
```

The canonical [composition.nix](composition.nix) also supplies a direct
normalized target descriptor and a three-contribution list. Its target rule is
identical to both forms above. Independent bundles reach composition as lists
before Nix attribute merging can erase duplicates. Equal definitions deduplicate
and retain their origins. Different definitions under one ID fail; module order
cannot choose the winner.

Small model: lesson 1's F1a/F2/Z0, with separate F1a R=F2 and F1a R=Z0
candidates. The external form must satisfy the first and violate the second with
the same owner/target/type witness. BAZ's independent R remains unaffected.

Concrete composition diagnostic: “Conflicting definitions for
`reference/element/FOO/relation/Parent/R/constraint/targetType`,” with
adjacent/external provenance showing FOO versus BAZ target definitions. Explicit
replacement/disable uses the inspected original definition digest and must
preserve dependencies. Renaming a declaration key intentionally changes its
exported identity; no alias is retained. See
[the evaluated public shape](authoring-prototype/public-shape.md) for that small
edit API.

Native tailoring reuses counts and target rules without imposing H. This
**complete canonical expression**, [native-tailoring.nix](native-tailoring.nix),
makes both endpoint obligations visible:

```nix
{
  grammar,
  schema,
  constraint,
}: let
  g = grammar.dsl;
  s = schema;
  c = constraint;
  uid = g.field.required (g.field.str "UID");
in
  s.grammar "tailoring" ({elements, ...}: {
    elements = {
      REQUIREMENT = _self: {fields = [uid];};
      STATEMENT = _self: let
        endpoint = reverseRole: {
          inherit reverseRole;
          cardinality = c.exactly 1;
          constraints.targetType = rel: c.isNodeType rel.target elements.REQUIREMENT;
        };
      in {
        fields = [uid];
        relations.P.parent = endpoint "P_back";
        relations.Q.child = endpoint "Q_back";
      };
    };
    constraints.nativeDag = c.nativeDag;
  })
```

Small model: REQUIREMENT UIDs STANDARD-1 and OTS-1; STATEMENT UID ADAPT-1 owns
Parent P=STANDARD-1 and Child Q=OTS-1. Connectivity is
`STANDARD-1 → ADAPT-1 → OTS-1`. No hierarchy is declared, so no common-root or
downward-path policy is added.

| STATEMENT's final endpoints | Expected result                                  |
| --------------------------- | ------------------------------------------------ |
| P=STANDARD-1, Q=OTS-1       | Counts/types satisfied; native graph is acyclic. |
| P=STANDARD-1, no Q          | Q count violated; observed 0.                    |
| P=STANDARD-1, Q=STANDARD-1  | Native cycle through ADAPT-1.                    |

Concrete diagnostic: “STATEMENT ADAPT-1, Child Q: expected exactly 1 endpoint,
observed 0.” The statement remains an intermediate authored record. Nix
lowering/check/render is executed evidence; Scribe enforcement of these rules is
not.

For field endpoints, [field-alternative.nix](field-alternative.nix) is a
separate complete grammar and custom-rule declaration. **Grammar fragment**
inside its `s.grammar "field-alternative"` callback, using the same
`uid = g.field.required (g.field.str "UID")` binding:

```nix
elements = {
  BAR = _self: {
    fields = [
      uid
      (g.field.required (g.field.str "UPPER"))
      (g.field.required (g.field.str "LOWER"))
    ];
  };
  FOO = self: {
    fields = [ uid (s.field.boolean "FLAG" { required = true; }) ];
    relations.H.parent = {
      reverseRole = "H_back";
      constraints.targetType = rel: c.isNodeType rel.target self;
    };
  };
};
views.H = c.forest {
  nodes = elements.FOO;
  edges = [ elements.FOO.relations.H.parent ];
};
constraints.nativeDag = c.nativeDag;
```

**Custom descriptor fragment** from the same source. Here `model` is the result
of that grammar declaration. Its complete descriptor also supplies the candidate
and validated H inputs, and the H-validity prerequisite; the fragment shows the
author's actual choices:

```nix
# Fields within customRule; inputs/needs/after are in the complete source.
id = "field-alternative/endpoint-path";
scope = "model";
contract = "consumer.field-adaptation/v1";
config = {
  records = model.elements.BAR.ref;
  lower = model.elements.BAR.fields.LOWER.ref;
  upper = model.elements.BAR.fields.UPPER.ref;
  targetType = model.elements.FOO.ref;
  endpointValues = "exactly-one-nonempty-uid";
  resolution = "model-wide-uid";
  boundaryField = model.elements.FOO.fields.FLAG.ref;
  path = "downward-original-origin-boundary-visibility";
  virtualConnectivity = {
    shape = "upper-to-record-to-lower";
    cycleCheck = "union-with-all-native-parent-child";
    createAuthoredRelations = false;
  };
};
```

Small model: lesson 4's FOO UID/FLAG values and H edges, now in grammar
`field-alternative`, plus BAR `UID=M, UPPER=F0, LOWER=F2`. BAR declares fields
rather than native P/Q relations.

| Separate field candidate | Expected custom result                      |
| ------------------------ | ------------------------------------------- |
| UPPER=F0, LOWER=F2       | Satisfied: downward path ends at closed F2. |
| UPPER=F0, LOWER=F2a      | Violated at boundary F2.                    |
| LOWER=MISSING            | Resolution error at LOWER.                  |
| UPPER=F2, LOWER=F2       | Virtual union-DAG violation through M.      |

The configured implementation reads exactly one nonempty UID per field, resolves
within the candidate model, checks FOO target types and the original-origin
downward boundary path, then derives `upper → record → lower`. It checks **all**
virtual edges together with every native Parent/Child edge. Per-record cycle
checks could miss a cycle involving several field records. The supplied
prototype lowers this configuration; it does not implement that resolver or
union check.

Concrete diagnostic: “BAR M.LOWER=F2a: path F0,F2,F2a blocked at F2,” with field
location and resolved endpoint identities. Missing/ambiguous resolution is an
input error; an invalid H forest blocks the path.

UID text creates no native link, reverse navigation or compliance export. The
reference owned-relation projection does not freeze UPPER/LOWER; a field-based
consumer must include them explicitly in its protection projection. Custom
Python/Rego logic can implement this contract without translation into a
universal expression language. Configuration, inputs, implementation binding and
structured results still cross the same common interface.

A backend may use ordinary Booleans internally. Its public result must
distinguish satisfied, violated, blocked and error, with rule/evaluation
identity, findings and causes. Exactly one result is required per invoked rule;
missing output or empty findings alone cannot establish success.
[Setup](setup.md#what-the-evidence-establishes) separates the executed helper
controls from that proposed process integration.
