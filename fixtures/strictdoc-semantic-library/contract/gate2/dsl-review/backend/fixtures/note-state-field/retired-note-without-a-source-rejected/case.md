Situation: `report` is retired and cites nothing. There is no second record.

Change: the SOURCE occurrence of the accepting reading is removed, and with it
the `outline` record.

Expected: `retired-notes-cite-a-source` violated. The filter finding on `report`
is satisfied, so the record is included, and its SOURCE count of zero violates
`gte` 1. That puts a SATISFIED filter leaf and a VIOLATED check leaf in one
entry, which is what this member pins.

Expected: `SOURCE.field-value` satisfied with `findings: []`. The occurrences
selector yields no subject, and a rule over zero selected subjects is satisfied.

Expected: `drafts-cite-nothing` satisfied. The field-value leaf on `report` is
violated, the `not` above it is satisfied, and the sibling count of zero
satisfies `eq` 0.

Why: "a rule over zero selected subjects returns satisfied with findings: []"
(contract.md:647-648); the envelope status is the worst across its entries
(contract.md:719-720), so one violated rule rejects the candidate.

provenance: field-value leaf design, gate 2 DSL review
