Situation: the drawn base corpus with no BAR records, evaluated against baseline
S0 (`baseline-empty`). Change: create BAR M owning only `P parent F0` at
occurrenceIndex 0 and no Q occurrence at all; `created` is `["M"]`. Expected:
`one-P` satisfied with count 1; `one-Q` violated on subject M with
`occurrences: []`, `count: 0`, `compare: "eq"`, `value: 1`, because zero
occurrences are counted and compared rather than treated as absent;
`Q.target-type` satisfied vacuously with `findings: []` since its occurrence
selector is empty; `endpoint-path` blocked at whole-rule granularity, with one
non-leaf finding on M (predicatePath null, kind null, code `prerequisite`,
`evidence.requires` naming the failed rule) and entry
`causes: ["model:reference/element:BAR/check:one-Q"]`; `H.target-type`,
`one-H-parent`, `H-forest`, `native-dag` and `baseline-preserved` satisfied.
Envelope blocked. Why: "Count all matching owned occurrences, including
duplicates and zero, then compare." (contract.md:240); "A violated or blocked
required rule blocks the dependent rule for every subject: this is whole-rule
granularity." (contract.md:749); "Whole-rule blocking emits one blocked non-leaf
finding for every subject the selector would select BEFORE where is applied"
(contract.md:651); "The envelope status is the worst across its findings and
rule entries: error > blocked > violated > satisfied" (contract.md:663).
Catalogue divergence: the row calls this "Reject exact-one Q cardinality", which
is the `one-Q` verdict, but the envelope status is `blocked` rather than
`violated` because the blocked dependent rule dominates aggregation. Both are
rejections.

provenance: B02
