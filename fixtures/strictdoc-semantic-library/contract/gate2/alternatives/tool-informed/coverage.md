# Coverage and delivery map

**Gate 2 design complete; implementation qualification pending.** This maps
every numbered reference case and the additional reviewed behavior families to
the proposed surface, draft human recipes/steering, supplied capability evidence
and later implementation evidence. No cell claims that writing an example
implemented its behavior. The
[reviewed requirements](../../reviewed-requirements.md) govern older reference
`PENDING` labels; new API, backend and consumer lifecycle choices remain
proposals.

`N1`–`N11` refer to labeled sections in [examples.nix](examples.nix).
`R01`–`R13` refer to headings in [recipes.md](recipes.md); every recipe includes
actual human instructions and a reusable **Steering draft**.
[design.md](design.md) specifies their semantics, public registration and
limits. Required reference `Commit`/`Unchanged` assertions use the strong
private-candidate boundary; Git-only refusal instead blocks commit and retains
staged author work.

Evidence review v2 updates the original v1-based map; the original output
remains independently archived by root. Current research links point to
`inputs/research-v2`. The [v2 review note](design.md#v2-evidence-review) records
corrections and why the interface remains unchanged. The 44 reference cases and
their later qualification obligations are unchanged; new probe records are not
new reference case IDs.

## Evidence key

| Key | Supplied evidence                                                                                                                                                                                       | What it establishes and does not establish                                                                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P   | [Public toolchain brief](../../public-toolchain.md), [DSL](../../../../../../packages/strictdoc-grammar/lib/dsl.nix), [module](../../../../../../packages/strictdoc-grammar/modules/devenv/default.nix) | Current native constructors, options and known runtime gaps; no semantic API                                                                                                                                      |
| N   | [Native results](../../research/experiments/results/native.json), [scope results](../../research/experiments/results/native-scope.json), [source pins](../../research/sources.md)                       | Native roots/multiple parents/Child ownership and named-role cycle gap; explicit all-edge detector can reject the tested cycle; no Scribe repair                                                                  |
| V   | [Finalist results](../../research/experiments/results/finalists.json), [Rego](../../research/experiments/scripts/policy.rego), [Datalog](../../research/experiments/scripts/traversal.cozo)             | 30 full-input comparisons plus four capability records; ten Parent and ten literal Child expectations, context/movement and unchanged/changed nonempty-snapshot controls; not 44 Scribe tests or full diagnostics |
| E   | [Provider controls](../../research/experiments/results/providers.json), [research handoff](../../research/handoff-for-design.md)                                                                        | Complete empty/protected, nonzero, timeout, malformed, incomplete/missing-ID controls; harness, not authenticated provider ABI                                                                                    |
| W   | [Bun/Wasm results](../../research/experiments/results/opa-bun.json), [research](../../research/research.md)                                                                                             | Same compiled policy on ten Parent and ten Child rows, boundary updates and unchanged/changed nonempty protection; no incremental maintenance                                                                     |
| C   | [Cost measurements](../../research/experiments/results/cost.json), [research](../../research/research.md)                                                                                               | V2 combined-run 1,000/10,000 full probes and revised measurements; same three budget-exceeded cells; no end-to-end Scribe cost or production threshold                                                            |
| A   | [Handoff and source record](../../research/handoff-for-design.md)                                                                                                                                       | Real Cozo fixed-rule callback/error and transaction probe, native tailoring documentation, health-only interop; no shared registry/publication implementation                                                     |
| R   | [Combined replay](../../research/experiments/results/combined-v2.json), [scratch instructions](../../research/reproduce.md)                                                                             | Original-host `--all` exit 0 using existing dependencies; copied-scratch replay documented, not new-host setup or production qualification                                                                        |
| D   | This design, Nix and recipe artifacts                                                                                                                                                                   | Proposed surface and explicit obligation only; no executed capability evidence                                                                                                                                    |

Later gates below follow the reference's qualification sequencing, not
authorization to begin those gates. Gate 3 requires human review first. Native
evidence cannot substitute for a custom semantic refusal whose native
preconditions must independently pass.

## All 44 numbered reference cases

| Case | Proposed interface and recipe                              | Capability evidence now                                                                  | Required later implementation evidence                                                                                                                                          |
| ---- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| G01  | N1 `c.targets`, R01                                        | P: contextual grammar; V: scoped facts                                                   | Gate 3: persist F1a-owned Parent R to F2 and report owner/type/role/target                                                                                                      |
| G02  | N1 and N2 `rawTarget`, R01/R11                             | P permits resolvable controls; D target rule                                             | Gate 3: Z0 resolves natively but custom FOO target check refuses with expected/actual types; unchanged/reload                                                                   |
| G03  | N1 BAZ without FOO policies, R01                           | V: selector components tested                                                            | Gate 3: Z0-owned R to I0 passes while G02 fails; same role spelling does not leak policy                                                                                        |
| G04  | N1 `c.forest roots=multiple`, R01                          | N: multiple roots accepted                                                               | Gate 4: isolated I1 accepted without connectedness obligation under complete custom policy                                                                                      |
| G05  | N1 `maximumParents=1`, R01                                 | N: several native parents allowed; D selected count                                      | Gate 4: F1a's F1/F0 H parents both appear in cardinality finding; otherwise native DAG                                                                                          |
| G06  | N1 `nativeDAG roles=all`, R01                              | N: named cycles accepted by stock; all-edge detector control                             | Integration qualification: refuse full named H cycle with witness, preserving state; no claim current native route already enforces it                                          |
| G07  | N1 complete native DAG, R01/R10                            | N/V: mixed-cycle detection capability and stock gap                                      | Complete-candidate all-role mixed Parent/Child cycle rejection, independent of individually acyclic projections                                                                 |
| G08  | N1 forest view plus bridge, R01/R03                        | N: multiple native parents; V: unselected bridge retained                                | Gate 4: F2 H count remains one despite incoming M connectivity; no bridge-based H ancestry                                                                                      |
| G09  | N1 bridge and N6 native tailoring, R03                     | N: M owns Parent/Child                                                                   | Gate 4: `F0 -> M -> F2` survives custom validation, persistence and reload without synthetic authored reverse                                                                   |
| T01  | N1 visible closed endpoint, R02                            | V/W: closed endpoint truth row                                                           | Gate 4: accept with path `F1a,F1,F0,F2` and persisted authored link                                                                                                             |
| T02  | N1 visible origin boundary, R02                            | V/W: blocked interior row                                                                | Gate 4: native-valid R to F2a rejects with F2/path witness; unchanged                                                                                                           |
| T03  | N1 field mapping, R02                                      | V/W: boundary opening control                                                            | Gate 4: opening F2 permits same R/path with correct new field state                                                                                                             |
| T04  | N1 model dependencies, R02/R12                             | V/W: changed full inputs, no incremental engine                                          | Gate 4: closing F2 revalidates unchanged R; refusal preserves prior open F2 and identifies changed boundary                                                                     |
| T05  | N1 hierarchy dependencies, N8 batch, R02/R07               | V: subtree movement comparisons                                                          | Gate 4: atomic candidate reparenting X into F2 rejects unchanged R, X remains under F1                                                                                          |
| T06  | N1 bridge downward path, R03                               | N: native bridge; V/W: bridge endpoint row                                               | Gate 4: final complete M P=F0/Q=F2 accepted with selected path and native owner facts                                                                                           |
| T07  | N1 bridge boundary, N5 direct alternative pattern, R02/R11 | V/W: blocked bridge row                                                                  | Gate 4: native-valid F0-to-F2a bridge refuses at F2 with meaningful path; equivalent backend witness later                                                                      |
| T08  | N1 selected H only, R02                                    | V: unselected shortcut row                                                               | Gate 4: BAZ native F0-to-G1 shortcut cannot validate BAR; report distinct H roots                                                                                               |
| T09  | N1 original-origin boundary, R02                           | V: nested closure controls                                                               | Gate 4: independently reject F2 then F2a boundary configurations with earliest blocked descent witness                                                                          |
| T10  | N1 uncapped traversal, R02/R12                             | C: larger deep probes; V basic paths                                                     | Gate 4/6: depths 1/3/12 positive and valid interior negatives, then larger measured depths; no depth-1 interior negative invented                                               |
| T11  | N1 native DAG plus visibility/bridge, R02/R03              | V: ten Parent base rows plus separate Child controls; N: native cycle controls           | Gate 4: all 15 decisions truth-table rows, including closed start/exit/internal sibling/cross-root/sibling bridge; native producer on equality and ancestor-cycle rows          |
| E01  | N3 preservation, N4 facts, R05                             | V/W: unchanged passes and changed fails under same nonempty snapshot; E provider success | Gate 4: full ownership projection refuses I0 FLAG change under captured S1 and shows diff/identity                                                                              |
| E02  | N3/N4, R05                                                 | V/E: complete empty allows simplified change                                             | Gate 4: same I0 change passes under S0, with no cached S1 decision                                                                                                              |
| E03  | N4 capture plus policy inputs, R05/R12                     | V/E/W: fresh snapshot change controls                                                    | Gate 4: S0-to-S1 without SDoc edits invalidates old success and reports new mismatch                                                                                            |
| E04  | N4 complete success, R05                                   | E: complete empty distinguished                                                          | Gate 4: isolated I0 deletion allowed under S0 with explicit zero-record capture evidence                                                                                        |
| E05  | N4 result/error protocol, R05/R09                          | E: four error families plus missing identity                                             | Gate 4: nonzero/timeout/malformed/incomplete all yield execution errors and no published mutation                                                                               |
| E06  | N10 coherent envelope, R05                                 | V/E: captured old versus fresh empty controls                                            | Gate 4: S1 retained through source change; intentional subsequent evaluation can use S0; no latest-at-publication claim                                                         |
| E07  | N4 independent executable, R05/R11                         | E harness; A public tool-native extension evidence                                       | Gate 5: independently packaged provider using the same shipped public registration repeats S1/S0 without privileged dispatch                                                    |
| B01  | N8/N10 private group, R07                                  | N: smaller single-operation bridge only; D transaction                                   | Gate 4: create M then endpoints privately, publish complete final candidate together; all participant/readiness evidence                                                        |
| B02  | N1 bridge count, N8 finalization, R07                      | D                                                                                        | Gate 4: final missing-Q candidate refuses with count zero and no published M                                                                                                    |
| B03  | N1 bridge count, N8 final-state check, R03/R07             | D; A database staging is insufficient                                                    | Gate 4: replace Q in either private staging order; same final one-Q state commits                                                                                               |
| B04  | N3 preservation, R05                                       | V/W unchanged/changed nonempty baseline comparison; full projection pending              | Gate 4: deletion and modeled revision under S1 refuse; incoming/layout positive controls also pass when otherwise valid                                                         |
| B05  | N3 conjunctive bundles, R05                                | V/E empty baseline control                                                               | Gate 4: branch-only delete/revision can commit under S0; unrelated T02 still refuses                                                                                            |
| B06  | N8 strong publisher, R10                                   | P reports existing integration limits; D guarantee                                       | Gate 4: T07 refusal leaves bytes and public graph unchanged; disposable/private state separately identified                                                                     |
| B07  | N8 publisher capabilities, R10                             | A Cozo transactions do not provide file atomicity; D                                     | Gate 6: injected Scribe/model/file publication failure restores verified before state or blocks writes pending recovery, never success                                          |
| B08  | N8 publication receipt, R10                                | P native reload/restart observations only                                                | Gate 4/6: accepted T06 and rejected T07 survive reload/cold restart under identical captured inputs                                                                             |
| B09  | N3 required reads, N10 envelope, R09                       | D; E acquisition controls                                                                | Gate 4: missing before or required baseline produces explicit inability to evaluate; no substitution or mutation                                                                |
| X01  | N1/N2/N4/N5 alternatives, R11                              | V backend verdict comparisons; A fixed rule; no public layered API                       | Gate 5: G02/T07/E01 via raw, consumer helper, packaged helper and chosen backend with real artifacts, equal diagnostics and Scribe effects                                      |
| X02  | N1 full contextual selectors, R01/R12                      | V selector component controls                                                            | Gate 5/6: full tag/role/field/UID rename preserves mapped verdicts and witnesses; no fixture dispatch names                                                                     |
| X03  | N3 projection and document scope, R05/R12                  | D                                                                                        | Gate 6: reordered links/moved document preserve reference semantics and refresh source locations; explicit document-sensitive policy remains possible                           |
| X04  | N8 captures and runtime full mode, R12                     | V/W full-input updates only                                                              | Gate 6: full/incremental parity over inserts/deletes/roles/endpoints/flags/moves/batches with before retained at every step                                                     |
| X05  | Public disposable views, N4 invalidation, R10/R12          | D                                                                                        | Gate 6: delete only cache/index, rebuild identical bridge facts/ownership/verdict/witness; authored bytes unchanged                                                             |
| X06  | N4 artifacts/capture identity, R05/R12                     | V/E source change controls; D policy invalidation                                        | Gate 6: policy-artifact or provider-config-only changes recompute dependents; no stale success                                                                                  |
| X07  | N11 optional aggregate callback, R11                       | A Cozo independent sum/error is a narrow affordance                                      | Gate 5 only after separate numeric-model approval: descendant sum plus external limit through direct/tool/helper layers, contributor witnesses; no core corpus fields added now |
| X08  | Full-first runtime proposal, R12                           | C bounded shape costs                                                                    | Gate 6: realistic 1,000/10,000 mixed workloads, init/edit/move/source-change/rebuild costs, scans/provider calls/serialization, parity and actual publication behavior          |

Count: G01–G09 = 9, T01–T11 = 11, E01–E07 = 7, B01–B09 = 9, X01–X08 = 8; total
**44**. T11 additionally expands to all 15 reference truth-table rows, not just
the ten Parent base rows exercised by the probes. V2 adds ten separate literal
Child-hierarchy expectations; those do not fill the remaining T11 rows.

## Reviewed behavior families beyond numbered coverage

| Reviewed family                                                                         | Concrete interface/content                                                  | Evidence boundary and later delivery                                                                                                                         |
| --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Existing native grammar and consumer-owned root/config                                  | N1/N9, R01; existing constructors and future separate contracts             | P current options; later normal generated grammar, readiness/seed and installed consumer qualification                                                       |
| Native Parent/Child ownership, contextual selectors, independent roots, all-role DAG    | N1/N2, R01/R03; G01–G09                                                     | N confirms capabilities/gaps; all-role whole-candidate integration remains required                                                                          |
| Selected target types, forest parent count, other native parents                        | N1 forest and targets, R01                                                  | V scoped facts and actual selected Child projection; custom production rules pending                                                                         |
| Origin-sensitive visit/expand, nesting, no arbitrary depth, unchanged-link revalidation | N1 boundary/visible, R02; T01–T11                                           | V/W Parent and actual Child traversal, C bounded costs; full diagnostic/incremental integration pending                                                      |
| Native compliance/Child tailoring to standard and immutable OTS                         | N6 `nativeTailoring`, actual R03 SDoc                                       | A upstream documented pattern, N native bridge; final renderer and runnable recipe verification pending                                                      |
| Alternate fields/custom logic, including honest equivalence limits                      | N6 `fieldBridgeRule`, actual R04 SDoc and algorithm                         | D; later endpoint/path mapping, virtual union-DAG and distinct export/projection controls                                                                    |
| Whole-model/document/change composition                                                 | N1/N3; design scopes, R09/R11                                               | D; later conjunctive scope coverage and document rules that read model/before                                                                                |
| Identity, main and LLM protection                                                       | N3 lifecycle callbacks, N4 fact registration, R06                           | E is unauthenticated baseline harness; verified principal/main providers and policy-specific projection need implementation/review                           |
| Human-authored/protected documents and HITL                                             | N3 human-review rule, R06 approval payload/steering                         | D; future trusted approval/UI binding, refusal and stale-approval controls; no SSH-key or UI work now                                                        |
| Consumer supersession and independent preservation                                      | N3 no-implicit-exception, N7 explicit replacement, R05/R06                  | D/V limited freeze; later explicit exception policy and conflicting preservation-rule controls                                                               |
| External executable acquisition and checking                                            | N4 runtime/backend/facts, R05/R11                                           | E executable error controls; A direct fixed callback; same public surface and actual package qualification pending                                           |
| Before/candidate/baseline coherence and timing                                          | N10 envelope, R05/R08/R09                                                   | E/V limited captured snapshots; staged trees, multi-source binding and trusted policy loading pending                                                        |
| Daemon transactions, Git hooks or both                                                  | N8 all three profiles, R07/R08                                              | P serialized writes/partial arrays; no existing group/Git atomicity; later boundary-specific effects and receipt reuse tests                                 |
| Deliberate parallel-agent grouping                                                      | N10 stage/ready/finalize messages, R07                                      | D; later membership/authentication, revision conflicts, late staging, stale base, missing participant and coordinator policy                                 |
| Refusal unchanged, publication restore-or-block, recovery                               | N8 publisher registration/capabilities, R10                                 | A sidecar limitation; fault/crash injection, public graph consistency and write-block recovery pending                                                       |
| Inspectable invalid state and consumer repair policy                                    | N8 repair option, R09                                                       | D; later complete-repair reference tests and separately defined alternative repair qualification                                                             |
| Public pluggable runtime/tool/backend/publisher, packaged-adapter parity                | N4 raw and packaged descriptors; N5 Rego; design direct Python/Datalog; R11 | V/A narrow backend/interop evidence; no host ABI implementation, cross-platform or cancellation proof                                                        |
| Explicit unsupported capabilities and composition conflicts                             | N4 negotiation, N7 conflict/replace/disable, R11                            | D; later malformed registry/version, stale edit, duplicate ID, unsupported witness and health-only refusal tests                                             |
| Equivalent helpers/direct surfaces and name independence                                | N1/N2/N5, R11/R12; X01–X03                                                  | V selected verdict comparisons; full public conformance and source-location parity pending                                                                   |
| Full/incremental equivalence, source/policy changes, disposable cache and cost          | N4 full default/invalidation, R12; X04–X06/X08                              | V/W/C full prototypes only; differential maintenance/rebuild/mixed end-to-end costs pending                                                                  |
| Optional numeric public extension challenge                                             | N11, R11; X07                                                               | A sum callback demonstrates an affordance only; separate approval and new isolated numeric model required                                                    |
| Generic Scribe and clean neutral fixture finalization                                   | Proposed neutral N1 has no guarded fields; R13                              | P records current coupling; cleanup after final qualification before fold-back, with no renamed substitutes and historical evidence outside fixture scope    |
| Human Markdown and generated-steering content for all families                          | R01–R13 include full draft steps/content and steering paragraphs            | Delivered as design text; final runnable validation and steering placement remain later, no SDoc/spec/plan edits                                             |
| Design/production boundary and dependency constraints                                   | Artifact status, progress log, R13                                          | No network, installs, builds, agent spawning, production edits, commits or pushes; no backend adoption; JVM excluded, SQLite requires compelling future case |

## Reference decisions carried into the proposal

The reviewed packet, not the older status labels, controls authority. This table
records where the reference behavior is expressible and where consumer choice
remains; it does not approve API names or promote every fixture choice into the
engine.

| Reference decision | Proposed representation and review boundary                                                                                             |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| D01                | N1 explicit false/open, true/closed mapping and input error for invalid value; configurable field/value mapping                         |
| D02                | N1/N2 full contextual target selectors; consumer names and permitted targets                                                            |
| D03                | N1 selected parent maximum and bridge exact counts over final candidates; helper parameters                                             |
| D04                | N1 `same-tree-up-then-down` plus origin-sensitive boundary expansion                                                                    |
| D05                | N1 closed origin included in its own subtree; R02 examples                                                                              |
| D06                | N1 downward bridge; zero-length conceptual path cannot overrule native DAG; R02/R03 controls                                            |
| D07                | N3 explicit existence/type/FLAG/owned-relations projection with stated exclusions                                                       |
| D08                | N3 `exceptions=[]`; R06 explicit consumer replacement required for supersession lifecycle                                               |
| D09                | N4 once-per-evaluation capture; N10 identified retained inputs; stronger publication freshness would need separate qualified capability |
| D10                | N4 result/error contract and R05 failure controls; empty success is explicit                                                            |
| D11                | N8/N10 private final-candidate group; Git boundary differences stated, no RPC-array substitution                                        |
| D12                | N8 `complete-valid-result`; R09 retains invalid input, alternative repair is an explicit future consumer policy                         |
| D13                | N8 required publisher guarantees; R10 recovery; exact crash protocol remains an implementation/review choice                            |
| D14                | N7 explicit identity-targeted actions; conflict checks described in design and R11                                                      |
| D15                | N11 remains disabled illustrative challenge outside the neutral grammar, pending separate approval                                      |

## Qualification delivery and present checks

The next review should choose API shape, implementation candidate and supported
boundary contract before production Gate 3. The first implementation slice
should make G02 a real resolvable wrong-target refusal through the public
consumer surface while preserving native checks. Later slices qualify the
forest/traversal/protection/group behavior, layered extensions, and finally
failure recovery, incrementality and scale. Existing native role gaps must be
addressed as an integration prerequisite for claiming the reviewed DAG
guarantee, not hidden behind a successful target slice.

For each later test, retain input/grammar/policy/adapter identities, required
before/baseline snapshots, contextual findings and publication state evidence.
Negative semantic tests must independently pass native resolution and global
cycle prerequisites. Compare authored bytes, observable/reloaded graph and
disposable views separately. No partial probe or unrelated native rejection
fills a semantic coverage cell.

Present verification is limited to formatting every edited Markdown/Nix/JSON
artifact with the required unwrapped treefmt and parsing `outputs/examples.nix`
with `nix-instantiate --parse`. No missing library exports were stubbed, and no
Nix evaluation, build, runtime backend test or production installation was
claimed. `progress.json` records reading and completion milestones. Finished
deliverables will be left stable for the root's independent freeze; no extra
hash manifest is necessary.

For the v2 evidence-only revision, the three Markdown artifacts and progress log
were reformatted; the unchanged Nix artifact retains its original successful
parse result and was not re-parsed. Current links, all v2 cost-table values, the
44 reference rows and 13 recipe/steering pairs were checked without replaying
experiments. Original v1 provenance remains in the design note and progress log.
