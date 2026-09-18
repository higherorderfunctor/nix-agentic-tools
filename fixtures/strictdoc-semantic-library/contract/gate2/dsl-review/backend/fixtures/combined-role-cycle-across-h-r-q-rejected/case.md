- Situation: base forest plus existing BAZ `Z0`, owning no relations. Change:
  create FOO `A` (`Parent H -> B`) and FOO `B`, then give `Z0` `Parent R -> A`
  (index 0) and `Child Q -> B` (index 1); `created` is `["A","B"]`.
- Expected native-dag violated, code `cycle`: witness `B,A,Z0,B` from edges
  `B -> A` (H, owner A), `A -> Z0` (R, owner Z0), `Z0 -> B` (Q, owner Z0).
  H-forest satisfied: view `H` carries only `B -> A`, so no one-role or
  one-element projection shows the cycle. one-H-parent satisfied over eleven FOO
  records; R.all and endpoint-path satisfied with `findings: []`.
- Contract over catalogue: the catalogue calls `Z0` fresh, but the drawn base
  supplies it, so only `A` and `B` appear in `created`.
- Why: edges span "every role and element" (contract.md:243)
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G07
