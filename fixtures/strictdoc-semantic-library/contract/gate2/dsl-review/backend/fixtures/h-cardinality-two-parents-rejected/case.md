- Situation: base forest; `F1a` already owns `Parent H -> F1` at index 0.
  Change: add a second `F1a Parent H -> F0` at occurrence index 1.
- Expected one-H-parent violated on `F1a`: count 2 against `lte` 1, both indexed
  occurrences (`F1` then `F0`) in evidence. H-forest violated: `F1a` has two
  incoming selected occurrences, one `violations` entry with `uid` and
  `parents`. native-dag satisfied: two distinct parents are no cycle. R.all and
  endpoint-path blocked, cause `H-forest`, `findings: []` — each selects zero
  subjects. Envelope blocked: blocked outranks the two violations.
- Why: "two selected parent occurrences violate forest cardinality"
  (contract.md:255); "A violated or blocked required rule blocks the dependent
  rule for every subject" (contract.md:750)
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G05
