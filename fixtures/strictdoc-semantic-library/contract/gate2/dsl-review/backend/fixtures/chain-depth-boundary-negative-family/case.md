Situation: three independent chain depths - 1, 3 and 12 - each built fresh on
the drawn base corpus as a new root K0 with an open sibling branch KS and a
descending H chain KD1..KDn. The base F and G trees are untouched in every
member, and connected: false lets K0 be an extra root (contract.md:296-298).

Change: each member creates K0, KS and its chain, then adds one R occurrence on
the sibling origin KS targeting the chain's deepest node KDn at
occurrenceIndex 1. The two negative members additionally close one interior
descendant (KD2 at depth 3, KD6 at depth 12).

Expected: acceptance does not decay with depth.
depth-1-closed-endpoint-accepted, depth-3-open-chain-accepted and
depth-12-open-chain-accepted are all satisfied, with walkedPath equal to the
full path in each. Depth 1 is the boundary-free control: its single chain node
is the closed endpoint, and it is still accepted because arrival never needs
expansion.

Expected: closing one interior descendant flips the same relation to violated
with code closed-boundary and boundary that node - KD2 at depth 3, KD6 at depth
12 - and walkedPath truncated to the permitted prefix. Depth 1 has no interior
node, so it contributes no negative member.

Why: ascent from KS reads no FLAG (contract.md:305-306), every downward
departure decodes the departure node's FLAG (contract.md:307-311), and "The
final endpoint needs no expansion" (contract.md:313). Depth adds only
departures, so a chain of open departures stays satisfied however long it is,
and the first closed one stops the walk (contract.md:312-313).

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T10
