Situation: `report` is retired and cites `outline`, which is final.

Change: none; this is the family's accepting base reading, where the filter
includes a record and the check it guards holds.

Expected: `SOURCE.field-value` satisfied. The one SOURCE occurrence reads the
TARGET's STATE, finds final in `["final","retired"]`, and its evidence names
`record: "outline"` while the finding's own uid stays the owner `report`.

Expected: `retired-notes-cite-a-source` satisfied. The filter finding on
`report` is satisfied with `values: ["retired"]`, so the record is included and
its SOURCE count of one satisfies `gte` 1. The filter finding on `outline` is
violated with `values: ["final"]`, so that record is excluded and emits no check
finding.

Expected: `drafts-cite-nothing` satisfied for both records. Each field-value
leaf is VIOLATED on its own - neither STATE is draft - while the `not` above it
is satisfied, so the `any` holds even though `report`'s sibling SOURCE count of
one violates `eq` 0.

Why: a present listed value is satisfied; a false `where` emits filter findings
but no check findings (contract.md:661-662); a leaf finding retains its own
status even when the `any` or `not` above it has a different truth value
(contract.md:229-231).

provenance: field-value leaf design, gate 2 DSL review
