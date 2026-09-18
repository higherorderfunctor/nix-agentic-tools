# Gate 1 dsl-review backend fixtures

A fixture is a directory holding a `candidate.json`, a `results.json` whose
`expected` is true, and a `case.md` stating the situation, the change, the
expected envelope, and the contract lines that force it. `results.json` is the
expected envelope per `contract.md`'s normative result fields, ordering,
blocking rules, and closed status/code sets — conformance means an evaluator's
real output matches this file exactly on every normative field.

## Fixture index

88 fixture directories carry a `results.json` (an actual expectation); 8 further
directories (`chain-depth-boundary-negative-family`,
`nested-boundary-earlier-f2-rejected`, `note-state-field`,
`provider-execution-error-family`, `s0-baseline-accepts-branch-only-change`,
`s1-baseline-rejects-delete-or-flag-revision`,
`script-default-source-success-vs-failure-family`,
`visibility-truth-table-family`) are families: their own `case.md` states what
the variants beneath share and carries no envelope of its own. `lowering-guards`
is neither a fixture nor a family: it holds nine lowering-time throw probes that
`tests/test_lowering_guards.py` evaluates directly, so it carries no envelope
and no member. "What it exercises" is derived by reading each fixture's
`results.json`: the statuses that appear across its rule and finding entries,
any leaf kind beyond the five that appear in nearly every fixture (`count`,
`native-dag`, `forest-validity`, `preserve`, `target-type`), any code beyond a
leaf's own same-named satisfied code, and any `all`/`any`/`not` composed
operator, recovered from a finding's `predicatePath` segments since no finding
in this corpus carries a literal `operator` key. 30 fixtures compose
`target-type` and `visible-target` under `all`; the six `note-state-field`
members compose `field-value` and `count` under `any`/`not`. Both are marked
`ops:` below — see the coverage matrix for the per-status breakdown.

