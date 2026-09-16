# Gate 2 DSL review: readable authoring surface (proposal)

Status: PROPOSAL for the human Gate 2 read, not for main. Produced 2026-09-15 by
a fresh Codex session (gpt-6-astra, xhigh) from a brief that named
`packages/strictdoc-grammar/values.nix` as the shape authority and the Gate 1
contract as the semantics. Evidence level: evaluated stub (`dsl.nix`), no
wiring. `examples.nix` and `composition.nix` evaluate with
`nix-instantiate --eval --strict --json`; see `transcript.txt`. Code first;
explanation follows each block.

[dsl.nix](dsl.nix) imports the existing
[grammar DSL](../../../../../packages/strictdoc-grammar/lib/dsl.nix). `el`,
`field.required`, and `rel.parent/child` are new wrappers preserving their
existing positional forms. `field.str/tag/one/many/mk/raw` and `rel.mk/file/raw`
remain the existing constructors. `boolean`, `creationDefault`, and all check,
selector, view, projection, composition and lowering constructors are new. These
are excerpts of the complete evaluated [examples](examples.nix) and
[composition](composition.nix); constructor imports are bare in both files.

```nix
# D01–D04: fields, relation sugar, and the element-level Meta list.
uid = required (str "UID");
flag = creationDefault false (required (boolean "FLAG"));
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
baz = el "BAZ" {} {
  fields = [uid];
  relations = [
    (parent "R" "R_back")
    (child "Q" "Q_back")
  ];
  constraints = [];
};
```

**Handwritten expectations, not executed** — case IDs throughout refer to
[scenarios.md](../inputs/gate1-contract/scenarios.md).

| Cases        | Expected result                                                                    |
| ------------ | ---------------------------------------------------------------------------------- |
| DFT01, DFT02 | New final absence gets Boolean false; explicit false remains false.                |
| DFT03, DFT05 | Invalid supplied values and existing required absence error; neither is defaulted. |
| G02, G03     | FOO R targeting BAZ rejects; BAZ R targeting FOO remains unrestricted.             |
| G05          | A second distinct H parent rejects, even when the total graph is acyclic.          |

```nix
# D04–D06: ancestry and the boundary policy are named values.
h = forest "H" (parentOf foo "H");
sight = visibility "H-visibility" h {
  closedWhenTrue = fieldOf foo flag;
  ascent = "unrestricted";
  visit = "always";
  expand = "open-or-origin-in-subtree-including-self";
};
```

**Handwritten expectations, not executed**

| Cases         | Expected result                                                                            |
| ------------- | ------------------------------------------------------------------------------------------ |
| G04, G08      | Multiple roots allowed; non-H native parents do not become ancestry.                       |
| T01, T02, T03 | Closed endpoint visible; its descendant hidden externally; opening it restores visibility. |
| T11           | Internal siblings and exits from a closed compartment are visible; cross-root R rejects.   |
| T04, T05      | Boundary or hierarchy edits must revalidate affected unchanged R declarations.             |

```nix
# D03, D05, D06: the bridge binds both endpoint collections.
bar = el "BAR" {} {
  fields = [uid];
  relations = [
    (parent "P" "P_back" (edge: isNodeType edge.target foo))
    (child "Q" "Q_back" (edge: isNodeType edge.target foo))
  ];
  constraints = [
    (check "one-P" (record (bridge: exactly 1 (bridge.parents "P"))))
    (check "one-Q" (record (bridge: exactly 1 (bridge.children "Q"))))
    (check "endpoint-path" (record (bridge: canDescend sight
      (only (bridge.parents "P")).target
      (only (bridge.children "Q")).target)))
  ];
};
```

**Handwritten expectations, not executed**

| Cases         | Expected result                                                                               |
| ------------- | --------------------------------------------------------------------------------------------- |
| B01, B02, B03 | Complete final P/Q state accepts; missing Q rejects; valid replacement accepts.               |
| T06, T07      | F0→F2 accepts; F0→F2a rejects at closed F2.                                                   |
| T08           | Cross-root endpoints reject despite other native connectivity.                                |
| T11           | Closed start F2→F2a accepts; sibling endpoints reject; equal endpoints reject the native DAG. |

```nix
# D07–D10: explicit baseline input and the entire frozen projection.
baseline = input "baseline" {
  kind = "external-snapshot"; required = true; complete = true;
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
rules = [
  (check "native-dag" nativeDag)
  (check "H-forest" (isForest h))
  (check "baseline-preserved" (preserve baseline modeledRecord))
];
```

**Handwritten expectations, not executed**

| Cases              | Expected result                                                                     |
| ------------------ | ----------------------------------------------------------------------------------- |
| E01 (S1), E02 (S0) | Listed FLAG revision rejects; the same edit with an empty baseline accepts.         |
| B04, E04           | Listed UID deletion rejects; a complete empty baseline permits isolated deletion.   |
| E05, B09           | Failed, incomplete or missing required input is an execution/cannot-evaluate error. |
| E06                | Runtime uses captured S1 throughout, even if the source changes to S0.              |
| G07                | A cycle combining H/R/Q rejects under the all-role native DAG.                      |

```nix
# D14: named checks in Meta and external contributions (composition.nix).
targetType = check "target-type" (edge: isNodeType edge.target foo);
baseFoo = el "FOO" {} {
  fields = [uid];
  relations = [(parent "R" "R_back")];
  constraints = [(on (parentOf baseFoo "R") targetType)];
};
declaration = model "composition" { elements = [foo]; };
equivalent = normalize (declaration // {
  contributions = [
    (contribute "extra-target-check" (parentOf foo "R") [targetType])
  ];
});
conflict = normalize (declaration // {
  contributions = [
    (contribute "incompatible-target-check" (parentOf foo "R") [
      (check "target-type" (const false))
    ])
  ];
});
```

