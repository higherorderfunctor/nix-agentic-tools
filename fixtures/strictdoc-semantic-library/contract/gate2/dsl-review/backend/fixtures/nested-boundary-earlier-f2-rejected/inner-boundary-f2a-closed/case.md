Situation: the same corpus and the same route F0, F2, F2a, F2a1, with the two
FLAG values swapped - F2 is now open and F2a is closed. This is the control for
the outer-boundary member.

Change: set F2.FLAG to ["false"] and F2a.FLAG to ["true"], create F2a1 (FOO,
FLAG ["false"], H -> F2a), and create a complete BAR M with P -> F0, Q -> F2a1.
created is ["F2a1","M"].

Expected: endpoint-path is violated for M with code closed-boundary, origin
"F0", target "F2a1", the same path ["F0","F2","F2a","F2a1"], but walkedPath
["F0","F2","F2a"] and boundary "F2a" - the walk now proceeds one step further
before stopping.

Expected: as in the outer member, H.target-type and one-H-parent gain a
satisfied finding for F2a1 and every other rule stays satisfied; the envelope is
violated. Neither F2 nor F2a is baseline-protected, so baseline-preserved
remains satisfied with differences [].

Why: the departure from open F2 is permitted, and the departure from closed F2a
excludes origin F0, making F2a the boundary (contract.md:307-313); walkedPath is
"the permitted prefix including the stopping node" (contract.md:646-649).
Comparing the two members shows the boundary tracks the FLAG values rather than
the route's shape.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T09
