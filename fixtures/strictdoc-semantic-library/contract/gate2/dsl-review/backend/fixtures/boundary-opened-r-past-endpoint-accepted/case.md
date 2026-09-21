Situation: the drawn base corpus with one FLAG flipped: F2.FLAG becomes
["false"], so the boundary that hid F2a is now open. The structural route is
unchanged.

Change: set F2.FLAG to ["false"], then add one R occurrence to F1a targeting F2a
at occurrenceIndex 1 - the same relation the closed-boundary case rejects.

Expected: R.all is satisfied. The visible-target leaf reports code
visible-target with path and walkedPath both ["F1a","F1","F0","F2","F2a"] and
boundary null; the target-type leaf is satisfied.

Expected: every other rule stays satisfied and the envelope is satisfied. F2 is
not baseline-protected (only I0 is), so changing its FLAG leaves
baseline-preserved satisfied with differences [].

Why: the only step the previous case forbade was the downward departure from F2,
and the expand policy "permits departure when that node is open"
(contract.md:307-310). The truth table rules this row Accept because "Boundary
is open" (decisions.md:44). Preserve compares only "every baseline-listed uid"
(contract.md:245).

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T03
