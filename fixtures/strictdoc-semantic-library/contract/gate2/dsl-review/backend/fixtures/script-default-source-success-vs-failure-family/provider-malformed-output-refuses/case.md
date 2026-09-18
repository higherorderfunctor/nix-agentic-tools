Variant of this family; read ../case.md for the situation, the change and the
citations. Binding: ["sh","-c","echo not-json"] with timeoutSeconds 10, so
stdout is not JSON at all. Expected: baseline-preserved error, causes
["model:reference/input:baseline"], one non-leaf finding with code `execution`;
envelope baseline null; envelope error. Why: malformed JSON is an execution
error for every rule declaring that input (contract.md:523-525); stdout must
contain exactly one JSON snapshot object (contract.md:520-522).

provenance: DFT04
