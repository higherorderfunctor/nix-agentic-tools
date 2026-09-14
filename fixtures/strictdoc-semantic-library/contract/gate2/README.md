# Teach your StrictDoc consumer its own rules

Start with a grammar and ordinary StrictDoc documents. Add policies beside the
declarations they constrain, or compose policies over the whole model, a
document, or a change. Choose which implementations run those policies and
whether to validate a private daemon transaction, the Git staged tree, or both.

This walkthrough explains the **Gate 2 proposal**. New `policy` functions,
module options, registrations, and transaction messages below are design syntax,
not installed APIs. Native fixture commands are identified separately. Complete
example inputs and expected decisions show the intended behavior; they do not
claim semantic enforcement already works.

The proposed first implementation uses Python/rustworkx and StrictDoc's native
parsing and checks, initially evaluating the complete candidate. OPA is an
optional adapter for consumers who choose Rego. **Install only enabled backend
dependencies in the consumer package.** A consumer using the graph
implementation must not acquire OPA, Cozo, or every experiment dependency. Cozo
experiments may inform a future optional adapter; Cozo is not selected or
supported by this proposal. Backend evidence and comparisons belong in the
accompanying review material; the rest of this page teaches what a consumer
would write and observe.

## Start with the existing native fixture

**Existing native commands, run from the retained fixture directory.** If your
shell is in this README's `contract/gate2` directory, first run `cd ../..`.
These refresh the filtered public toolchain, generate its current grammar, and
load the small native workspace. They do not activate the proposed policy
library.

```bash
bash bootstrap.sh
bash tests/devenv.sh tasks run generate:sgra
bash tests/devenv.sh up -d scribe
bash tests/devenv.sh shell -- scribe-client --root "$PWD" ping
bash tests/devenv.sh shell -- scribe --root "$PWD" check
bash tests/devenv.sh shell -- scribe --root "$PWD" show F0
bash tests/devenv.sh shell -- scribe-client --root "$PWD" info
```

Detached startup may finish before readiness. Retry ping within a bounded
startup window and continue only after the exact fixture root answers. The
wrapper clears inherited development-shell/root variables and invokes ordinary
devenv from this directory. Bash, Nix, and devenv are prerequisites; the fixture
uses the normal shared host/store and a filtered dependency.

The empty seed document imports the generated grammar so native `new` has a
loaded grammar to use. An empty running daemon alone is insufficient. On the
fixture's fresh base, these **existing native mutations** illustrate ownership:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" new BAR --uid M --path documents/M.sdoc --relate P=F0 --relate Q=F2
bash tests/devenv.sh shell -- scribe --root "$PWD" relate F1a --role R --target F2
```

The expected authored facts are M-owned Parent P targeting F0, M-owned Child Q
targeting F2, and F1a-owned Parent R targeting F2. M remains an intermediate
node, giving `F0 → M → F2`. These separate writes are not a grouped transaction.
The fixture's retained snapshots and native probes document current behavior;
native success does not prove target, visibility, or preservation enforcement.

For present-runtime cleanup, remove owned relations before deleting M:

```bash
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate F1a --role R --target F2
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate M --role Q --target F2
bash tests/devenv.sh shell -- scribe --root "$PWD" unrelate M --role P --target F0
bash tests/devenv.sh shell -- scribe --root "$PWD" delete M
bash tests/devenv.sh down
```

The current source consumer is small enough to show inline. Its
[devenv.yaml](../../devenv.yaml) selects the filtered local toolchain refreshed
by bootstrap and pinned native devenv/nixpkgs inputs:

```yaml
inputs:
  devenv:
    url: github:cachix/devenv/190959a9a4bb52d4802f076a90c3c4e3aa2e6fa2
  library:
    url: path:./.toolchain
  nixpkgs:
    url: github:NixOS/nixpkgs/c043004d1c6985732bcc1cbc5a9c9aecbbb4e0f0
```

Its complete [devenv.nix](../../devenv.nix) imports the public module and passes
normalized grammar elements to the ordinary grammar output:

```nix
{inputs, lib, pkgs, ...}: let
  grammar = inputs.library.lib.ai.strictdocGrammar {inherit lib;};
in {
  imports = [inputs.library.devenvModules.nix-agentic-tools];
  ai.strictdoc = {
    enable = true;
    package = inputs.library.packages.${pkgs.stdenv.hostPlatform.system}.strictdoc;
    grammars.fixture = {
      elements = import ./grammar.nix {inherit (grammar) dsl;};
      target = "grammar.sgra";
    };
  };
}
```

The retained [grammar.nix](../../grammar.nix) is the complete existing fixture
source. It includes temporary repository-field requirements and a historical
string encoding of FLAG. Those accommodations explain current fixture operation;
they are not the neutral typed-field design taught below.

The complete empty [seed.sdoc](../../documents/seed.sdoc) supplies the native
import used by the fixture:

```text
[DOCUMENT]
TITLE: Neutral fixture grammar seed

[GRAMMAR]
IMPORT_FROM_FILE: @repo
```

Keep the fixture's root/document configuration while reproducing its commands.
Bootstrap refreshes `.toolchain` and the native lock; restart the daemon after a
toolchain refresh. Grammar changes require regeneration and explicit reload or
restart. Generated grammar/toolchain artifacts are not implementation sources.

## Define the grammar before adding policy

The public grammar DSL already returns normalized Nix attribute sets. Start with
those constructors. This **existing normalized grammar expression** defines an
ordinary string-valued workflow status; `grammar` is the public library argument
supplied by the consumer's existing toolchain integration:

```nix
{grammar}: let
  g = grammar.dsl;
