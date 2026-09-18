- Situation: base forest; BAZ `Z0` owns its own `Parent R`, sharing the role
  spelling `R` with FOO's restricted relation.
- Change: `Z0` owns `Parent R -> I0` at occurrence index 0.
- Expected native-dag satisfied: edge `I0 -> Z0` closes no cycle. R.all
  satisfied with `findings: []` — its selector is `(FOO, R, parent)`, so a
  BAZ-owned occurrence is never selected. one-H-parent and H-forest satisfied
  and unchanged: both see FOO only, and `I0` gains incoming connectivity, not an
  owned occurrence.
- Why: "a rule over zero selected subjects returns satisfied with
  `findings: []`" (contract.md:592); the count leaf reads only owned
  occurrences, "Count all matching owned occurrences, including duplicates and
  zero" (contract.md:240)
- Coverage note: under an I0-protecting snapshot this candidate would also
  exercise preserve's exclusion of incoming relations owned elsewhere
  (contract.md:353-354). The catalogue default is the empty snapshot, which
  makes preserve vacuous here, so that exclusion stays unobserved by this
  fixture.
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G03
