# Proposed common semantic contract

**Gate 2 proposal, not installed exports or production enforcement.** The
[reviewed requirements](reviewed-requirements.md) and
[scope reconciliation](scope-reconciliation.md) incorporate the latest handoff.
Exact names and schema spelling remain reviewable. The
[historical recommendation](recommendation.md) retains backend measurements, not
governing lifecycle/API requirements. Python/rustworkx with native StrictDoc
reuse remains the initial direction; OPA is optional. No new backend survey is
needed.

## Configuration and finite authoring

The common semantic interface is fully Nix-configurable and backend-agnostic.
Consumer DSLs emit versioned contracts and register implementations through the
same route as shipped helpers. Python/Rego/custom programs need not translate
into a universal Nix expression language: their configuration, identified
inputs, registration, bindings and results pass through this common boundary.
The host dispatches a named contract; it need not understand forest algorithms
or the neutral fixture.

`g` denotes existing `grammar.dsl` native-normalized constructors. Proposed `s`
denotes the richer semantic schema/type layer. Proposed `c` denotes a **new
constraint DSL**, not a Nix builtin or the old `p` namespace renamed. Its
callbacks produce tagged, typed, serializable descriptions over symbolic
subjects. Runtime equality uses an explicit constructor such as `c.eq`; Nix
`==`, `&&` and `if` evaluate during configuration. Reject raw Nix Boolean
callback results where a predicate descriptor is expected. Explicit constant
predicates are allowed; Boolean defaults and ordinary Nix configuration
conditionals remain valid.

The evaluated proposal spelling returns
`{ elements; views; normalized; rendered; }`. `elements` and `views` are
authoring handles; serialize only `normalized` and `rendered`.
`normalized = { grammar; semanticTypes; bundle; }` holds the checked native
element list, identified semantic metadata and declaration/rule/view lists. The
bounded prototype is not an installed export. Direct native-normalized inputs
remain available and validated. Never inject semantic keys into the existing
native field option schema. Preserve ordered field lists while exposing keyed
field handles; attribute-name sorting cannot replace declared order. Every
addressable element explicitly declares UID.

Resolve finite declaration identities first, evaluate callbacks over symbolic
references, then lower to plain data. References never serialize closures, owner
builders or recursively connected schemas. `self` is an enclosing element
declaration, `self.fields.FLAG` a field declaration, `self.relations.R.parent` a
contextual authored relation declaration; `elements.FOO` is an element type.
`rel.owner` and `rel.target` are runtime node references. Type equality, node
identity and “node is of type” are distinct operations.

Adjacent named constraints and external `c.on subject { name = predicate; }` use
the same lowering. Names are stable diagnostic/composition identities;
constraints on one subject are conjunctive. Use explicit disjunction/conjunction
operators. A general named constraint slot replaces author-facing `allowed`
lists; direct normalized target contracts may still use such a list. Fluent
decoration is optional sugar over the same route.

| Subject                          | Quantification and dependency                                                                                                             |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Authored relation predicate      | Every existing selected occurrence; empty collection is vacuously satisfied.                                                              |
| Relation cardinality             | Every selected owner, including zero occurrences; counts owned occurrences.                                                               |
| Record predicate                 | Every selected record; can read its endpoint collections.                                                                                 |
| Checked singleton, e.g. `c.only` | Requires explicit exactly-one guarantee; blocked on failed prerequisite, never silently picks an endpoint or injects a hidden count rule. |
| Forest/view predicate            | Reads a validated named graph view; invalid view blocks dependents.                                                                       |
| Model/document/change rule       | Explicit scope and inputs; not forced into relation callbacks.                                                                            |

Keyed declarations in separate contributions must be retained as definition
lists before composition; a Nix attribute merge that already lost duplicates is
not checked composition. Exported IDs derive from keys, never list position:
`reference/element/FOO`, `reference/element/FOO/relation/Parent/R`, that
relation plus `/constraint/targetType` or `/cardinality`, `reference/view/H`
with `/valid`, and `reference/constraint/nativeDag`. Renaming a key
intentionally changes identity; there is no implicit alias. Freeze escaping or
reject reserved separators before production. Any future explicit continuity
mapping must be separately defined. Cross-model/baseline identity migration
requires an explicit mapping.

## Semantic types and native representation

This is a distinct, validated option layer, not documentation decoration. A
field definition is shared by defaults and constraint expressions. Proposed
normalized shapes:

```text
ElementRef = {grammar; element;}
FieldRef = {grammar; element; name;}
Selector = {grammar; ownerElement; nativeType; role;}
SemanticTypes = {
  schema = "sdoc-policy.semantic-types/v1"; digest;
  fields = [{field = FieldRef; native; semantic; default;}];
}
BooleanSemantic = {
  type = "boolean"; presence = "required" | "optional";
  multiplicity = "single";
  encode = {false = "false"; true = "true";};
  decode = {false = false; true = true;};
  invalid = "error";
}
```