in {
  elements = [
    (g.el "TASK" {} {
      fields = [
        (g.field.required (g.field.str "UID"))
        (g.field.required (g.field.one "STATUS" ["pending" "complete"]))
      ];
    })
  ];
}
```

`g.el` and `g.field.*` produce normalized data; they are not a bypass into a
separate raw grammar interface. `g.field.required` sets a Nix Boolean
`required = true`. The existing emission chain denormalizes that property and
writes this grammar line:

```text
REQUIRED: True
```

That Boolean means “the field is required.” It does not mean “the document
field's value is Boolean.” STATUS above is intentionally a string choice and is
authored as a string. Its complete record body is:

```text
[TASK]
UID: TASK-1
STATUS: pending
```

Use the document/import header shown in the seed before this record when the
consumer binds its generated TASK grammar to the same import. This separate TASK
expression illustrates the native DSL and has not been installed and exercised
as a fresh Scribe consumer here. The retained fixture above supplies the
existing complete runnable source. With no native relations on an element, omit
relations or use null: an empty relations list fails normalized validation.

The current public constructors are `many`, `mk`, `one`, `raw`, `required`,
`str`, and `tag`. The coordinator's bounded source/evaluation check found no
Boolean document-field constructor or `__functor`. Boolean `required` and
`isComposite` values pass normalized validation; their string versions fail.
Choice lists accept strings and reject Boolean values. `raw` is an identity
helper whose output still undergoes normalized validation. The emitter's Boolean
encoding for required/composite grammar properties is not decoding SDoc fields.

**Unresolved required interface: Boolean-valued document fields.** The reference
lessons below use FOO's desired Boolean FLAG: false means open, true means
closed. The earlier fixture used string choices as a research accommodation.
That is not the desired typed consumer contract, and this walkthrough does not
replace a missing Boolean API with that string convention.

Before the reference grammar becomes a complete consumer example, the interface
must specify its Boolean field constructor, native representation, encode/decode
behavior, invalid-input handling, and preservation through semantic extraction.
The proposed shared snapshot currently has string-only field lists and the
boundary descriptor has string sets; both must be reconciled with this typed
requirement. Arbitrary semantic metadata cannot be inserted into the existing
normalized native field schema: its validation rejects that extension. Any
future typed metadata must survive through a reviewed layer before native
lowering. No new constructor, option, schema, or wrapper name is chosen in this
draft.

Once that gap is settled, the complete reference definition must include FOO
with required UID/Boolean FLAG and Parent H/R; BAR with UID, Parent P and Child
Q; and BAZ with UID and its own Parent R/Child Q. Every addressable element
needs UID explicitly declared. The definition must show both Boolean document
values and their extracted typed values. A field named FLAG has no automatic
visibility meaning; the consumer chooses that policy separately.

The proposed adjacent wrapper's `native = ...` accepts an existing normalized
element value. Its name does not require raw syntax or an alternate grammar API.
For example, a wrapper can contain `g.el "TASK" ...` from the expression above
while collecting policies separately. The current fixture's temporary repository
field requirements must not be copied into the neutral consumer design.

## Add one scoped target rule

**Proposed policy definition.** This complete rule expression accepts the
proposed `policy` library as its sole argument. It restricts FOO's Parent R in
grammar `reference`; another element's R remains independent.

```nix
{policy}: let
  p = policy;
  foo = {grammar = "reference"; element = "FOO";};
  r = {
    grammar = "reference";
    ownerElement = "FOO";
    nativeType = "Parent";
    role = "R";
  };
in
  p.targets {
    id = "reference/R-target";
    select = r;
    allowed = [foo];
  }
```

Here is the complete adjacent alternative, including its grammar and element
bindings. **Proposed policy wrappers around existing normalized grammar DSL
values**; this small grammar teaches just target selection and does not yet
include the forest or Boolean field:

```nix
{grammar, policy}: let
  g = grammar.dsl;
  p = policy;
  foo = {grammar = "reference"; element = "FOO";};
  uid = g.field.required (g.field.str "UID");
in
  p.grammar {
    id = "reference";
    elements = [
      (p.element {
        native = g.el "FOO" {} {
          fields = [uid];
          relations = [(g.rel.parent "R" "R_back")];
        };
        policies = self: [
          (p.targets {
            id = "reference/R-target";
            select = self.parent "R";
            allowed = [foo];
          })
        ];
      })
      (g.el "BAZ" {} {
        fields = [uid];
        relations = [(g.rel.parent "R" "R_back")];
      })
    ];
  }
```

`native` receives the normalized value returned by `g.el`; it does not demand
raw grammar syntax or bypass type checks. `self.parent "R"` supplies exactly the
selector written above. `p.grammar` returns native `elements` and a separate
`bundle` of the adjacent rules. It must not insert policy keys into the
generated StrictDoc grammar.

For this lesson the complete logical input consists of three FOO records F1a,
F2, and I0, and one BAZ Z0, all resolved within the same model. Each row below
is a separate candidate containing only its listed relation; there are no other
relations to create a cycle or hide a target error.

| Candidate authored declaration | Expected target-rule result                            |
| ------------------------------ | ------------------------------------------------------ |
| F1a owns Parent R → F2         | Satisfied: resolved target is reference/FOO            |
| F1a owns Parent R → Z0         | Violated: expected reference/FOO, actual reference/BAZ |
| Z0 owns Parent R → I0          | Satisfied: no FOO-owned Parent R subjects              |
| F1a owns Parent R → MISSING    | Input error: endpoint resolution failed                |

The wrong-type finding must identify the full selector, F1a as owner, Z0 as
target, and expected/actual element types. A missing UID is a different problem
and cannot stand in for this negative test.

Consumers can author the same rule without the helper. **Proposed direct
descriptor, alternative to the preceding definition:**

```nix
{
  id = "reference/R-target";
  scope = "model";
  contract = "sdoc-policy.targets/v1";
  config = {
    select = {
      grammar = "reference";
      ownerElement = "FOO";
      nativeType = "Parent";
      role = "R";
    };
    allowed = [{grammar = "reference"; element = "FOO";}];
  };
  inputs.candidate = {
    from = "candidate";
    schema = "sdoc-policy.model/v1";
  };
  needs = ["model.resolved-endpoints/v1"];
}
```

Choose the helper or the direct definition. Defining the same ID differently
twice is a configuration error, not a module-order override.

## Select a hierarchy, then define visibility

Consider this complete logical base. All drawn edges are authored on the child
as Parent H. FLAG is false/open except F2, which is true/closed. Z0 is BAZ; the
other records are FOO. There are initially no R declarations and no BARs.

```text
F0 (open)                 G0 (open)       I0 (open)       Z0 : BAZ
├── F1 (open)             └── G1 (open)
│   └── F1a (open)
└── F2 (closed)
    ├── F2a (open)
    └── F2b (open)