| Fixture                                                                               | Section                                  | What it exercises                                                           | Provenance    |
| ------------------------------------------------------------------------------------- | ---------------------------------------- | --------------------------------------------------------------------------- | ------------- |
| `bar-batch-boundary-rejection-preserves-authored-bytes`                               | Transition/batch/recovery                | satisfied/violated +endpoint-path codes:closed-boundary                     | B06           |
| `bar-boundary-f2-on-path-to-f2a-rejected`                                             | Traversal                                | satisfied/violated +endpoint-path codes:closed-boundary                     | T07           |
| `bar-bridge-no-h-ancestry-accepted`                                                   | Structural graph                         | satisfied +endpoint-path                                                    | G08           |
| `bar-downward-path-closed-endpoint-accepted`                                          | Traversal                                | satisfied +endpoint-path                                                    | T06           |
| `bar-endpoint-swap-final-one-q-accepted`                                              | Transition/batch/recovery                | satisfied +endpoint-path                                                    | B03           |
| `bar-final-state-accepted-despite-private-incomplete-mutation`                        | Transition/batch/recovery                | satisfied +endpoint-path                                                    | B01           |
| `bar-final-valid-despite-private-incomplete-endpoint-order`                           | Authoring/publication (revised controls) | satisfied +endpoint-path                                                    | A01           |
| `bar-missing-q-cardinality-rejected`                                                  | Transition/batch/recovery                | satisfied/violated/blocked codes:prerequisite                               | B02           |
| `bar-no-h-path-despite-native-bridge-rejected`                                        | Traversal                                | satisfied/violated +endpoint-path codes:no-shared-root                      | T08           |
| `bar-ownership-f0-m-f2-no-reverse-edge-accepted`                                      | Structural graph                         | satisfied +endpoint-path                                                    | G09           |
| `bar-q-target-wrong-element-baz-rejected`                                             | Negative control (no catalogue id)       | satisfied/violated/blocked +endpoint-path codes:input                       | none          |
| `batch-reparent-hides-unchanged-r-rejected`                                           | Traversal                                | satisfied/violated +visible-target ops:all codes:closed-boundary            | T05           |
| `baz-parent-r-unrestricted-accepted`                                                  | Structural graph                         | satisfied                                                                   | G03           |
| `boundary-opened-r-past-endpoint-accepted`                                            | Traversal                                | satisfied +visible-target ops:all                                           | T03           |
| `captured-snapshot-consistency-across-provider-switch`                                | External-state                           | satisfied/violated codes:difference                                         | E06           |
| `chain-depth-boundary-negative-family/depth-1-closed-endpoint-accepted`               | Traversal                                | satisfied +visible-target ops:all                                           | T10           |
| `chain-depth-boundary-negative-family/depth-12-interior-closed-rejected`              | Traversal                                | satisfied/violated +visible-target ops:all codes:closed-boundary            | T10           |
| `chain-depth-boundary-negative-family/depth-12-open-chain-accepted`                   | Traversal                                | satisfied +visible-target ops:all                                           | T10           |
| `chain-depth-boundary-negative-family/depth-3-interior-closed-rejected`               | Traversal                                | satisfied/violated +visible-target ops:all codes:closed-boundary            | T10           |
| `chain-depth-boundary-negative-family/depth-3-open-chain-accepted`                    | Traversal                                | satisfied +visible-target ops:all                                           | T10           |
| `close-boundary-leaves-reference-hidden`                                              | Authoring/publication (revised controls) | satisfied/violated +visible-target ops:all codes:closed-boundary            | A02           |
| `close-boundary-with-repaired-reference-in-same-batch`                                | Authoring/publication (revised controls) | satisfied +visible-target ops:all                                           | A02           |
| `combined-role-cycle-across-h-r-q-rejected`                                           | Structural graph                         | satisfied/violated codes:cycle                                              | G07           |
| `consistent-renaming-preserves-verdicts`                                              | Cross-cutting qualification              | satisfied/violated/blocked +visible-target ops:all codes:input              | X02           |
| `create-set-unset-default-and-create-delete-lifecycle`                                | Defaults (revised controls)              | satisfied                                                                   | DFT06         |
| `delete-target-and-referencing-declarations-in-one-batch`                             | Authoring/publication (revised controls) | satisfied                                                                   | A03           |
| `deleted-target-leaves-dangling-reference`                                            | Authoring/publication (revised controls) | satisfied/blocked +visible-target ops:all codes:unresolved-target           | A03           |
| `empty-baseline-allows-isolated-deletion`                                             | External-state                           | satisfied                                                                   | E04           |
| `empty-relation-collection-blocks-bar-endpoint-path`                                  | Authoring/publication (revised controls) | satisfied/violated/blocked codes:prerequisite                               | A10           |
| `explicit-values-preserved-no-default-applied`                                        | Defaults (revised controls)              | satisfied/violated +visible-target ops:all codes:closed-boundary            | DFT02         |
| `flag-absent-defaults-to-canonical-false`                                             | Defaults (revised controls)              | satisfied +visible-target ops:all                                           | DFT01         |
| `flag-change-accepted-under-empty-baseline`                                           | External-state                           | satisfied                                                                   | E02           |
| `flag-change-rejected-under-protecting-baseline`                                      | External-state                           | satisfied/violated codes:difference                                         | E01; E03      |
| `h-cardinality-two-parents-rejected`                                                  | Structural graph                         | satisfied/violated/blocked                                                  | G05           |
| `h-target-wrong-element-baz-rejected`                                                 | Negative control (no catalogue id)       | satisfied/violated/blocked                                                  | none          |
| `identical-candidate-accepted-under-narrow-baseline`                                  | Authoring/publication (revised controls) | satisfied                                                                   | A08           |
| `invalid-value-multiplicity-errors-never-defaulted`                                   | Defaults (revised controls)              | satisfied/blocked +visible-target ops:all codes:input                       | DFT03         |
| `isolated-root-added-multi-root-forest-accepted`                                      | Structural graph                         | satisfied                                                                   | G04           |
| `missing-before-or-baseline-acquisition-cannot-evaluate`                              | Transition/batch/recovery                | satisfied/error codes:execution                                             | B09           |
| `native-cycle-f0-f1-f1a-rejected`                                                     | Structural graph                         | satisfied/violated/blocked codes:cycle                                      | G06           |
| `nested-boundary-earlier-f2-rejected/inner-boundary-f2a-closed`                       | Traversal                                | satisfied/violated +endpoint-path codes:closed-boundary                     | T09           |
| `nested-boundary-earlier-f2-rejected/outer-boundary-f2-closed`                        | Traversal                                | satisfied/violated +endpoint-path codes:closed-boundary                     | T09           |
| `no-backfill-on-existing-absent-field`                                                | Defaults (revised controls)              | satisfied/blocked +visible-target ops:all codes:input                       | DFT05         |
| `note-state-field/cited-source-in-draft-rejected`                                     | Field-value leaf (variant model)         | satisfied/violated +field-value ops:any,not                                 | variant model |
| `note-state-field/cited-source-without-a-state-accepted`                              | Field-value leaf (variant model)         | satisfied/violated +field-value ops:any,not                                 | variant model |
| `note-state-field/draft-note-owning-a-source-rejected`                                | Field-value leaf (variant model)         | satisfied/violated +field-value ops:any,not                                 | variant model |
| `note-state-field/note-without-a-state-is-not-retired-accepted`                       | Field-value leaf (variant model)         | satisfied/violated +field-value ops:any,not                                 | variant model |
| `note-state-field/retired-note-owning-a-source-accepted`                              | Field-value leaf (variant model)         | satisfied/violated +field-value ops:any,not                                 | variant model |
| `note-state-field/retired-note-without-a-source-rejected`                             | Field-value leaf (variant model)         | satisfied/violated +field-value ops:any,not                                 | variant model |
| `policy-or-provider-config-change-forces-recomputation`                               | Cross-cutting qualification              | satisfied/violated +visible-target ops:all codes:closed-boundary,difference | X06           |
| `provider-execution-error-family/incomplete-snapshot`                                 | External-state                           | satisfied/error codes:execution                                             | E05           |
| `provider-execution-error-family/malformed-output`                                    | External-state                           | satisfied/error codes:execution                                             | E05           |
| `provider-execution-error-family/nonzero-exit`                                        | External-state                           | satisfied/error codes:execution                                             | E05           |
| `provider-execution-error-family/timeout`                                             | External-state                           | satisfied/error codes:execution                                             | E05           |
| `r-into-closed-endpoint-accepted`                                                     | Structural graph                         | satisfied +visible-target ops:all                                           | G01           |
| `r-past-closed-boundary-rejected`                                                     | Traversal                                | satisfied/violated +visible-target ops:all codes:closed-boundary            | T02           |
| `r-target-wrong-element-baz-rejected`                                                 | Structural graph                         | satisfied/violated/blocked +visible-target ops:all codes:input              | G02           |
| `r-to-closed-endpoint-visible-path-accepted`                                          | Traversal                                | satisfied +visible-target ops:all                                           | T01           |
| `closing-boundary-again-hides-existing-r-rejected`                                    | Traversal                                | satisfied/violated +visible-target ops:all codes:closed-boundary            | T04           |
| `s0-baseline-accepts-branch-only-change/i0-deletion`                                  | Transition/batch/recovery                | satisfied                                                                   | B05           |
| `s0-baseline-accepts-branch-only-change/i0-flag-revision`                             | Transition/batch/recovery                | satisfied                                                                   | B05           |
| `s1-baseline-rejects-delete-or-flag-revision/i0-deletion`                             | Transition/batch/recovery                | satisfied/violated codes:difference                                         | B04           |
| `s1-baseline-rejects-delete-or-flag-revision/i0-flag-revision`                        | Transition/batch/recovery                | satisfied/violated codes:difference                                         | B04           |
| `script-default-source-success-vs-failure-family/empty-complete-snapshot-is-a-value`  | Defaults (revised controls)              | satisfied                                                                   | DFT04         |
| `script-default-source-success-vs-failure-family/provider-empty-stdout-refuses`       | Defaults (revised controls)              | satisfied/error codes:execution                                             | DFT04         |
| `script-default-source-success-vs-failure-family/provider-malformed-output-refuses`   | Defaults (revised controls)              | satisfied/error codes:execution                                             | DFT04         |
| `script-default-source-success-vs-failure-family/provider-missing-identity-refuses`   | Defaults (revised controls)              | satisfied/error codes:execution                                             | DFT04         |
| `script-default-source-success-vs-failure-family/provider-non-object-json-refuses`    | Defaults (revised controls)              | satisfied/error codes:execution                                             | DFT04         |
| `script-default-source-success-vs-failure-family/provider-nonzero-exit-refuses`       | Defaults (revised controls)              | satisfied/error codes:execution                                             | DFT04         |
| `script-default-source-success-vs-failure-family/provider-timeout-refuses`            | Defaults (revised controls)              | satisfied/error codes:execution                                             | DFT04         |
| `source-change-after-preparation-publishes-captured-value`                            | Defaults (revised controls)              | satisfied                                                                   | DFT07         |
| `unrelated-dangling-reference-stays-out-of-forest-causes`                             | Negative control (no catalogue id)       | satisfied/blocked codes:unresolved-target,prerequisite                      | none          |
| `visibility-truth-table-family/bridge-across-distinct-roots-rejected`                 | Traversal                                | satisfied/violated +endpoint-path codes:no-shared-root                      | T11           |
| `visibility-truth-table-family/bridge-between-siblings-needs-ascent-rejected`         | Traversal                                | satisfied/violated +endpoint-path                                           | T11           |
| `visibility-truth-table-family/bridge-from-closed-start-accepted`                     | Traversal                                | satisfied +endpoint-path                                                    | T11           |
| `visibility-truth-table-family/bridge-past-closed-intermediate-rejected`              | Traversal                                | satisfied/violated +endpoint-path codes:closed-boundary                     | T11           |
| `visibility-truth-table-family/bridge-to-closed-endpoint-accepted`                    | Traversal                                | satisfied +endpoint-path                                                    | T11           |
| `visibility-truth-table-family/bridge-with-equal-endpoints-native-cycle-rejected`     | Traversal                                | satisfied/violated +endpoint-path codes:cycle                               | T11           |
| `visibility-truth-table-family/closed-endpoint-visited-from-outside-accepted`         | Traversal                                | satisfied +visible-target ops:all                                           | T11           |
| `visibility-truth-table-family/closed-origin-exits-its-own-compartment-accepted`      | Traversal                                | satisfied +visible-target ops:all                                           | T11           |
| `visibility-truth-table-family/external-origin-cannot-expand-closed-node-rejected`    | Traversal                                | satisfied/violated +visible-target ops:all codes:closed-boundary            | T11           |
| `visibility-truth-table-family/internal-origin-exits-closed-compartment-accepted`     | Traversal                                | satisfied +visible-target ops:all                                           | T11           |
| `visibility-truth-table-family/internal-origin-reaches-internal-sibling-accepted`     | Traversal                                | satisfied +visible-target ops:all                                           | T11           |
| `visibility-truth-table-family/opened-boundary-lets-external-origin-descend-accepted` | Traversal                                | satisfied +visible-target ops:all                                           | T11           |
| `visibility-truth-table-family/relation-across-distinct-roots-rejected`               | Traversal                                | satisfied/violated +visible-target ops:all codes:no-shared-root             | T11           |
| `visibility-truth-table-family/relation-to-own-descendant-native-cycle-rejected`      | Traversal                                | satisfied/violated +visible-target ops:all codes:cycle                      | T11           |
| `visibility-truth-table-family/relation-to-self-native-cycle-rejected`                | Traversal                                | satisfied/violated +visible-target ops:all codes:cycle                      | T11           |
| `warm-cache-recomputes-on-metadata-policy-baseline-change`                            | Authoring/publication (revised controls) | satisfied/violated codes:difference                                         | A08           |

