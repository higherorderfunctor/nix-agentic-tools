# Draft human recipes and agent steering

**PROPOSED Gate 2 content.** These are actual draft playbooks for review, not
commands verified against an installed semantic engine. Proposed operation names
below describe the interface in [design.md](design.md) and data in
[examples.nix](examples.nix). Final runnable verification belongs after
implementation and the final qualification gate, before landing. The native
grammar constructors exist today; new policy helpers, group operations,
providers and publication guarantees do not. Current generic Scribe still has
temporary guarded-field requirements, so the clean neutral examples are not
claimed loadable there tonight.

Each recipe includes a paste-ready steering paragraph. Keep its qualification
label when generating steering until it has been verified. Steering module
placement is deferred. Start each reference case from its named fresh base, not
from an accumulation of earlier example links. Capture complete empty S0 unless
the case calls for S1. Record a validation receipt separately from a publication
receipt.

**V2 evidence update:** The original recipes accompanied the v1-based design,
archived independently by root. The
[v2 review note](design.md#v2-evidence-review) records the corrected Child and
protection controls and current costs; the interface is unchanged. Updated
[research replay instructions](../../research/reproduce.md) require a disposable
copy of experiments, with `inputs/research-v2` as this workspace's packet. They
are evidence-replay guidance, not runnable production recipes or authorization
to acquire dependencies in this review.

## R01: Native grammar, contextual targets and forest structure

Use `N1` in `examples.nix`: declare required `UID` and the required
single-choice string `FLAG` on FOO. Keep Parent H/R and BAR's Parent P/Child Q.
Generate the native grammar from `model.elements`; attach `model.bundle` and
`graphBundle` separately. For the future installed flow, retain `generate:sgra`,
a grammar-loaded seed and a daemon rooted in the consumer's document set. Use
bounded readiness retries before authoring; a connection timeout is not a graph
error. Do not infer ancestry from document nesting or the current
one-node-per-document packaging.

Draft record content for the reference hierarchy:

```text
[FOO]
UID: F1a
FLAG: false
RELATIONS:
- TYPE: Parent
  VALUE: F1
  ROLE: H
```

With endpoint records present, add `Parent R -> F2` to F1a: FOO is a permitted
target. Try `Parent R -> Z0` instead with Z0 a resolvable BAZ: expect a
target-type finding, not a missing-UID error. Let Z0 own its own
`Parent R -> I0`: this selector has a different owner element and does not
inherit FOO's restriction. Keep isolated roots; add a second H parent to F1a and
expect both parent IDs in the refusal. Other roles can supply native parents
without increasing its H count.

Validate all native Parent/Child edges for cycles, including mixed named roles.
Preserve authored direction and owner in diagnostic/export facts. Stock
named-role cycle acceptance is a known gap, not permission to publish. Future
qualification must compare bytes and observable state after refusal, reload, and
cold restart.

**Steering draft:** Use declared `UID`s and full grammar/element/type/role
selectors. Preserve authored Parent/Child ownership. Several roots are valid; at
most one selected H parent is allowed. Run the complete native DAG check across
all roles. A passing stock named-role load is insufficient evidence of cycle
safety.

## R02: Closed boundaries and unchanged relationships

Use `forest.view`, `boundary`, `fixture/R-visible`, and `fixture/bridge/path`.
Begin with F2 closed, F2a/F2b below it, and F1a in the open sibling branch.
`F1a R -> F2` can visit the boundary; `F1a R -> F2a` must identify F2 as
blocking expansion. Open F2 and the latter can pass. Then close F2 without
changing R: the candidate must still reject because the unchanged link becomes
hidden.

From a fresh base, `F2a R -> F2b` is allowed because the original origin is
inside F2. `F2a R -> F1a` can leave. A bridge from closed F2 down to F2a can
start inside. Add a deeper closed boundary under F2: an origin inside F2 but
outside the new boundary still cannot traverse that new interior. Moving an R
target's H parent into a closed subtree requires the same nonlocal revalidation.

Use a native-valid sibling-origin relation when testing visibility.
`F2 Parent R -> F2a` and equal-endpoint bridges already form native cycles; they
cannot isolate visibility behavior. Repeat open chains at depths 1, 3, 12 and
later larger measured depths without changing policy. There is no semantic depth
cap. Cross-root links and unselected-role shortcuts cannot satisfy the
selected-path rule.

V2 now demonstrates traversal over an actually Child-authored selected
hierarchy, not just exclusion of the opposite relation kind. Its
[literal input](../../research/experiments/results/child-input.json) and
backend/Wasm results include forward versus reverse descent and closed-origin
controls. Later adapter qualification should retain these direction controls:
Parent normalizes target-to-owner, Child owner-to-target. The reference N1
example continues to select Parent H; changing authored direction must preserve
the chosen ancestry interpretation, not blindly reverse every edge.

**Steering draft:** Evaluate visibility relative to the original origin and the
chosen hierarchy. A closed endpoint is visitable; its interior expands only for
an origin already inside. Revalidate unchanged links after closing or moving
nodes. Preserve nested boundaries and distinguish native-cycle refusals from
traversal findings.

## R03: Native Child tailoring

Use `nativeTailoring` from `N6`, plus consumer-selected endpoint types. Assume
STANDARD-1 and OTS-1 already exist and have suitable grammar declarations. Draft
authored content:

```text
[ADAPTATION]
UID: ADAPT-1
STATEMENT: Apply STANDARD-1 to this deployment through the immutable OTS requirement.
RELATIONS:
- TYPE: Parent
  VALUE: STANDARD-1
  ROLE: Adapts
- TYPE: Child
  VALUE: OTS-1
  ROLE: AppliesTo
```

The adaptation owns both declarations; connectivity is
`STANDARD-1 -> ADAPT-1 -> OTS-1`. Leave the standard and OTS records untouched.
Reverse display labels are navigation labels, not authored reciprocal links.
This follows the supplied research's upstream tailoring/compliance-matrix
evidence; rendering and the future public integration still need verification.

For the neutral bridge case use BAR M with `P=F0,Q=F2`: require exactly one
endpoint of each kind and a downward H path. Replace Q in one grouped candidate
so intermediate zero/two links stay private. `P=F0,Q=F2a` fails at F2.
`P=F1,Q=F2` is a sibling path and fails the downward condition. Tailoring
between standard and OTS records does **not** automatically require this neutral
H path; enable a path policy only when that consumer has deliberately modeled
one.

**Steering draft:** Prefer a native adaptation/compliance record owning Parent
to the upper requirement and Child to the lower project/OTS requirement. Keep
the record in connectivity. Stage endpoint changes together. Apply only the
endpoint/path policies configured by this consumer; the reference H hierarchy is
not a universal tailoring requirement.

## R04: Field-oriented tailoring and custom logic

Use `fieldTailoring` and `fieldBridgeRule` from `N6` as a separate consumer
model. Draft content:

```text
[ADAPTATION_FIELDS]
UID: ADAPT-FIELDS-1
STATEMENT: Check this adaptation using the consumer's field policy.
UPPER_UID: F0
LOWER_UID: F2
```

Register `consumer-python` through `N4`. The proposed `field_bridge:check`
algorithm is concrete:

1. Select `ADAPTATION_FIELDS` in the configured grammar. Read each required
   field as one UID, with a field source span. Reject absent/malformed/ambiguous
   identifiers as input errors.
2. Resolve endpoints in `endpointGrammar`; enforce `endpointElement` with both
   expected/actual types in findings.
3. Read the explicitly named valid hierarchy. Require the downward path; visit a
   closed endpoint and expand according to the original upper endpoint's
   position.
4. For the equivalence variant requested in N6, add virtual edges
   `upper -> adaptation -> lower` to a disposable view of the complete native
   graph and check the union DAG. Include all field adaptations in that union.
   Report virtual edges with field provenance and never write native links while
   checking.
5. Return a complete result tied to the evaluation and rule. Preserve the
   underlying authored fields in protection projections chosen for this model.

Change `LOWER_UID` to F2a and expect a field-path finding at F2. Equal endpoints
must fail the virtual union-DAG variant. If the consumer elects field-only
endpoint/path checking without the union check, document the weaker semantics.
Field results cannot establish native traceability, reverse navigation,
compliance-matrix export or native-link protection equivalence. A mapping to a
shared endpoint projection may compare decisions; it does not make the authored
models identical.

**Steering draft:** Field references are consumer data. Resolve and validate
them through the registered callback; do not pretend they are authored
Parent/Child links. State whether virtual connectivity is checked. Compare only
the decision/projection properties covered by the explicit mapping, and do not
promise native exports without native relations.

## R05: Captured baseline and external programs

Use `authoredProjection`, `preservation`, and the public `fact` descriptors
(`N3`/`N4`). The baseline executable reads a capture request on stdin and writes
one protocol result to stdout; operational logs go to stderr. Draft success
messages illustrate the proposed wire contract:

```json
{
  "status": "complete",
  "id": "S0",
  "schema": "protected-records/v1",
  "data": [],
  "provenance": { "source": "consumer-baseline" }
}
```

```json
{
  "status": "complete",
  "id": "S1",
  "schema": "protected-records/v1",
  "data": [
    {
      "grammar": "fixture",
      "uid": "I0",
      "element": "FOO",
      "fields": { "FLAG": "false" },
      "ownedNativeRelations": []
    }
  ],
  "provenance": { "source": "consumer-baseline" }
}
```

The proposed `protected-records/v1` wire schema uses a list with explicit
grammar and UID, matching N10. The host validates unique contextual keys and may
index these records internally. Duplicate keys are input errors, never
last-writer selection; qualification must test this conversion. S0 explicitly
means successful complete empty acquisition. Nonzero exit, timeout, malformed
output, missing identity or `complete=false` must never be treated as S0. The
host binds provider artifact/configuration and content digest, not just its
display ID.

First retain I0 unchanged under nonempty S1 and require no preservation finding.
Then change only its projected FLAG under that same snapshot and require I0's
violation. V2 [CLI results](../../research/experiments/results/finalists.json)
and [Wasm results](../../research/experiments/results/opa-bun.json) now exercise
this narrow positive/negative pair; v1 lacked the unchanged positive control.
This does not establish full ownership projection or acquisition-to-verdict
integration, which still need implementation qualification.

Under S1, try changing I0's FLAG or deleting I0: expect preservation findings
with baseline identity and field/existence diff. Under S0 the same isolated
changes can pass, subject to all other rules. Add an incoming link owned by
another record or move I0's file without changing modeled ownership:
preservation alone permits these positive controls. Reordering owned relation
declarations does not change the set projection. An owned H edit does.

Capture S1, then change the source to S0 during evaluation: the current run
still uses S1; the next deliberate evaluation can use S0. Change S0 to S1
without editing SDoc and rerun: stale success must be invalidated. Save before
separately from baseline; do not replace missing before with candidate or branch
HEAD with main.

**Steering draft:** Pin a complete identified baseline once per evaluation.
Empty success is distinct from provider failure. Freeze the consumer's chosen
ownership projection, not arbitrary incoming links or layout. Keep
before/candidate/main distinct, and re-evaluate when source or provider
configuration changes even if SDoc does not.

## R06: Verified actor, main protection, HITL and supersession

Select `lifecyclePolicy` only after choosing consumer rules. Resolve main to an
immutable identified model through a trusted provider. The configured principal
provider must bind the request to a verified session/identity, for example a
future SSH identity service. Never accept request labels or authored attribution
fields as proof of a human. Classification can come from a trusted main/history
source and remains separate from node authoring fields.

For the illustrative `main-llm` policy, an LLM change to a main-listed record
produces a denial. A branch-only change can pass that rule. For the
document-review policy, changing a human-authored/protected document produces
`needs-review` unless a verified approval covers the exact
before/candidate/effective-policy/main/principal binding. Draft approval payload
content:

```json
{
  "decision": "approve",
  "decisionId": "review-17",
  "approver": "verified-human-42",
  "binding": {
    "before": "model-before-42",
    "candidate": "model-candidate-43",
    "policy": "effective-policy-9",
    "main": "main-model-A",
    "principal": "verified-session-8"
  }
}
```

This is the data a future UI could submit to a trusted approval service; the
object alone is not an authenticated approval. Show a concrete diff and findings
in that UI. Any subsequent candidate change needs a new binding. Acquisition
failure is an operational error, distinct from a human declining or no approval
existing.

An approval cannot override an independently active main-LLM denial or neutral
preservation. To support an approved supersession workflow, explicitly replace
the relevant consumer policy with documented transition rules and adjust any
conflicting preservation policy through an identity-targeted edit. A superseding
relation alone grants no deletion/revision exception. No key handling or UI
implementation is needed for this draft.

**Steering draft:** Use verified external principal and approval facts. Never
claim `actor=human` authenticates a request. Present the exact candidate for
HITL and bind the decision to its inputs. Treat supersession exceptions as
explicit consumer policy; approvals do not silently waive other active rules.

## R07: One candidate shared by parallel agents

Use the `groupMessages` example (`N10`) and daemon boundary (`N8`). Begin a
private group at a captured base and name the participants. Agent A creates M
and its Parent P endpoint; agent B adds M-owned Child Q. Stage requests carry
expected revisions, so conflicting work must be resolved deliberately. Neither
agent should call an ordinary persisted mutation and assume it belongs to the
private group.

Both participants mark the final revision ready; the coordinator finalizes that
revision. Later staging clears readiness. A missing participant leaves the
candidate inspectable and incomplete; timeout is not readiness. Membership
changes or coordinator takeover require the consumer's authorized group
operation. If the published base changes, report stale candidate, explicitly
merge/rebase private changes, and validate again.

Final M with one P and one Q can pass even though intermediate staging could
not. Final M without Q fails and leaves published state unchanged. Replacing Q
in either staging order yields the same final result. Abort drops private
staging without authored publication. Record all participant patches and the
selected before/candidate identities for review, without inferring authorization
from a participant's chosen name.

**Steering draft:** Group related agent edits explicitly. Work in private
candidate staging, attach expected revisions, and signal readiness for the final
revision. Only the designated coordinator finalizes. Validate the complete
candidate once membership is ready; individual serialized writes or RPC arrays
are not transactions.

## R08: Git commit boundary, or daemon then commit

Choose `boundaries.git` or `boundaries.both` from `N8`. In Git-only mode,
assemble the intended staged tree, including deletions and applicable grammar
inputs. Capture the index tree, an explicit before tree and a resolved main
baseline. Do not validate the unrelated worktree; unstaged edits must not
accidentally influence the result. Unmerged index entries cannot produce a
complete candidate. Merge-before interpretation is a consumer configuration
choice and must be supplied.

The hook blocks commit for invalid/incomplete results and retains the user's
staged/worktree edits. It does not promise to restore the files to their
pre-edit content. Check the index identity again before the commit adapter
proceeds; a changed index invalidates the receipt. A local hook alone is not
authenticated enforcement against bypass; the consumer's trusted publication
path determines enforcement scope.

For daemon-then-commit, publish the private transaction under its strong
boundary, stage the intended resulting bytes, and capture the actual commit
inputs. Reuse the earlier receipt only when relevant identities and
freshness/approval requirements match exactly. An unrelated staged edit,
different before tree, changed policy, or new main snapshot requires another
evaluation. Rules keep the same meaning; their selected transition may differ.

**Steering draft:** Validate the captured staged tree at a commit boundary. Keep
main and before explicit. A refused hook preserves staged work and blocks
commit; it is not private staging. After daemon publication, verify commit
inputs and reuse a receipt only when its bindings still match.

## R09: Invalid input, diagnostics and deliberate repair

Load invalid authored input for inspection and ask for the complete available
diagnostic report. Missing UID, duplicate identity, missing endpoint and
malformed FLAG are input problems. A valid endpoint of the wrong type is a
policy violation. If H is not a forest, report its structural findings and mark
dependent traversal rules blocked; do not fabricate a path. Missing
before/baseline makes the dependent rule unevaluable even if state-only checks
can still run.

For the reference repair profile, stage all repairs needed for a valid final
candidate. A repair that leaves an unrelated required violation still cannot
publish. Retain the invalid candidate and its findings for the author. If a
consumer later wants progressive repair, explicitly choose and qualify its
before-violation comparison; do not silently turn diagnostics into warnings.

A useful target finding shows stable rule ID, contextual selector, owner,
target, expected/actual element and source. A visibility finding adds path and
blocked boundary; a parent-count finding lists all selected parents; a
preservation finding shows captured baseline and modeled diff. Sort findings for
readability while comparing their semantic content rather than incidental order.

**Steering draft:** Keep invalid input inspectable. Distinguish input errors,
policy findings, missing prerequisites and execution failures. Repair against
the configured final-candidate policy. Do not erase a failing rule or relabel
its finding to obtain a pass.

## R10: Refusal, publication failure and recovery

In the strong daemon profile, first try `M: P=F0,Q=F2a`. The semantic refusal
must leave authored bytes and public graph at before; private staging may remain
for inspection. Then try valid `M: P=F0,Q=F2` and, in a later qualification
harness, inject failure between validation and publication/model reload. A valid
result alone must never be reported as a completed mutation.

On uncertain publication failure, inspect the transaction ID and recorded phase
before retrying. The publisher reports either verified restoration or
`recovery-required`, with writes blocked. Show before/after identities, affected
paths, restored paths, and pending reload/recovery actions. Follow the qualified
recovery operation, then verify authored bytes and held/reloaded model agree. Do
not manually edit disposable indexes to manufacture agreement or clear a block
without evidence.

Reload and cold-restart after both accepted and rejected cases. Accepted M must
exist with its authored owner/directions; refused M must be absent from
published state. Cache deletion alone neither restores authored files nor proves
correctness. A database transaction cannot establish multi-file/Scribe/Git
atomicity. Fault injection and crash-window qualification remain later work.

**Steering draft:** Report validation and publication separately. A refusal
leaves the strong boundary's published state unchanged. On publication
uncertainty, query status before retrying; restore and verify, or keep writes
blocked pending recovery. Never report success for divergent files and model
state.

## R11: Direct adapters, helper equivalence and composition conflicts

Start with raw `rawTarget` from `N2` as an alternative to the corresponding
helper definition. Register a consumer runner and backend with the plain `N4`
descriptors; a shipped graph adapter returns the same public descriptor shape.
Supply an executable baseline and repeat S1/S0 through the public acquisition
contract. Required entries/capabilities must be negotiated before
evaluation/publication.

For direct Rego, supply a real policy artifact and entrypoint to
`opaRegistration`, then use `regoVariant` to explicitly replace R visibility
with an expected prior definition identity. Retain complete contextual
selectors, original-origin traversal and boundary/path findings. CLI strict
built-in errors and complete required results are mandatory. Bun/Wasm requires
its own capability evidence. Direct Datalog consumers can supply the recursive
query and public fixed-rule callback; callback exceptions remain errors. A
health-only adapter cannot claim graph support.

Try `duplicateConflict`: two different R target definitions with the same ID
must fail regardless of ordering. Also try a stale replacement identity, two
replacements, unknown disable target, incompatible view schema and unsupported
path-witness capability. Inspect the effective policy and all origins after
successful composition. Explicit disable makes a different policy profile and
may fail the chosen boundary's required capabilities; module ordering must not
silently choose it.

For equivalent rules, replay G02/T07/E01 through raw descriptors, consumer
helpers, packaged helpers and the chosen direct backend. Compare decisions and
meaningful structured witnesses using the same captured inputs. No claim of
automatic translation or equivalence for arbitrary backend programs is made.
Optional X07 can later use a custom aggregate callback returning contributing
nodes, sum and limit; it requires its own approved numeric model.

**Steering draft:** Package and consume adapters through the same public
registration interface. Use explicit identity-targeted replacements/disables and
inspect the effective policy. Reject conflicts and unsupported capabilities.
Preserve direct tool-native authoring, and prove equivalence only for the
specific rules and diagnostics claimed.

## R12: Rename, relocation, cache rebuild and full/incremental comparison

Keep one frozen before/candidate/policy/fact set for each comparison. Rename
element tags, fields, roles and UIDs consistently and map expected findings
back; no fixture names may remain in engine dispatch. Change each
selector-context component independently to guard against accidental role-name
matching. Reorder relation declarations and relocate a document: relation-set
policies stay equivalent, diagnostic locations refresh, and deliberately
document-sensitive policies can differ.

Run insertion/deletion, endpoint/role change, FLAG toggle, subtree move and
grouped changes through full evaluation. Once an incremental evaluator exists,
replay the same captured sequence and compare every validity result and
meaningful witness. Retain before for fresh transition comparisons. Change only
policy/provider configuration and require dependent results to update. Delete
disposable caches and rebuild without authored changes; compare the
reconstructed model, ownership and findings.

Measure roughly 1,000 and 10,000 nodes in shallow/wide and deep/narrow forms
with varied edge density. Report cold/warm initialization, serialization,
provider calls, scans, invalidation, rebuild and publication separately. Include
unchanged-link rejection after a deep boundary closure. No invented threshold or
fixed semantic depth is acceptable. Treat resource exhaustion as an operational
failure, not an invalid graph or successful partial result.

**Steering draft:** Compare incremental and full evaluation on identical
captured inputs, including before, policy and sources. Revalidate unchanged
dependents after structural/boundary changes. Treat caches as disposable and
refresh locations after moves. Record workload and costs honestly; warm toy
timing is not a production guarantee.

## R13: Final delivery and generic Scribe cleanup

Keep these recipes as Markdown and steering source until implementation exists.
After the final qualification gate, replace proposed operation placeholders with
actual supported invocations and verify every recipe, including negative/error
controls, against the same public surface available to consumers. Keep native
Child and field/custom-logic variants and document their equivalence limits. Do
not move this draft into SDocs or create specification/plan nodes during Gate 2.

Before folding into trial, remove mandatory repository-specific guarded-field
policy from generic Scribe. The final neutral fixture scope must contain no
`AUTHORED_BY` or `PARENT_FP` declarations/content and no renamed substitutes.
Historical accommodations/evidence belong outside that fixture scope.
Demonstrate both a clean neutral consumer and the repository's actual policy
through public helpers/adapters/tools. Do not count changing field spellings as
removing coupling.

**Steering draft:** Gate 2 artifacts are proposals. Obtain the next human review
before production Gate 3. After final qualification, verify all runnable recipes
and clean generic Scribe/neutral fixtures before landing. Express repository
policy through the public extension surface, and keep historical evidence
outside the clean fixture boundary.