```

**Proposed forest definition:**

```nix
{policy}: policy.forest {
  id = "reference/H";
  nodes = {grammar = "reference"; element = "FOO";};
  select = [{
    grammar = "reference";
    ownerElement = "FOO";
    nativeType = "Parent";
    role = "H";
  }];
}
```

This produces the `reference/H/valid` rule and `reference/H` view. The rule
requires selected endpoints to be members, no selected cycle, and at most one
distinct selected parent per node. Multiple trees and isolated roots are valid.
The view is usable only after that rule succeeds; it cannot repair an invalid
projection silently.

F1a already has selected parent F1. Adding H → F0 gives it two selected parents
and must identify both. Adding BAR M with P=F0/Q=F2 instead gives F2 another
native parent while leaving its single H parent unchanged. SDoc file placement
and document nesting do not add ancestry.

Also require this **proposed all-role model rule** in every active composition:

```nix
{
  id = "reference/native-dag";
  scope = "model";
  contract = "sdoc-policy.native-dag/v1";
  config = {};
  inputs.candidate = {
    from = "candidate";
    schema = "sdoc-policy.model/v1";
  };
  needs = ["model.resolved-parent-child/v1" "native.all-role-dag/v1"];
}
```

It checks all Parent/Child roles and elements, including cycles assembled from
different individually acyclic role projections. The review packet records a
named-role gap in the pinned native integration; invoking today's native check
alone does not prove this guarantee. The intended implementation repairs/reuses
native validation and must qualify the complete-candidate Scribe path.

A consumer may select Child authoring instead: a parent owns Child H targeting
its child, and the selector's nativeType is Child. The resulting parent-to-child
forest can be the same. Authored ownership is different and matters later for
protection. Reverse display names manufacture no reciprocal declarations.

For visibility, attach `p.visible { id; select; hierarchy; boundary; }` to R,
using this forest's view and an explicit Boolean FLAG mapping. **The precise
typed boundary declaration is held with the Boolean API correction.** The
behavior itself is concrete:

1. Find the original owner's and declared target's selected roots. Different
   roots violate the rule; native links under other roles are not shortcuts.
2. Follow their unique undirected selected path. Ascent is unrestricted.
3. During descent, allow arrival at a closed node. Expand that node only if the
   original owner lies in its selected subtree, including the node itself.
4. Apply the same test at every deeper boundary. Preserve the original owner
   throughout traversal; do not substitute the current path node.

Run each row against a fresh base unless the row supplies a different state:

| Candidate                  | Expected complete outcome and evidence                       |
| -------------------------- | ------------------------------------------------------------ |
| F1a R → F2                 | Accept; path F1a,F1,F0,F2 ends at closed boundary            |
| F1a R → F2a                | Reject; first blocked expansion is F2                        |
| Same relation with F2 open | Accept; path continues through F2                            |
| F2a R → F2b                | Accept; original owner is inside F2                          |
| F2a R → F1a                | Accept; owner may leave its closed compartment               |
| F2 R → F1a                 | Accept; closed start is inside its own boundary              |
| F1a R → G1                 | Reject; roots F0 and G0 differ                               |
| F2 R → F2                  | Reject native self-cycle                                     |
| F2 R → F2a                 | Reject native cycle; this cannot isolate visibility behavior |

Now start with F2 open and a valid F1a R → F2a already installed. Closing F2
must recheck that unchanged R and refuse the candidate. Similarly, start with X
under F1 and F1a R → X; moving X under closed F2 makes the unchanged R invalid.
The diagnostic must name the R owner and changed boundary or hierarchy edge.

An open descendant behind a closed ancestor remains hidden. Add open F2a1 under
F2a: an external path is first blocked at F2. Open F2 and close F2a: the same
path is now first blocked at F2a. There is no semantic depth cap; resource
exhaustion is an execution error. Depth 1, 3, and 12 cases need positive
controls and interior-boundary negatives only where an interior actually exists.

## Model tailoring with native Parent and Child

A standard requirement can remain unchanged while an adaptation statement links
it to an immutable OTS requirement. **Proposed complete document**, using the
fixture's native import convention with the generated tailoring grammar assigned
to that import:

```text
[DOCUMENT]
TITLE: Deployment tailoring

[GRAMMAR]
IMPORT_FROM_FILE: @repo

[REQUIREMENT]
UID: STANDARD-1
STATEMENT: The deployment shall retain diagnostic records.

[REQUIREMENT]
UID: OTS-1
STATEMENT: The supplied appliance retains records for thirty days.

[ADAPTATION]
UID: ADAPT-1
STATEMENT: Use the appliance retention capability for this deployment.
RELATIONS:
- TYPE: Parent
  VALUE: STANDARD-1
  ROLE: Adapts
- TYPE: Child
  VALUE: OTS-1
  ROLE: AppliesTo
```

The complete grammar expression uses the existing normalized constructors.
REQUIREMENT has no relations, so its declaration omits that attribute:

```nix
{grammar}: let
  g = grammar.dsl;
  uid = g.field.required (g.field.str "UID");
in {
  elements = [
    (g.el "REQUIREMENT" {} {
      fields = [uid (g.field.str "STATEMENT")];
    })
    (g.el "ADAPTATION" {} {
      fields = [uid (g.field.str "STATEMENT")];
      relations = [
        (g.rel.parent "Adapts" "AdaptedBy")
        (g.rel.child "AppliesTo" "AppliedBy")
      ];
    })
  ];
}
```

Pass these elements to the consumer's native grammar output and bind the
resulting grammar to the document import shown above. The adaptation owns both
declarations. Native connectivity stays `STANDARD-1 → ADAPT-1 → OTS-1`; it is
not flattened to an endpoint-only edge. These native constructors exist today;
this neutral tailoring example still needs later Scribe integration
verification.

**Complete proposed policy bundle for those native elements:**

```nix
{policy}: let
  p = policy;
  requirement = {grammar = "tailoring"; element = "REQUIREMENT";};
  records = {grammar = "tailoring"; element = "ADAPTATION";};
  upper = {
    grammar = "tailoring";
    ownerElement = "ADAPTATION";
    nativeType = "Parent";
    role = "Adapts";
  };
  lower = upper // {nativeType = "Child"; role = "AppliesTo";};
