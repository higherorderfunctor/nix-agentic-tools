Situation: base corpus; origin F1a is in F0's open branch and the target F2 is
the closed branch root itself.

Change: add F1a R -> F2 at occurrenceIndex 1.

Expected: R.all satisfied - visible-target with path and walkedPath
["F1a","F1","F0","F2"], boundary null.

Expected: no other rule changes - H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings, and the four
BAR rules plus endpoint-path stay vacuously satisfied over zero subjects
(contract.md:592-594). The envelope is satisfied.

Why: the endpoint is only visited, never expanded (contract.md:306-313); the
table rules it Accept, "A closed endpoint can be visited" (decisions.md:42).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
