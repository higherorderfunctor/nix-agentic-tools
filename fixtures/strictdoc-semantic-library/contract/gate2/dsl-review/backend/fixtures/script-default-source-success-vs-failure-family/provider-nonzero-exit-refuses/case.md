Variant of this family; read ../case.md for the situation, the change and the
citations. Binding: ["sh","-c","exit 3"] with timeoutSeconds 10, so the command
exits nonzero with no snapshot. Expected: baseline-preserved error, causes
["model:reference/input:baseline"], one non-leaf finding with code `execution`;
envelope baseline null; envelope error. Why: nonzero exit is an execution error
for every rule declaring that input (contract.md:523-525), which errors that
rule with the input ID in causes (contract.md:660-661).

provenance: DFT04
