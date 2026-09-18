Situation: the drawn base corpus. F0 is the open root and closed F2 is its
direct child, so a bridge from F0 to F2 is one downward step.

Change: create a complete BAR M with P -> F0 (occurrenceIndex 0) and Q -> F2
(occurrenceIndex 1), appended after Z0. created is ["M"].

Expected: endpoint-path is satisfied for M, code endpoint-path, with indexed
upper and lower lists holding the two endpoint occurrences, origin "F0", target
"F2", path and walkedPath both ["F0","F2"], boundary null.

Expected: P.target-type, Q.target-type, one-P and one-Q each gain one satisfied
finding for M (both endpoints resolve to FOO; each count is 1). one-H-parent and
H.target-type are unchanged because M is not a FOO. native-dag is satisfied -
the bridge is F0 -> M -> F2 alongside the H edge F0 -> F2, which is not a cycle.
The envelope is satisfied.

Why: BAR needs a downward H path with the same origin-sensitive expansion
(contract.md:304-305), the only departure is from open F0, and "The final
endpoint needs no expansion" so arriving at closed F2 is fine
(contract.md:306-313). The truth table rules this row Accept: "Closed endpoint
does not require expansion" (decisions.md:49). Parent and child occurrences
build F0 -> M and M -> F2 (contract.md:253-256).

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T06