`native` is the existing checked native field definition (`singleChoice` with
`choices = ["false" "true"]`, title and requiredness for Boolean fields), not a
new native tag. The schema suffix `/v1` is the metadata version.
`default = null` means no provider; otherwise it is a typed default declaration
below. Ordered fields and duplicate-title rejection precede keyed handle
construction.

Encoding/decoding is data, not an executable callback. Required presence has
minimum one; optional presence minimum zero; scalar maximum is one, and native
requiredness must agree. Initial Boolean multiplicity is scalar; list-valued
Boolean fields require a separate supported contract. Strict native strings
`"false"`/`"true"` are canonical and case-sensitive. No trimming, numeric
coercion or arbitrary-string-to-Boolean conversion occurs. Native placeholder
values such as `TBD`/`TBC` are invalid semantic Booleans even where the native
choice validator permits them. A semantic default `false` differs from a string
default `"false"`. String fields retain strings, including empty strings;
unsupported semantic types/codecs fail explicitly.

Snapshot fields may remain `{ <name> = [String]; }`. A missing key means absent,
`[""]` means a present empty scalar, `["false"]` means present Boolean false
under this field's metadata. A present `[]` is invalid scalar multiplicity, not
absence; two values are also invalid. Required absence is an input error after
creation defaults have run. Optional absence remains a distinct missing value; a
predicate requiring a value must guard presence or return an input error.
Missing, multiple or unrecognized Boolean values never mean false. The native
extraction adapter must preserve this distinction or report unsupported/input
failure.

A backend can decode to Booleans or lower typed Boolean expressions into
native-string operations using the exact mapping. A second Boolean-valued
runtime graph is unnecessary. Metadata is attached once to the identified
grammar/element/field definition, not repeated on each record.
Conflicting/missing metadata, wrong codec/version, a stale grammar digest or
ambiguous field identity errors before a dependent decision. Native `required`
and `isComposite` option Booleans are unrelated to document Boolean typing.

The prototype metadata digest hashes `{schema; fields;}` before adding `digest`;
ordered fields include contextual identity, checked native definition, semantic
mapping and default declarations. Grammar artifact digests are separate required
receipt/input identities, not extra unrecognized metadata fields. The proposed
common digest convention is SHA-256 over UTF-8 normalized JSON with
deterministic object-key order, preserved meaningful list order and no own
digest property. The prototype uses Nix JSON serialization; C1 must freeze
cross-language canonicalization and numeric/escaping details before
interoperability is claimed. Engine payloads and receipts carry the
schema/version and digest. Unknown schema, type or mapping versions fail
explicitly. A native-only field can remain native but cannot silently become
semantic Boolean. The prototype metadata is finite lowering evidence; production
schema validation and runtime transport remain later work.

## Creation-time defaults

Defaults are authoring-time materialization, separate from semantic validation
and Nix module defaults such as `mkDefault`. Proposed field option:

```text
Default = {literal = TypedValue;}
       or {script = {argv = [AbsoluteExecutable Argument ...]; timeoutMs;};}
DefaultRequest = {protocol = "sdoc-default/v1"; requestId;
                  candidatePreparationId; record; field = FieldRef;
                  semanticTypesDigest; config;}
DefaultResponse = {protocol = "sdoc-default/v1"; requestId;
                   status = "ok"; value = TypedValue;}
               or {protocol = "sdoc-default/v1"; requestId;
                   status = "error"; error = {code; message;};}
```

The public prototype uses `s.default.literal value` and
`s.default.script { argv; timeoutMs; }` with the normalized spelling above.
Exactly one variant is allowed. Execution captures executable/config identity
and enforces an output-byte limit through the default runner configuration;
these runtime concerns do not invent extra unchecked field-option keys. The
default request/response ABI is a proposed later contract, not executed by the
prototype.

TypedValue is a JSON value checked against the referenced semantic field type.
Boolean accepts only JSON Boolean; string accepts JSON string. `null` is not
absence or a valid value for these initial scalar types. One UTF-8 JSON response
on stdout, zero exit for protocol completion, bounded stderr diagnostics;
nonzero exit, timeout, absent `value`, extra/malformed output, mismatched
request ID and type error all refuse preparation. A successful `value = ""` is
an explicit empty string; empty stdout is failure. Default scripts execute at
runtime, never during Nix evaluation. Configured argv is not shell text;
packaging later supplies absolute paths and only enabled provider dependencies.

