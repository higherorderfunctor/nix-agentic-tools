Situation: base corpus with its two disjoint roots F0 and G0; no BAZ bridge or
other relation joins them in this member.

Change: create a complete BAR M with P -> F0 and Q -> G1; created is ["M"].

Expected: endpoint-path violated for M with code no-shared-root, origin "F0",
target "G1", empty path and walkedPath, boundary null.

Expected: P.target-type, Q.target-type, one-P and one-Q each gain one satisfied
finding for M; H.target-type, one-H-parent, native-dag, H-forest and
baseline-preserved are unaffected. The envelope is violated.

Why: shared root is determined first and a different root violates the path rule
(contract.md:302-303, 821-823); the table rules it "Reject with distinct roots",
"Cross-root bridge has no H path" (decisions.md:53).

Why the two path arrays are empty: as in the relation row, no permitted
structural route exists and the walk never starts, so both arrays are empty
(contract.md:647-648, 821-822).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
