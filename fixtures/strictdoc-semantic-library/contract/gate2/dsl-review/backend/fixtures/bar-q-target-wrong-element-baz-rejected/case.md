- Situation: base forest plus the drawn resolvable BAZ `Z0`, which sits outside
  the `H` hierarchy (contract.md:420-424).
- Change: create BAR `M` with `Parent P -> F0` (index 0) and `Child Q -> Z0`
  (index 1); `created` is `["M"]`.
- Expected Q.target-type violated on `M` index 1, expected FOO and actual BAZ.
  The check is a standalone leaf with no sibling, so the rule entry is
  `violated`, not blocked — this is the corpus's only rule-level target-type
  violation. P.target-type satisfied. one-P and one-Q satisfied with count 1
  each: "Count checks need occurrence lists but do not need resolved endpoints."
  (contract.md:259)
- Expected endpoint-path blocked with code `input`: its three prerequisites
  (one-P, one-Q, H-forest) all hold, so the leaf is evaluated, and then the
  resolved lower endpoint `Z0` is no `H` vertex. Evidence keeps the indexed
  `upper`/`lower` lists with empty `path` and `walkedPath`; `causes` is empty,
  since the block is neither a prerequisite nor an external input failure.
- Expected native-dag satisfied: `P` yields `F0 -> M` and `Q` yields `M -> Z0`,
  closing no cycle. H-forest satisfied: the view selects FOO records and FOO's
  `H` relation only, so neither `M` nor `Z0` is a vertex. Envelope blocked,
  because blocked outranks the violation (contract.md:663-664).
- Why: "Both path endpoints must resolve to hierarchy vertices; otherwise the
  path occurrence is blocked" (contract.md:301-302), and code `input` "includes
  invalid needed FLAG and resolved non-view path endpoints" (contract.md:814).
  The restriction under test is "BAR `P` and `Q` target FOO" (model.md:114,
  decisions.md:15).
- No catalogue row: the structural-graph table carries no BAR endpoint-element
  negative, and the FOO `R` wrong-target analogue can only report blocked,
  because its sibling visible-target leaf dominates aggregation
  (contract.md:226-227). Before this fixture, no results file in the corpus
  drove H.target-type, P.target-type or Q.target-type off satisfied, so a
  backend that accepted a BAZ target for BAR `P` or `Q` passed every fixture.
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: none — negative control for D02 (decisions.md:15), paired with the
  FOO R wrong-target fixture.
