Situation: the drawn base corpus already carrying a valid BAR M with
`P parent F0` and `Q child F2`, evaluated against baseline S0
(`baseline-empty`). M is an old record, so `created` is `[]`. Change: M's Q
occurrence targets F1 instead of F2 in the final candidate. The batch that
removed `Q child F2` and added `Q child F1` is not represented, and neither is
the order of those two steps. Expected: `one-Q` satisfied with count 1 — the
transient zero-Q and two-Q states are not inputs; `one-P` satisfied with count
1; `P.target-type` and `Q.target-type` satisfied because F0 and F1 both resolve
to FOO; `endpoint-path` satisfied on subject M, origin F0, target F1, `path` and
`walkedPath` both `["F0","F1"]`, `boundary: null`, because F0 is open and F1 is
the final endpoint; `H-forest`, `native-dag` (`F0 -> M -> F1` runs parallel to
`F0 -> F1` and closes no cycle) and `baseline-preserved` satisfied. Envelope
satisfied. Why: "Only the final batch state is evaluated; private intermediate
states do not decide validity." (contract.md:449) and "Count all matching owned
occurrences, including duplicates and zero, then compare." (contract.md:240)
Catalogue divergence: the row's "reverse endpoint-operation order has same
outcome" claim is unrepresentable, because the candidate declares no operation
order; this fixture pins the single final state that both orders reach.

provenance: B03
