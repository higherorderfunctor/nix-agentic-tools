- Situation: F2a holds R to F1a, visible while F1 is open (decisions.md:46).
- Change: set F1.FLAG true only; the R occurrence is left untouched.
- Expected R.all: violated; /check/all/0 target-type satisfied, /check/all/1
  visible-target violated, code closed-boundary, boundary F1, path F2a F2 F0 F1
  F1a, walkedPath F2a F2 F0 F1.
- Expected every other rule satisfied; envelope violated.
- Why: "A closed departure that excludes the origin violates the path rule and
  is its boundary." (contract.md:311); expand policy at contract.md:308.
- Paired repair: close-boundary-with-repaired-reference-in-same-batch.
- provenance: A02