Collect the ordered explicit operations first. Track record creation by
operation provenance, not simply by a changed UID. Once operations finish, apply
defaults only to still-existing records newly created by this invocation and
only to absent fields. A newly created then deleted record gets no defaults. An
edited/moved/renamed existing record is not newly created. Deletion then
explicit recreation is creation, still subject to before/baseline preservation
rules. Later explicit assignments, including false and empty strings, win;
invalid supplied values fail validation instead of being replaced. An explicit
unset on a newly created record leaves it eligible if still absent at the end.
Existing missing fields are never backfilled.

Resolve each eligible field once per prepared candidate and record
provider/artifact/config identity plus the captured value or failure. Do not
retry providers invisibly, evaluate defaults as part of checking, replay
mutations after dry-run, or rerun defaults during publication. A later explicit
invocation is a new preparation and may obtain different external values.
Initially require construction identifiers such as UID explicitly; do not hide
early default acquisition needed to resolve subsequent operations.
Dependent/script expression engines are outside this minimal contract. A script
is an ordinary runtime provider; teaching semantic-backend calls as default
providers is outside the intended design. Authored identity defaults are data,
not authenticated principal evidence.

## Rules, views and effective bindings

```text
Rule = {id; scope = "model" | "document" | "change";
        contract; config; inputs = {<name> = InputBinding;};
        needs = [Capability]; after ? [RuleId];}
InputBinding = {from = "candidate" | "before" | "fact:<id>" | "view:<id>";
                schema;}
View = {id; contract; config; inputs; needs; after ? [RuleId]; schema;}
Binding = {contract; implementation; entry;}
       or {rule; implementation; entry;}
```

Each rule covers its complete selected subject set. Document rules select
declared documents and may read the whole model; change rules require before and
candidate. Every rule/view gets one binding; duplicate bindings at one
specificity error. An explicit per-rule binding overrides a contract-level
binding only for that rule and must implement its contract. Dependency cycles,
unsupported inputs and silent omitted rules error. A view is identified
disposable data, not a private backend object. Required prerequisites must
satisfy before a dependent can decide.

| Public contract                | Required normalized meaning                                                                                                                                            |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sdoc-policy.native-dag/v1`    | All authored Parent/Child roles/elements; complete resolution, cycle and authored-edge witnesses. Required by reference profile; no removable optional helper.         |
| `sdoc-policy.targets/v1`       | `{select; allowed = [ElementRef];}`; wrong resolved target type violates; missing target is input error.                                                               |
| `sdoc-policy.forest-valid/v1`  | `{nodes = ElementRef; select = [Selector];}`; selected endpoints are members, no selected cycles, at most one distinct selected parent. Multiple/isolated roots valid. |
| `sdoc-policy.forest-view/v1`   | Same config, dependent on forest validity; identified nodes, normalized edges with authored provenance and exactly one root per member.                                |
| `sdoc-policy.visible/v1`       | `{select; boundary = {field = FieldRef;};}` with validated hierarchy and semantic Boolean metadata; original owner to declared endpoint in one tree.                   |
| `sdoc-policy.count/v1`         | `{records; select; min; max;}`; owned occurrences for every selected record, including zero.                                                                           |
| `sdoc-policy.endpoint-path/v1` | `{records; upper; lower; boundary;}` plus hierarchy, after both exactly-one rules; downward path from upper target to lower target.                                    |
| `sdoc-policy.preserve/v1`      | `{projection;}` and complete baseline; listed records exist and equal specified old projections.                                                                       |

A successful forest view serializes
`{nodes = [NodeRef]; edges = [{parent; child; declarations = [RelationRef];}]; roots = [{node; root;}];}`.
Validate coverage, references and selected-candidate consistency, including each
isolated node's own root. Never repair an invalid forest silently or return a
view after its prerequisite fails.

The public DSL vocabulary uses
`s.grammar "reference" ({ elements, views, ... }: ...)`,
`s.field.boolean "FLAG" { required = true; default = s.default.literal false; }`,
`c.isNodeType`, `c.forest`, `c.boundaryVisibility`, `c.fieldValue`, `c.exactly`,
`c.only` and `canDescend`. A richer expression cannot be discarded during
lowering.

The finite generic predicate representation is `{ op; args; }`; authoring
constructors return tagged Boolean expressions before serialization. Public
prototype operations are `isNodeType`, `eq` (same node), `sameNodeType`,
`constant`, `allOf`, `anyOf` and Boolean `fieldValue`; `canSee`/`canDescend` are
bound visibility-view operations. Non-specialized supported expressions emit
`sdoc-policy.predicate/v1` with `{quantification; subject; expression;}`. The
generic interpreter is not implemented by the bounded Python harness. Freeze
exact operand schemas/type checking in C2 before runtime use; unknown operators
reject.

Compound generic predicates retain the recursively collected inputs of nested
expressions, including visibility inside `allOf`/`anyOf`. Alongside
`inputs.candidate`, each named hierarchy binding is keyed by its `from`
identity, for example:

```text
inputs = {
  candidate = {from = "candidate"; schema = "sdoc-policy.model/v1";};
  "view:reference/view/H" = {
    from = "view:reference/view/H"; schema = "sdoc-policy.forest/v1";
  };
};
after = ["reference/view/H/valid"];  # plus nested singleton prerequisites
```

Nested view-validity and explicit singleton prerequisites are lifted into the
rule's `after` list. Identical view bindings deduplicate; conflicting bindings
for the same identity reject. Checked composition therefore rejects removal of a
required forest view or its validity rule even when the only consumer is inside
a compound predicate. This is evaluated dependency-preserving lowering in the
bounded prototype, not execution of the generic predicate contract or a change
to constructors/canonical reference lowering.

Supported patterns specialize to retained target/visible/endpoint-path contracts
with the same meaning and diagnostics. `canSee rel.owner rel.target`
specializes; reversed operands reject in the current bounded lowering instead of
silently reversing semantics. Endpoint-path specialization requires checked
Parent-upper and Child-lower collections owned by the current record. A future
generic implementation can support other operand patterns under an explicit
contract. A pure Boolean field boundary specializes to
`boundary = {field = FieldRef;}`; more general closed predicates need supported
expression semantics. Generic invocation carries either contract unchanged
without privileged shipped-name dispatch.

Semantic Boolean false means open, true means closed in the reference policy. On
the unique selected path, ascent is unrestricted. Descent can visit a closed
node but can expand it only if the **original origin** is within that boundary's
subtree, including itself. Repeat for nested boundaries without changing origin.
Visibility can ascend/descend; endpoint-path only descends. Other roles and
document placement never provide selected ancestry. Invalid forest blocks
traversal; boundary changes and ancestry edits revalidate affected unchanged
references.

A BAR owns Parent P to upper and Child Q to lower, preserving upper → BAR →
lower. Counts and path are separately visible; no flattening. Native tailoring
may use target/count rules without a common hierarchy. Equal endpoints cause a
native cycle regardless of conceptual zero-length path. Field/custom endpoints
require explicit resolution and any consumer-required virtual union-DAG check;
UID text alone creates no native edge or native export/ownership equivalence.

```text
Projection = {id; fieldsWhenPresent = [FieldRef];
              elementType = true; ownedRelations = "set";}
