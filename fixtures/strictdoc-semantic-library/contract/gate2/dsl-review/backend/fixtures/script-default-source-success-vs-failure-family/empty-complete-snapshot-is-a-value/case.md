Variant of this family; read ../case.md for the situation, the change and the
citations. Binding: ["cat","baseline.json"] with timeoutSeconds 10 over the
local complete snapshot identified "baseline-empty" and protecting zero records.
Expected: acquisition succeeds and the empty snapshot is used as a value —
baseline-preserved satisfied with differences [], envelope baseline
"baseline-empty", envelope satisfied. N0's absent FLAG is still filled and still
produces no field error. Why: "An empty complete snapshot ... is valid and
protects nothing" (contract.md:526-528); the captured identity is echoed into
the envelope (contract.md:568-570).

provenance: DFT04
