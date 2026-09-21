- Situation: base forest plus existing BAZ `Z0`, owning no relations. Change:
  create FOO `A` (`Parent H -> B`) and FOO `B`, then give `Z0` `Parent R -> A`
  (index 0) and `Child Q -> B` (index 1); `created` is `["A","B"]`.
- Expected native-dag violated, code `cycle`: witness `A,Z0,B,A` from edges
  `A -> Z0` (R, owner Z0, index 0), `Z0 -> B` (Q, owner Z0, index 1), `B -> A`
  (H, owner A, index 0). H-forest satisfied: view `H` carries only `B -> A`, so
  no one-role or one-element projection shows the cycle. one-H-parent satisfied
  over eleven FOO records; R.all and endpoint-path satisfied with
  `findings: []`.
- Contract over catalogue: the catalogue calls `Z0` fresh, but the drawn base
  supplies it, so only `A` and `B` appear in `created`.
- Why: edges span "every role and element" (contract.md:243)
- Walk start over catalogue prose: scenarios.md:41 names the cycle
  `B -> A -> Z0 -> B`, which is the order its own prose introduces the three
  occurrences rather than a stated rule for where a witness walk starts. The
  contract fixes the witness shape (contract.md:636, contract.md:616-618) and
  never fixes the walk start, so the walk begins at the cycle vertex earliest in
  candidate record order, which is the contract's only stated ordering principle
  (contract.md:580-581). Here that is `A` at record position 9, ahead of `B` and
  `Z0`. The same rule reproduces the `F0 -> F1 -> F1a -> F0` witness of
  scenarios.md:40 and all three native-cycle rows of the visibility truth table,
  while a rule starting at `B` reproduces none of them.
- Disputed: the walk start is unspecified. This corpus cannot separate earliest
  candidate record order from smallest uid, because the two agree on every
  recorded cycle. The owner key inside an indexed edge is unspecified too; this
  fixture spells it `owner`, as the other graph witnesses in the corpus do.
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G07
