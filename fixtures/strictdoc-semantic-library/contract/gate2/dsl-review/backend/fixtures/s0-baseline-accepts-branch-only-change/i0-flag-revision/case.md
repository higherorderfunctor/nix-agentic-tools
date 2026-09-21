Situation: the drawn base corpus, evaluated against baseline S0
(`baseline-empty`), a successful complete capture with an empty protected set.
Change: I0's `FLAG` becomes `["true"]`; all other records are identical and
`created` stays `[]`. This candidate is byte-identical to the one under
s1-baseline-rejects-delete-or-flag-revision/i0-flag-revision; only the captured
baseline differs. Expected: `baseline-preserved` satisfied with one model-level
finding, code `preserve`, `evidence.baseline: "baseline-empty"` and
`differences: []`; I0 is a candidate record absent from the protected set and is
therefore unprotected. `one-H-parent` still reports count 0 for I0;
`H.target-type`, `H-forest` and `native-dag` satisfied; `R.all` and the four BAR
rules vacuously satisfied with `findings: []`. Envelope satisfied — the same
edit S1 rejects is a branch-only change under S0, and the verdict is read from
this evaluation's captured identity rather than any earlier S1 result. Why: "An
empty complete snapshot ... is valid and protects nothing." (contract.md:526);
"A candidate record absent from the baseline is unprotected by preserve."
(contract.md:355); "Capture one identified immutable snapshot per evaluation and
reuse it throughout" (contract.md:529). Mixed scope: the row's cross-candidate
claim — an unrelated invalid candidate must still reject under the same S0 —
spans two evaluations and cannot be asserted in one results envelope, so this
fixture does not cover it. Note: the family case.md holds the shared situation
and the non-interference obligation this fixture does not cover.

provenance: B05
