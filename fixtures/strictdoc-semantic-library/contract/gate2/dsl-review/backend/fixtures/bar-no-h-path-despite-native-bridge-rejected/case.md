Situation: the drawn base corpus has two roots, F0 and G0. Z0 is a BAZ outside
the hierarchy, and its Parent R / Child Q are unconstrained context controls.

Change: give the existing Z0 relations R -> F0 (occurrenceIndex 0) and Q -> G1
(occurrenceIndex 1), which creates native connectivity F0 -> Z0 -> G1, then
create a complete BAR M with P -> F0 and Q -> G1. created is ["M"] - Z0 is an
old record.

Expected: endpoint-path is violated for M with code no-shared-root, origin "F0",
target "G1", and empty path and walkedPath, boundary null.

Expected: native-dag is satisfied, so the native bridge through Z0 does not
rescue the BAR and does not reject it either. P.target-type and Q.target-type
report FOO for M's two endpoints and skip Z0's R and Q entirely, because those
selectors name element BAR. one-P and one-Q stay satisfied. The envelope is
violated.

Why: BAZ's R and Q "intentionally have no target-type, count, or path
constraints" and contribute only to model rules such as native-dag
(contract.md:118-121), and no BAZ role becomes an H edge, so the H forest still
has F0 and G0 as separate roots; "A different root violates a path rule"
(contract.md:302-303) and shared root is settled before direction or boundaries
(contract.md:821-823). The truth table rules this row "Reject with distinct
roots" (decisions.md:53).

Why the two path arrays are empty: disjoint roots admit no structural route at
all, and "Use empty arrays for unusable endpoints/hierarchy or no permitted
structural route" (contract.md:647-648) covers both arrays. walkedPath is
additionally empty because shared root is determined first, before direction and
before walking (contract.md:821-822), so the policy walk never starts and there
is no stopping node for walkedPath to include (contract.md:646-647).

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T08
