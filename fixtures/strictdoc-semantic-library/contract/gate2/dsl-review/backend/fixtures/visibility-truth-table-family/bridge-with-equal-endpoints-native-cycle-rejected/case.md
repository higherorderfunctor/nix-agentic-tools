Situation: base corpus; both bridge endpoints are the same node F2, which makes
the bridge a native cycle F2 -> M -> F2 while the traversal question is a
zero-step path.

Change: create a complete BAR M with P -> F2 and Q -> F2; created is ["M"].

Expected: native-dag violated with code cycle and one witness - cycle
["F2","M","F2"] and the two indexed edges, M's P occurrence (index 0) and Q
occurrence (index 1), each carrying its owner uid.

Expected: endpoint-path SATISFIED for M with path and walkedPath ["F2"] and
boundary null - the rejection must come from native-dag, not from an inferred
traversal verdict. P.target-type, Q.target-type, one-P, one-Q and H-forest stay
satisfied. The envelope is violated.

Why: "A zero-step path is satisfied after endpoint and dependency checks; the
separate native DAG rule can still be violated" (contract.md:313-315); a parent
occurrence is an edge target->owner and a child occurrence owner->target
(contract.md:253-256); "Native DAG overrides traversal admissibility"
(decisions.md:54).

Disputed: the contract fixes the witness shape (contract.md:636, 616-618) but
not where a cycle walk starts or the key naming the owner. This fixture starts
each walk at the cycle vertex earliest in candidate record order, the contract's
only stated ordering principle (contract.md:580-581), and names the owner
"owner", as every other graph witness in the corpus does.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
