Situation: base corpus; the downward route from F0 to F2a passes through the
closed intermediate F2.

Change: create a complete BAR M with P -> F0 and Q -> F2a; created is ["M"].

Expected: endpoint-path violated for M - code closed-boundary, path
["F0","F2","F2a"], walkedPath ["F0","F2"], boundary "F2".

Expected: P.target-type, Q.target-type, one-P and one-Q each gain one satisfied
finding for M; H.target-type, one-H-parent, native-dag, H-forest and
baseline-preserved are unaffected. native-dag stays satisfied. The envelope is
violated.

Why: the departure from closed F2 excludes the bridge origin F0, which is F2's
parent rather than its descendant (contract.md:307-311); the table rules it
"Reject with boundary F2" (decisions.md:50).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