**Handwritten expectations, not executed** — the lowering observations are
separately recorded below.

| Cases | Expected result                                                                                   |
| ----- | ------------------------------------------------------------------------------------------------- |
| A10   | Equivalent inline, element-list and external definitions agree; the duplicate keeps both origins. |
| A10   | Same identity with a different meaning throws naming `target-type`.                               |

## Departures and unknowns

- Anonymous inline identity is the enclosing model/element/native-type/role path
  plus `check:predicate`. This avoids a naming wrapper on each short lambda;
  bodies and list positions never determine identity. Explicit
  `check "target-type"` overrides that local name.
- The bridge binder is `bridge`. It binds one BAR record; `only` denotes a
  checked singleton accessor, blocking path evaluation on zero/multiple
  endpoints. Lambdas only construct symbolic data; raw Boolean predicate returns
  throw.
- The element/model `constraints` list is the base. `on` selects a relation
  inside that list; the trailing parenthesized predicate is sugar.
  `sameNormalized` proves equality with `==` on the complete lowered output.
  Reused checks bind separately under each owner.
- Visibility requires one H root and its unique path; descent uses the original
  origin, including a closed start itself. Zero-length reachability is
  conceptual; native cycles still reject. BAR remains two native edges through
  its owner.
- Preservation freezes exactly the listed projection, including existence and
  field presence. Relation sets ignore order; incoming declarations, layout and
  reverse labels are excluded. There is no supersession exception (D08).
- D09–D13 have no runtime implementation here: capture/error handling, final
  candidate batches, dry-run, repair and recovery remain runtime obligations
  (E05–E06, B01–B09). Only the required complete baseline dependency is
  declared; preservation does not consume a `before` snapshot.
- D14 explicit identity-targeted replacement/disable is **not yet expressible**.
  Extension, deduplication and conflict detection are expressible; origins
  retain declaration/contribution labels, not source coordinates.
- Version strings, codecs and metadata digests are provisional. The stub
  supports Boolean literal defaults; native option validation/rendering, general
  script defaults, graph evaluation and dependency scheduling remain
  unimplemented. D15 is excluded.

## Evidence

level = "evaluated stub, no wiring". [transcript.txt](transcript.txt) contains
actual outputs. Commands run from the packet root; exit 1 is intentional in the
two negative probes. No scenario verdict was executed.

| Exact command                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Exit |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| `nix-instantiate --eval --strict --json examples.nix`                                                                                                                                                                                                                                                                                                                                                                                                                     | 0    |
| `nix-instantiate --eval --strict --json -A equivalent composition.nix`                                                                                                                                                                                                                                                                                                                                                                                                    | 0    |
| `nix-instantiate --eval --strict --json -A sameNormalized composition.nix`                                                                                                                                                                                                                                                                                                                                                                                                | 0    |
| `nix-instantiate --eval --strict --json -A deduplicated composition.nix`                                                                                                                                                                                                                                                                                                                                                                                                  | 0    |
| `nix-instantiate --eval --strict --json -A conflict composition.nix`                                                                                                                                                                                                                                                                                                                                                                                                      | 1    |
| `nix-instantiate --eval --strict --json --expr 'let dsl = import dsl.nix; inherit (dsl) el rel check isNodeType model normalize; target = check "target-type" (edge: isNodeType edge.target a); a = el "FOO" {} { relations = [(rel.parent "R" "R_back" target)]; }; b = el "BAZ" {} { relations = [(rel.parent "R" "R_back" target)]; }; lowered = normalize (model "reuse" { elements = [a b]; }); in map (rule: { inherit (rule) id subject; }) lowered.bundle.rules'` | 0    |
| `nix-instantiate --eval --strict --json --expr 'let dsl = import dsl.nix; inherit (dsl) el rel model normalize; foo = el "FOO" {} { relations = [(rel.parent "R" "R_back" (edge: true))]; }; in normalize (model "bad" { elements = [foo]; })'`                                                                                                                                                                                                                           | 1    |

`sameNormalized` and `deduplicated` returned `true`; equivalent composition has
one rule with two origins. The reuse probe emitted distinct FOO/BAZ subjects.
Conflicting definitions named `target-type`; the raw Boolean probe named
`predicate`.

## Self-check

| #   | Requirement                                                                | Result |
| --- | -------------------------------------------------------------------------- | ------ |
| 1   | No function-valued let binding in examples; predicates inline              | PASS   |
| 2   | No dotted attribute path on the left of assignment                         | PASS   |
| 3   | Plain name references, including FOO to itself; no wrapper/self binders    | PASS   |
| 4   | One positional call per relation; trailing predicates parenthesized        | PASS   |
| 5   | Element/model Meta lists and inline sugar; lowered equality proven         | PASS   |
| 6   | Written check names or the specified relation-derived identity             | PASS   |
| 7   | Bare constructors via inherit; import-group prefixes explained at file top | PASS   |
| 8   | Examples and equivalent exit 0; conflict exits 1 naming its check          | PASS   |
| 9   | Only out written; no backend, runners, repository commands or tutorial     | PASS   |
| 10  | Rejected keyed shape never reproduced                                      | PASS   |
