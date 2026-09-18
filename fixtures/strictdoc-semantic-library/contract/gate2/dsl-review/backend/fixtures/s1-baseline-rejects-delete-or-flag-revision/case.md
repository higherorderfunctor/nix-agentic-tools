Situation: the drawn base corpus, evaluated against baseline S1
("baseline-I0-open"), a complete snapshot protecting the isolated FOO record I0
with FLAG ["false"] and no relations (contract.md:485-498). Change: two
INDEPENDENT candidates, one per subdirectory. i0-deletion removes I0 from
`records`; i0-flag-revision sets I0.FLAG to ["true"]. Both keep `created` empty
and leave every other record, uid and FLAG value identical. I0 owns no
occurrence and is no occurrence's target, so no path, forest or count verdict
moves in either variant. Expected (both): baseline-preserved is violated with
one model-level finding (uid null), code `difference`, evidence baseline
"baseline-I0-open" and exactly one difference identifying I0 — `existence` false
for the deletion, the FLAG field's presence/values object for the revision. The
other ten rules keep the base-sample results, except that one-H-parent and
H.target-type select eight FOO records instead of nine in the deletion variant.
Each envelope is violated. Why: "`existence: true` requires each baseline-listed
record to survive." (contract.md:344); "Compare every baseline-listed uid with
the final candidate; missing records and changed projected facts violate."
(contract.md:245); "Components are existence (Booleans), element (names), a
field ID (presence/value objects), or a relation ID" (contract.md:643-644).
Structure: the catalogue row recorded below carries two independent candidates
under one id, and one results envelope describes one candidate, so this row is a
family with one subdirectory per variant — the same shape
provider-execution-error-family uses.

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

provenance: B04
