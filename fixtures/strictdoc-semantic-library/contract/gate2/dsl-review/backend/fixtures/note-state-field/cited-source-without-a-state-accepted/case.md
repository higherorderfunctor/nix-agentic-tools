Situation: `report` is final and cites `outline`, which carries no STATE key.

Change: relative to `cited-source-in-draft-rejected`, the cited source's STATE
key is absent rather than draft.

Expected: `SOURCE.field-value` satisfied. The edge leaf carries
`absentSatisfies: true`, so the target's absence satisfies it, and its evidence
records what was read: `present: false` with `values: []`.

Expected: `retired-notes-cite-a-source` satisfied. Both filter findings are
violated - `report` is final, `outline` has no STATE - so both records are
excluded and the entry emits two filter findings and no check findings.

Expected: `drafts-cite-nothing` satisfied for both records, each through its
negated field-value leaf.

Why: the same absence that the record-scope filter VIOLATES (no
`absentSatisfies`) the edge leaf SATISFIES, which is the whole point of putting
the flag on the leaf rather than deriving it: absence has no envelope finding
behind it, so only the author can say what it means.

provenance: field-value leaf design, gate 2 DSL review