## Coverage matrix

Rows are the closed status set (contract.md:778); columns are the eight closed
leaf kinds (contract.md:843) plus the three composed operators
(contract.md:843). A cell counts the fixtures, of 88, whose `results.json` has
at least one finding of that status carrying that leaf kind or whose
`predicatePath` carries that operator segment; the `error` row is zero
throughout because every `error` finding in this corpus carries `kind: null`
with code `execution`, which matches no leaf-kind or operator column here.

| Status    | target-type | count | field-value | visible-target | endpoint-path | native-dag | forest-validity | preserve | all | any | not |
| --------- | ----------- | ----- | ----------- | -------------- | ------------- | ---------- | --------------- | -------- | --- | --- | --- |
| satisfied | 82          | 88    | 5           | 16             | 9             | 75         | 78              | 65       | 27  | 6   | 2   |
| violated  | 4           | 8     | 6           | 10             | 8             | 5          | 3               | 6        | 12  | 6   | 6   |
| blocked   | 2           | 0     | 0           | 5              | 1             | 2          | 1               | 0        | 5   | 0   | 0   |
| error     | 0           | 0     | 0           | 0              | 0             | 0          | 0               | 0        | 0   | 0   | 0   |

## Deferred to runtime

Catalogue rows and other items this section did not turn into a fixture, and
why. Most are excluded because the coordinator scoped them to a later gate
(`scenarios.md`'s Cross-cutting qualification and Revised contract controls
sections say so explicitly); the rest note something a merge needs to know.

