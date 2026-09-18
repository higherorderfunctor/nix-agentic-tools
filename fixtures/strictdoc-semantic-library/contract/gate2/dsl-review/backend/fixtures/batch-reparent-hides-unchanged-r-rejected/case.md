Situation: the drawn base corpus. One batch creates an open FOO X under F1,
points F1a's new R occurrence at X, and then moves X's H parent to closed F2.
Only the batch's final state is a candidate.

Change: create X (FOO, FLAG ["false"], H -> F1, appended after Z0), add F1a R ->
X at occurrenceIndex 1, then set X's H target to F2. created is ["X"].

Expected: R.all is violated. visible-target on F1a's unchanged R occurrence
reports code closed-boundary with path ["F1a","F1","F0","F2","X"], walkedPath
["F1a","F1","F0","F2"] and boundary "F2" - the witness names the moved edge's
new parent as the boundary.

Expected: H.target-type and one-H-parent each gain one satisfied finding for X
(H -> F2, count 1). native-dag stays satisfied (new edges F2 -> X and X -> F1a
close no cycle) and H-forest stays satisfied because X has exactly one in-view H
parent. The envelope is violated.

Why: the intermediate X -> F1 parentage is private; the rule reads the final H
projection (contract.md:449-450) in which the route to X passes closed F2, whose
departure excludes origin F1a (contract.md:307-313). X is newly allocated so its
uid belongs in created (contract.md:883-887); its FLAG is authored explicitly,
so creation defaulting has nothing to fill.

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T05
