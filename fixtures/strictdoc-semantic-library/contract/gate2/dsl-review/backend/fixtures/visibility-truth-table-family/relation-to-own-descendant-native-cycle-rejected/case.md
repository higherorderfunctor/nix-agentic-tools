Situation: base corpus; closed F2 points an R occurrence at its own H child F2a,
so the H edge F2 -> F2a and the R edge F2a -> F2 close a native cycle.

Change: add F2 R -> F2a at occurrenceIndex 1.

Expected: native-dag violated with code cycle - cycle ["F2","F2a","F2"] and two
indexed edges: F2a's H occurrence (index 0, owner F2a) supplying F2 -> F2a, then
F2's R occurrence (index 1, owner F2) supplying F2a -> F2.

Expected: R.all SATISFIED - visible-target reports code visible-target with path
and walkedPath ["F2","F2a"], boundary null, because the closed departure node F2
contains the origin F2 itself. H-forest stays satisfied because role R is not in
the H view. The envelope is violated.

Why: the expand policy includes the node itself (contract.md:307-310) so the
traversal is admissible, while every authored Parent/Child edge across all roles
feeds native-dag (contract.md:243, 253-256); decisions.md:56 rules it "Reject
native cycle F2 -> F2a -> F2" and warns "Do not use this case to test
closed-start semantics".

Disputed: the cycle walk start and the owner key are unspecified, as in the
other two native-cycle rows; this fixture starts the walk at the cycle vertex
earliest in candidate record order (contract.md:580-581) and names the owner
"owner", as every other graph witness in the corpus does.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