- **`runtime-scope-cases`** — The runtime-scope list handed to this section was
  empty, so nothing was skipped for scope. All eleven Traversal rows are scope
  evaluator and all were written; none is mixed, so no fixture carries an
  uncovered-runtime-obligation line.
- **`side-effect:treefmt-reformatted-26-foreign-fixture-files`** — Disclosure,
  not a deferral. Following the repo rule to run treefmt on changed files, I
  built the file list with find over backend/fixtures and an exclusion list of
  the six sibling directories that existed when I started. Between then and the
  run, other section agents had created ~30 more directories, so the single
  command at 2026-09-17 20:48:12 also formatted about 26 files outside my area
  (mostly case.md, plus results.json in r-target-wrong-element-baz-rejected,
  baz-parent-r-unrestricted-accepted and
  isolated-root-added-multi-root-forest-accepted). The change is whitespace
  only - prettier prose reflow and biome JSON formatting, the repo's own
  formatters, which preserve markdown content and JSON values - and no file of
  mine touched any foreign directory otherwise. I cannot show the pre-change
  bytes because running git was forbidden. Every later formatting pass was
  restricted to my own 11 directories (93 files) and is idempotent. If a section
  owner reports unexpected reflow in their case.md, this is the cause.
- **`convention:case.md-is-one-paragraph-per-labelled-statement`** — Heads-up
  for merging. The tree's markdown formatter has proseWrap=always, so a case.md
  written as one long line per label gets reflowed and consecutive labels get
  JOINED into one paragraph - that is the current state of the baseline
  section's fixtures (for example
  flag-change-accepted-under-empty-baseline/case.md ends '(contract.md:601-602).
  provenance: E02' mid-line). My 33 case.md files separate each labelled
  statement with a blank line, which the formatter keeps intact, so
  Situation/Change/Expected/Why/Ambiguity/provenance all stay line-initial and
  searchable. Each file has at most 12 labelled statements; the 12-line cap
  cannot be met physically once an 80-column reflow runs. Worth normalizing the
  other sections the same way.
