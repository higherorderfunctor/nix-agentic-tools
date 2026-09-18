- Situation: base forest already holds the disconnected roots `F0` and `G0` plus
  isolated `I0`. Change: create FOO `I1`, explicit `FLAG` false, no relations;
  `created` is `["I1"]`.
- Expected H-forest satisfied with `violations: []`: `I1` is an isolated
  selected record and therefore a vertex, and the view admits a further
  disconnected root. one-H-parent satisfied with a tenth finding, `I1` count 0.
  native-dag satisfied: no edge is added. `FLAG` is present on `I1`, so creation
  defaulting never runs: "Never overwrite a present list" (contract.md:890).
- Why: "Isolated selected records are vertices." (contract.md:296);
  "`connected: false` permits multiple roots." (contract.md:298)
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G04
