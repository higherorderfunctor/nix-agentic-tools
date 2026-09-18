Variant of this family; read ../case.md for the situation, the change and the
citations. Binding: a printf of
{"complete":true,"model":"reference","records":[]} with no `identity` key — the
catalogue's "no value" mode, a shape that is otherwise a valid empty snapshot.
Expected: baseline-preserved error, causes ["model:reference/input:baseline"],
one non-leaf finding with code `execution`; envelope baseline null; envelope
error. This is the one arm distinguished from empty-complete-snapshot-is-a-value
only by the missing identity. Why: missing identity is listed with nonzero exit
and timeout as an execution error (contract.md:523-525), and `identity` is a
required nonempty opaque string recorded in the envelope (contract.md:487-490).

provenance: DFT04
