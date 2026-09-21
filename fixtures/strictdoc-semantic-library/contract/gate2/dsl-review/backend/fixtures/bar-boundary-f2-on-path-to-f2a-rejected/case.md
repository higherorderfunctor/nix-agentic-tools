Situation: the drawn base corpus. The downward route from root F0 to F2a passes
through closed F2, and the bridge origin F0 is above that boundary rather than
inside it.

Change: create a complete BAR M with P -> F0 (occurrenceIndex 0) and Q -> F2a
(occurrenceIndex 1). created is ["M"].

Expected: endpoint-path is violated for M with code closed-boundary, origin
"F0", target "F2a", path ["F0","F2","F2a"], walkedPath ["F0","F2"] and boundary
"F2".

Expected: P.target-type, Q.target-type, one-P and one-Q stay satisfied for M,
and native-dag stays satisfied - F0 -> M -> F2a plus the H edges F0 -> F2 -> F2a
form no directed cycle, so the rejection comes from the traversal rule alone.
The envelope is violated.

Why: the departure from F2 toward F2a decodes F2's FLAG, and expansion requires
the node to be open or to contain the original origin F0 in its subtree; F0 is
F2's parent, not its descendant (contract.md:307-311). The truth table rules
this row "Reject with boundary F2" (decisions.md:50).

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T07
