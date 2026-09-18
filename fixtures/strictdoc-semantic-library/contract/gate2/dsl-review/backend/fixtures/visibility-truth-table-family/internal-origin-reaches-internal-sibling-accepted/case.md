Situation: base corpus; F2a and F2b are both open children of closed F2, so
origin and target share the closed compartment.

Change: add F2a R -> F2b at occurrenceIndex 1.

Expected: R.all satisfied - visible-target with path and walkedPath
["F2a","F2","F2b"], boundary null; the one departure decodes closed F2 and is
allowed.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). The envelope is satisfied.

Why: F2 contains the original origin F2a in its subtree, which the expand policy
permits (contract.md:307-310); the table rules it Accept, "Origin is already
inside F2" (decisions.md:45).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
