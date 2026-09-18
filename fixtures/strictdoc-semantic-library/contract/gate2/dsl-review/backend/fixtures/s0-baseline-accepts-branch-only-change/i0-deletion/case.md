Situation: the drawn base corpus, evaluated against baseline S0
(`baseline-empty`) — a successfully captured complete snapshot whose `records`
list is empty and which therefore protects nothing. Change: I0 is absent from
the candidate's `records`; `created` stays `[]`. This candidate is
byte-identical to the one under
s1-baseline-rejects-delete-or-flag-revision/i0-deletion; only the captured
baseline differs. Expected: `baseline-preserved` satisfied with one model-level
finding, code `preserve`, `evidence.baseline: "baseline-empty"` and
`differences: []` — acquisition succeeded and an empty protected set is valid
input, never an error. `one-H-parent` satisfied over the eight surviving FOO
records; `H.target-type`, `H-forest` and `native-dag` satisfied; `R.all` and the
four BAR rules vacuously satisfied. Envelope satisfied. Why: "An empty complete
snapshot ... is valid and protects nothing." (contract.md:526) and
"`required: true` requires a successful capture, and `complete: true` requires a
complete protected set, not a nonempty set." (contract.md:497) Mixed scope: the
row also claims a separately submitted, unrelated invalid candidate still
rejects under S0. That is a non-interference property across two evaluations,
and one envelope describes one candidate, so this fixture does not cover it.
Note: the family case.md holds the shared situation and the non-interference
obligation this fixture does not cover.

provenance: B05
