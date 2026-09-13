# Scenario catalogue

Status: **DRAFT COVERAGE — proposed semantic expectations await user review.**
These 44 IDs preserve the handoff acceptance matrix. They are not 44 executed
tests. Native observations belong in `../evidence/`; they cannot approve the
semantic expectations here. Decisions D01–D15 are in [decisions](decisions.md).

## Reading a case

`Base` is the fresh forest in [model](model.md), with no `R` or BAR instances.
Unless a row says otherwise, use a successful complete empty external snapshot.
`Commit` means the complete candidate is persisted, observable graph agrees, and
a fresh reload confirms it. `Unchanged` means all authored files and observable
state remain at the pre-operation snapshot, followed by reload confirmation.
These required outcomes are intended future assertions, not claims about today's
runtime.

Each case records initial state, operation, proposed result and structured
evidence, and resulting state. Diagnostic names below describe evidence, not
settled code strings. Native, custom semantic, and provider execution errors
must be distinguishable. Stable rule identity, subjects, and useful
paths/blocked boundaries matter; prose and incidental result order do not.

Gate 1 retains small readable examples and measures native behavior. Semantic
mutations become executable acceptance tests after behavior and surfaces are
approved. Later gate labels identify qualification work rather than accepted
skips. Every negative traversal example must independently satisfy native
endpoint resolution and absence of cycles in the whole graph.

## Structural graph cases

| ID  | Initial state and candidate operation                                                           | Proposed result and evidence                                                                                                                 | Resulting state / qualification                                  |
| --- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| G01 | Base; add `F1a Parent R -> F2`                                                                  | Accept selected relation targeting FOO; persisted owner/type/role/target                                                                     | Commit; Gate 3 first target-type slice                           |
| G02 | Base including resolvable, natively eligible BAZ `Z0`; add `F1a Parent R -> Z0`                 | Reject custom target-type rule with selector, owner, target, expected FOO and actual BAZ; parser/missing UID failures do not count           | Unchanged; Gate 3                                                |
| G03 | Base; let BAZ `Z0` own `Parent R -> I0`                                                         | Accept; FOO selector does not apply to BAZ's same role spelling                                                                              | Commit; Gate 3; require G02 as restrictive control               |
| G04 | Base has F0/G0 roots; create isolated FOO `I1` with `FLAG=false`                                | Accept forest with three existing roots and the added isolated root; no connectedness obligation                                             | Commit; Gate 4; native load probe at Gate 1                      |
| G05 | Base where `F1a H -> F1`; add `F1a H -> F0`                                                     | Reject H cardinality, showing both distinct parents F1/F0; this graph is otherwise a DAG                                                     | Unchanged; Gate 4                                                |
| G06 | Base; add `F0 H -> F1a`                                                                         | Reject cycle with witness `F0 -> F1 -> F1a -> F0`                                                                                            | Unchanged; Gate 1 native probe, required global constraint       |
| G07 | Fresh FOO A/B and BAZ Z0; A owns `H -> B`, Z0 owns `Parent R -> A`; add Z0-owned `Child Q -> B` | Reject combined cycle `B -> A -> Z0 -> B`, although H/R/Q projections are individually acyclic; no BAR cardinality or bridge policy masks it | Unchanged required; measure present runtime separately at Gate 1 |
| G08 | Base plus BAR `M: P=F0,Q=F2`; revalidate F2 hierarchy                                           | Accept; F2 has one H parent despite native parents F0 and M; no M-based H ancestry                                                           | Commit; Gate 4 with role-projection evidence                     |
| G09 | Base; create `M: P=F0,Q=F2`                                                                     | Accept `F0 -> M -> F2`; declarations remain owned by M with Parent P/Child Q, and no authored reverse edge appears                           | Commit; Gate 1 public ownership probe and Gate 4 semantic slice  |

## Traversal cases

