Situation: the same fresh chain of depth 12 under root K0 with the open sibling
origin KS, except that the interior descendant KD6 carries FLAG ["true"]. The
chain's deepest node KD12 is open, as is everything above and below the closed
node.

Change: create K0, KS and KD1..KD12 with KD6 closed, then add one R occurrence
to KS targeting KD12 at occurrenceIndex 1. created lists all 14 new uids.

Expected: R.all is violated. The visible-target leaf reports code
closed-boundary with boundary "KD6", the full path ["KS", "K0", "KD1", "KD2",
"KD3", "KD4", "KD5", "KD6", "KD7", "KD8", "KD9", "KD10", "KD11", "KD12"] and
walkedPath ["KS", "K0", "KD1", "KD2", "KD3", "KD4", "KD5", "KD6"]; the
target-type leaf stays satisfied.

Expected: H.target-type, one-H-parent, native-dag, H-forest and
baseline-preserved stay satisfied, so the traversal rule is the only rejection
and the envelope is violated.

Why: the origin KS is in K0's other branch, so it is not in KD6's subtree, and a
closed departure that excludes the origin "violates the path rule and is its
boundary" (contract.md:307-313). The open chain below KD6 is unreachable from
outside it: "An open node behind an intervening closed ancestor stays hidden"
(model.md:132-133).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T10
