# Gate 2 playbooks and steering drafts

These are contract recipes under [interface](interface.md), synchronized to the
new schema/type `s` and constraint `c` direction. Exact names remain proposals,
not installed commands. The companion canonical source/tutorial supplies
complete examples; former N1–N9 labels are historical and do not govern these
recipes. Final runnable commands/results and matching steering-ready content
must be verified after implementation, before landing. Steering placement
remains deferred.

Use fresh copies of the [reference base](../model.md) for independent cases.
Unless specified otherwise, capture successful complete empty baseline S0. The
[reviewed requirements](reviewed-requirements.md) govern older pending labels.
Record exact candidate/before/policy/source identities and distinguish a
validation receipt from a publication receipt.

**P01 — Grammar, scoped targets and direct authoring.** Use explicit native
`UID`, semantic Boolean FOO `FLAG`, Parent H/R and BAR Parent P/Child Q.
Proposed `s.grammar` emits native elements, semantic metadata and a bundle.
Validate the native output and compose constraint contributions separately. The
existing public flow uses `generate:sgra`, a grammar-loaded empty seed and a
consumer-rooted Scribe daemon; use bounded readiness checks. The clean proposed
grammar is not yet runnable on the installed Scribe field guard; do not add
repository policy fields to make a design demonstration appear integrated.

A draft native record, assuming document/import and endpoint declarations:

```text
[FOO]
UID: F1a
FLAG: false
RELATIONS:
- TYPE: Parent
  VALUE: F1
  ROLE: H
```

Add F1a-owned Parent R to F2 and expect the target rule to pass. Change the
target to resolvable BAZ Z0 and expect the contextual named target rule with
expected FOO/actual BAZ. Let Z0 own Parent R to I0 as a positive scope control.
For direct authoring use `sdoc-policy.targets/v1` instead of the adjacent
`constraints.targetType = rel: c.isNodeType rel.target self`, with identical
contextual selector/config/inputs/needs and stable named rule identity. External
`c.on` attaches the same predicate. Do not define two conflicting versions of
that ID. Gate 3 must demonstrate a real Scribe refusal with unchanged files,
held model and reload; JSON acceptance alone is insufficient.

**Steering draft:** Identify the full grammar/owner/type/role selector. Use the
helper or its documented plain descriptor. A resolvable wrong type tests policy;
a missing UID tests input validation. Keep native grammar and policy artifacts
separate and inspect their effective identities.

**P02 — Complete native graph and selected forest.** Select only FOO Parent H
through `c.forest` and retain `reference/constraint/nativeDag` across every
native Parent/Child role. Multiple roots and isolated nodes pass. A second
distinct H parent for F1a fails `reference/view/H/valid`, showing both parents.
BAR M targeting F2 through Child Q gives F2 another native parent but does not
add an H parent. Do not infer ancestry from document nesting or
one-record-per-document packaging.

Test named Parent-only, Child-only and mixed cycles, including G07's
individually acyclic role projections. A reverse display name must not add
another authored edge. For a selected Child hierarchy, author the declarations
on each parent and choose its Child selector; normalized parent→child
connectivity should match the intended forest. Compare the ten literal
[Child controls](research/experiments/results/child-input.json). Equivalent
connectivity does not make Parent-owned and Child-owned protection projections
equal.

**Steering draft:** Preserve authored owner/target/type/role separately from
connectivity. All native Parent/Child edges need the complete DAG check; only
selected edges count toward the forest. Current named-role native acceptance is
a documented gap, not valid publication evidence.

**P03 — Visibility, nesting and unchanged links.** Use `c.boundaryVisibility`,
the validated H view and a typed `c.fieldValue` expression with false/open,
true/closed metadata. Unknown/missing/multiple FLAG values are input errors.
From F1a, F2 is visitable but F2a behind it is hidden; opening F2 allows the
path. With the allowed link already present, closing F2 must revalidate that
unchanged link and refuse the candidate. Repeat by moving an R target's H parent
into F2's closed subtree.

From inside F2, F2a may reach F2b or leave to F1a. A closed start is inside its
own boundary. A deeper closed boundary still blocks an origin outside that
deeper subtree. Unselected BAZ shortcuts never connect H roots. Use depths 1, 3
and 12 with positive controls and interior-boundary negatives where an interior
exists; there is no depth-1 interior negative or semantic depth cap. Resource
exhaustion is an error, not a new validity limit.

