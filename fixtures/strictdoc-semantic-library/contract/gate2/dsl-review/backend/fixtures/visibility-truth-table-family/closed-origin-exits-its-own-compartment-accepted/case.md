Situation: base corpus; the origin is the closed node F2 itself, and the target
F1a is in F0's other branch.

Change: add F2 R -> F1a at occurrenceIndex 1, after F2's existing H parent.

Expected: R.all satisfied - visible-target with path and walkedPath
["F2","F0","F1","F1a"], boundary null. No FLAG is read at F2 because the first
step is upward.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). The envelope is satisfied.

Why: "A closed origin is inside its own boundary" (decisions.md:19) and ascent
is unrestricted (contract.md:305-306); the table rules it Accept, "Closed origin
can exit" (decisions.md:47).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
