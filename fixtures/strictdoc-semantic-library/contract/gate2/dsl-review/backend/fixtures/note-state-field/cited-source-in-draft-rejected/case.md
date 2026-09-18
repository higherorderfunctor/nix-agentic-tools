Situation: `report` is final and cites `outline`, which is still a draft.

Change: relative to the accepting reading, the cited source's STATE is draft
instead of final.

Expected: `SOURCE.field-value` violated. A present UNLISTED value on an edge
target violates rather than blocks. The finding's uid is the OWNER `report`, its
occurrence names the target `outline` at occurrenceIndex 0, and its evidence
`record` is the TARGET `outline` - which is what lets the leaf read one record
while the finding identifies another.

Expected: `retired-notes-cite-a-source` satisfied. Neither record is retired, so
both filter findings are violated, both records are excluded, and the entry is
satisfied with two filter findings and no check findings.

Expected: `drafts-cite-nothing` satisfied. On `outline` the field-value leaf is
SATISFIED - its STATE really is draft - so the `not` above it is violated, and
the entry holds only because `outline`'s SOURCE count of zero satisfies the
other branch of the `any`.

Why: a present value outside `values` is violated, never blocked; `uid` is the
owner for an occurrence subject (contract.md:665-667).

provenance: field-value leaf design, gate 2 DSL review
