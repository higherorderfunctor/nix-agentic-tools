- Situation: two independent H trees, one rooted at F0 and one at G0, with an
  empty complete baseline that protects nothing (contract.md:526).
- Change: re-point F1's H (index 0) at the absent GHOST-H, and give G1 a second
  occurrence, an R (index 1), targeting the absent GHOST-R.
- Expected envelope findings: two errors with code unresolved-target, in
  candidate record order, so F1's H is /findings/0 and G1's R is /findings/1
  (contract.md:460, contract.md:580).
- Expected H-forest: blocked with causes ["/findings/0"] and nothing else. H is
  the view's own edges relation, so the forest needs F1's H resolved; it never
  reads G1's R, and a dangling R on its own leaves H-forest satisfied
  (contract.md:296, backend/fixtures/deleted-target-leaves-dangling-reference).
  Only a resolution a rule needs may be its cause (contract.md:462).
- Expected native-dag: blocked with BOTH causes, because that graph is built
  from every role and every element (contract.md:243).
- Expected H.target-type: blocked with causes ["/findings/0"]; G1's own H
  resolves and is satisfied. one-H-parent satisfied throughout, because counts
  do not need target resolution (contract.md:465).
- Expected R.all and endpoint-path: blocked on the H-forest prerequisite at
  whole-rule granularity, endpoint-path with no subjects at all
  (contract.md:749, contract.md:654).
- Why: this is the difference between citing the findings a rule needs and
  citing every unresolved-target finding in the envelope. The two readings agree
  whenever exactly one occurrence dangles, and disagree here.
- provenance: none
