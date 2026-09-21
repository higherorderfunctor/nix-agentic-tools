- Situation: drawn forest; candidate bytes are fixed across this pair.
- Change: set F1.FLAG true. This fixture ships a wider baseline protecting F1
  (FLAG false) and I0, plus its own `cat baseline.json` binding so the wider
  snapshot is the one captured (contract.md:511-516).
- Expected baseline-preserved: violated, code difference, one difference on F1's
  FLAG, before present ["false"], after present ["true"].
- Expected others satisfied; envelope violated, baseline identity recorded.
- Why: "changed projected facts violate" (contract.md:245).
- Pair: identical-candidate-accepted-under-narrow-baseline is satisfied on the
  same bytes, so bytes alone cannot key a verdict.
- Mixed: no cache is observable here; warming, dependency-precise invalidation
  and cold/warm agreement are outside this stateless contract.
- provenance: A08
