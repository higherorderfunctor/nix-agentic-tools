**Gate 2 design drafts, using the proposed contract in
[interface.md](interface.md) and examples N1–N9 in
[recommended.nix](recommended.nix).** These are human recipes and steering
source, not runnable verification. Every operation/API is proposed unless
explicitly identified as an existing native command. Final commands and results
must be verified after implementation and the last qualification gate, before
landing. Steering module placement is deferred.

Use fresh copies of the [reference base](../model.md) for independent cases.
Unless specified otherwise, capture successful complete empty baseline S0. The
[reviewed requirements](reviewed-requirements.md) govern older pending labels.
Record exact candidate/before/policy/source identities and distinguish a
validation receipt from a publication receipt.

**P01 — Grammar, scoped targets and direct authoring.** Use N1's native `UID`,
FOO `FLAG`, Parent H/R and BAR Parent P/Child Q. Generate native grammar from
`model.elements` and compose policies separately. The existing public flow uses
`generate:sgra`, a grammar-loaded empty seed and a consumer-rooted Scribe
daemon; use bounded readiness checks. The clean proposed grammar is not yet
runnable on the installed Scribe field guard; do not add repository policy
fields to make a design demonstration appear integrated.

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
target to resolvable BAZ Z0 and expect `reference/R-target` with expected
FOO/actual BAZ. Let Z0 own Parent R to I0 as a positive scope control. For
direct authoring use N2 `directTarget` instead of the adjacent helper, with the
same normalized selector/config/inputs/needs. Do not define two conflicting
versions of that ID. Gate 3 must demonstrate a real Scribe refusal with
unchanged files, held model and reload; JSON acceptance alone is insufficient.

**Steering draft:** Identify the full grammar/owner/type/role selector. Use the
helper or its documented plain descriptor. A resolvable wrong type tests policy;
a missing UID tests input validation. Keep native grammar and policy artifacts
separate and inspect their effective identities.

**P02 — Complete native graph and selected forest.** Select only FOO Parent H
through `p.forest` and retain `reference/native-dag` across every native
Parent/Child role. Multiple roots and isolated nodes pass. A second distinct H
parent for F1a fails `reference/H/valid`, showing both parents. BAR M targeting
F2 through Child Q gives F2 another native parent but does not add an H parent.
Do not infer ancestry from document nesting or one-record-per-document
packaging.

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

**P03 — Visibility, nesting and unchanged links.** Use `p.visible`, the
validated H view and explicit false/open, true/closed mapping.
Unknown/missing/multiple FLAG values are input errors. From F1a, F2 is visitable
but F2a behind it is hidden; opening F2 allows the path. With the allowed link
already present, closing F2 must revalidate that unchanged link and refuse the
candidate. Repeat by moving an R target's H parent into F2's closed subtree.

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

**P04 — Native Child tailoring and endpoint changes.** N5 uses a native
adaptation statement owning both links, following the documented
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

Compose `tailoring.bundle`, `tailoringEndpoints` and a complete native-DAG rule
for that model. Connectivity stays STANDARD-1 → ADAPT-1 → OTS-1 without editing
either endpoint. Endpoint target/count rules are explicit consumer policies;
`p.bridge` without hierarchy emits counts only. A downward hierarchy is not
inherent in compliance modeling or native export.

For the neutral BAR bridge instead use N1's `p.bridge` with H and boundary. M
P=F0/Q=F2 passes; Q=F2a fails at F2; sibling and cross-root paths fail. Stage Q
removal/replacement in one private candidate so temporary zero/two counts do not
determine validity. An incomplete final M fails its count rule. Protect
OTS-owned content separately: a new incoming M-owned Child declaration does not
change the neutral owned projection of OTS.

**Steering draft:** Use an intermediate statement with owned Parent and Child
links when native traceability is wanted. Retain that statement as a graph node.
Apply a selected downward path only when the consumer declares one. Group
endpoint changes and check counts on the complete final candidate.

**P05 — Fields and a consumer tool.** Add N6's `ADAPTATION_FIELDS` grammar to
the same captured model and register `consumer/checks` plus `fieldBinding`. The
proposed `field-adaptation` entry consumes candidate and public forest view:

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
3. For N6's explicit union-DAG variant, derive upper→statement→lower for **all**
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

**P06 — Complete external snapshots and protection.** Use N1 `projection`,
`p.preserve`, and N3 `protectedSource`. The proposed source response value
inside a successful runner envelope for an empty baseline is:

```json
{
  "schema": "sdoc-policy.baseline/v1",
  "snapshotId": "S0",
  "complete": true,
  "data": {
    "schema": "sdoc-policy.baseline/v1",
    "model": "reference-model",
    "projectionDigest": "sha256:<configured-projection>",
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

**P07 — Main, authenticated identity, human review and supersession.** N4's
`lifecycle` is an optional consumer bundle. Compose it deliberately using
`withLifecycle`, including sources/bindings and trusted policy loading. The main
provider resolves the configured ref to an immutable commit and extracts records
with compatible grammar/model identity. It never silently fetches or substitutes
main for before. The principal provider must verify the actual
session/transport; separate SSH identities can later supply that binding. No
keys or UI are built here, and a claimed human label or Git author string does
not authenticate.

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

**P08 — Grouped daemon transactions and parallel contributors.** Use N8's daemon
boundary and N9's proposed `begin`, `stage`, `seal` messages. Begin at a
captured before revision with explicit participants and seal authority. Agent A
privately creates M/P; agent B adds Q at the next expected group revision.
Revision mismatch requires conflict resolution. Existing persisted mutations or
RPC arrays do not become part of a group because they happened nearby in time.

Select the consumer's sealing policy. With all-ready enabled, each readiness
acknowledgment binds the same revision; later staging invalidates it. An absent
participant or timeout is not consent. Without all-ready, an authorized seal can
still define a deliberate complete candidate. Membership/takeover changes must
be explicit. Seal freezes bytes; late writes conflict. If the published base
changes, merge/rebase privately and re-evaluate rather than reuse the old
receipt.

A complete M with one P/Q can publish; incomplete M fails without authored or
observable publication. Replacing Q in either staging order yields the same
final state. Abort discards staging; rejected candidates can remain inspectable.

**Steering draft:** Share an explicit private group and expected revisions.
Resolve conflicts and seal the intended final candidate under the chosen group
policy. Validate the whole final state. Serialized individual writes are not a
multi-operation transaction, and elapsed time never implies readiness.

**P09 — Staged-tree hooks and transaction then commit.** Use N8's commit
boundary alone or `both`. Capture the actual index tree including deletions,
relevant grammar inputs and authorized policy configuration. Keep unstaged edits
out of the candidate. Unmerged entries error. Choose before explicitly; merge
commits require a declared interpretation. Main remains its own captured fact.

On invalid/error, refuse this commit and leave the author's already staged and
worktree changes for repair. Bind the validated tree to the actual commit
through the enforcing adapter; merely checking then releasing an index has a
race. A local hook alone provides neither authenticated identity nor
non-bypassable commit enforcement. Require those capabilities only from a
qualified integration.

After daemon publication, stage the intended bytes and capture commit inputs.
Reuse a receipt only if all required identities/trust/freshness bindings match;
otherwise evaluate again. A refused hook does not undo a published transaction.
Latest-main-at-publication would require additional source capabilities;
captured per-evaluation main is the reference guarantee.

**Steering draft:** Check the captured staged tree with explicit before/main,
not the worktree. A refused hook blocks commit while retaining edits. Treat a
transaction followed by commit as two boundaries and reuse receipts only when
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
validation and publication separately. On uncertain timeout, query transaction
`status` before retrying. `restored` needs evidence that before was recovered;
`recovery-required` blocks writes. `recover` may clear that block only after
bytes and held/reloaded state agree. Retain affected paths/phase/identities.
Reload and cold-restart after accepted and rejected candidates; cache deletion
is a separate control, not evidence of restoration. Fault/crash windows and
external-reader scope still require qualification.

**Steering draft:** Keep invalid input inspectable and distinguish invalidity,
blocked prerequisites and execution errors. Never call a valid report a
published change. On publication uncertainty, inspect status and restore/verify
or keep writes blocked; do not infer file/Scribe/Git atomicity from a sidecar
transaction.

**P11 — Public adapters, native programs and explicit overrides.** N3 registers
an independent process with a `targets` entry under the same contract as the
shipped graph adapter. Apply `independentTargetBinding` to R only and compare
G02's helper/direct/independent results, including the owner/selector/type
witness. Shipped descriptors must satisfy the same `describe`, `plan`,
`evaluate` and schema validation. A missing rule result, unsupported
schema/capability or boolean-only visibility result lacking required path
evidence errors.

For native Rego use N7's module artifact, entrypoint, registration and explicit
`regoVariant` replacement. Preserve inputs/witnesses and strict CLI error
handling; undefined/malformed output is not success. Bun/Wasm is separately
qualified. Other public implementations may accept native Datalog and fixed
callbacks or ordinary executable code without a universal translation language.
A callback exception is an execution error. No health-only adapter advertises
graph checks.

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
captured inputs, including before. Caches are disposable. Policy and external
changes can invalidate unchanged records. Record workload/cost honestly and
never substitute resource truncation for complete semantic evaluation.

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
WORK/MECH/DEC nodes, spec/plan corpus, merge or Gate 3 advance belongs here. The
later coordinator provides the reviewable branch-chain web diff.

**Steering draft:** These are design drafts until implementation qualification.
After the last gate, verify recipes and clean generic Scribe and the entire
neutral fixture scope before folding into trial. Keep repository policy in
public consumer extensions and historical evidence outside the clean fixture
boundary.

**Coverage and delivery mapping.** All 44 reference IDs are mapped below; these
are future integrated evidence obligations, not tests executed by this worker.
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
| B01, B02, B03 | stage/seal/count; P04/P08                            | Complete grouped publication, missing endpoint refusal, staging-order equivalence                                                                        |
| B04, B05      | preserve plus conjunctive rules; P06                 | Full owned projection/deletion refusal, incoming/layout positives, unrelated visibility still enforced                                                   |
| B06, B07, B08 | publisher/status/recover; P10                        | Gate 4 refusal bytes/held/reload; Gate 6 failure injection, restore-or-block, cold restart                                                               |
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
| Daemon, hook and transaction-then-commit                        | P08/P09: group conflicts/seal, staged-tree capture, receipt mismatch and commit binding                                   |
| Flexible readiness and repair                                   | P08/P10: reference complete validity; other consumer policies explicit and qualified                                      |
| Capabilities, overrides and unprivileged bundled adapters       | P11: independent target/source and missing-result/schema/conflict failures                                                |
| Invalid inputs, publication isolation/recovery                  | P10: inspection, error causality, refusal, write restriction, fault/restore/block evidence                                |
| Neutral fixtures, repository policy and recipes                 | P13: after final gate, field-policy removal, full-scope absence, public extension proof, verified human/steering delivery |

Before Gate 3 implementation, resolve C1–C4 in [interface.md](interface.md) as
applicable to the first slice. Later trust, grouped publication, commit and
crash contracts must be fixed before their own capabilities are advertised. The
separate numeric extension above stays in later obligations and outside the
front review and completion recap.
