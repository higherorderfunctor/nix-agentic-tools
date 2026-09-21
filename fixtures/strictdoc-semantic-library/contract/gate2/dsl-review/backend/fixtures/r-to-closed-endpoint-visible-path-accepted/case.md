Situation: the drawn base corpus. F1a sits under F1 under root F0; closed F2
(FLAG ["true"]) is F0's other child, so the two nodes share root F0.

Change: add one R occurrence to F1a targeting F2. It lands at occurrenceIndex 1,
after F1a's existing H parent.

Expected: R.all is satisfied for that occurrence. Its target-type leaf
(/check/all/0) reports actualElement FOO; its visible-target leaf (/check/all/1)
reports code visible-target with path and walkedPath both ["F1a","F1","F0","F2"]
and boundary null.

Expected: no other rule changes. H.target-type, one-H-parent, native-dag,
H-forest and baseline-preserved keep their base-sample findings (the R
occurrence adds native edge F2 -> F1a, which closes no cycle, and the H view
ignores role R), so the envelope is satisfied.

Why: ascent to the shared root reads no FLAG, "`visit: always` permits arrival
at a closed node, including the endpoint", and "The final endpoint needs no
expansion" (contract.md:305-313). The contract states this exact finding as its
own worked example (contract.md:668-685).

Disputed: this fixture supplies no baseline.json or invocation.json, so it
inherits the packet binding (contract.md:500-517) and keeps envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T01
