# Design coverage and recipe delivery

This document maps all 44 neutral reference scenarios to the independent
proposed surface. It records design coverage only. No semantic scenario has been
executed here. Read the reviewed requirements as authority when older reference
files say pending. The optional aggregate challenge X07 remains optional rather
than quietly extending the neutral grammar.

## Scenario mapping

| Case | Proposed surface and decision obligation                       | Evidence still required after implementation                                   |
| ---- | -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| G01  | `targets`, fully scoped FOO Parent R                           | Positive eligible target and preserved declaration                             |
| G02  | Same `targets` rule rejects resolvable BAZ                     | Expected/actual type plus restrictive control                                  |
| G03  | Selector includes owner element and grammar                    | BAZ Parent R passes while G02 fails                                            |
| G04  | `forest` permits isolated records and multiple roots           | Native load and selected forest acceptance                                     |
| G05  | Forest's exported validity rule limits selected parent count   | Both H parents, otherwise valid DAG                                            |
| G06  | Required complete-native-DAG integration capability            | H cycle witness and refusal                                                    |
| G07  | Same capability includes all Parent/Child roles                | Mixed-direction combined cycle refusal                                         |
| G08  | Explicit selected hierarchy, independent of all native parents | F2 keeps one H parent despite bridge parent                                    |
| G09  | Authored facts separate from normalized connectivity           | M owns both declarations; upper -> M -> lower                                  |
| T01  | `visible`, endpoint visit permitted                            | Path ending at closed F2                                                       |
| T02  | Same rule prevents external closed expansion                   | Blocked F2 on path to F2a                                                      |
| T03  | Explicit false/open predicate                                  | Same path valid after opening F2                                               |
| T04  | Complete candidate and nonlocal invalidation contract          | Closing F2 rechecks unchanged reference                                        |
| T05  | Same contract after hierarchy edit                             | Subtree move invalidates unchanged owner link                                  |
| T06  | `adaptation`, downward path and visit/expand boundary          | Closed lower endpoint passes                                                   |
| T07  | Same helper blocks expansion through closed interior           | Native-valid bridge fails at F2                                                |
| T08  | View context excludes unrelated native connectivity            | Different H roots despite BAZ path                                             |
| T09  | Original-origin boundary predicate at every nested boundary    | Earlier and deeper blockers independently                                      |
| T10  | No validity depth cap                                          | Depth 1/3/12 positives and interior negatives                                  |
| T11  | Truth subset in design plus full reference truth table         | All internal-peer, exit, closed-start, sibling, root and native-cycle controls |
| E01  | `preserveListed` with explicit projection                      | I0 FLAG mismatch bound to S1                                                   |
| E02  | Same rule under captured empty S0                              | Branch-only edit passes without stale S1                                       |
| E03  | Input identity participates in receipts/invalidation           | New S1 changes outcome without document edit                                   |
| E04  | Provider complete-empty envelope is valid                      | Zero protected records and deletion acceptance                                 |
| E05  | Executable acquisition errors differ from violations           | Nonzero, timeout, malformed and incomplete controls                            |
| E06  | Captured immutable evaluation envelope                         | S1 applies throughout; subsequent S0 run differs                               |
| E07  | Public `registerBackend`/executable provider registration      | Independent executable, no privileged dispatch                                 |
| B01  | Private transaction with explicit group sealing                | Incomplete private staging; final complete M publishes                         |
| B02  | Exported adaptation endpoint-count rule                        | Missing Q causes refusal with no published M                                   |
| B03  | Final candidate determines endpoint cardinality                | Both staging orders produce exactly one Q                                      |
| B04  | Preservation checks existence and owned projection             | Deletion/FLAG/H edits fail; incoming/layout positives                          |
| B05  | Successful empty S0 removes only preservation restriction      | Branch edit passes; invalid visibility still fails                             |
| B06  | Read-only evaluation before conditional publication            | Refusal preserves bytes and observable graph                                   |
| B07  | Publication adapter recovery contract                          | Injected failure restores or blocks writes; no success                         |
| B08  | Receipts and full evaluation over same snapshots               | Reload/restart confirm accepted and refused states                             |
| B09  | Explicit required input bindings                               | Missing before/baseline is unevaluable, never guessed                          |
| X01  | Helper/direct descriptors and public backend module surface    | Normalize and compare decisions plus structured witnesses                      |
| X02  | Handles, consumer namespaces, no engine domain constants       | Consistent renaming preserves mapped outcomes                                  |
| X03  | Stable record identity and explicit projection                 | Reordering/location changes preserve semantics                                 |
| X04  | Incremental correctness contract over identical envelopes      | Differential full/incremental mutation sequence                                |
| X05  | Disposable indexes; authored inputs remain authority           | Delete/rebuild cache without semantic change                                   |
| X06  | Effective policy/provider config digests in receipt            | Policy/source config edit invalidates cached success                           |
| X07  | Optional `programRule` with public view/input bindings         | Separate approved corpus; sum/contributor/limit witness                        |
| X08  | No latency assertion in public semantic contract               | Measured 1k/10k wide/deep workloads and correctness                            |