The full T11 truth table must remain visible in final verification:

| Candidate on fresh base | Required total outcome                                     |
| ----------------------- | ---------------------------------------------------------- |
| F1a R→F2                | Accept closed endpoint                                     |
| F1a R→F2a               | Reject at F2                                               |
| Same with F2 open       | Accept                                                     |
| F2a R→F2b               | Accept internal peer                                       |
| F2a R→F1a               | Accept exit                                                |
| F2 R→F1a                | Accept closed-origin exit                                  |
| F1a R→G1                | Reject distinct roots                                      |
| M P=F0, Q=F2            | Accept downward closed endpoint                            |
| M P=F0, Q=F2a           | Reject at F2                                               |
| M P=F2, Q=F2a           | Accept closed start                                        |
| M P=F1, Q=F2            | Reject sibling path, not downward                          |
| M P=F0, Q=G1            | Reject distinct roots                                      |
| M P=F2, Q=F2            | Reject native cycle                                        |
| F2 R→F2                 | Reject native self-cycle                                   |
| F2 R→F2a                | Reject native cycle; cannot isolate closed-start traversal |

**Steering draft:** Keep the original origin throughout traversal. Visit a
closed endpoint; expand a closed node only from inside its selected subtree.
Recheck unchanged dependents after closure or movement. Distinguish a native
cycle from a visibility failure and require the appropriate path/boundary
witness.

