Situation: base corpus; F2's new R occurrence points at F2 itself, which is a
native self-loop.

Change: add F2 R -> F2 at occurrenceIndex 1.

Expected: native-dag violated with code cycle - cycle ["F2","F2"] and one
indexed edge, F2's R occurrence at index 1 carrying "owner" F2.

Expected: R.all SATISFIED - the target-type leaf reports FOO and the
visible-target leaf reports code visible-target with path and walkedPath ["F2"],
boundary null. one-H-parent, H.target-type, H-forest and baseline-preserved stay
satisfied, and the BAR rules stay vacuous. The envelope is violated.

Why: a zero-step path is admissible while the DAG rule still rejects, and "any
directed cycle, including a self-loop, violates" (contract.md:243, 313-315); the
table rules it "Reject native self-cycle", with "No independent traversal
acceptance evidence" (decisions.md:55).

Disputed: as in the equal-endpoint bridge row, the cycle walk start and the
owner key are unspecified; this fixture starts the walk at the cycle vertex
earliest in candidate record order (contract.md:580-581) and names the owner
"owner", as every other graph witness in the corpus does.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