## Reviewed additions beyond the original numbered matrix

| Reviewed requirement                         | Present design content                                                         | Later delivery obligation                                                                         |
| -------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| Familiar native tailoring                    | `tailoring` example with A42, STD-1 and OTS-9                                  | Run emitted grammar, author through supported client, inspect ownership and native outputs        |
| Field/custom-logic alternative               | `fieldAlternative` plus program recipe below                                   | Implement independently supplied program; qualify limited equivalence claim                       |
| Consumer identity/main policy                | `repositoryPolicy`, captured ref and trusted context contracts                 | Demonstrate actual identity binding, projections and approval facts                               |
| Supersession remains consumer-defined        | Neutral exceptions empty; custom lifecycle program may add explicit exceptions | Test deletion remains refused without explicit exception and chosen exception behavior separately |
| Human/protected documents and HITL           | Document scope plus verified candidate-bound approvals                         | Consumer decides classification; future UI/trust provider stays out of this gate                  |
| Parallel grouped work                        | Group revision, contributors and seal contract                                 | Race/conflict/seal tests; serialized writes are insufficient                                      |
| Daemon, Git hook or both                     | Separate candidate acquisition/publication contracts                           | Verify staged-tree capture and transaction-then-commit behavior                                   |
| Conflicting definitions and rule replacement | Qualified identities, expected artifact and explicit edits                     | Duplicate/conflicting/unknown/stale/competing replacement controls                                |
| Public backend/tool extension                | Registry, capability planning, result mapping and direct descriptors           | Independent plugin must fail explicitly on unsupported contracts                                  |
| Invalid input and recovery                   | Partial inspection, complete-validity reference admission                      | Repair whole model; retain violations under any later waiver mode                                 |
| Remove generic mandatory repository fields   | No such fields in proposed neutral grammar                                     | After final gate, fix generic Scribe and clean all neutral fixture declarations/content           |
| Human and agent playbooks                    | Drafts below, no SDocs                                                         | Verify final runnable instructions before landing; steering placement deferred                    |

## Human recipe 1: declare a scoped target restriction

Start with the neutral grammar in `examples.nix`. It uses only UID and the
explicit false/true FLAG field; it is a proposed clean consumer grammar and will
not yet satisfy the installed Scribe runtime's temporary repository-field guard.
Do not add that guard's fields to this final-design example to make it appear
runnable.

Attach the neutral bundle or keep it beside the grammar through the separate
composition entry point. Choose the full FOO Parent R relation handle and
require FOO targets. Inspect the effective policy manifest: it should contain
the qualified reference-target rule with the owner element, native direction and
role intact.

Once the eventual implementation exists, try a link from F1a to closed F2 and
expect acceptance. Change only its target to resolvable BAZ Z0 and expect a type
violation. Then create BAZ's own Parent R to I0 and expect acceptance. This
paired negative/positive control proves scope rather than merely showing a rule
ran.

## Human recipe 2: chosen hierarchy and boundaries

Select FOO Parent H as the hierarchy and require a forest. Add the visibility
helper using FLAG `false` as open and `true` as closed. Keep other roles outside
the hierarchy while retaining them in complete native-cycle validation.

Use fresh copies of the reference forest for independent examples. F1a may
target closed F2 but may not target F2a behind it. F2a may target internal peer
F2b and may leave to F1a. Add a native bridge starting at closed F2 and ending
at F2a to exercise closed-start descent without manufacturing an
ancestor-reference cycle.

Open F2, add F1a's reference to F2a, then close F2 in a candidate. The candidate
must be refused even though the reference itself was untouched. Repeat with a
subtree move. Read the diagnostic's rule, declaration owner, selected path and
boundary; do not infer failure from native endpoint or cycle errors. Repeat on
deeper chains without configuring a depth limit.

## Human recipe 3: native tailoring of an immutable requirement

Use the tailoring grammar and bundle. Author STD-1 and OTS-9 as requirements;
OTS-9's hierarchy Parent points to STD-1. Author A42 as an adaptation statement
with text explaining how the OTS behavior satisfies the standard requirement.
A42 owns Parent `source` to STD-1 and Child `implementation` to OTS-9.

The target rules and endpoint counts check declaration validity. The adaptation
path rule checks downward reachability over the explicitly selected requirement
hierarchy. Inspect authored ownership and normalized connectivity: STD-1 -> A42
-> OTS-9 must remain visible as three nodes.