```

The reference projection checks listed record existence, grammar/element
identity, selected field presence and exact values, and owned
`(owner, resolved target, nativeType, role, owner grammar/model context)`
relation sets. Incoming relations, reverse labels, order, placement and
bookkeeping are excluded. Native validation still sees duplicate authored
occurrences. There is no implicit supersession exception. Incompatible baseline
projection/type schemas error; migration requires explicit mapping. Consumer
programs can define richer projections through the same route.

## Identified model and captured facts

```text
NodeRef = {model; uid;}
RelationRef = {snapshot; id;}
Location = {document; path; start; end;}
ModelSnapshot = {
  schema = "sdoc-policy.model/v1"; model; digest; complete;
  grammarArtifacts = [{id; digest;}]; parserArtifact;
  semanticTypes = {schema; digest;};
  documents = [{id; path; bytesDigest; nodes = [NodeRef]; native;}];
  nodes = [{ref; element = ElementRef; document;
            fields = {<name> = [String];}; locations; native;}];
  authoredRelations = [{id; owner; declaredTarget; target;
    nativeType; role; reverseRole; location; native;}];
}
Baseline = {schema = "sdoc-policy.baseline/v1"; model; projectionDigest;
            semanticTypesDigest;
            records = [{ref; value = {element; fields; ownedRelations;};}];}
Evaluation = {id; candidate; before?; policyDigest; registryDigest;
              grammarDigests; semanticTypes; facts; context;}