- **`E07`** — Listed as runtime scope and explicitly excluded from this
  section's work by the task instruction. Skipped entirely; no fixture directory
  created.
- **`B07`** — Runtime scope, excluded by the task. Injecting a Scribe
  publication, model or file failure after a valid candidate passes semantic
  checks, and then asserting what was restored and whether writes were blocked
  pending reload, requires an actual publication attempt. The dsl-review bundle
  declares no publication operation, no recovery-required status (the closed
  status set is satisfied/violated/blocked/error, contract.md:778) and no result
  field for restoration evidence, so it cannot be expressed as a candidate.json
  plus results.json pair.
- **`B08`** — Runtime scope, excluded by the task. Performing accepted T06 and
  rejected T07, then reloading and cold-restarting after each, and comparing
  reloaded existence/relations/FLAG against the reported result, is a
  persistence and process-lifecycle claim. The contract's boundary is one
  evaluation over one supplied final candidate graph (contract.md:433-434);
  there is no reload, no restart and no cross-run comparison in the envelope, so
  the assertion has nowhere to live.
- **`X01`** — Runtime scope, listed by the coordinator as out of scope. Requires
  expressing the same rules through shared primitives, a consumer helper, an
  adopted helper and the chosen backend surfaces, then comparing verdicts across
  entry points. There is no entry-point dimension in a fixture directory:
  contract.md:1026 states no backend evaluator, provider runner or result
  generator runs at Gate 1, so equal-verdict-across-surfaces has nothing to
  compare.
- **`X03`** — Runtime scope, listed by the coordinator as out of scope.
  Reordering relation declarations needs a second bundle (bundle.json is the
  single fixed rule set, contract.md:110-116), and moving a record to another
  document needs document placement, which contract.md:355-356 explicitly
  excludes from the projection and which the candidate record shape does not
  carry at all (contract.md:439-440: a record has exactly uid, element, fields,
  relations).
- **`X04`** — Runtime scope, listed by the coordinator as out of scope. A
  differential sequence of inserts, deletes, endpoint changes, FLAG toggles,
  subtree moves and batches compared against fresh runs needs multiple
  successive evaluations. A fixture carries exactly one candidate and one
  envelope, and contract.md:450 says only the final batch state is evaluated, so
  intermediate steps are not representable.
