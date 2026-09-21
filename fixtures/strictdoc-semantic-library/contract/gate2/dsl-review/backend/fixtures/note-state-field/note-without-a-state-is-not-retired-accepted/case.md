Situation: `report` carries no STATE key at all and cites nothing.

Change: STATE is absent rather than retired, which is legal because STATE is
optional.

Expected: `retired-notes-cite-a-source` satisfied with ONE violated finding. The
filter leaf reads an absent field against `absentSatisfies: false`, so it is
violated with `present: false` and `values: []`, the record is excluded, and no
check finding is emitted. Every selected subject is excluded, so the entry is
satisfied while its only finding is violated.

Expected: `drafts-cite-nothing` satisfied. The same absence violates the
field-value leaf on draft, the `not` above it is satisfied, and the count of
zero satisfies `eq` 0 as well.

Expected: `SOURCE.field-value` satisfied with `findings: []`; there is no SOURCE
occurrence.

Why: absence is violated unless the leaf says otherwise, which is what the
`absentSatisfies` flag exists to say; an absent OPTIONAL field is not an
envelope input error, so nothing blocks (contract.md:298-302). The entry status
reading is contract.md:661-662 with contract.md:647-648.

Disputed: `results.json` exercises no `where` (contract.md:768-773), so the
all-excluded reading above is stated here first rather than inherited.

provenance: field-value leaf design, gate 2 DSL review
