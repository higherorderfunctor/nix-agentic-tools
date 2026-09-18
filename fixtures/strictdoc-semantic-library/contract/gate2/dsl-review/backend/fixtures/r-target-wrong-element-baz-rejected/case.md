- Situation: base forest plus resolvable, natively eligible BAZ `Z0`, outside
  the `H` hierarchy. Change: add `F1a Parent R -> Z0` at occurrence index 1.
- Expected R.all blocked: `/check/all/0` target-type violated, expected FOO and
  actual BAZ; `/check/all/1` blocked with code `input` because `Z0` is no `H`
  vertex. Both findings are kept, and `causes` is empty: `Z0` resolves.
- Contract over catalogue: the catalogue calls the wrong-target case a
  target-type REJECTION, but no-short-circuit evaluation makes the expression,
  the entry and the envelope `blocked`. The candidate is rejected either way.
- Why: "any blocked child makes the expression blocked" (contract.md:227); "Both
  path endpoints must resolve to hierarchy vertices" (contract.md:301); code
  `input` covers "resolved non-view path endpoints" (contract.md:814)
- Control pairing: a standalone rule-level `violated` for a wrong endpoint
  element is carried by `bar-q-target-wrong-element-baz-rejected`, because
  R.all's sibling visible-target leaf always blocks here and dominates
  aggregation (contract.md:226-227).
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G02
