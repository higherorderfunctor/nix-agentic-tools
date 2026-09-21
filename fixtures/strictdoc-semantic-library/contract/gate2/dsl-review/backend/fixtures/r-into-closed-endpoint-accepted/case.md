- Situation: base forest; `F1a` sits under `F1` under `F0`, and closed `F2`
  (`FLAG` true) is `F1`'s sibling under that same root.
- Change: add `F1a Parent R -> F2` as `F1a` occurrence index 1.
- Expected R.all satisfied: `/check/all/0` target-type FOO; `/check/all/1`
  visits closed `F2` along `F1a,F1,F0,F2`, boundary null. H-forest and
  native-dag satisfied: view `H` never selects `R`, and `F2 -> F1a` closes no
  cycle. one-H-parent satisfied: an `R` occurrence is not counted.
- Why: "`visit: always` permits arrival at a closed node, including the
  endpoint." (contract.md:306); "The final endpoint needs no expansion."
  (contract.md:313)
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G01