```

Native UID resolution is model-wide: different grammars cannot disambiguate
duplicate UIDs. Grammar names are logical identities distinct from artifact
digests. Parent normalizes target → owner; Child owner → target; reverse display
labels create no authored facts. External File/ID relation checks require
identified captured file bytes and extractor/config identities when used; live
mutable path/mtime-only lookups cannot establish candidate input identity.
Candidate moves must resolve file-dependent policy against the advertised final
paths or explicitly reject unsupported cases. Tagged native forms remain
available; unsupported forms error for dependent checks rather than disappear.
Preserve document membership, final move paths and locations. C1 fixes source
coordinate units and full serialized shapes before implementation.

`complete = true` requires complete extraction and endpoint resolution.
Malformed input remains inspectable with partial facts/diagnostics, but these
cannot masquerade as complete snapshots. Resolved graphs with cycles can be
complete inputs to a violated DAG rule. All snapshots are immutable captured
contents, not references to mutable paths or a live graph. A frozen wrapper
around shared mutable objects is insufficient.

The corrected bounded Python entries share an explicit identity/resolution
prerequisite over synthetic input containing `model`. It checks full
`{model; uid;}` references, unique NodeRefs even across grammars, unique
relation occurrence IDs, element identities and resolved owners/targets;
foreign-model references reject. Resolution follows authored relation order so
later input failures retain earlier findings. Target selection and membership
algorithms remain separate between the two entries. Count/path helpers also use
qualified references, projecting endpoint UIDs into the supplied forest only
after one-model resolution. This supplies bounded contextual-resolution
evidence, not a complete native ModelSnapshot validator or cross-model resolver.

The evaluation supplies the actual immutable semantic metadata artifact (inline
or through an identified captured-input reference), not only a digest with
unavailable contents. Its schema/digest must match every dependent snapshot and
typed expression; the selected implementation must receive and honor the
artifact.

Before is the replaced state; baseline/main is independently captured policy
input. Missing required comparison input errors, with blocked dependents; never
substitute current for before. A capture is complete even if empty.
Nonzero/timeout/malformed/incomplete/schema/trust failures remain operational
errors. Host-computed content digests prevent reused labels aliasing changed
facts. Capture dependencies form an acyclic graph; acquisition occurs once for
this evaluation and freezes before dependent validation. Cross-source coherence
requires a declared common revision/attestation; concurrent acquisition is not
global atomicity. Subsequent external changes affect subsequent evaluations, not
an implicit latest-at-publication guarantee.

Trusted boundary configuration loads policy and selects source authority; a
candidate cannot disable its own protection by changing untrusted config.
Principal/approval facts need an explicit consumer verifier and binding to
actual session/enforcing context, candidate/before/baseline/policy/action as
required. Git author strings and defaulted labels do not authenticate. A
configured main source resolves its ref once to an immutable commit, with
grammar/extraction identities; no silent fetch. Trust and approval schemas must
be settled before those slices, without SSH-key/UI implementation now.

## Common JSON invocation

All module options below are provisional conveniences over public data, not
installed options:

```text
ai.strictdoc.semantic = {model; semanticTypes; effective; nativeRule;}
ai.policyRuntime = {registrations = [Registration]; bindings = [Binding]; mode = "full";}
ai.validation.inputs = {<name> = CaptureConfiguration;}
```

Native `ai.strictdoc.grammars.<name>.{target,elements}` emission remains beneath
the semantic layer. Standalone consumers can pass the same normalized values.
Selected candidate capture (Scribe batch or Git staged tree) belongs to
integration configuration, not a required generic lifecycle service. Only
enabled implementations/providers bring runtime dependencies.

```text
Registration = {kind = "implementation"; id; artifact; runner;
  entries = [{name; contract; inputSchemas; configSchema; resultSchema;
              capabilities; mode = "full";}];}
Runner = {protocol = "sdoc-policy.runner/v1"; argv;
          limits = {timeoutMs; outputBytes;};}
Request = {protocol; requestId; operation; payload;}
Response = {protocol; requestId; status = "ok"; value;}
        or {protocol; requestId; status = "error";
            error = {code; message; details;};}
describe({}) -> {entries; operations; schemas; capabilities; artifactDigest;}
plan({manifestDigest; invocations; inputSchemas; requestedCapabilities;})
  -> {planId; accepted = [{id; entry; dependencies;}]; rejected = [{id; reason;}];}
evaluate({planId; evaluation; invocations = [{id; entry; config; inputs;}];})
  -> {evaluationId; complete = true; results = [RuleResult]; views = [ViewResult];}
capture({evaluationId; candidateDigest; beforeDigest?; policyDigest;
         context; dependencies; config;})
  -> {schema; snapshotId; complete = true; data; provenance;}
```

Source registrations add `schema`, `config`, `dependencies` and consumer `trust`
policy with `capture` support. Model extraction registrations identify
parser/schema/capabilities and capture/inspect fixed document/grammar bytes.
Neither requires public begin/stage/seal/abort/participants. Artifact identity
covers executable/module/config content. Static descriptors and `describe` must
agree; planning accounts for every assignment exactly once. Unknown
schema/entry/capability or unsupported evidence fails explicitly.

Use one UTF-8 JSON request on stdin, one response on stdout; zero process exit
means protocol completion, not semantic satisfaction. Bounded stderr carries
diagnostics. Nonzero exit, timeout, extra/malformed output, wrong
request/evaluation identity and overflow error. Optional in-process/long-lived
adapters implement the same semantics. Native Rego/Datalog/custom code can
remain native behind registered entries; OPA undefined decisions or built-in
errors must map to errors, never empty satisfaction. Backend helpers construct
RuleResult/Finding/evidence so authors do not hand-build reports for every
predicate.

## Results and checked composition

```text
RuleResult = {id; evaluationId;
  status = "satisfied" | "violated" | "blocked" | "error";
  findings = [Finding]; causes = [RuleIdOrInputId];}
