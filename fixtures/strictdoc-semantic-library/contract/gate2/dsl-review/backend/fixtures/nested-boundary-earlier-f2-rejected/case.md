Situation: a two-member control pair on the drawn base corpus, extended with a
new open grandchild F2a1 under F2a so that the downward route from root F0
crosses two candidate boundaries, F2 then F2a.

Change: both members add F2a1 (FOO, H -> F2a) and a complete BAR M with P -> F0,
Q -> F2a1. They differ only in which of F2 / F2a carries FLAG ["true"]; each
candidate is an independent final state, never a sequence.

Expected: exactly one boundary is reported per member, and it is the FIRST
forbidden departure on the route - outer-boundary-f2-closed reports boundary
"F2" with walkedPath ["F0","F2"], inner-boundary-f2a-closed reports boundary
"F2a" with walkedPath ["F0","F2","F2a"]. Both carry the same full structural
path ["F0","F2","F2a","F2a1"], and both envelopes are violated.

Expected: in both members P.target-type, Q.target-type, one-P, one-Q,
H.target-type, one-H-parent, native-dag, H-forest and baseline-preserved stay
satisfied, so endpoint-path is the only rule that rejects.

Why: the policy walk stops "at the first blocked or forbidden departure"
(contract.md:312-313) and walkedPath is "the permitted prefix including the
stopping node" (contract.md:646-649), so a deeper closed node is never reached
and never reported. Openness below a closed ancestor does not help: "An open
node behind an intervening closed ancestor stays hidden" (model.md:132-133).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T09
