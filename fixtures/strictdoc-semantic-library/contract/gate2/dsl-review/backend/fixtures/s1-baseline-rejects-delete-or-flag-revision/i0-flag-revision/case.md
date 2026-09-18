Situation: the drawn base corpus, evaluated against baseline S1
(`baseline-I0-open`), protecting isolated FOO I0 with `FLAG: ["false"]`. Change:
I0's `FLAG` becomes `["true"]`; every other record, uid and FLAG value is
identical and `created` stays `[]`. I0 owns no occurrence and is no occurrence's
target, so its closed state reaches no path rule — this candidate has no R
occurrences and no BAR records. Expected: `baseline-preserved` violated with one
model-level finding, code `difference`, `evidence.baseline: "baseline-I0-open"`,
and one projected-field difference:
`component: "model:reference/element:FOO/field:FLAG"`,
`before: {present: true, values: ["false"]}`,
`after: {present: true, values: ["true"]}`. Every other rule matches the base
expectation: `H.target-type` and `one-H-parent` satisfied over all nine FOO
records — I0 still counts 0 H parents — plus `H-forest` and `native-dag`
satisfied and `R.all` and the four BAR rules vacuously satisfied. Envelope
violated. Why: "Compare present field lists exactly as native strings, without
defaulting or semantic coercion." (contract.md:347), the preserve algorithm at
contract.md:245, and "Presence differences use objects with `present` and
`values`." (contract.md:638). Note: the family case.md holds the shared
situation and the reason this catalogue row is split into two variant
directories.

provenance: B04