- **`X05`** — Runtime scope, listed by the coordinator as out of scope. Deleting
  disposable index/cache state and rebuilding requires derived runtime state,
  which does not exist at Gate 1 (contract.md:1026 lists no default
  materializer, provider runner or result generator), and contract.md:356
  excludes runtime bookkeeping from the compared projection.
- **`X07`** — Runtime scope, listed by the coordinator as out of scope, and
  additionally blocked by the profile. It needs a new numeric FOO field and an
  aggregate sum rule; contract.md:968 restricts semantic.type to string or
  boolean in this profile, contract.md:236-237 closes the leaf set to seven
  kinds with no aggregate, and scenarios.md:107 itself gates the row on separate
  approval and a pending decision.
- **`X08`** — Runtime scope, listed by the coordinator as out of scope. A
  1,000/10,000-node performance workload measuring cold and warm latency, scans,
  provider calls, serialization, invalidation and rebuild is a measurement
  harness, not an expected-envelope fixture; nothing in the envelope shape
  (contract.md:565-573) records timing or call counts.
- **`DFT07`** — Runtime scope, excluded by the task. It asserts that a default
  SOURCE changes after preparation and that the captured value is published
  exactly, with no rerun, while a later explicit invocation counts as a new
  preparation. Nothing in it is decidable from a single expected envelope: the
  contract defines no default-source provider at all (semanticTypes carries only
  default null or {"literal": false}, contract.md:972-974), and the one
  capture-timing rule it does state — "Capture one identified immutable snapshot
  per evaluation and reuse it throughout; a provider change affects the next
  evaluation, never a later rule in this one" (contract.md:529-531) — is about
  the BASELINE input, whose per-evaluation coherence the external-state section
  already owns (the sibling captured-snapshot-consistency-across-provider-switch
  fixture, E06). Writing DFT07 as a fixture would require inventing both a
  default-source wire shape and a way to express "no rerun" inside one envelope,
  and two evaluations of the same envelope shape cannot show a rerun did not
  happen.