in
  p.bundle {
    id = "tailoring/policy";
    includes = [
      (p.bridge {id = "tailoring/endpoints"; inherit records upper lower;})
    ];
    rules = [
      (p.targets {id = "tailoring/upper-target"; select = upper; allowed = [requirement];})
      (p.targets {id = "tailoring/lower-target"; select = lower; allowed = [requirement];})
      {
        id = "tailoring/native-dag";
        scope = "model";
        contract = "sdoc-policy.native-dag/v1";
        config = {};
        inputs.candidate = {from = "candidate"; schema = "sdoc-policy.model/v1";};
        needs = ["model.resolved-parent-child/v1" "native.all-role-dag/v1"];
      }
    ];
  }
```

Without a hierarchy argument, bridge supplies exactly-one upper and lower count
rules. The three-record example passes; removing AppliesTo from its final state
fails `tailoring/endpoints/lower-count` with observed count zero. A second lower
endpoint fails with count two. Using the same upper/lower UID makes a native
cycle. A common selected hierarchy is not inherent in tailoring.

For the reference BAR instead, the consumer deliberately supplies H and FLAG to
`p.bridge`. Its upper/lower selectors are BAR Parent P and BAR Child Q. These
add a downward endpoint-path rule after the two counts:

| Fresh-base BAR candidate | Expected result                           |
| ------------------------ | ----------------------------------------- |
| M: P=F0, Q=F2            | Accept downward path to a closed endpoint |
| M: P=F0, Q=F2a           | Reject expansion at F2                    |
| M: P=F2, Q=F2a           | Accept; upper endpoint is a closed start  |
| M: P=F1, Q=F2            | Reject; sibling endpoint is not downward  |
| M: P=F0, Q=G1            | Reject; different selected roots          |
| M: P=F2, Q=F2            | Reject native cycle                       |

A BAZ-owned native shortcut from F0 through Z0 to G1 changes none of those H
paths. Target/count/path/native rules are conjunctive: success in one does not
waive another.

## Choose fields when you want custom representation

Ordinary fields are another consumer choice. **Complete logical input added to
the reference base**, under a grammar declaring required string UPPER_UID and
LOWER_UID and no native relations on ADAPTATION_FIELDS:

```text
[DOCUMENT]
TITLE: Field-based deployment tailoring

[GRAMMAR]
IMPORT_FROM_FILE: @repo

[ADAPTATION_FIELDS]
UID: ADAPT-FIELDS-1
STATEMENT: Check this deployment adaptation through field policy.
UPPER_UID: F0
LOWER_UID: F2
```

The proposed custom rule's configuration is explicit:

```nix
{
  records = {grammar = "field-tailoring"; element = "ADAPTATION_FIELDS";};
  upperField = "UPPER_UID";
  lowerField = "LOWER_UID";
  endpointModel = "reference-model";
  allowed = [{grammar = "reference"; element = "FOO";}];
  path = "downward";
  virtualConnectivity = "check-union-DAG";
}
```

The final custom descriptor also binds candidate and validated H inputs and the
corrected FLAG boundary mapping. Its contract is consumer.field-adaptation/v1,
scope is model, and it requires field-path diagnostics. No core code recognizes
these element or field names specially.

Here is the full decision procedure the consumer program must implement; these
are algorithm steps, not opaque calls to a hidden fixture evaluator:

1. Visit every record selected by the configured grammar and element. Require
   exactly one upper and lower field value. Resolve both in endpointModel;
   missing or ambiguous UIDs are input errors. Record source field locations.
2. Compare both resolved element references to allowed. A resolvable wrong type
   produces a policy finding at the corresponding field.
3. From the lower endpoint, repeatedly follow its unique H parent, recording the
   path, until reaching the upper endpoint or a root. A root reached first means
   no downward path. An invalid H view blocks this step.
4. Reverse the recorded path. For each node with a next descent step, apply the
   FLAG test from the visibility lesson using the upper endpoint as original
   origin. A closed final node is visitable. Report the first blocked expansion
   with the field, endpoints, path, and boundary.
5. For every field record, derive upper → record → lower edges with field
   provenance. Union them with all native Parent/Child edges. Repeatedly remove
   zero-incoming-degree nodes and decrement their outgoing neighbors' counts. If
   edges remain after no more nodes can be removed, find a cycle in the residual
   graph and report its native/field origins. Checking only each new record
   separately can miss cycles made by multiple field records.
6. Return one complete result for the rule's entire selected set, including the
   zero-record case. Preserve errors and blocked prerequisites as such.

F0/F2 passes. Changing LOWER_UID to F2a fails at F2. Changing it to MISSING
errors in resolution. F2/F2 fails the union DAG. These claims concern endpoint,
path, and union-cycle policy. The fields do not create native links, reverse
navigation, compliance exports, or the same owned-relation protection
projection. Include these fields explicitly if the consumer wants them frozen.

## Supply your own decision logic through the public adapter route

A packaged helper must not have privileged access unavailable to a consumer
program. To see the extension boundary without hiding its logic, this is a
**standalone educational Python decision body**, using small local dictionaries.
Its `nodes` and `relations` are an explanatory input shape, not the proposed
shared model or runner wire schema.

```python
def target_findings(nodes, relations, selector, allowed):
    findings = []
    for relation in relations:
        owner = nodes[relation["owner"]]
        actual_selector = (
            owner["grammar"], owner["element"],
            relation["nativeType"], relation["role"],
        )
        if actual_selector != selector:
            continue
        if relation["target"] not in nodes:
            raise ValueError("unresolved target: " + relation["target"])
        target = nodes[relation["target"]]
        actual_type = (target["grammar"], target["element"])
        if actual_type not in allowed:
            findings.append({
                "owner": relation["owner"],
                "target": relation["target"],
                "selector": selector,
                "expected": sorted(allowed),
                "actual": actual_type,
            })
    return findings


nodes = {
    "F1a": {"grammar": "reference", "element": "FOO"},
    "F2": {"grammar": "reference", "element": "FOO"},
    "I0": {"grammar": "reference", "element": "FOO"},
    "Z0": {"grammar": "reference", "element": "BAZ"},
}
selector = ("reference", "FOO", "Parent", "R")
allowed = {("reference", "FOO")}
for owner, target in [("F1a", "F2"), ("F1a", "Z0"), ("Z0", "I0")]:
    relation = {"owner": owner, "target": target, "nativeType": "Parent", "role": "R"}
    print(target_findings(nodes, [relation], selector, allowed))
