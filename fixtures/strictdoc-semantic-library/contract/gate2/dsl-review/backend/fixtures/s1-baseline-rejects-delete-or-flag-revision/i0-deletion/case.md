Situation: the drawn base corpus, evaluated against baseline S1
(`baseline-I0-open`) — a complete snapshot protecting the isolated FOO record I0
with `FLAG: ["false"]` and no relations. Change: I0 is absent from the
candidate's `records`; nothing else moves and `created` stays `[]`. I0 owns no
occurrence and is no occurrence's target, so only the FOO record set changes,
losing I0. Expected: `baseline-preserved` violated with one model-level finding,
code `difference`, `evidence.baseline: "baseline-I0-open"` and one difference
`{uid: "I0", component: "existence", before: true, after: false}`; the finding's
own `uid` stays null because the subject is the model. `one-H-parent` satisfied
over the eight surviving FOO records; `H.target-type`, `H-forest` and
`native-dag` satisfied; `R.all` and all four BAR rules vacuously satisfied with
`findings: []`. Envelope violated. Why: "`existence: true` requires each
baseline-listed record to survive." (contract.md:344), the preserve algorithm
"Compare every baseline-listed uid with the final candidate; missing records and
changed projected facts violate." (contract.md:245), and "Components are
existence (Booleans), element (names), a field ID (presence/value objects), or a
relation ID" (contract.md:643). Reading taken: a deleted protected record yields
the existence difference only, not additional element, field and relation
differences, since the contract names "missing records" as one violation and the
record has no candidate side to compare. Note: the family case.md holds the
shared situation and the reason this catalogue row is split into two variant
directories.

provenance: B04
