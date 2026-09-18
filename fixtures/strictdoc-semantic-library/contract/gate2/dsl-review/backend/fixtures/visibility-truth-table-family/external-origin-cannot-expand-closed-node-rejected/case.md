Situation: base corpus; the target F2a sits behind closed F2 and the origin F1a
is outside F2's subtree.

Change: add F1a R -> F2a at occurrenceIndex 1.

Expected: R.all violated - visible-target with code closed-boundary, boundary
"F2", path ["F1a","F1","F0","F2","F2a"], walkedPath ["F1a","F1","F0","F2"]; the
target-type leaf stays satisfied.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). The envelope is violated.

Why: the departure from F2 excludes the origin (contract.md:307-311); the table
rules it "Reject with boundary F2" (decisions.md:43).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