**P04 — Native Child tailoring and endpoint changes.** Use a native adaptation
statement owning both links, following the documented
[StrictDoc tailoring pattern](https://github.com/strictdoc-project/strictdoc/blob/b56ebb266c0a58f016c3be6ed5337c8a9833be0e/docs/strictdoc_01_user_guide.sdoc#L2347).
With REQUIREMENT endpoints declared, draft:

```text
[ADAPTATION]
UID: ADAPT-1
STATEMENT: Apply the standard to this deployment through the immutable OTS requirement.
RELATIONS:
- TYPE: Parent
  VALUE: STANDARD-1
  ROLE: Adapts
- TYPE: Child
  VALUE: OTS-1
  ROLE: AppliesTo
```

Compose the tailoring declaration, explicit endpoint target/count constraints
and a complete native-DAG rule for that model. Connectivity stays STANDARD-1 →
ADAPT-1 → OTS-1 without editing either endpoint. Endpoint target/count rules are
explicit consumer policies; Do not add a path predicate unless a hierarchy is
intentionally selected. A downward hierarchy is not inherent in compliance
modeling or native export.

For the neutral BAR bridge show P/Q `cardinality = c.exactly 1`, then a record
predicate using checked `c.only` and `views.visibility.canDescend` with H and
Boolean boundary. M P=F0/Q=F2 passes; Q=F2a fails at F2; sibling and cross-root
paths fail. Collect Q removal/replacement in one private candidate so temporary
zero/two counts do not determine validity. An incomplete final M fails its count
rule. Protect OTS-owned content separately: a new incoming M-owned Child
declaration does not change the neutral owned projection of OTS.

**Steering draft:** Use an intermediate statement with owned Parent and Child
links when native traceability is wanted. Retain that statement as a graph node.
Apply a selected downward path only when the consumer declares one. Group
endpoint changes and check counts on the complete final candidate.

**P05 — Fields and a consumer tool.** Add an `ADAPTATION_FIELDS` grammar to the
same captured model and register a consumer implementation with an explicit
field-check binding through the common JSON interface. The proposed
`field-adaptation` entry consumes candidate and public forest view:

```text
[ADAPTATION_FIELDS]
UID: ADAPT-FIELDS-1
STATEMENT: Consumer field policy checks this adaptation.
UPPER_UID: F0
LOWER_UID: F2
```

Implement these steps through the public rule protocol after approval:

1. Select the configured grammar/element; read exactly one upper/lower UID with
   field locations. Resolve in the configured model; missing/ambiguous endpoints
   are input errors, wrong types are policy findings.
2. Require the chosen downward H path and original-origin boundary semantics.
   Changing LOWER_UID to F2a produces a field-path finding at F2.
3. For the explicit union-DAG variant, derive upper→statement→lower for **all**
   such records, union with the complete native graph, and check cycles with
   field provenance. Equal endpoints fail. Checking never writes native links.
4. Return a complete result with contextual subjects, fields and witness. Bind a
   consumer projection if fields participate in protection.

Endpoint/path parity requires identical resolution, type/count and traversal
choices. Total graph-admissibility comparison also requires the union-DAG rule;
field-only path checks are weaker. Even the union variant does not supply native
link editing, reverse navigation, compliance exports or authored-link ownership
parity. Consumers may deliberately choose different custom logic instead.

**Steering draft:** Ordinary fields are not implicit native relations. Use the
registered consumer program and state whether virtual connectivity is checked.
Claim only the endpoint/path/union properties covered by the mapping; native
exports and preservation need separate evidence.

**P06 — Complete external snapshots and protection.** Use the explicit
preservation projection and named complete baseline source from the current
contract; the DSL helper lowers to `sdoc-policy.preserve/v1`. The proposed
source response value inside a successful runner envelope for an empty baseline
is:

```json
{
  "schema": "sdoc-policy.baseline/v1",
  "snapshotId": "S0",
  "complete": true,
  "data": {
    "schema": "sdoc-policy.baseline/v1",
    "model": "reference-model",
    "projectionDigest": "sha256:<configured-projection>",
    "semanticTypesDigest": "sha256:<semantic-types>",
    "records": []
  },
  "provenance": { "source": "consumer-baseline" }
}
```

For S1 add
`{ref:{model:"reference-model",uid:"I0"}, value:{element:{grammar: "reference",element:"FOO"}, fields:{FLAG:["false"]}, ownedRelations:[]}}`.
First require unchanged I0 to pass under this nonempty baseline; then change
only FLAG and require a preservation diff. Deletion and owned-H edits also fail.
Incoming declarations owned elsewhere, relation ordering and file relocation are
positive controls for this whitelist, subject to other rules. Under S0,
branch-only deletion/change can pass, while T02 still fails.

Inject provider nonzero exit, timeout, malformed stdout, declared incomplete,
missing identity, duplicate baseline keys and trust failure. None becomes empty
success or a policy violation. Capture S1, switch the source to S0 during the
run and retain S1 for that run; the next intentional evaluation may use S0.
Change source/config without SDoc edits and require new dependent results. The
[provider probe](research/experiments/scripts/providers.py) and
[v2 same-snapshot controls](research/experiments/results/opa-bun.json) cover
only narrower harness behavior, not this full contract.

**Steering draft:** Capture complete identified facts once per evaluation. Empty
success is legitimate; failed/incomplete acquisition is an error. Compare the
consumer's explicit owned projection, keep before distinct from baseline, and
invalidate results when sources or provider configuration change.

**P07 — Main, authenticated identity, human review and supersession.** A
lifecycle policy is an optional consumer-defined bundle of model/document/change
rules, not live transaction management. Compose it deliberately with explicit
sources/bindings and trusted policy loading. The main provider resolves the
configured ref to an immutable commit and extracts records with compatible
grammar/model identity. It never silently fetches or substitutes main for
before. The principal provider must verify the actual session/transport;
separate SSH identities can later supply that binding. No keys or UI are built
here, and a claimed human label or Git author string does not authenticate.

The example consumer denies LLM revisions of main-listed projections. Its
separate document rule compares before/candidate under the consumer's document
projection, selects trusted human/protected classifications, and requires a
verified approval bound to before, candidate, main, policy, principal and
action. A complete empty approval set produces `approval-required`; failed
acquisition produces error. Test branch-only permission, main denial,
missing/declined/valid approval and stale approval after any bound input
changes. A future UI must show the concrete diff and return a decision through
that trusted source.

These are illustrative policies, not the user's settled lifecycle. Define human
permissions, classifications, projection, approval expiry/revocation and any
supersession exception explicitly before the corresponding slice. Supersession
alone grants none. Approval does not waive an independent main denial or neutral
preservation; replace every affected consumer policy explicitly when changing
that lifecycle, while retaining structural constraints.

**Steering draft:** Use verified principal/main/classification/approval facts
from the configured authority. Treat lifecycle and supersession as consumer
policy. Bind human decisions to the exact candidate and input identities; do not
let an untrusted candidate policy disable its own protection.

**P08 — One-invocation ordered atomic batches.** One proposed Scribe invocation
carries an ordered operation list. Create M with explicit UID, add P=F0 and Q=F2
using that UID, then validate the complete candidate. Initial required endpoints
may be absent privately; final M must satisfy both counts. A current `new` with
initial relations demonstrates a smaller existing operation shape, not this
batch guarantee. RPC arrays independently calling `apply` are not an atomic
candidate.

Replace Q by remove/add or add/remove and require the same valid final one-Q
state. Close a boundary while removing/repairing the references it invalidates;
delete related records and references together. Final checks must use coherent
updated indexes, not stale graph lookup state. Keep syntax/type/existence checks
necessary for each operation; do not promise arbitrary forward references.

Capture before and authoritative base once, apply operations privately,
materialize defaults, freeze bytes/paths/membership/inputs and complete native
plus semantic validation. Publish exactly that candidate or return dry-run
diff/report. A stale base refuses and requires a new preparation. No operation
replay or provider rerun occurs at publication. No public
begin/stage/seal/abort, participants or readiness are required; this is a single
invocation, not a contributor coordination service.

**Steering draft:** Put related changes into one ordered invocation and
reference earlier explicitly created UIDs. Check final-state validity. Dry-run
and real write share preparation, not replay. Refusal discards private state and
leaves published files/model unchanged.

**P09 — Staged-tree hooks and Scribe then commit.** Select a Git staged-tree
check alone or after a Scribe atomic batch. Capture the actual index tree
including deletions, relevant grammar inputs and authorized policy
configuration. Keep unstaged edits out of the candidate. Unmerged entries error.
Choose before explicitly; merge commits require a declared interpretation. Main
remains its own captured fact.

On invalid/error, refuse this commit and leave the author's already staged and
worktree changes for repair. Bind the validated tree to the actual commit
through the enforcing adapter; merely checking then releasing an index has a
race. A local hook alone provides neither authenticated identity nor
non-bypassable commit enforcement. Require those capabilities only from a
qualified integration.

After daemon publication, stage the intended bytes and capture commit inputs.
Reuse a receipt only if all required identities/trust/freshness bindings match;
otherwise evaluate again. A refused hook does not undo a published Scribe batch.
Latest-main-at-publication would require additional source capabilities;
captured per-evaluation main is the reference guarantee.

**Steering draft:** Check the captured staged tree with explicit before/main,
not the worktree. A refused hook blocks commit while retaining edits. Treat a
Scribe batch followed by commit as two boundaries and reuse receipts only when
all required bindings match.

**P10 — Invalid input, refusal, publication and recovery.** Inspect invalid
input and retain available native/custom diagnostics. A malformed field or
unresolved endpoint differs from a wrong target type. An invalid forest blocks
its path rules; missing before/baseline blocks comparisons. State-only results
may still be useful, but omitted required rules cannot yield valid.

Under reference `complete-validity`, repair the entire final candidate before
publication. Alternative admission is an explicit consumer implementation with
before-violation comparison; retain underlying invalidity and required inputs.
An approval or waiver must not silently turn structural failure into
satisfaction.

Test T07 refusal by comparing authored bytes and observable held state to
before. Then test valid T06 with injected file/model/publication failure. Report
validation and publication separately. On uncertain completion, inspect actual
publication state before retrying; no public transaction API is prescribed.
`restored` needs evidence that before was recovered; `recovery-required` blocks
writes. Clear that block only after bytes and held/reloaded state agree. Retain
affected paths/phase/identities. Reload and cold-restart after accepted and
rejected candidates; cache deletion is a separate control, not evidence of
restoration. Fault/crash windows and external-reader scope still require
qualification.

**Steering draft:** Keep invalid input inspectable and distinguish invalidity,
blocked prerequisites and execution errors. Never call a valid report a
published change. On publication uncertainty, inspect status and restore/verify
or keep writes blocked; do not infer file/Scribe/Git atomicity from a sidecar
transaction.

**P11 — Public adapters, native programs and explicit overrides.** Register an
independent process with a `targets` entry under the same contract as the
shipped graph adapter. Apply `independentTargetBinding` to R only and compare
G02's helper/direct/independent results, including the owner/selector/type
witness. Shipped descriptors must satisfy the same `describe`, `plan`,
`evaluate` and schema validation. A missing rule result, unsupported
schema/capability or boolean-only visibility result lacking required path
evidence errors.

For native Rego use an identified module artifact, entrypoint, public
registration and explicit digest-guarded replacement. Preserve inputs/witnesses
and strict CLI error handling; undefined/malformed output is not success.
Bun/Wasm is separately qualified. Other public implementations may accept native
Datalog and fixed callbacks or ordinary executable code without a universal
translation language. All configuration and results still pass through the
common Nix-configured JSON boundary; consumer-defined DSLs can emit their own
versioned contracts and implementation bindings. This is not an alternate bypass
configuration system. A callback exception is an execution error. No health-only
adapter advertises graph checks.

Try conflicting definitions under one ID, stale/unknown replace or disable,
competing replacements, broken view dependencies and duplicate registrations.
Expect configuration errors independent of order. Inspect effective definitions,
expanded child IDs, origins and bindings. Replacing a rule retains its ID and
changes its definition digest; replacing an implementation changes registry and
receipt identity. A disable cannot erase a required native profile invariant.

**Steering draft:** Register shipped and independent tools through the public
contract. Use explicit bindings and digest-guarded replacements/disables, never
module precedence. Require complete results and useful witnesses. Compare
specific claimed helper/direct/native equivalence on identical captured inputs.

**P12 — Renaming, relocation, rebuild, incrementality and cost.** Rename all
fixture tags, roles, fields and UIDs consistently and map witnesses back; no
consumer names may become engine dispatch keys. Change selector components
independently. Reorder declarations and move documents: the neutral set
projection stays equivalent but locations refresh. Explicit document rules may
differ.

Keep complete before/candidate/policy/source envelopes. Run
insertions/deletions, role/endpoint changes, closure toggles, subtree moves and
batches through full evaluation. Once an incremental path exists, replay those
same envelopes and compare every result and meaningful witness. Include
policy/provider-only changes, negative lookups and collection membership. Delete
only disposable index/cache state and rebuild; authored data and outcomes must
remain unchanged.

Measure roughly 1,000/10,000 records, shallow/wide and deep/narrow with varied
edge density and many policy subjects. Separate parsing, initialization,
serialization, provider calls, local edit, subtree move, source revision,
rebuild and publication. Record scans/invalidation and warm/cold cost. The
supplied single-query probes do not determine an all-rule production SLA or
prove true incremental maintenance.

**Steering draft:** Compare full and incremental evaluation over the same
captured inputs, including before. Caches are disposable and writable derived
state. Rejected-candidate caches may remain under their exact dependency
identities; they cannot become accepted state. Type mapping/version,
parser/backend/config/policy, facts and before/baseline join verdict keys where
relevant; structural indexes need only their actual inputs. Corrupt caches
rebuild or error. No commit/rollback callback is required just for cache
management. Policy and external changes can invalidate unchanged records. Record
workload/cost honestly and never substitute resource truncation for complete
semantic evaluation.

**P13 — Qualification, clean fixtures and final delivery.** Preserve the
[closing obligations](closing-plan.md). After the final gate, remove mandatory
repository-specific field policy from generic Scribe. Final neutral fixture
scope must contain **no `AUTHORED_BY` or `PARENT_FP` declarations/content
anywhere**, no renamed substitutes and no historical accommodations hidden in
fixture notes. Move historical evidence outside that scope while preserving
provenance. Prove neutral operation without hidden repository grammar/modules
and exercise repository policy through public helpers/adapters/tools.

Replace every proposed operation with verified supported commands before
landing. Deliver human Markdown and matching generated-steering source for every
family above, including both tailoring representations, failures and positive
controls. Keep steering placement deferred and do not migrate to SDocs yet. No
WORK/MECH/DEC nodes or spec/plan corpus changes belong to this revision;
advancement to Gate 3 requires a subsequent user decision. Provide a reviewable
branch-chain diff for the later human decision.

**Steering draft:** These are design drafts until implementation qualification.
After the last gate, verify recipes and clean generic Scribe and the entire
neutral fixture scope before folding into trial. Keep repository policy in
public consumer extensions and historical evidence outside the clean fixture
boundary.

**P14 — Semantic types and creation defaults.** Declare FLAG once with proposed
`s.field.boolean "FLAG" { required = true; default = s.default.literal false; }`.
Force native singleChoice lowering and separately identified metadata with
grammar/element/field reference, canonical false/true encoding, version/digest
and required scalar multiplicity. Native placeholders `TBD`/`TBC`, unknown
strings, a present empty list and multiple values are input errors, never false.
Native choice acceptance alone is not semantic Boolean validation.

Create a record with final absence and expect one default materialization.
Explicit false and empty strings remain present; invalid supplied values are not
replaced. For a string script default,
`{"protocol":"sdoc-default/v1","requestId":"example","status":"ok","value":""}`
is successful empty data; empty stdout, missing value, nonzero exit, malformed
output, timeout and wrong type are provider errors. No eval-time acquisition or
backfill on existing edits/checks/moves. Creation followed by explicit set uses
that value; creation followed by unset defaults final absence; creation then
deletion runs no provider. Keep identity-provider examples simple; authored
identity is not authentication.

Dry-run resolves once for its own candidate; real publication resolves once for
its own preparation and publishes that captured value without replay. Two
explicit invocations may obtain different values. Verify required-field
construction and empty serialization through the eventual native adapter:
current source rejects missing required creation fields and empty strings, so
this is a later integration obligation, not current enforcement.

**Steering draft:** Use presence, not truthiness. Defaults fill only surviving
newly created final absence, once. Retain type metadata with the native values.
Provider failure is error; defaulting never repairs an invalid supplied field or
silently fills an old record.

**P15 — Frozen moves, reads and derived state.** Prepare moves with old/new
path, bytes, deletions and document membership, then run document/change rules
against the proposed location. Publish exact frozen bytes instead of rendering
again at save. Run concurrent readers/exporters against accepted state during
refused/dry-run candidates and require no shared mutable-object/index leakage.
Update or rebuild relevant indexes before full validation; do not mistake an
immutable wrapper for an immutable graph.

Caches/scratch may be written on dry-run or rejection under actual input
identity. Candidate/before/baseline/metadata remain fixed read-only authority.
Verify stale-base refusal for relevant published document/grammar/config changes
and test partial publication plus failed restoration. State the actual
trust/locking/crash/external-reader boundary. No general filesystem transaction
or security subsystem is part of this recipe.

**Steering draft:** Include paths and membership in the validated candidate,
inspect the exact diff, and never replay at publication. A rejected cache is
disposable derived state, not accepted authority. Report restore-or-block
honestly when publication fails.

**Coverage and delivery mapping.** All 44 reference IDs are mapped below; these
are future integrated evidence obligations, not executed integration tests.
G/T/E/B/X refer to [scenarios](../scenarios.md); P refers to the recipe above.
Reviewed additions follow the table. Gate labels are sequencing, not
authorization. `Unchanged` assertions apply to strong private publication; a
hook instead refuses a commit and retains edits.

| Cases         | Contract / recipe                                    | Required delivery                                                                                                                                        |
| ------------- | ---------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G01, G02, G03 | targets; P01/P11                                     | Gate 3 native-valid target pass/refusal/scope control, real Scribe bytes/held state/reload                                                               |
| G04, G05      | forest-valid/view; P02                               | Gate 4 roots/isolated positive and selected second-parent witness                                                                                        |
| G06, G07      | required native-dag; P02/P10                         | All-role Parent/Child/mixed cycle rejection through complete-candidate integration                                                                       |
| G08, G09      | forest plus bridge; P02/P04                          | Selected-parent count unaffected by other native parents; owned Parent/Child bridge retained                                                             |
| T01, T02, T03 | visible; P03                                         | Gate 4 closed endpoint/interior/open controls with correct paths                                                                                         |
| T04, T05      | complete candidate/view invalidation; P03/P12        | Unchanged-link revalidation after closure and subtree move                                                                                               |
| T06, T07      | endpoint-path; P04/P10                               | Native-valid downward bridge pass/refusal and unchanged state                                                                                            |
| T08, T09      | selected forest/boundary; P03                        | Unselected shortcut, cross-root and nested-boundary controls                                                                                             |
| T10, T11      | visible/endpoint-path/native-dag; P03                | Depth 1/3/12 controls and all 15 truth rows above; correct native producer                                                                               |
| E01, E02      | preserve/source; P06                                 | Same nonempty baseline unchanged/changed pair, then same edit under S0                                                                                   |
| E03, E04      | snapshot identity/empty success; P06/P12             | Source-only invalidation and deletion with complete empty data                                                                                           |
| E05, E06      | capture/error envelope; P06                          | Nonzero/timeout/malformed/incomplete and capture-time source-change injection                                                                            |
| E07           | public source registration; P06/P11                  | Gate 5 independent packaged executable repeats S1/S0 via normal extension                                                                                |
| B01, B02, B03 | ordered batch/count; P04/P08                         | Complete grouped publication, missing endpoint refusal, staging-order equivalence                                                                        |
| B04, B05      | preserve plus conjunctive rules; P06                 | Full owned projection/deletion refusal, incoming/layout positives, unrelated visibility still enforced                                                   |
| B06, B07, B08 | publisher/restore-or-block; P10                      | Gate 4 refusal bytes/held/reload; Gate 6 failure injection, restore-or-block, cold restart                                                               |
| B09           | declared before/baseline inputs; P06/P10             | Missing required input errors with no substitution/publication                                                                                           |
| X01, X02, X03 | descriptors/bindings/model identity; P01/P02/P11/P12 | Gate 5/6 helper/direct/backend witness parity, renaming, ordering and relocation                                                                         |
| X04, X05, X06 | full reference/receipt/cache contract; P12           | Gate 6 incremental differential sequence, cache rebuild and policy/provider-only changes                                                                 |
| X07           | separate later consumer extension; P11               | Gate 5 only after separate review: numeric descendant sum/external limit, contributor witnesses, direct/tool/helper forms; no core fixture extension now |
| X08           | full evaluation measurements; P12                    | Gate 6 representative all-rule cost, scans/provider/serialization/invalidation/rebuild and correctness                                                   |

| Reviewed addition                                               | Recipe and later evidence                                                                                                 |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Actual selected Child hierarchy                                 | P02/P03: ten literal direction/boundary controls, plus unchanged-link integration                                         |
| Native compliance/immutable OTS tailoring                       | P04: ownership/native exports and consumer endpoint policy; optional selected path                                        |
| Alternative field/custom logic                                  | P05: independent program, field witnesses, explicit union-DAG and limited parity                                          |
| Whole-graph/document/change composition                         | P01/P07/P11: model rules plus document rule reading before and complete graph                                             |
| Trusted main, SSH principal, human/protected HITL, supersession | P07: authority/binding/expiry and consumer lifecycle positive/negative controls; no key/UI work now                       |
| Atomic Scribe invocation, hook and batch-then-commit            | P08/P09: ordered candidate/stale-base refusal, staged-tree capture, receipt mismatch and commit binding                   |
| Final-state validity and repair                                 | P08/P10: reference complete validity; other consumer policies explicit and qualified                                      |
| Capabilities, overrides and unprivileged bundled adapters       | P11: independent target/source and missing-result/schema/conflict failures                                                |
| Invalid inputs, publication isolation/recovery                  | P10: inspection, error causality, refusal, write restriction, fault/restore/block evidence                                |
| Neutral fixtures, repository policy and recipes                 | P13: after final gate, field-policy removal, full-scope absence, public extension proof, verified human/steering delivery |

Before Gate 3 implementation, resolve C1–C4 in [interface.md](interface.md) as
applicable to the first slice. Later trust, atomic publication, commit and crash
contracts must be fixed before their own capabilities are advertised. The
separate numeric extension above stays in later obligations and outside the
front review and completion recap.

| Revision cases | Contract / recipe                    | Required later evidence                                                                                              |
| -------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| DFT01–DFT07    | Types/defaults; P14                  | Native+semantic metadata, false/empty, invalid values, script failures, final absence and once-per-candidate capture |
| A01–A03        | Atomic batch; P04/P08                | Create-then-edge, endpoint replacement, coordinated boundary/reference repair and related deletions                  |
| A04–A08        | Frozen candidate/caches; P10/P12/P15 | Move membership, stale base, reader isolation, restore-or-block, rejected cache and metadata invalidation            |
| A09–A10        | Common contract/composition; P01/P11 | Consumer DSL registration, independent result parity, raw Boolean error, zero collection and blocked singleton       |
| A11            | Git staged tree; P09                 | Refused hook preserves index/worktree and prior Scribe publication                                                   |
