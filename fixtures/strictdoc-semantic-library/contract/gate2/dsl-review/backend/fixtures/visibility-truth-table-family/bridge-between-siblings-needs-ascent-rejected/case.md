Situation: base corpus; F1 and F2 are siblings under root F0, so they are
connected but neither is an ancestor of the other.

Change: create a complete BAR M with P -> F1 and Q -> F2; created is ["M"].

Expected: endpoint-path violated for M with code endpoint-path (route requires
ascent), origin "F1", target "F2", boundary null, and path and walkedPath both
empty.

Expected: P.target-type, Q.target-type, one-P and one-Q each gain one satisfied
finding for M; H.target-type, one-H-parent, native-dag, H-forest and
baseline-preserved are unaffected. native-dag stays satisfied - F1 -> M -> F2
adds no cycle - so the rejection is the descent requirement alone. The envelope
is violated.

Why: "Endpoint paths require the origin to be an ancestor of the target; needing
ascent violates this rule" (contract.md:304-305), and that code covers a "route
requires ascent" (contract.md:809); the table rules it "Reject with
endpoint/path evidence", "Sibling connectivity is not descent"
(decisions.md:52).

Why the two path arrays are empty: endpoint-path admits only a route in which
the origin is an ancestor of the target (contract.md:304-305), so the undirected
route F1-F0-F2 is not a permitted structural route for this rule, and "Use empty
arrays for unusable endpoints/hierarchy or no permitted structural route"
(contract.md:647-648) covers both arrays. walkedPath is additionally empty
because the rule decides "direction before walking" (contract.md:821-823): the
policy walk never starts, so there is no "stopping node" for walkedPath to
include (contract.md:646-647). This is the same two-empty-array shape the two
distinct-root rows report, and for the same reason - both reject before walking.
No diagnostic distinction is lost, because code separates them: endpoint-path
for an ascent rejection, no-shared-root for distinct roots (contract.md:809).
Settled - do not relitigate: the alternative, path ["F1","F0","F2"] with
walkedPath ["F1"], was authored first and rejected, because walkedPath ["F1"]
asserts a walked prefix in a case contract.md:821-823 decides before walking.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
