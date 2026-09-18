Situation: base corpus; the bridge starts AT the closed node F2 and descends to
its open child F2a.

Change: create a complete BAR M with P -> F2 and Q -> F2a; created is ["M"].

Expected: endpoint-path satisfied for M - origin "F2", target "F2a", path and
walkedPath ["F2","F2a"], boundary null. The single departure decodes closed F2
and is allowed.

Expected: P.target-type, Q.target-type, one-P and one-Q each gain one satisfied
finding for M; H.target-type, one-H-parent, native-dag, H-forest and
baseline-preserved are unaffected. The envelope is satisfied.

Why: the expand policy includes the node itself, so a closed start contains its
own origin (contract.md:307-310, decisions.md:19); the table rules it Accept,
"Closed start is inside its own boundary" (decisions.md:51).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
