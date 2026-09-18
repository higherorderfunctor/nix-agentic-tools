- Situation: F2a holds R to F1a, visible while F1 is open (decisions.md:46).
- Change: set F1.FLAG true and re-point that R from F1a to F1, one candidate.
- Expected R.all: satisfied; /check/all/0 target-type satisfied, /check/all/1
  visible-target satisfied, walked F2a F2 F0 F1, boundary null.
- Expected every other rule satisfied; envelope satisfied.
- Why: ascent is unrestricted and "The final endpoint needs no expansion."
  (contract.md:304, contract.md:313)
- Why one verdict: "Only the final batch state is evaluated" (contract.md:450)
- Paired refusal: close-boundary-leaves-reference-hidden.
- provenance: A02
