Situation: the drawn base corpus, evaluated against baseline S0
("baseline-empty") — a successfully captured complete snapshot whose `records`
list is empty and which therefore protects nothing (contract.md:526-528).
Change: the same two INDEPENDENT candidates as
s1-baseline-rejects-delete-or-flag-revision, byte for byte: i0-deletion removes
I0, i0-flag-revision sets I0.FLAG to ["true"]. Only the captured baseline
differs. Expected (both): baseline-preserved is satisfied with one model-level
finding (uid null), code `preserve`, evidence baseline "baseline-empty" and
`differences: []`; acquisition succeeded and an empty protected set is valid
input, never an error. All other rules match the base sample, with eight FOO
records instead of nine in the deletion variant. Each envelope is satisfied —
the very edits S1 rejects are branch-only changes under S0. Why: an empty
complete snapshot "is valid and protects nothing" (contract.md:526-528);
"`required: true` requires a successful capture, and `complete: true` requires a
complete protected set, not a nonempty set." (contract.md:497-498); "A candidate
record absent from the baseline is unprotected by preserve."
(contract.md:355-356). Mixed scope: the row also claims a separately submitted,
unrelated invalid candidate still rejects under the same S0. That
non-interference property spans two evaluations and cannot be asserted in one
envelope, so no fixture here covers it. That invalid candidate is itself covered
by r-past-closed-boundary-rejected, whose envelope captures the S1 identity
`baseline-I0-open`, so not even pairing the two fixtures observes the claim
under S0. Structure: the catalogue row recorded below carries two independent
candidates under one id, so it is a family with one subdirectory per variant.

Disputed: whether this family-level case.md may carry a `provenance:` line at
all, since the two variant case.md files each carry one and that puts the same
case id on three provenance lines inside one family. The contract governs
evaluator semantics and says nothing about case.md provenance placement, so
nothing decides it. Kept as authored, on two grounds: every file still carries
exactly one provenance line and names no case id in its prose, and every other
family in this corpus does the same — provider-execution-error-family/case.md,
chain-depth-boundary-negative-family/case.md,
visibility-truth-table-family/case.md,
script-default-source-success-vs-failure-family/case.md and
nested-boundary-earlier-f2-rejected/case.md each carry a family-level provenance
line beside their variants'.

provenance: B05