| ID  | Initial state and candidate operation                                                                                       | Proposed result and evidence                                                                                                                            | Resulting state / qualification                                                                                 |
| --- | --------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| T01 | Base; add `F1a R -> F2`                                                                                                     | Accept closed endpoint; hierarchy path `F1a,F1,F0,F2`                                                                                                   | Commit; Gate 4                                                                                                  |
| T02 | Base; add `F1a R -> F2a`                                                                                                    | Reject boundary F2 on path `F1a,F1,F0,F2,F2a`                                                                                                           | Unchanged; Gate 4                                                                                               |
| T03 | Base except `F2.FLAG=false`; add `F1a R -> F2a`                                                                             | Accept same path after opening F2                                                                                                                       | Commit; Gate 4                                                                                                  |
| T04 | T03 already committed; set F2 true                                                                                          | Reject because unchanged F1a-owned R would become hidden; identify R owner and changed boundary                                                         | Unchanged including FLAG=false; Gate 4 nonlocal revalidation                                                    |
| T05 | Base plus open FOO `X H -> F1` and `F1a R -> X`; replace X's H parent with F2 in one batch                                  | Reject because unchanged R now targets inside closed F2; witness new path and changed H edge                                                            | Unchanged, X remains under F1; Gate 4                                                                           |
| T06 | Base; create `M: P=F0,Q=F2`                                                                                                 | Accept downward path `F0,F2`; closed endpoint visited                                                                                                   | Commit; Gate 4                                                                                                  |
| T07 | Base; create `M: P=F0,Q=F2a`                                                                                                | Reject boundary F2 on `F0,F2,F2a`; native connectivity itself is acyclic                                                                                | Unchanged; Gate 4                                                                                               |
| T08 | Base plus BAZ `Z0: Parent R=F0, Child Q=G1`; create `M: P=F0,Q=G1`                                                          | Reject no H path despite permitted native connectivity `F0 -> Z0 -> G1`; show distinct roots and selected H context                                     | Unchanged; Gate 4; Z0 has no FOO R or BAR bridge policy                                                         |
| T09 | Base plus open `F2a1 H -> F2a`; create `M: P=F0,Q=F2a1`                                                                     | Reject earlier boundary F2 despite open F2a/F2a1; after opening F2 and closing F2a, reject at F2a                                                       | Unchanged for each independent candidate; Gate 4 nested-boundary controls                                       |
| T10 | Fresh open chains of lengths 1, 3, and 12, each with an open sibling branch; add sibling-origin R to deepest chain endpoint | Accept at each depth, including a closed endpoint at depth 1; at depths 3/12, closing an interior descendant rejects with that boundary/path            | Relation persists; rejected interior FLAG edit unchanged; Gate 4; depth 1 has no intermediate-boundary negative |
| T11 | Fresh Base for each row in the decisions truth table                                                                        | Apply explicit closed-origin, internal-sibling, exit, equal-endpoint, sibling-bridge and cross-root rulings; native-cycle rows identify native producer | Commit/Unchanged according to each row; Gate 4; do not infer semantic equality behavior from native rejection   |

## External-state cases

Define `S1` as a successful complete baseline snapshot protecting the exact
modeled record for isolated FOO I0; `S0` is successful complete and empty.
Baseline identities are distinct. These are conceptual inputs, not an approved
provider wire schema.

| ID  | Initial state, external input, candidate operation                                                                       | Proposed result and evidence                                                                                                  | Resulting state / qualification                                                               |
| --- | ------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| E01 | Base, S1; set `I0.FLAG=true`                                                                                             | Reject preservation with UID I0, changed FLAG, baseline identity S1                                                           | Unchanged; Gate 4                                                                             |
| E02 | Base, S0; same FLAG change                                                                                               | Accept branch-only edit; evidence uses S0 rather than a cached S1 verdict                                                     | Commit; Gate 4                                                                                |
| E03 | Current I0 true is valid under S0; provider changes to S1 containing I0 false without an SDoc edit; validate             | Report mismatch under new source identity; prior S0 success is invalidated                                                    | No document mutation; Gate 4                                                                  |
| E04 | Base; provider successfully returns complete empty S0; delete isolated I0                                                | Accept, subject to all other rules; explicitly record acquisition success, completeness, and zero protected records           | Commit; Gate 4                                                                                |
| E05 | Base; attempt E01 while provider separately exits nonzero, times out, emits malformed data, or declares incomplete data  | Execution error for each case, with provider/source identity and failure kind; not a preservation violation or empty baseline | Unchanged; Gate 4 failure injection                                                           |
| E06 | Base; capture S1, provider switches to S0 during evaluation, then propose E01                                            | Reject using coherent captured S1 throughout; a subsequent evaluation may use S0 and accept                                   | First unchanged, second commits if retried intentionally; Gate 4; D09 snapshot policy pending |
| E07 | Base; fixture-owned packaged executable supplies S1 through the eventual public provider surface; repeat E01 then use S0 | Same reject/accept distinction as E01/E02, with normal public acquisition and no privileged fixture dispatch                  | Unchanged/Commit respectively; Gate 5 public extension proof                                  |

## Transition, batch, and recovery cases

