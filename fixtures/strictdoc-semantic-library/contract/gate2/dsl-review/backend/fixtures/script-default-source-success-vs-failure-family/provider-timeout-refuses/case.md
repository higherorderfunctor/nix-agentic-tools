Variant of this family; read ../case.md for the situation, the change and the
citations. Binding: ["sleep","5"] with timeoutSeconds 0.1, so acquisition times
out before any stdout arrives. Expected: baseline-preserved error, causes
["model:reference/input:baseline"], one non-leaf finding with code `execution`;
envelope baseline null; envelope error. Why: timeout is an execution error for
every rule declaring that input (contract.md:523-525); timeoutSeconds is any
positive finite number of seconds (contract.md:513-515).

provenance: DFT04
