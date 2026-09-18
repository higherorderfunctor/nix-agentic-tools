Situation: base corpus; F1a is under root F0 and G1 is under root G0, and
nothing connects the two roots.

Change: add F1a R -> G1 at occurrenceIndex 1.

Expected: R.all violated - visible-target with code no-shared-root, origin
"F1a", target "G1", empty path and walkedPath, boundary null.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). native-dag stays satisfied, so the rejection is the
traversal rule's alone. The envelope is violated.

Why: "Require one shared H root" (model.md:121-122) and "A different root
violates a path rule" (contract.md:302-303), settled before direction or
boundaries (contract.md:821-823); the table rules it "Reject with distinct
roots" (decisions.md:48).

Why the two path arrays are empty: disjoint roots admit no structural route at
all (contract.md:647-648), and shared root is determined before direction and
before walking (contract.md:821-822), so the walk never starts and walkedPath
has no stopping node to include (contract.md:646-647).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
