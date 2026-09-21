Situation: `report` is a draft and cites `outline`, which is final.

Change: relative to the accepting reading, the citing note's STATE is draft
instead of retired.

Expected: `drafts-cite-nothing` violated on `report`. Its field-value leaf is
SATISFIED - the STATE is draft - so the `not` above it is violated, its sibling
SOURCE count of one violates `eq` 0, and an `any` with no satisfied child is
violated. This is the member that pins a satisfied leaf finding inside a
violated expression.

Expected: `drafts-cite-nothing` still satisfied on `outline`, whose final STATE
violates the field-value leaf, satisfies the `not` and leaves the entry violated
only because of `report`.

Expected: `SOURCE.field-value` satisfied - the target is final - and
`retired-notes-cite-a-source` satisfied with both records excluded by a violated
filter finding.

Why: evaluate all children without short-circuiting, then apply the operator;
leaf findings retain their own status, so a violated child can belong to a
satisfied expression and a satisfied child to a violated one
(contract.md:226-233).

provenance: field-value leaf design, gate 2 DSL review