- **`A04`** — Runtime scope, and unrepresentable in the envelope: document move
  with path/membership policy. The record shape excludes document placement
  (contract.md:353-357: 'document placement, and runtime bookkeeping are
  excluded'), and there is no publication step, destination path, or membership
  input anywhere in the contract, bundle or invocation schema.
- **`A05`** — Runtime scope: authoritative base changes after validation and
  before publication. The contract ends at the result envelope and models no
  publication, no receipt, and no base revision identity. Its only temporal
  statement is that one immutable snapshot is captured per evaluation
  (contract.md:529-531), which does not express stale refusal.
- **`A06`** — Runtime scope: dry-run and refused candidate while other readers
  hold a prior generation. There is no reader, generation, speculative-index or
  export surface in the contract; a refused candidate is simply an envelope that
  is not satisfied (contract.md:665).
- **`A07`** — Runtime scope: injected partial save and restoration failure.
  Publication, restore-or-block and recovery-required outcomes are outside the
  evaluation envelope; the closed status space is
  satisfied/violated/blocked/error (contract.md:778) with no recovery status.
- **`A09`** — Needs a second bundle authoring and a registration surface, not a
  candidate: a consumer DSL emitting its own contract and an independently
  registered implementation. bundle.json is fixed for this corpus, and
  unsupported-contract rejection happens during lowering or as a configuration
  error before any per-case envelope differs (contract.md:247-250).
- **`A11`** — Runtime scope: git staged-tree refusal after a Scribe batch
  publication. No VCS, index, worktree or publication concept exists in the
  contract; model.md:165-167 states explicitly that the fixture provider
  establishes no Git baselines or cross-revision identity.

## Disputed

Open questions this section's author and its verifier did not converge on. Each
is left as authored; none blocks this index. The corpus-wide
`baseline-preserved` assumption is the one item that can flip 30 envelopes at
once and wants an operator ruling before Gate 1 closes.

### `section-wide: all 30 traversal leaf fixtures (declared in all 33 case.md; e.g. visibility-truth-table-family/bridge-between-siblings-needs-ascent-rejected/case.md:37-40)`

**Rule:** model:reference/check:baseline-preserved

**Author's position:** No fixture directory supplies baseline.json or
invocation.json; each inherits the packet-level binding at
contract/gate2/dsl-review/invocation.json and baseline.json, so every envelope
reports baseline "baseline-I0-open" and a satisfied baseline-preserved with
differences []. The closest supporting text is contract.md:515-517, which
resolves a binding's relative paths from "the invocation working directory, the
packet directory for this sample" - but that fixes where a command's paths
resolve, not whether a fixture SUBDIRECTORY inherits the packet's
invocation.json at all.

**Verifier's position:** Accepts the same values as what the section uniformly
declares, but flags that nothing normative states the fallback, and that the
literal reading of contract.md:523-525 ("a missing command binding is also an
execution error") would instead make model:reference/check:baseline-preserved
error and force every envelope in the section to error. Calls it the single
assumption the whole section rests on and asks for it to be pinned in
contract.md before Gate 1 closes. I agree: this is the one open item that can
flip all 30 envelopes, so it wants an operator ruling, not a fixture edit.

**Contract lines:** contract.md:511-517, contract.md:519-525; declared at
visibility-truth-table-family/bridge-between-siblings-needs-ascent-rejected/case.md:37-40
and in the other 32 case.md files of the section

### `visibility-truth-table-family/bridge-with-equal-endpoints-native-cycle-rejected (plus relation-to-self-native-cycle-rejected and relation-to-own-descendant-native-cycle-rejected)`

**Rule:** model:reference/check:native-dag

**Author's position:** The contract fixes the witness SHAPE but not where a
cycle's closed uid walk starts nor the key naming the edge owner. These three
fixtures start each walk at the lexicographically smallest uid in the cycle and
name the owner key "uid", matching the finding-level owner field: cycle
["F2","M","F2"], ["F2","F2","F2"-style self-loop "F2","F2"], and
["F2","F2a","F2"].

**Verifier's position:** Re-derived the same witnesses from candidate RECORD
order rather than lexicographic order, and notes the two rules coincide on every
cycle in this section: all are two nodes long and the smallest uid is also first
in record order, so the choice is not exercised anywhere and neither derivation
is testable here. A three-node cycle would separate them. Asks for the rule to
be stated in contract.md before a backend is written against it. I agree the
contract does not decide it; contract.md:617-618 ("graph witnesses additionally
contain the owner's uid") arguably settles the KEY name but says nothing about
the start node.

**Contract lines:** contract.md:616-618, contract.md:636; declared at
visibility-truth-table-family/bridge-with-equal-endpoints-native-cycle-rejected/case.md:22-26,
relation-to-self-native-cycle-rejected/case.md:19-21,
relation-to-own-descendant-native-cycle-rejected/case.md:21-23

### `closing-boundary-again-hides-existing-r-rejected`

**Rule:** model:reference/element:FOO/relation:parent:R/check:R.all

**Author's position:** Because only final state is evaluated, this fixture's
candidate and expected envelope are conformance-identical to
r-past-closed-boundary-rejected; the contract offers no field recording WHICH
edit invalidated the path, so "identifies the changed boundary" is satisfied by
the boundary evidence alone. Kept as a fixture because it documents the
re-closing intent that the identical final state cannot express.

**Verifier's position:** Accepts the declaration and names the consequence to
accept knowingly: the fixture cannot fail independently of
r-past-closed-boundary-rejected, so it documents intent rather than testing
anything new. Classed as informational, not a defect. Left as authored because
nothing in the contract decides whether a conformance-redundant fixture should
exist; the keep-or-retire call is the operator's, and it is the same call as the
G01/T01 duplication reported in `fixed`.

**Contract lines:** contract.md:575-578 (message ignored by conformance
comparison); closing-boundary-again-hides-existing-r-rejected/case.md:23-27

### `s1-baseline-rejects-delete-or-flag-revision`

**Rule:** Naming discipline: 'A case id may appear ONLY on a single provenance:
line inside that fixture's case.md' — does the family-level case.md, which has
no results.json of its own, count as 'that fixture's case.md' and so get a
provenance line too?

**Author's position:** Kept as authored. Nothing in the contract governs case.md
provenance placement, and the per-file reading is the one the whole corpus
implements: each of the eleven files in this section carries exactly one
provenance line and names no case id in prose. Four families outside this
section do the same — provider-execution-error-family/case.md:23,
chain-depth-boundary-negative-family/case.md:34,
visibility-truth-table-family/case.md:42,
script-default-source-success-vs-failure-family/case.md:41 (and
nested-boundary-earlier-f2-rejected/case.md:30) each carry a family-level
provenance line beside their variants'. Under the per-id reading every family in
the corpus is wrong, T11 appearing on 17 provenance lines. Stripping the line
from these two families alone would make this section the odd one out. Recorded
under 'Disputed:' at s1-baseline-rejects-delete-or-flag-revision/case.md:24-35.

**Verifier's position:** Reported as 'family-level provenance duplication
(structural, not a contract violation)': one case id appears on three provenance
lines inside one family, whereas the five single-directory fixtures each carry
exactly one. The verifier asserted no violation and demanded no change.

**Contract lines:** none —
fixtures/strictdoc-semantic-library/contract/gate2/dsl-review/contract.md is
silent on case.md structure; it normatively covers only result fields, codes,
ordering, blocking and defaults lifecycle. The rule in question is the task's
naming discipline, not a contract clause.

### `s0-baseline-accepts-branch-only-change`

**Rule:** Same question, second family: may the family-level case.md carry a
provenance line alongside its two variants' lines?

**Author's position:** Kept as authored, for the reasons above; recorded under
'Disputed:' at s0-baseline-accepts-branch-only-change/case.md:26-37. All other
body case ids in this family were removed, so the only occurrence per file is
the standalone provenance line.

**Verifier's position:** Same report: three provenance lines for one case id
inside one family, flagged as structural rather than a contract violation.

**Contract lines:** none — see the preceding entry; contract.md does not address
fixture documentation.

### `script-default-source-success-vs-failure-family`

**Rule:** Whether three DFT04 variants that restate provider modes already
covered by the sibling provider-execution-error-family should be deleted as
duplicates

**Author's position:** Keep all seven variants. The catalogue row this family is
graded against enumerates nonzero exit and timeout by name (scenarios.md:130);
the sibling family is graded against a different row over a candidate with no
record awaiting a fill. Deleting the three would leave two of this row's named
modes resting only on a fixture that does not assert them, so the coverage unit
(the catalogue row) would regress even though no provider mode disappears from
the corpus. Deletion is also irreversible here (this agent may not run git),
while the cost of keeping them is three small files. The overlap is now stated
plainly in the family case.md and the dispute is recorded there under
'Disputed:'.

**Verifier's position:** Collapse provider-nonzero-exit-refuses,
provider-timeout-refuses and provider-malformed-output-refuses: the union across
both families still covers nonzero exit, timeout, malformed JSON, non-object
JSON, empty stdout, missing identity, incomplete snapshot and valid-empty
snapshot, and the only DFT04-specific content in them (a created record awaiting
a default still gets its fill while acquisition fails) can be carried by one
remaining variant.

**Contract lines:** contract.md:500-531 and contract.md:804-818 govern provider
acquisition and the closed code set; nothing in contract.md, model.md or
decisions.md addresses redundancy between fixtures, so the contract does not
decide it. scenarios.md:130 is the catalogue row that names the modes.

### `corpus-input-file-resolution`

**Rule:** How a fixture nested below the packet resolves invocation.json and the
relative paths inside a binding's command (contract.md:515-517 fixes only 'the
packet directory for this sample')

**Author's position:** Per-fixture inheritance with REPLACEMENT: the invocation
configuration is the nearest invocation.json searching fixture directory, then
enclosing family directories, then the packet directory; it replaces the
packet's rather than merging, and relative paths in its command resolve from the
directory that supplied it. Evidence: 42 fixtures ship neither file and expect
baseline-I0-open (inheritance); 25 ship both and expect their own identity (cwd
= fixture directory); the six note-state-field members ship neither and inherit
their FAMILY's `{"inputs": {}}`, which is the enclosing-directory step of the
same search and is why envelope baseline is null there; 0 ship baseline.json
without invocation.json, so no per-file fallback is ever exercised; and
missing-before-or-baseline-acquisition-cannot-evaluate ships {"inputs": {}}
expecting the missing-binding execution error of contract.md:525, which a
merging harness could never produce. Written up in backend/fixtures/README.md.

**Verifier's position:** Per-FILE fallback to the packet is required — each
named relative file resolves in the fixture directory first and the packet
directory second — argued from the claim that
warm-cache-recomputes-on-metadata-policy-baseline-change ships baseline.json
with no invocation.json. That fixture does ship an invocation.json, so the
premise does not hold; the verifier is right that the tree documents no rule at
all, and that without one two reasonable harnesses disagree on most of the
corpus.

**Contract lines:** contract.md:515-517 (relative paths resolve from the
invocation working directory, the packet directory for this sample),
contract.md:519-525 (invoke once; a missing command binding is an execution
error). The contract does not extend either to a nested fixture tree.
