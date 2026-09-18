- Situation: base forest; endpoints `F0` and `F2` exist, `F2` closed.
- Change: create BAR `M`, `Parent P -> F0` (index 0), `Child Q -> F2` (index 1);
  `created` is `["M"]`, so `M` is a new record (contract.md:883-884).
- Expected ownership: both occurrences live in `M`'s own `relations`, so `P`
  yields `F0 -> M` and `Q` yields `M -> F2`, never `F0 -> F2`. No reverse edge:
  `P_back`/`Q_back` materialize nothing, so one-P and one-Q count 1 from `M`
  alone, H.target-type still emits six findings, and one-H-parent reports `F0`
  count 0, `F2` count 1. endpoint-path satisfied: origin `F0`, target `F2`.
- Why: "a parent occurrence is an edge target->owner, a child occurrence
  owner->target" (contract.md:253); "A reverse-role label does not manufacture a
  reciprocal authored relation." (model.md:111)
- Pair: `bar-bridge-no-h-ancestry-accepted` carries the same final graph with
  `M` already present and `created: []`. Only `FOO.FLAG` has a creation default,
  and only the final batch state is evaluated, so the two verdicts are
  necessarily identical; the pair asserts that newness alone does not move the
  verdict (contract.md:449-450, contract.md:888-891).
- Inputs: the fixture ships its own `invocation.json` and `baseline.json`; the
  snapshot is the catalogue default, a successful complete empty one with
  identity `baseline-empty` (scenarios.md:12, scenarios.md:63-64). Provider
  paths resolve from the fixture directory, so every expectation here is
  reachable without inheriting a packet file (contract.md:515-516). An empty
  complete snapshot protects nothing, so baseline-preserved is satisfied with
  `differences: []` (contract.md:526-528).
- provenance: G09
