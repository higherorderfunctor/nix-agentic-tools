Situation: the drawn base corpus — open root F0 with children F1 and closed F2,
F2 owning open F2a and F2b, second root G0 with G1, isolated I0, BAZ Z0, no R
occurrences and no BAR records — evaluated against baseline S0
(`baseline-empty`), a successful complete capture with an empty protected set.
Change: create BAR M owning `P parent F0` at occurrenceIndex 0 and `Q child F2`
at occurrenceIndex 1; `created` is `["M"]`. BAR declares only UID, so creation
defaulting materializes nothing. Expected: `one-P` satisfied with count 1 and
`one-Q` satisfied with count 1, so `endpoint-path` is evaluated; `P.target-type`
and `Q.target-type` satisfied because F0 and F2 both resolve to FOO;
`endpoint-path` satisfied on subject M, origin F0, target F2, `path` and
`walkedPath` both `["F0","F2"]`, `boundary: null` — F0 is open so the one
downward departure is permitted, and closed F2 is only visited; `H-forest`
satisfied since M is not an H vertex; `native-dag` satisfied because
`F0 -> M -> F2` runs parallel to `F0 -> F2` and closes no cycle;
`baseline-preserved` satisfied with `differences: []`. Envelope satisfied. Why:
"Only the final batch state is evaluated; private intermediate states do not
decide validity." (contract.md:449) and "The final endpoint needs no expansion."
(contract.md:313) Catalogue divergence: the row's "one ordered invocation, then
P and Q" narrative and its "captured before" input have no representation here —
`candidate.json` carries one final graph and `bundle.inputs` declares only the
baseline — so the fixture asserts the final state alone, which is what the
contract evaluates.

provenance: B01
