Situation: the drawn base corpus — F0 open, closed F2 (`FLAG: ["true"]`) under
F0, open F2a under F2 — evaluated against baseline S0 (`baseline-empty`).
Change: create BAR M owning `P parent F0` at occurrenceIndex 0 and `Q child F2a`
at occurrenceIndex 1; `created` is `["M"]`. Expected: `one-P` and `one-Q`
satisfied with count 1 each, and `P.target-type`/`Q.target-type` satisfied, so
`endpoint-path` is evaluated rather than blocked. `endpoint-path` violated on
subject M with code `closed-boundary`, origin F0, target F2a,
`path: ["F0","F2","F2a"]`, `walkedPath: ["F0","F2"]`, `boundary: "F2"`:
departure from open F0 is permitted, F2 may be visited, but F2 is closed and
does not contain origin F0 in its subtree, so the departure toward F2a is
forbidden and the walk stops at F2. `native-dag` satisfied — `F0 -> M -> F2a`
runs parallel to `F0 -> F2 -> F2a` and closes no cycle. `H.target-type`,
`one-H-parent`, `H-forest` and `baseline-preserved` satisfied. Envelope
violated. Why: "`expand: open-or-origin-in-subtree-including-self` permits
departure when that node is open or contains the original origin in its subtree,
including itself." (contract.md:309) and "A closed departure that excludes the
origin violates the path rule and is its boundary." (contract.md:311) Mixed
scope: the row additionally requires comparing authored file bytes, the held
graph and disposable derived state against a pre-operation snapshot after the
rejection. Those are Scribe-backed publication observations with no
representation in `candidate.json`, `bundle.inputs` or the results envelope, so
this fixture covers only the evaluator verdict.

provenance: B06
