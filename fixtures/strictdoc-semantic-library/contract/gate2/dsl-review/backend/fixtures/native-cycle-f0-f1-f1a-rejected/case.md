- Situation: base forest; the chain `F0 -> F1 -> F1a` exists, authored on each
  child as `Parent H`. Change: add `F0 Parent H -> F1a` at `F0` index 0.
- Expected native-dag violated, code `cycle`: witness `F0,F1,F1a,F0` with its
  three indexed owning occurrences in walk order. H-forest violated on
  acyclicity with the same witness; every vertex still has at most one incoming
  occurrence. one-H-parent satisfied: `F0` now counts exactly one `H` parent.
  H.target-type satisfied with a seventh finding, `F0` index 0. R.all and
  endpoint-path blocked with cause `H-forest`. Envelope blocked.
- Why: "any directed cycle, including a self-loop, violates" (contract.md:243),
  built by "a parent occurrence is an edge target->owner" (contract.md:253)
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G06
