Situation: base corpus; the bridge runs one step down from the open root F0 to
its closed child F2.

Change: create a complete BAR M with P -> F0 (index 0) and Q -> F2 (index 1);
created is ["M"].

Expected: endpoint-path satisfied for M - origin "F0", target "F2", path and
walkedPath ["F0","F2"], boundary null, with the indexed upper and lower endpoint
occurrences in evidence.

Expected: P.target-type, Q.target-type, one-P and one-Q each gain one satisfied
finding for M; H.target-type, one-H-parent, native-dag, H-forest and
baseline-preserved are unaffected. The envelope is satisfied.

Why: the only departure is from open F0 and the endpoint needs no expansion
(contract.md:306-313); the table rules it Accept, "Closed endpoint does not
require expansion" (decisions.md:49).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