```

Expected output:

```text
[]
[{'owner': 'F1a', 'target': 'Z0', 'selector': ('reference', 'FOO', 'Parent', 'R'), 'expected': [('reference', 'FOO')], 'actual': ('reference', 'BAZ')}]
[]
```

This explains the decision, including the same-role positive control. A real
public adapter must additionally consume the frozen shared model, preserve
model-wide UID identity and locations, validate schemas, implement the runner,
and produce complete structured rule results. A bare list is not that protocol.
Native input validation still rejects unresolved endpoints outside this selected
rule; the tiny function is not a replacement for model capture or native checks.

**Complete proposed registration expression**, parameterized by the actual
consumer tool artifact and executable path that will exist after implementation:

```nix
{artifact, executable}: {
  kind = "implementation";
  id = "consumer/checks";
  inherit artifact;
  runner = {
    protocol = "sdoc-policy.runner/v1";
    argv = [executable];
    limits = {timeoutMs = 10000; outputBytes = 16777216;};
  };
  entries = [{
    name = "targets";
    contract = "sdoc-policy.targets/v1";
    inputSchemas.candidate = "sdoc-policy.model/v1";
    configSchema = "sdoc-policy.targets-config/v1";
    resultSchema = "sdoc-policy.rule-result/v1";
    capabilities = ["model.resolved-endpoints/v1"];
    mode = "full";
  }];
}
```

Bind it to the rule with
`{ rule = "reference/R-target"; implementation = "consumer/checks"; entry = "targets"; }`.
The default shipped graph adapter uses the same registration and binding rules.
No core branch should special-case either ID.

The process protocol proposes one JSON request on stdin and one JSON response on
stdout per invocation. `describe` identifies entries and schemas; `plan`
accounts for every assigned invocation; `evaluate` returns one result per rule.
Nonzero exit, timeout, extra/malformed output, mismatched request ID, overflow,
missing result, unsupported schema/capability, and incomplete witnesses are
errors. Empty output and a Boolean alone are not proof of complete evaluation.
The exact schemas still need freezing; this page does not invent an executable
adapter envelope to conceal that gap.

For a consumer who wants native Rego, the existing
[standalone experimental policy](research/experiments/scripts/policy.rego)
contains the traversal itself. Here is the complete small policy, including
contextual selection, normalization, adjacency, and the result entrypoint:

```rego
package gate2

import rego.v1

# Authored ownership and contextual relation selectors remain input facts.
selected(r) if {
	r.model == input.hierarchy.model
	r.owner_type == input.hierarchy.owner_type
	r.kind == input.hierarchy.kind
	r.role == input.hierarchy.role
}

endpoints(r) := [r.target, r.owner] if r.kind == "Parent"
endpoints(r) := [r.owner, r.target] if r.kind == "Child"

parents := {n: {p | some r in input.relations; selected(r); [p, c] := endpoints(r); c == n} |
	some n in object.keys(input.nodes)
}

children := {n: {c | some r in input.relations; selected(r); [p, c] := endpoints(r); p == n} |
	some n in object.keys(input.nodes)
}

inside(origin, boundary) if boundary in graph.reachable(parents, {origin})

expand(_, node) if input.nodes[node].closed == false
expand(origin, node) if inside(origin, node)

# Two comprehensions avoid a quadratic all-node cross product.
adjacency(q) := {n: union({up, down}) |
	some n in object.keys(input.nodes)
	up := {p | q.mode == "visible"; some p in parents[n]}
	down := {c | expand(q.origin, n); some c in children[n]}
}

answers := {q.id: answer |
	some q in input.queries
	reachable := graph.reachable(adjacency(q), {q.origin})
	answer := q.target in reachable
}

protection contains uid if {
	some uid, old in input.snapshot.records
	object.get(input.projection, uid, null) != old
}

result := {
	"answers": answers, "protected_changes": protection,
	"snapshot": input.snapshot.id,
}
```

Parents/children match the hierarchy's model, owner type, native kind, and role,
then normalize Parent as target → owner and Child as owner → target. Use this
complete small **experimental JSON input**, which is distinct from the proposed
public model:

```json
{
  "hierarchy": {
    "kind": "Parent",
    "model": "reference-model",
    "owner_type": "FOO",
    "role": "H"
  },
  "nodes": {
    "F0": { "closed": false },
    "F2": { "closed": true },
    "F2a": { "closed": false }
  },
  "projection": {},
  "queries": [
    { "id": "endpoint", "mode": "downward", "origin": "F0", "target": "F2" },
    { "id": "interior", "mode": "downward", "origin": "F0", "target": "F2a" },
    { "id": "inside", "mode": "downward", "origin": "F2", "target": "F2a" }
  ],
  "relations": [
    {
      "kind": "Parent",
      "model": "reference-model",
      "owner": "F2",
      "owner_type": "FOO",
      "role": "H",
      "target": "F0"
    },
    {
      "kind": "Parent",
      "model": "reference-model",
      "owner": "F2a",
      "owner_type": "FOO",
      "role": "H",
      "target": "F2"
    }
  ],
  "snapshot": { "id": "S0", "records": {} }
}
```

Expected `data.gate2.result` value:

```json
{
  "answers": { "endpoint": true, "inside": true, "interior": false },
  "protected_changes": [],
  "snapshot": "S0"
}
```

This demonstrates executable-native Boolean data and query semantics inside an
experiment. It does not supply the missing normalized Boolean document-field
API, public model codec, complete diagnostics, or Scribe enforcement.

The proposed public OPA registration uses the same mechanism as the independent
Python tool. Here is the whole descriptor and binding expression; its supplied
artifacts are future packaged values, not files claimed to exist today:

```nix
{regoArtifact, adapterExecutable}: let
  contract = "consumer.rego-visibility/v1";
  registration = {
    kind = "implementation";
    id = "consumer/opa";
    artifact = regoArtifact;
    runner = {
      protocol = "sdoc-policy.runner/v1";
      argv = [adapterExecutable];
      limits = {timeoutMs = 10000; outputBytes = 16777216;};
    };
    entries = [{
      name = "data.consumer.visibility.result";
      inherit contract;
      inputSchemas = {
        candidate = "sdoc-policy.model/v1";
        hierarchy = "sdoc-policy.forest/v1";
      };
      configSchema = "consumer.rego-visibility-config/v1";
      resultSchema = "sdoc-policy.rule-result/v1";
      capabilities = ["diagnostic.boundary-path/v1" "opa.graph-reachable/v1"];
      mode = "full";
    }];
  };
