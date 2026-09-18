Situation: the drawn base corpus with FLAG values untouched - F2 is closed, F2a
and the new F2a1 are open. The route from root F0 down to F2a1 is F0, F2, F2a,
F2a1.

Change: create F2a1 (FOO, FLAG ["false"], H -> F2a) and a complete BAR M with P
-> F0, Q -> F2a1. created is ["F2a1","M"].

Expected: endpoint-path is violated for M with code closed-boundary, origin
"F0", target "F2a1", path ["F0","F2","F2a","F2a1"], walkedPath ["F0","F2"] and
boundary "F2" - the earlier boundary, although F2a and F2a1 are both open.

Expected: H.target-type and one-H-parent gain one satisfied finding each for
F2a1; P.target-type, Q.target-type, one-P, one-Q, native-dag and H-forest stay
satisfied. The envelope is violated.

Why: the first departure out of F0 is permitted because F0 is open, and the walk
then stops at F2: expansion needs the departure node open or containing origin
F0 (contract.md:307-311), and the walk stops "at the first blocked or forbidden
departure" (contract.md:312-313). Nodes below the boundary are never examined.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T09
