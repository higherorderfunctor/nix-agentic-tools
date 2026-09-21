- Situation: drawn forest, no BAR record (contract.md:430).
- Change: create BAR M owning one P to F0 and zero Q; created ["M"].
- Expected one-Q: violated, count 0 against compare eq value 1, occurrences [].
- Expected Q.target-type: satisfied vacuously, zero selected occurrences.
- Expected endpoint-path: blocked for M, code prerequisite, requires and causes
  naming one-Q, no leaf evaluated. Envelope blocked (contract.md:663).
- Why: "A violated or blocked required rule blocks the dependent rule for every
  subject: this is whole-rule granularity." (contract.md:749)
- Contract over catalogue: the row says singleton blocks, but singleton is a
  leaf code and "for whole-rule blocking no leaves are evaluated" (820).
- Mixed: this row's other three sub-cases throw during lowering.
- provenance: A10