in {
  inherit registration;
  binding = {
    inherit contract;
    implementation = registration.id;
    entry = "data.consumer.visibility.result";
  };
}
```

A matching consumer rule declares that contract, candidate and validated forest
inputs, its selector, and the reviewed boundary mapping. Replace the old rule
explicitly as shown in the composition lesson. The proposed
`data.consumer.visibility.result` is a future consumer entrypoint; it is not the
experiment's `data.gate2.result`. Translating the public envelope and producing
its required witnesses is adapter work still to do. A claimed capability is not
proof that this work already exists.

Require strict built-in errors and validate the complete decision: undefined
output is an error. Bun/Wasm delivery needs its own qualification. A consumer
can retain native Rego instead of translating it into a universal library
language. The existing
[Cozo program](research/experiments/scripts/traversal.cozo) also carries the
original query identity through recursive traversal and is a concrete
experimental alternative. An eventual optional Cozo adapter remains possible; it
is not selected or qualified here.

To reproduce the existing backend experiments, from `contract/gate2` copy the
packet to scratch first. **Existing standalone research workflow**, requiring
uv, Python, Bun, network access, and the recorded Linux amd64 environment:

```bash
#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
packet="$PWD/research"
scratch=$(mktemp -d -t strictdoc-gate2-replay.XXXXXXXX)
cp -a "$packet/experiments" "$scratch/experiments"
bash "$scratch/experiments/scripts/setup.sh"
bash "$scratch/experiments/scripts/run.sh" --backends
```

The runner covers more than this small input and installs experiment
dependencies inside the scratch copy. Never run setup inside the retained
packet. The [reproduction record](research/reproduce.md) distinguishes executed
replay from fresh-install limits. These research dependencies do not define the
consumer package closure; enabled-only packaging below remains required.

## Capture external facts and define what protection means

Preservation compares a candidate with a captured baseline. It does not infer
protected status from file paths, UID spelling, a Git author string, or a record
claiming that it was written by a human.

For the reference consumer, freeze listed records' existence, grammar/element,
FLAG value when present, and owned modeled relations as a set. Ignore relation
ordering, incoming declarations owned elsewhere, reverse display labels,
document placement, and temporary runtime bookkeeping. An optional field-based
consumer can choose a different projection explicitly.

**Complete proposed preservation definition.** The projection names the fields
it compares; the baseline argument names the captured source registration:

```nix
{policy}: let
  projection = {
    id = "reference/authored-record/v1";
    elementType = true;
    fieldsWhenPresent = [{
      grammar = "reference";
      element = "FOO";
      name = "FLAG";
    }];
    ownedRelations = "set";
  };
in {
  inherit projection;
  rule = policy.preserve {
    id = "reference/preserve";
    baseline = "protected";
    inherit projection;
  };
}
```

The helper binds candidate plus
`baseline = { from = "fact:protected"; schema = "sdoc-policy.baseline/v1"; }` in
the resulting rule's inputs. It does not acquire the baseline during Nix
evaluation. Register the `protected` source shown below and compose this
expression's `rule` as `preservationRule` in the later bundle. The source and
rule must use this same projection identity.

The projection's field reference is explicit, but FLAG's desired Boolean value
codec and the string-only proposed snapshot still require reconciliation. This
snippet does not resolve that gap or substitute string equality for the
requested typed value. The
[bounded normalized-authoring findings](normalized-authoring/README.md) record
the current public grammar behavior.

**Complete conceptual baseline inputs**, using readable projection notation
rather than an invented serialization schema:

```text
S0: successful complete captured baseline; model=reference-model; records=[]

S1: successful complete captured baseline; model=reference-model
    records=[
      identity=(reference-model, I0)
      element=(reference, FOO)
      FLAG=present false
      owned modeled relations={}
    ]
