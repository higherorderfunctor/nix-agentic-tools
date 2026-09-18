Situation: the starting point is the accepted open-boundary state (F2 open, F1a
already owning R -> F2a), not the drawn base corpus. Nothing about the R
occurrence is being edited.

Change: flip F2.FLAG back to ["true"], leaving F1a's R occurrence at
occurrenceIndex 1 untouched. The resulting candidate is therefore byte-identical
to the closed-boundary case's candidate.

Expected: R.all is violated at the unchanged occurrence - visible-target with
code closed-boundary, boundary "F2", path ["F1a","F1","F0","F2","F2a"],
walkedPath ["F1a","F1","F0","F2"]. The finding names F1a as the owner (uid) and
F2 as the boundary, which is how a reader sees that the FLAG edit, not the
relation, caused the rejection.

Expected: every other rule stays satisfied; the envelope is violated.

Why: "Only the final batch state is evaluated; private intermediate states do
not decide validity" (contract.md:449-450), so an occurrence that no edit
touched is still re-judged against the new FLAG (contract.md:307-313). Evidence
identifies the owner through the finding's uid and the departure node through
boundary (contract.md:609-612, 646-649).

Disputed: because only final state is evaluated, this candidate and its expected
envelope are identical to r-past-closed-boundary-rejected; the contract offers
no field that records which edit made the path invalid, so "identifies the
changed boundary" is satisfied only by the boundary evidence, not by any
diff-aware output.

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T04
