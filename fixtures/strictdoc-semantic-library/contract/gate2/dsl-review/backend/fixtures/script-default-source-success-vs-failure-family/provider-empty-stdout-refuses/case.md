Variant of this family; read ../case.md for the situation, the change and the
citations. Binding: ["sh","-c","true"] with timeoutSeconds 10 — a clean exit
that writes nothing, the catalogue's "no stdout" mode. Expected:
baseline-preserved error, causes ["model:reference/input:baseline"], one
non-leaf finding with code `execution`; envelope baseline null; envelope error.
A silent success is never read as an empty snapshot. Why: stdout must contain
exactly one JSON snapshot object with only surrounding whitespace permitted
(contract.md:520-522), so no object present is a malformed shape and therefore
an execution error (contract.md:523-525). Contrast
empty-complete-snapshot-is-a-value: an EXPLICIT empty snapshot is a value,
silence is not.

provenance: DFT04