```

| Captured input and candidate                                       | Expected result                                             |
| ------------------------------------------------------------------ | ----------------------------------------------------------- |
| S1; leave I0 unchanged                                             | Satisfied, even though the baseline is nonempty             |
| S1; change I0 to closed                                            | Preservation violation with old/new projection and S1       |
| S1; delete I0                                                      | Preservation violation naming missing protected identity    |
| S1; add a valid incoming relation owned elsewhere                  | Preservation satisfied; other policies still apply          |
| S1; move I0 to another document or reorder declarations            | Same neutral projection; refresh locations                  |
| S0; change or delete isolated I0                                   | Preservation satisfied; all other rules still apply         |
| Source exits nonzero, times out, returns malformed/incomplete data | Acquisition error, not empty S0 or a preservation violation |
| Required baseline or immediate before state missing                | Cannot evaluate the dependent comparison; no substitution   |

After I0 becomes closed under S0, a later evaluation receiving S1 must detect
the mismatch without an SDoc edit. If S1 was already captured when the provider
changes to S0, finish that evaluation against immutable S1; a later evaluation
may use S0. Per-evaluation capture is not a latest-at-publication guarantee.

**Proposed executable source registration:**

```nix
{baselineExecutable, projection}: {
  kind = "source";
  id = "protected";
  schema = "sdoc-policy.baseline/v1";
  artifact = baselineExecutable;
  dependencies = [];
  config = {modelId = "reference-model"; inherit projection;};
  runner = {
    protocol = "sdoc-policy.runner/v1";
    argv = [baselineExecutable];
    limits = {timeoutMs = 10000; outputBytes = 16777216;};
  };
  trust = {verifier = "consumer/trust"; purpose = "reference-baseline";};
}
```

Its capture operation must return identified complete data and provenance. The
host hashes the actual content: a reused provider label cannot alias changed
facts. `consumer/trust` is also a public registration chosen by trusted consumer
setup, not implicit package authority. Its concrete verification schema is
unsettled, so this registration is not yet an operational source recipe.

Record identity is `(model, UID)`. Grammar identifies element types and
selectors but does not disambiguate duplicate UIDs in one model. A UID rename,
cross-model mapping, or schema migration needs an explicit mapping; no basename
or first-match fallback. A relation occurrence's snapshot-local identity is not
a permanent history identity. Preserve source documents for diagnostics without
treating document layout as hierarchy.

For repository lifecycle policy, keep these separate captured inputs:

| Input          | What the consumer must establish                                                   |
| -------------- | ---------------------------------------------------------------------------------- |
| approvals      | Trusted decision bound to candidate, before, main, policy, principal, and action   |
| before         | Immediate state this candidate replaces                                            |
| classification | Trusted human-authored/protected document classification for the captured revision |
| main           | Chosen ref resolved once to an immutable commit and compatible extracted model     |
| principal      | Verified actual boundary/session identity, possibly from future SSH integration    |

An example consumer may deny an LLM's changes to main-listed projections and
separately require human approval for changes to protected documents.
Branch-only changes may then pass the main rule. A complete empty approval set
can yield `approval-required`; failed acquisition errors. Changing any
approval-bound input makes the earlier approval inapplicable.

Before is not main. Authored labels, claimed request names, and ordinary Git
author text do not authenticate a person. Sources need explicit coherence when
their facts must describe one revision. No implicit fetch or private-key
handling is part of the semantic engine. A future UI would show the concrete
change and supply an appropriately bound decision through the same source
interface.

Supersession gives no automatic exception. A verified approval does not waive a
separate main-denial or preservation rule. The consumer must define permissions,
classification, expiry/revocation, projections, and every intended exception;
untrusted candidate policy cannot authorize its own protection removal.

## Compose policy and install the implementations you enabled

**Proposed composition expression.** `model`, `forest`, and `bridge` are the
results of the grammar/forest/bridge definitions taught above; `nativeRule`,
`visibilityRule`, and `preservationRule` are explicit rule definitions. These
parameters name required definitions, not existing imported implementation
files.

```nix
{policy, model, forest, bridge, nativeRule, visibilityRule, preservationRule}:
policy.compose {
  bundles = [
    (policy.bundle {
      id = "reference/policy";
      includes = [model.bundle forest.bundle bridge];
      rules = [nativeRule visibilityRule preservationRule];
    })
  ];
  edits = [];
}
```

The manifest exposes expanded IDs, provenance, dependencies, original/effective
definition digests, and required contracts. Identical definitions under one ID
deduplicate with their origins; different definitions conflict. A document rule
can inspect the whole model and before state. Scope does not mean “only touched
records,” and document boundaries do not hide unchanged dependencies.

**Proposed explicit replacement:**

```nix
{policy, reference, originalDefinitionDigest, replacementRule}:
policy.compose {
  bundles = [reference];
  edits = [{
    action = "replace";
    id = "reference/R-visible";
    expect = originalDefinitionDigest;
    rule = replacementRule;
    reason = "Use the consumer visibility rule through its chosen adapter";
  }];
}
```

The replacement retains the logical ID and supplies the complete new rule.
`expect` comes from the inspected original manifest. Unknown IDs, stale digests,
competing edits, and broken view dependencies are errors. Disable likewise
requires an ID, expected digest, and reason. The required all-role native rule
cannot be disabled while claiming the reference profile. A per-rule binding can
change only the implementation while preserving the contract; that changes
registry/receipt identity even if the rule definition stays the same.

The proposed consumer wiring has three values:

```text
ai.strictdoc.policy = { model; effective; nativeRule; }
ai.policyRuntime = { registrations; bindings; mode = "full"; }
ai.validation.boundaries = { daemon = ...; commit = ...; }
```

Grammar generation continues from the native elements; root/document inclusion
and grammar selection remain explicit consumer configuration. A standalone host
can receive the same three values. These names do not imply three services.

Dependency packaging must follow enabled implementation and boundary choices:

| Consumer choice                  | Dependencies its package should include                                            |
| -------------------------------- | ---------------------------------------------------------------------------------- |
| Native grammar/Scribe only       | The chosen existing native toolchain                                               |
| Graph rules                      | Shared capture/protocol machinery and the selected Python/rustworkx/native runtime |
| Graph rules plus Rego visibility | The preceding requirements plus the explicitly enabled OPA adapter/runtime         |
| Independently supplied checker   | That enabled checker's declared runtime and required shared inputs                 |
| No Cozo adapter enabled          | No Cozo dependency                                                                 |

Registering a shipped adapter must use the same public descriptor contract as an
independent adapter. Disabled adapters must not be pulled into the consumer
closure through a catalog or wrapper. A mere `enable = false` label is not
proof: qualification must inspect the built consumer closure and the executed
programs. The current module proposal lacks a final enabled-only
package-construction example; do not invent an option path to disguise that
unresolved delivery work.

## Choose when a complete candidate is validated

The rules retain their mathematical meaning. The boundary decides which bytes,
before state, and captured inputs constitute an evaluation and what a refusal
prevents.

| Boundary                 | Candidate                                    | Refusal preserves                                             |
| ------------------------ | -------------------------------------------- | ------------------------------------------------------------- |
| Daemon transaction       | Sealed private group over an identified base | Published authored bytes and observable held state            |
| Staged-tree commit check | Captured index tree, with explicit before    | Already edited index/worktree; this commit is refused         |
| Daemon then commit       | Each of those candidates in order            | Refused commit does not undo an earlier published transaction |

For two agents building one BAR, **proposed messages, not current Scribe RPCs**:

```text
begin(baseRevision=before-42,
      participants=[agent-A, agent-B], sealAuthority=coordinator)
  -> group-17, revision=0

stage(group=group-17, expectedRevision=0, contributor=agent-A,
      patch=create M with its owned Parent P=F0)
  -> revision=1

stage(group=group-17, expectedRevision=1, contributor=agent-B,
      patch=add M-owned Child Q=F2)
  -> revision=2

seal(group=group-17, expectedRevision=2, authority=coordinator)
  -> immutable candidate and before identities