Use an independent preservation bundle if OTS-9 is immutable. Protect its
existence and chosen owned projection in a captured baseline. Adding A42's
incoming Child link must not by itself mutate OTS-9's owned projection. Changing
OTS-9's protected fields must still fail. A consumer may choose a broader
protection projection, but that is a different policy and should have a separate
recipe.

## Human recipe 4: fields and an independent program

Declare ADAPTATION_FIELDS with required SOURCE_UID and IMPLEMENTATION_UID
fields. These are ordinary strings. Register a program through the public
backend/program contract, bind the candidate and selected hierarchy snapshot,
and scope the program to this element in its grammar namespace. Do not let the
engine guess that similarly named fields in other grammars are references.

The following is algorithm pseudocode, not an installed runtime API:

```text
for each candidate record of the configured adaptation element:
  resolve SOURCE_UID and IMPLEMENTATION_UID in the configured model namespace
  report missing/ambiguous/wrong-type endpoints with field source locations
  if both endpoints resolve and the selected hierarchy is valid:
    require a downward hierarchy path from source to implementation
    for each required descent expansion at node B on that path:
      reject when B is closed and source is outside B's selected subtree
return a complete rule result with subjects, path and blocked boundary
```

Return a violated result for a well-defined policy failure and an unevaluable
result for missing required model/view input. Count string field cardinality
through grammar validation, then check endpoint resolution and semantics through
the program. Fields do not create native graph edges, so this recipe claims
equivalent endpoint/path decisions only. To reproduce complete native bridge
connectivity, explicitly add consumer-derived edges to an additional union-graph
rule and qualify it independently.

## Human recipe 5: external protection and identity

First supply a successful complete fake baseline S1 listing I0. Change I0's FLAG
and expect a preservation violation identifying S1. Repeat with successful
complete empty S0 and expect acceptance. Exercise provider timeout, nonzero
exit, malformed output and declared incompleteness; each is an error rather than
a passing empty baseline.

Next replace the fake provider with a consumer program resolving the configured
main ref once and extracting its records with identified schema/model context.
Capture that baseline and the complete candidate as one evaluation envelope.
Retain it for full/incremental comparison. Changing main during that run affects
a later evaluation unless a separately configured publication freshness contract
requires another check.

Bind actor context from an authenticated integration and classify LLM/human
using consumer-owned facts. Do not use a request field or document author string
as proof. A document-sensitive consumer program may require verified approvals
for its protected documents; bind approval to the exact candidate, policy and
baseline. The main protection projection, actor permissions, human-document
classification and supersession exceptions are consumer code. Test each with
restrictive and permissive controls rather than assuming a built-in lifecycle
model.

A concrete consumer decision sketch, independent of any evaluator language:

```text
require complete candidate, before, captured main, actor facts and approval facts
require actor evidence from the configured trust authority
changedMain = compare(main.listedRecords, candidate, consumer.frozenProjection)
changedDocuments = compare(before.documents, candidate.documents,
                           consumer.documentProjection)
if actor.classification == "llm" and changedMain is nonempty:
  violate "consumer:repository-lifecycle/main-protection", with changed records
for each changed document classified protected by consumer.classification:
  if no verified approval binds its change to candidate/main/policy/action:
    violate "consumer:repository-lifecycle/approval", with document and binding
# A supersession declaration adds no exception to these two chosen rules.
```

This example intentionally applies the approval condition even to authenticated
humans and still refuses an LLM main-projection change with an approval. Those
are explicit example-consumer choices, not a default engine rule or the user's
settled lifecycle. A different consumer can replace either named rule through
the public composition interface. A source acquisition or trust-validation
failure produces an error before dependent satisfaction can be claimed.

## Human recipe 6: group a change or validate a Git commit

For a strong transaction, begin a group against a known before revision. Give
its ID to participating agents. Stage creation of M and its endpoints privately,
resolve concurrent edit conflicts, then seal a precise group revision. Validate
the complete candidate. Publish only after a valid result and a matching before
precondition. If semantic evaluation refuses, discard the candidate and confirm
authored bytes and observable state remain unchanged.

For Git, configure evaluation of the staged tree with an explicit parent/before
and separately captured main baseline. A refusal prevents the commit while
preserving staged edits for repair. A local hook does not magically provide
authenticated actors or prevent bypass; choose an enforcing integration when the
policy requires those properties.

When a transaction is followed by a commit, expect two boundary decisions. Reuse
a receipt only if all required snapshots and context match. Exercise publication
failure separately: report restored state or recovery-required write blocking,
never a successful commit on divergent files and model state. Do not call a
successful sidecar check an atomic Scribe transaction.