Finding = {producer; code; rule; subjects; locations; message; evidence;}
ViewResult = {id; evaluationId; schema; digest; data;}
```

Exactly one result per invoked rule; omissions, duplicates, unknown IDs and
invalid schemas are protocol errors. `satisfied` means evaluated and holds,
including defined empty quantification; `violated` means evaluated and fails
with a structured witness; `blocked` identifies unsatisfied prerequisites;
`error` denotes configuration/input/execution failure. Empty findings alone are
not success. Successful views are validated against their advertised schema and
candidate context; no view result may imply success for a missing rule.

The broader production Finding subject surface remains `SourceRef`, including
node/document and other schema-defined source identities required by the
selected contract; it is not restricted to NodeRef. Native source-coordinate
representation remains a C1 schema decision.

The corrected local Python
`validate_results(invoked, results, evaluation_id="probe")` checks the expected
evaluation identity, exact result/Finding fields, string identities/text, typed
statuses/lists, matching Finding rule identity and JSON-object evidence before
aggregation. Null lists, scalar findings, string causes, numeric identities and
malformed subjects/locations/evidence reject. Its concrete subject/location
checker covers only NodeRef subjects and integer-coordinate locations used by
these local entries; unsupported shapes reject locally. That bound does not
narrow production SourceRef, establish DocumentRef/native-coordinate support or
qualify the full runner/result schema. Preserve broader production result
validation and explicit unsupported-schema errors.

Aggregate `valid` requires all required rules satisfied. Known policy violations
and their blocked dependents produce `invalid` if no operational incompleteness
remains; configuration/input/execution failures dominate as `error`. Preserve
known findings even when errors dominate. Admission is separate; reference
`complete-validity` requires valid final state. An explicitly configured
alternative repair admission may assess progress but cannot relabel invalidity,
omit required inputs or claim this reference profile with missing invariants.

Witnesses retain contextual selector, owner, target and expected/actual type;
conflicting selected parents/cycle declarations; path, original origin and first
blocked descent boundary; baseline identity and projected old/new differences.
Evidence distinguishes authored ownership from normalized direction.
Before/candidate/policy/registry/type
metadata/grammar/parser/implementation/config/fact/projection identities bind
the validation receipt. Helper/direct/independent implementations must agree on
meaningful contextual evidence, not incidental ordering or prose.

### Concrete target result conformance case

This is a **specified expected JSON response value**, not captured execution.
Given F1a's Parent R resolving to BAZ Z0, both a shipped entry and an
independently registered entry implementing `sdoc-policy.targets/v1` must return
this same rule result for the identified evaluation. `producer` names the
logical contract; each entry's actual implementation/artifact identity remains
in the receipt. Locations are empty here because this abstract contract input
supplies none; real extraction must preserve supplied locations.

```json
{
  "id": "reference/element/FOO/relation/Parent/R/constraint/targetType",
  "evaluationId": "target-wrong-type-example",
  "status": "violated",
  "findings": [
    {
      "producer": "sdoc-policy.targets/v1",
      "code": "target-type",
      "rule": "reference/element/FOO/relation/Parent/R/constraint/targetType",
      "subjects": [
        { "model": "reference-model", "uid": "F1a" },
        { "model": "reference-model", "uid": "Z0" }
      ],
      "locations": [],
      "message": "Parent R owned by FOO requires a FOO target.",
      "evidence": {
        "selector": {
          "grammar": "reference",
          "ownerElement": "FOO",
          "nativeType": "Parent",
          "role": "R"
        },
        "owner": { "model": "reference-model", "uid": "F1a" },
        "target": { "model": "reference-model", "uid": "Z0" },
        "expected": [{ "grammar": "reference", "element": "FOO" }],
        "actual": { "grammar": "reference", "element": "BAZ" }
      }
    }
  ],
  "causes": []
}
```

For a resolved FOO target, the result is satisfied with no findings or causes.
If Z0 is unresolved, capture/input error replaces a semantic wrong-type decision
and dependent checks are blocked. For an empty BAR Q collection, the count rule
is violated with count zero and the dependent singleton/path rule is blocked
with that cardinality rule ID as cause. These cases distinguish defined empty
quantification from missing required endpoints and require the same result
accounting from every registered implementation.

The public composition prototype accepts
`{ contributions = [{origin; bundle;}]; edits ? []; required ? []; }` and
returns `{ definitions; provenance; digest; edits; }`. Bundles hold
`declarations`, `rules` and `views` lists; independent element declarations
carry `{id; kind = "element-declaration"; native; semanticFields;}`. Provenance
retains all origins, original `expect` digest and `effectiveDigest`. Compose
these definition lists before Nix merges. Equivalent canonical definitions under
one ID deduplicate while retaining every origin; conflicting definitions error.
Explicit edits are `{action = "replace"; id; expect; rule; reason;}` or
`{action = "disable"; id; expect; reason;}`, guarded by original definition
digest. Unknown/stale/competing edits error independent of ordering; replacement
keeps logical ID. Validate dependencies after edits; do not disable a required
profile rule or needed view without compatible replacement. Policy changes and
binding changes update their respective receipt identities. Module precedence is
not override authorization.

The evaluated composition prototype also guards the meaning of required
definitions whose **original contract** is `sdoc-policy.native-dag/v1`. Both
original and effective definitions must retain that contract, model scope, empty
all-role config, the candidate model input and mandatory capabilities
`model.resolved-parent-child/v1` and `native.all-role-dag/v1`. Equivalent
replacement and additional capability requirements are permitted; replacing with
a true predicate, narrowing config, switching to before, changing scope or
dropping a mandatory capability rejects. The guard follows the known original
contract, not a fixture ID; it also rejects an invalid original required
native-DAG definition.

This evaluated semantic guard is bounded. Other required IDs receive presence
checking and do not automatically acquire native-DAG semantics. Arbitrary
custom-contract replacement/dependency compatibility remains future preflight
work; the broader production requirement to preserve required meaning and
compatible dependencies is unchanged.

## One prepared candidate, validation and publication

The initial Scribe requirement is **one invocation with an ordered operation
list**, including repeated operations. One operation is a one-item batch. No
public cross-call begin/stage/seal/abort, participants, readiness or
coordination lifecycle is required. JSON-RPC arrays of separately committed
calls are not this batch.

```text
capture stable base
  -> apply ordered operations to private candidate
  -> default newly created records still absent after explicit operations
  -> render/freeze candidate bytes, paths, deletions, membership and effective inputs
  -> complete-candidate native validation
  -> configured semantic validation and admission
  -> dry-run report/diff, OR publish the exact prepared candidate