evaluate complete candidate -> valid
publish against the same before -> published only after bytes/model agree
```

Private staging may be incomplete. Sealing after only the first stage fails the
lower-count rule and leaves no published M. Replacing a valid M's Q=F2 with Q=F1
passes when the complete final candidate has exactly one Q, regardless of
whether removal or insertion was staged first.

Expected revision mismatch conflicts rather than overwrites. Seal freezes bytes;
late staging conflicts. Boundary policy authenticates contributors and seal
authority. A consumer may require revision-bound all-ready acknowledgments;
later staging invalidates readiness. Core sealing does not require all-ready,
and silence or timeout never implies readiness. Takeover/membership changes are
explicit authorized actions. A changed published base requires reconciliation
and a fresh evaluation. Serialized ordinary writes do not form this group.

For staged-tree validation, capture index additions, modifications, deletions,
and relevant grammar/configuration bytes. Exclude unstaged edits. Unmerged index
entries error. Select before explicitly for a merge commit instead of silently
choosing a parent. The separately captured main baseline retains its own
meaning.

An invalid or incomplete report refuses the commit and leaves edits for repair.
An enforcing adapter must bind the validated tree to the actual commit; checking
then releasing an unguarded index has a race. An ordinary local hook alone does
not provide authenticated identity or non-bypassable enforcement.

After daemon publication, a commit boundary may reuse a receipt only if all
required candidate/before/policy/registry/grammar/fact/trust/freshness
identities match. Otherwise it evaluates again. The two publications are
separate; no sidecar database transaction makes Scribe, files, and Git atomic.

## Read failures and recover without confusing validity with publication

| Observation                                    | Meaning and required response                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------- |
| Resolved wrong target type                     | Policy violation with contextual owner/target/type evidence                   |
| Malformed Boolean or unresolved endpoint       | Input error; retain inspectable partial diagnostics                           |
| Invalid selected forest                        | Forest violation; dependent paths blocked with a causal reference             |
| Missing before/baseline or provider timeout    | Cannot complete the dependent evaluation                                      |
| Complete invalid private candidate             | Refuse publication; preserve published bytes and held model                   |
| Valid candidate, failed file/model publication | Operational failure; restore before or block writes pending recovery          |
| Uncertain publication timeout                  | Query transaction status before repeating a potentially non-idempotent action |

Every required rule returns exactly one result: satisfied, violated, blocked, or
error. Aggregate validity requires all required rules satisfied. Known policy
violations yield invalid when there are no operational errors; incompleteness or
execution failures yield error while preserving known findings. A valid report
is not a publication receipt.

The reference admission policy requires a complete valid final result. Invalid
input remains inspectable; private repair can proceed through incomplete states.
A consumer may explicitly choose another assessed repair admission policy, but
it cannot relabel invalidity as valid, hide missing inputs, or drop required
profile invariants.

Evaluation must not write published state, including through provider callbacks.
A strong boundary must qualify that restriction for its chosen trusted extension
or isolation model; JSON inputs alone are not isolation. Publication records
must identify the transaction, before/candidate, affected paths, last completed
step, receipt, and observed installed state. A failure yields restored state or
recovery-required with writes blocked. Clear the block only after bytes and
held/reloaded model agree. Crash windows and external-reader scope need explicit
qualification before any strong atomicity claim.

## What remains before these become runnable consumer recipes

This walkthrough is a review of behavior and proposed authoring. The next gate
must first freeze the extracted model, native/Boolean field representation,
canonical identities, diagnostics, runner schemas, and target lowering. It must
then demonstrate the target restriction through public Nix configuration and a
real Scribe refusal, with the accepted and same-role controls, unchanged bytes
and held state on refusal, and matching reload. A standalone Python decision or
successful Nix parse does not establish that integration.

The later evidence must retain these families:

| Family                         | Required evidence beyond the examples above                                                           |
| ------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Targets and selectors          | All grammar/element/native-type/role components; helper/direct/independent parity                     |
| Native graph and forest        | Parent-only, Child-only, mixed named cycles; isolated roots; selected versus other parents            |
| Visibility and bridge          | Every truth row above; nested/deep boundaries; unchanged-link closure/move revalidation               |
| Native and field tailoring     | Owned intermediate links; counts; field-path/union-DAG logic and honest limits of equivalence         |
| Sources and protection         | Nonempty unchanged/changed pair; empty success; every acquisition failure; immutable capture          |
| Identity and lifecycle         | Trusted source binding, branch/main distinctions, approval absence/denial/acceptance/staleness        |
| Group and commit boundaries    | Staging-order parity, conflicts/seal/readiness, staged-tree binding, refusal/reload/recovery          |
| Extension and composition      | Independent tool/source/helper, unsupported capability, duplicate/conflicting/stale definitions       |
| Packaging                      | Enabled-only closures; compatible runtimes/platforms; no disabled adapter dependencies                |
| Rebuild and change propagation | Consistent renaming; relation reordering; moved locations; policy/source-only invalidation            |
| Correctness and cost           | Full/incremental parity over identical captured inputs; cache deletion; cold/warm realistic workloads |

Exercise inserts/deletes, role/endpoint changes, closure toggles, subtree moves,
and grouped edits. Full evaluation is the initial reference; later incremental
evaluation must match meaningful findings for the same complete input envelope.
Policy/provider changes, negative lookups, and collection membership can
invalidate unchanged records. Indexes/caches are disposable. Measure parsing,
providers, serialization, recomputation, reload, and publication separately on
deep/wide models near 1,000 and 10,000 records; single-query experiments are not
all-rule Scribe latency guarantees.

Before final delivery, generic Scribe must shed mandatory repository-specific
field policy, the neutral fixture must contain neither AUTHORED_BY nor PARENT_FP
content, and the repository policy must be exercised through public extensions.
No renamed equivalent or hidden historical accommodation satisfies that cleanup.
Verify every recipe against the implemented public exports, retain corresponding
steering-ready explanations, and keep their placement and SDoc migration
deferred.

Supplementary references are the [proposed interface](interface.md),
[complete declaration catalog](recommended.nix),
[scenario matrix](../scenarios.md), and [closing obligations](closing-plan.md).
The [backend recommendation](recommendation.md) retains comparison evidence.
These add detail and provenance; they do not replace the examples on this page.
No Gate 3 implementation or backend adoption follows from this draft.
