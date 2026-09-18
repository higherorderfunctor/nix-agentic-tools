- Situation: base forest plus the drawn resolvable BAZ `Z0`
  (contract.md:420-424).
- Change: create FOO `J0` with explicit `FLAG` false and one `Parent H -> Z0` at
  occurrence index 0; `created` is `["J0"]`.
- Expected H.target-type violated on `J0` index 0, expected FOO and actual BAZ,
  with the six base occurrences still satisfied in record order. The rule is a
  standalone leaf, so its entry is `violated`.
- Expected H-forest violated, code `forest-validity`: `Z0` resolves but is not a
  FOO vertex, so the violation object is the indexed offending occurrence with
  `owner`, `expectedElement` and `actualElement` — the third violation shape of
  contract.md:637, which no other fixture in the corpus exercises.
- Expected R.all and endpoint-path blocked with cause `H-forest` and
  `findings: []`: each selects zero subjects, and "With no such subjects, entry
  status and causes still record blocking." (contract.md:654)
- Expected one-H-parent satisfied with a tenth finding, `J0` count 1: the count
  leaf never reads the target's element. native-dag satisfied: the occurrence
  contributes the edge `Z0 -> J0`, which closes no cycle. Envelope blocked,
  because blocked outranks the two violations (contract.md:663-664).
- Why: "A resolved forest endpoint outside the selected vertex element violates
  `forest-validity`." (contract.md:258); "wrong element is violated, unresolved
  uid blocked" (contract.md:239). The restriction under test is "FOO `H` and `R`
  target FOO" (model.md:114, decisions.md:15).
- No catalogue row: the structural-graph table has no `H` target-element
  negative, so before this fixture a backend that reported H.target-type
  satisfied on a BAZ target conformed to every results file in the corpus.
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: none — negative control for D02 (decisions.md:15), the `H` half of
  the restriction the R wrong-target fixture covers.