| ID  | Initial state, comparison inputs, candidate operation                                                            | Proposed result and evidence                                                                                              | Resulting state / qualification                                                                                                                 |
| --- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| B01 | Base, captured before and S0; stage new BAR M, then P=F0 and Q=F2 in one candidate batch                         | Accept complete final bridge despite private staging without endpoints                                                    | Commit M and both declarations together; Gate 4; current `new` with both relations alone proves only the smaller one-operation case             |
| B02 | Base, before and S0; complete a batch containing M and P=F0 but no Q                                             | Reject exact-one Q cardinality with M and observed count 0                                                                | Unchanged, no persisted M; Gate 4                                                                                                               |
| B03 | Base plus valid `M: P=F0,Q=F2`, before and S0; remove Q=F2 and add Q=F1 within one batch                         | Accept final one-Q state; intermediate zero/two Q does not define validity                                                | Commit only Q=F1; Gate 4; reverse staging order has same outcome                                                                                |
| B04 | Base, before and S1; independently delete I0 or set I0 true                                                      | Reject deletion or modeled revision with S1 witness                                                                       | Unchanged; Gate 4; incoming/layout exclusions from D07 need explicit positive controls                                                          |
| B05 | Base, before and S0; independently delete I0 or set I0 true                                                      | Accept corresponding branch-only change; a separate T02 candidate still rejects under S0                                  | Commit branch change; unrelated invalid candidate unchanged; Gate 4                                                                             |
| B06 | Base, before and S0; stage M with P=F0/Q=F2a, then run semantic checks                                           | Reject with T07 boundary; compare authored bytes, held graph, and disposable derived state against before                 | Unchanged; Gate 4                                                                                                                               |
| B07 | Base, before and S0; validate valid M, then inject a Scribe publication/model/file failure                       | Explicit operational error; recovery evidence must state what was restored and whether writes were blocked pending reload | Restore before where possible; otherwise no success and explicit recovery-required state; Gate 6 failure injection, not a crash-atomicity claim |
| B08 | Independently perform accepted T06 and rejected T07; reload and cold-restart after each                          | Reloaded existence/relations/FLAG and complete validation match reported result under the same input snapshots            | Accepted M persists; rejected M absent; native subset at Gate 1, semantic comparison Gate 4/6                                                   |
| B09 | Current Base; invoke transition comparison without before, or preservation without required baseline acquisition | Explicit cannot-evaluate/execution error identifying missing input; never substitute current as before                    | No mutation; Gate 4; state-only checks may still have their own evaluable results                                                               |

## Cross-cutting qualification

These cases intentionally belong to later gates. Their inclusion is coverage
planning, not a claim that Gate 1 implements providers, alternative authoring
variants, an evaluator, or a performance harness.

| ID  | Initial inputs and transformation                                                                                                                                                         | Required proposed comparison and evidence                                                                                                | Resulting state / qualification                                                     |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| X01 | Same approved G02/T07/E01 inputs and snapshots; express representative rules via shared primitives, consumer helper, adopted helper, then chosen backend surfaces                         | Equal verdicts and relevant structured witnesses; real generated artifacts and Scribe integration for each claimed entry point           | Same Commit/Unchanged result for each equivalent variant; Gate 5                    |
| X02 | Rename FOO/BAR/BAZ, H/R/P/Q, FLAG, and all UIDs consistently in approved declarations and examples                                                                                        | Same mapped verdict/witness; no core fixture names                                                                                       | Correspondingly renamed persisted state; Gate 5/6                                   |
| X03 | Reorder relation declarations and move F1a to another document without changing modeled facts; run T01/T02 and S1 projection comparisons                                                  | Same outcomes, with updated diagnostic locations; document ownership remains available to explicitly document-sensitive future policies  | Moves can commit; relation verdicts remain equivalent; Gate 6                       |
| X04 | Sequence inserts/deletes, relation role and endpoint changes, FLAG toggles, subtree moves, and batches; capture identical before/candidate/external inputs for incremental and fresh runs | Same validity and meaningful structured diagnostics at every step; transition inputs retained for fresh comparison                       | Same accepted state and unchanged rejected state; Gate 6 differential qualification |
| X05 | Accepted T06 plus captured inputs; delete only disposable index/cache state and rebuild                                                                                                   | Same bridge facts, verdict, owner/direction, and witness semantics; derived state is not authority                                       | Authored files unchanged; Gate 6                                                    |
| X06 | Hold SDoc constant; replace visibility policy artifact or change provider configuration from S0 source to S1 source                                                                       | Dependent outcomes recomputed under new artifact/config identity; stale success not reused                                               | No implicit document mutation; Gate 6                                               |
| X07 | After separate approval, add numeric FOO field and external limit; consumer derives selected-descendant sum and checks it through public lower layers, then wraps a helper                | Independent aggregate rule rejects an over-limit candidate with contributing nodes/sum/limit; no core domain branch                      | Unchanged invalid candidate; Gate 5 optional challenge pending D15                  |
| X08 | Approved rules over roughly 1,000 and 10,000 nodes, shallow/wide and deep/narrow, varied edge density; measure initialization, local edit, subtree move and source revision               | Record cold/warm latency, scans, provider calls, serialization, invalidation, rebuild, and correctness comparison; no invented threshold | Valid edits commit and invalid edits do not; Gate 6 workloads pending measurement   |

## Current coverage boundary

Gate 1 can verify installation, generation, native input acceptance, ownership,
mutation refusal/dry-run, reload, and observed batch/cycle behavior. It cannot
establish target-type rules, forest cardinality, closed-boundary semantics,
baseline protection, transaction guarantees, shared/backend API equivalence, or
incremental semantic correctness. Record these as unimplemented or pending
review with the corresponding IDs. A native cycle rejection cannot fill a
traversal coverage cell.
