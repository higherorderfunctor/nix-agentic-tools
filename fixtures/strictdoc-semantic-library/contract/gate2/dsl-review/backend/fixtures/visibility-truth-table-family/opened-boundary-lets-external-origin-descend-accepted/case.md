Situation: base corpus with F2.FLAG set to ["false"], so the previously
rejecting boundary is open.

Change: set F2.FLAG to ["false"], then add F1a R -> F2a at occurrenceIndex 1.

Expected: R.all satisfied - visible-target with path and walkedPath
["F1a","F1","F0","F2","F2a"], boundary null.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). F2 is not baseline-protected, so baseline-preserved stays
satisfied. The envelope is satisfied.

Why: expansion is permitted when the departure node is open
(contract.md:307-310); the table rules it Accept, "Boundary is open"
(decisions.md:44).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
