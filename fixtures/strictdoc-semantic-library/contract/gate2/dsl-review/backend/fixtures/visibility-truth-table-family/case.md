Situation: one fixture per row of the visibility truth table
(decisions.md:42-56), each a fresh single-change candidate on the drawn base
corpus. Nine rows add one FOO R occurrence, six add one complete BAR, and one of
those fifteen also flips a FLAG - opened-boundary-lets-external-origin-descend
opens F2.

Change: every member changes exactly what its row names and nothing else, so the
rows are independent readings of the same base forest rather than a sequence.
created lists the BAR (and nothing else) in the bridge rows and is empty in the
relation rows.

Expected: seven rows accept and eight reject. The accepting rows are two
closed-endpoint visits, an opened boundary, an internal sibling hop, two exits
from a closed compartment, and a closed-start bridge. The rejecting rows split
into two closed boundaries, two distinct-root rejections, one bridge that would
need ascent and three native cycles, and - counted among them - nothing that
rejects for a reason the contract does not name.

Expected: the three native-cycle rows (equal-endpoint bridge, self relation,
relation to own descendant) reject through native-dag with code cycle and a
nonempty cycles witness, while their traversal leaf is SATISFIED - zero-step and
closed-origin traversal are admissible and only the DAG constraint rejects. No
member infers a semantic verdict from a native cycle or the reverse.

Why: the table rows are the retained reviewed visibility meanings
(model.md:119-137), the policy walk is contract.md:296-315, and "A zero-step
path is satisfied after endpoint and dependency checks; the separate native DAG
rule can still be violated" (contract.md:313-315). native-dag has no `requires`,
so a cycle blocks nothing (contract.md:77-84).

Overlap: five rows restate cases that also exist as standalone fixtures
(r-to-closed-endpoint-visible-path-accepted, r-past-closed-boundary-rejected,
boundary-opened-r-past-endpoint-accepted,
bar-downward-path-closed-endpoint-accepted,
bar-boundary-f2-on-path-to-f2a-rejected). Each fixture here is self-contained;
the duplication is deliberate so the table is complete in one place.

Disputed: these fixtures supply no baseline.json or invocation.json, so they
inherit the packet binding (contract.md:500-517) and keep envelope baseline
"baseline-I0-open"; the contract never states the fallback for a fixture
directory that omits them.

provenance: T11
