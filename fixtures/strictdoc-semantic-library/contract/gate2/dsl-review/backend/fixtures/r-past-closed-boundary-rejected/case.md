Situation: the drawn base corpus. F2 is closed and owns F2a; the origin F1a
lives in F0's other branch, so it is outside F2's subtree.

Change: add one R occurrence to F1a targeting F2a, at occurrenceIndex 1.

Expected: R.all is violated. The target-type leaf (/check/all/0) stays
satisfied, and the visible-target leaf (/check/all/1) is violated with code
closed-boundary, path ["F1a","F1","F0","F2","F2a"], walkedPath
["F1a","F1","F0","F2"] and boundary "F2".

Expected: every other rule stays satisfied (native edge F2a -> F1a closes no
cycle), so the envelope is violated.

Why: the walk reaches F2 legitimately, but the departure toward F2a decodes F2's
FLAG, and expansion needs the node open or containing the original origin in its
subtree (contract.md:307-310). "A closed departure that excludes the origin
violates the path rule and is its boundary" (contract.md:311-313). A violated
leaf inside `all` still emits its own finding and makes the subject violated
(contract.md:226-232). The contract states this exact finding as its own worked
example (contract.md:686-702).

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T02
