Situation: base corpus; the origin F2a is inside closed F2 and the target F1a is
in the other branch of root F0.

Change: add F2a R -> F1a at occurrenceIndex 1.

Expected: R.all satisfied - visible-target with path and walkedPath
["F2a","F2","F0","F1","F1a"], boundary null.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). The envelope is satisfied.

Why: the steps out of the compartment are ascent, which "allows every upward
step without reading FLAG", and the descent departures F0 and F1 are open
(contract.md:305-310); the table rules it Accept, "Exiting a closed compartment
is permitted" (decisions.md:46).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