## Human recipe 7: extend, replace and diagnose

Import a bundle and add a separately named document/change program rule.
Register its independently packaged evaluator using the public registry. Ask the
runtime to explain the effective rules, input requirements and evaluator
assignments. Unsupported kinds must stop evaluation with a named capability
error.

Replace one imported rule through its qualified identity and expected artifact.
Confirm its siblings remain. Try an accidental duplicate with a different
definition and expect a configuration error. Compare the helper target
restriction with its direct descriptor under identical input snapshots. After
changing policy or provider configuration, expect a new receipt even when no
SDoc changed.

Keep invalid input inspectable. Under the reference admission recipe, repair
until the entire final candidate is valid. Later consumer waiver policies must
preserve the report of remaining invalidity. Delete disposable indexes and
re-evaluate from the same envelope to confirm they are not the authority.

## Steering-ready draft

This block is proposed agent-facing content for the eventual verified recipes.
Keep its design warning until the implementation and concrete commands have been
qualified. Placement in a generated steering module is deferred; do not move
this content into SDocs.

```text
DESIGN DRAFT — proposed interfaces below are not installed commands.

Before editing semantic documents, identify the consumer's policy bundle,
model namespace, full relation selectors, and selected validation boundary.
Use the generated effective manifest to find stable rule identities and inputs.
Do not infer hierarchy from file layout or from every native Parent relation.

Preserve authored owner, target, native type and role. Parent and Child authoring
both contribute to the full native DAG. Reverse labels do not add owned edges.
Use native adaptation statements when appropriate: the statement owns Parent
to its source requirement and Child to its implementation/OTS requirement.
Keep the statement node in connectivity. Field/custom-program styles are also
valid consumer choices, with explicitly narrower or different graph semantics.

Use the selected hierarchy and explicit false/open, true/closed predicate.
An external origin can visit a closed boundary but cannot enter its interior;
an internal origin can reach peers or leave. A closed origin is inside itself.
Revalidate affected unchanged references after flag changes and subtree moves.

Acquire every required before/baseline/external input as a complete identified
snapshot. Complete empty data is legitimate; timeout, malformed, incomplete and
failed acquisition are errors. Do not substitute current state for missing
before or trust user-supplied actor labels as authenticated identity.
Repository protection, approvals and supersession are consumer policies.

For a grouped change, use its private staging workspace and explicit seal.
Evaluate the complete final candidate, not every incomplete intermediate edit.
For a Git boundary, evaluate the staged tree under the configured inputs.
A refused hook leaves prior edits available; a refused private transaction must
not publish authored changes. Transaction success does not promise commit
success. Publication error requires verified restoration or blocked writes.

Add rules with distinct identities. Replace or disable imported rules explicitly
with the expected artifact guard. Never rely on module order or silently skip
an unsupported evaluator capability. Public helper and direct forms owe equal
decisions and meaningful evidence for any claimed equivalence.

Read diagnostics before repair: distinguish native invalidity, custom policy
violation, missing input, and publication failure. Keep invalid input inspectable.
The reference repair recipe requires a fully valid final candidate. Cache data
are disposable; preserve the immutable evaluation envelope for reproduction.
```

## Final delivery checklist and remaining gaps

All 44 scenario IDs and reviewed additions have a design location. The artifacts
include a coherent native grammar/attachment sketch, concrete authored tailoring
facts, an alternative field program algorithm, external/identity policy binding,
direct descriptors, public registration, grouped work and Git boundaries, and
human/agent recipe drafts.

Still unimplemented and unverified: actual builder exports and schemas;
helper/direct normalization; executable wire protocol; independent backend
adapters; native-cycle integration closure; immutable capture and authenticated
identity binding; Scribe publication/recovery; grouped multi-agent races; staged
Git capture and enforcement; incremental dependency maintenance; costs and
runtime choice; final executable recipe commands. The partial runtime
registration in `examples.nix` deliberately leaves assignments to be supplied by
the future chosen backend. It is not a runnable engine configuration.

Remaining design choices are listed in `design.md`: snapshot schema size,
descriptor ownership, replacement locks, publication integration, trust
authorities, cross-revision identity and freshness, witness equivalence, and
repair admission. No uncertainty was resolved by reading backend research.

Validation for this deliverable is limited to formatting and parsing the Nix
syntax. Nix parsing does not instantiate any hypothetical p.* function, assert
exported API existence, or prove a policy outcome. Later final clean-fixture
delivery must remove mandatory repository fields from generic Scribe and all
neutral fixture declarations/content, including relocating historical evidence
outside fixture scope if needed. Final runnable recipes require implementation
verification after the last qualification gate and before landing. No SDocs,
commits, pushes or production changes are part of this handoff.