```

Operation syntax/type/existence checks run when needed for meaningful mutation.
A later operation can reference an earlier created explicit UID; arbitrary
forward references are not promised. Required-relation counts, exactly-one
replacement, graph invariants and semantic checks evaluate final state. Audit
existing prechecks so transient zero/two endpoints or incomplete newly created
records do not prematurely reject a final-valid batch. Invalid individual
supplied values remain errors; defaulting cannot conceal them. Full validation
does not require a full graph rebuild on each mutation.

```text
PreparedCandidate = {id; baseIdentity; before; operationsDigest;
  createdRecords; resolvedDefaults; candidate; effectiveInputs;
  writes = [{path; bytesDigest; bytes;}]; deletions = [Path];
  moves = [{from; to;}]; documentMembership;
  validationReceipt; admission;}
```

This is internal reviewable data, not a public transaction-management API.
Candidate identity covers final bytes, additions/deletions, both move paths,
document membership and the identified effective inputs used by validation.
Capture all authoritative document/grammar/config model inputs, not only touched
paths; a concurrent change to that published base makes it stale. Separately
captured external fact sources follow their declared per-evaluation freshness
policy: their later changes do not by themselves invalidate a captured snapshot.
Complete native validation includes every role and element; reparsing touched
documents alone is insufficient. Required inputs finish capture and become fixed
before their dependent semantic decisions. No mutation or provider acquisition
follows final validation.

Publication verifies expected base under the integration's qualified
serialization/locking boundary and consumes the prepared bytes/paths once. A
changed base refuses; rebasing is a new preparation and evaluation. Real write
never invokes public dry-run then replays operations. Dry-run uses the same
preparation/default/full-validation machinery but stops before publication. It
may create temporary files, execute default scripts and write derived
caches/diagnostics; it publishes no authoritative documents or accepted-state
pointer. Different explicit dry-run/write invocations can acquire different
values and have different results.

Private candidate mutations cannot leak into held generations, indexes, export
state or concurrent model readers. An accepted pointer is updated only when
published bytes and observable model agree. Ordinary
mutation/default/native/semantic refusal discards private candidate state and
needs no document rollback. Validation success alone is not publication success.
A failed publication restores before or blocks further writes with
`recovery-required`; record before/candidate identities, affected paths,
validation receipt, last completed step and observed installed-state identity.
Never report published while files/model diverge. An uncertain completion must
be inspected and reconciled before retry; no blind replay of non-idempotent
publication. Recovery clears the write block only after document and
held/reloaded state agreement is verified.

The eventual implementation must state crash windows, durability, locking scope
and external-reader guarantees. Existing restore code and in-memory/database
transactions do not establish crash-atomic multi-file publication or atomic
visibility to arbitrary filesystem readers. The initial contract requires honest
restore-or-block behavior inside the qualified Scribe boundary, not a new
general filesystem transaction service.

## Authoritative inputs and disposable derived state

Validators receive fixed read-only candidate/before/baseline/context/type
metadata and separate writable cache/scratch locations. They may retain
rejected-candidate caches and diagnostics; they cannot mutate authoritative
documents or the accepted-state pointer. A read-only view of a live mutable
graph is not a snapshot. Read-only JSON/chmod does not establish resistance to
arbitrary host access; declare trusted-extension or isolated-execution
assumptions before claiming that protection.

Cache keys cover the actual computation dependencies. A structural index needs
document/graph/parser inputs relevant to it; a semantic verdict additionally
needs rules/config, typed mappings, implementation/version, binding,
baseline/before and captured facts where used. Location-bearing cached
diagnostics depend on paths/coordinates and refresh on moves. Negative lookups
and collection membership are dependencies. A cache for rejected candidate A
cannot become accepted B. Identical captured inputs must give equivalent
cold/warm/full results; corruption rebuilds or yields operational error, never a
different policy answer. Do not require commit/rollback callbacks merely to
manage caches.

## Git staged-tree consumer boundary

Retain Git validation as a separate consumer-selected invocation. Capture actual
staged additions/deletions and relevant grammar/config bytes, explicit before
and separately identified main/baseline; exclude unstaged edits. Unmerged
entries error; merge-before interpretation is explicit. A refusal leaves the
user's edited index/worktree alone. Bind a receipt to the actual committed tree
when an enforcing adapter advertises that guarantee; check-then-release and a
bypassable local hook do not prove it.

Scribe publication followed by Git commit is two boundaries. A rejected commit
does not undo the earlier published Scribe batch. Receipt reuse requires all
relevant snapshot/type/policy/registration/trust/freshness identities to match,
otherwise evaluate again. No generic live lifecycle is necessary. Per-evaluation
captured facts remain the reference guarantee; latest-at-publication needs
explicit source-specific capabilities.

## C1–C4 and later implementation entry conditions

- **C1 — schema/type/capture before the first implementation slice:** freeze
  model JSON, canonical digest encoding, source coordinates, model-wide UID
  resolution, contextual references, lossless native forms/error mapping,
  semantic type version/digest and Boolean presence/multiplicity/codec. Force
  finite s/c lowering and metadata alongside valid native grammar; demonstrate
  duplicate UID, missing endpoint, wrong resolved type and invalid Boolean
  cases. Freeze creation-default typed literal/script output and absence
  semantics before adding defaults. These are proposed contracts, not evidence
  of extraction or enforcement.
- **C2 — common invocation and public equivalence before backend integration:**
  freeze registrations, binding/plan/capability accounting, predicate/operator
  schemas and request/result validation. A shipped target entry and independent
  process entry consume the same identified native+semantic payload and produce
  matching structured target witnesses. Consumer DSLs have the same registration
  route. Demonstrate adjacent/external/direct equivalence, raw-Boolean
  rejection, singleton blocking and conflict preservation. Bounded prototype
  evidence is separate from integrated execution.
- **C3 — before any publishing slice:** specify stable-base capture, private
  held-graph isolation, ordered single-invocation batches, defaults once, final
  all-role native plus semantic checks, final paths/membership, dry-run and
  exact-candidate publication. Real public Nix-to-Scribe G02 refusal with
  G01/G03 controls must preserve authored/held state and reload. Qualify
  create-plus-edge, endpoint replacement, related deletion, boundary/reference
  repair, stale base, moves and publication restore-or-block. Git staged-tree
  qualification remains separate; no lifecycle/participant implementation is
  required.
- **C4 — runtime adoption and packaging qualification:** retained later host
  evidence records CPython 3.14.6, StrictDoc 0.28.3 and rustworkx 0.17.1 loading
  together on x86_64-linux using StrictDoc's interpreter and temporary
  combined-closure site-packages `PYTHONPATH`. CLI imports and synthetic
  Parent/Child/DAG/path controls passed, not native parser/validator or Scribe
  enforcement. The earlier CPython 3.13.15/rustworkx 0.18.1 benchmarks are
  unchanged. Initial pairing is useful evidence; production packaging, supported
  platforms, native integration and dependencies only for enabled
  implementations remain required before adoption.

The [closing plan](closing-plan.md) orders later work. Full evaluation is the
initial oracle; incremental behavior is optional until implemented and qualified
over identical inputs. Extra backends, process sharing, optimized storage,
general cross-model continuity and consumer repair policies can remain open with
explicit unsupported errors. Trust/approval schemas, Git merge-before and crash
scope must be fixed before their own claims. Gate 2 stops at human review.
