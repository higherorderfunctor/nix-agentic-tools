- Situation: base forest plus a complete pre-existing BAR `M` owning
  `Parent P -> F0` (index 0) and `Child Q -> F2` (index 1); closed `F2` already
  owns its single `Parent H -> F0`.
- Change: none. The row revalidates `F2`'s hierarchy against an unchanged final
  state, so `M` is an old record and `created` is `[]` (scenarios.md:42; "an old
  record has its uid outside created", contract.md:883-884).
- Expected one-H-parent satisfied: `F2`'s evidence still lists exactly one
  occurrence, `H -> F0`, though `F2` now has native parents `F0` and `M`.
  H-forest satisfied, `violations: []`: view `H` selects only FOO's `H`
  relation, so `M` adds no `H` ancestry. one-P/one-Q count 1, P/Q.target-type
  actual FOO, endpoint-path satisfied on walk `F0,F2`, boundary null.
- Why: "A BAR remains a record between its endpoints in the native graph."
  (contract.md:260), and view `H` selects only its own `edges` relation
  (contract.md:295)
- Pair: `bar-ownership-f0-m-f2-no-reverse-edge-accepted` carries the same final
  graph with `M` created in the batch (`created: ["M"]`). Only `FOO.FLAG` has a
  creation default, and only the final batch state is evaluated, so the two
  verdicts are necessarily identical; the pair asserts that newness alone does
  not move the verdict (contract.md:449-450, contract.md:888-891). The two
  candidates were byte-identical before this split.
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G08
