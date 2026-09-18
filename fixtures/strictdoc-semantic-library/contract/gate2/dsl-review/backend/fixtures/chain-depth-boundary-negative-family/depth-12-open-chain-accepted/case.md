Situation: the drawn base corpus plus a fresh root K0 with two branches - the
open sibling origin KS, and an H chain of depth 12, KD1..KD12, whose deepest
node KD12 is open. Every interior chain node is open.

Change: create K0, KS and KD1..KD12, then add one R occurrence to KS targeting
KD12 at occurrenceIndex 1. created lists all 14 new uids.

Expected: R.all is satisfied. The visible-target leaf reports code
visible-target with path and walkedPath both ["KS", "K0", "KD1", "KD2", "KD3",
"KD4", "KD5", "KD6", "KD7", "KD8", "KD9", "KD10", "KD11", "KD12"] and boundary
null; the target-type leaf reports FOO.

Expected: H.target-type gains a satisfied finding for each new node that owns an
H parent, one-H-parent gains one per new FOO (each count 0 or 1), and
native-dag, H-forest and baseline-preserved stay satisfied - K0 is simply an
additional root. The envelope is satisfied.

Why: the single ascending step KS -> K0 reads no FLAG (contract.md:305-306);
each downward departure is permitted because the node is open
(contract.md:307-310). Eleven interior departures are each open, so an accepted
path is bounded only by openness, never by length.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T10
