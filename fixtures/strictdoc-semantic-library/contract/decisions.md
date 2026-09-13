# Decisions awaiting review

Status: **PROPOSED — no behavior approval recorded.** The DAG, multiple-root,
Child-authoring, clean-context, and native-devenv constraints are established.
The following choices are proposals. Current implementation behavior, a passing
native smoke test, or a convenient backend cannot approve them.

## Concrete choices

| ID  | Proposed ruling                                                                                                                                   | Consequence requiring review                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| D01 | Required `FLAG` strings `false`/`true` mean open/closed                                                                                           | Absent or malformed fields are input errors, never open defaults                                                                    |
| D02 | FOO `H`/`R` and BAR `P`/`Q` target FOO; selectors include full model/type context                                                                 | BAZ's Parent `R`/Child `Q` are unrestricted context controls, outside FOO/BAR rules                                                 |
| D03 | FOO has at most one `H` parent; completed BAR has exactly one `P` and one `Q`                                                                     | Cardinality is checked on final candidate state                                                                                     |
| D04 | `R` stays in one hierarchy root; ascending is unrestricted; descent uses origin-sensitive closed expansion                                        | An internal origin may leave its closed compartment or reach an internal sibling                                                    |
| D05 | A closed origin is inside its own boundary                                                                                                        | A BAR may descend from closed `F2` to `F2a`                                                                                         |
| D06 | BAR requires a downward `H` path; conceptual reachability includes zero length                                                                    | Equal endpoints are nevertheless always inadmissible native cycles; conceptual zero length has no independent Scribe pass case      |
| D07 | Baseline-listed UIDs and their modeled authored records are preserved exactly                                                                     | Deletion and modeled revision reject; incoming relations, layout, and bookkeeping are not automatically frozen                      |
| D08 | Supersession supplies no implicit exception to preservation                                                                                       | No supersession lifecycle or cleanup helper is part of this first fixture                                                           |
| D09 | Capture one identified complete immutable external snapshot per evaluation; use it throughout the candidate and comparison runs                   | A concurrent external change applies to the next evaluation; do not silently mix observations or claim latest-at-commit consistency |
| D10 | Provider nonzero exit, timeout, malformed output, or incomplete output is an execution error                                                      | Complete empty output is valid input; error is never absence of protected records                                                   |
| D11 | A batch evaluates its complete final state, with private incomplete staging                                                                       | Current individual writes or an RPC request array cannot substitute for the proposed transaction                                    |
| D12 | Existing invalid input is inspectable and diagnosable; accept repairs only when the complete final candidate is valid                             | Partial repairs that leave unrelated violations need a separate future decision; missing baseline/before inputs cannot be evaluated |
| D13 | Rejection restores authored files and observable graph; publication failure reports error and restores or blocks writes pending explicit recovery | Exact crash guarantees need integration evidence; never report a committed success for divergent state                              |
| D14 | Distinct rules extend; replacing/disabling a rule requires explicit identity-targeted action; conflicting duplicate identities error              | Module merge order never silently selects semantic meaning; effective rule origins remain inspectable                               |
| D15 | A proposed numeric descendant aggregate and external limit become a later independent extension challenge only after approval                     | X07 cannot quietly add fields or domain requirements to the retained core corpus                                                    |

Every row above is **PENDING**. The shared and opinionated signatures in
[surfaces](surfaces.md) are additional API review items, not exported options.

## Visibility truth table

All rows use the [base forest](model.md). Each row starts fresh. “Proposed
semantic result” is distinct from total native validity. Positive semantic cases
are not reported as current runtime enforcement.

| Relation or bridge endpoints  | Proposed semantic result     | Expected overall result under the proposed contract | Reason                                               |
| ----------------------------- | ---------------------------- | --------------------------------------------------- | ---------------------------------------------------- |
| `F1a Parent R -> F2`          | Visible                      | Accept                                              | A closed endpoint can be visited                     |
| `F1a Parent R -> F2a`         | Hidden                       | Reject with boundary `F2`                           | Cannot expand the externally encountered closed node |
| Same, after `F2.FLAG = false` | Visible                      | Accept                                              | Boundary is open                                     |
| `F2a Parent R -> F2b`         | Visible                      | Accept                                              | Origin is already inside `F2`                        |
| `F2a Parent R -> F1a`         | Visible                      | Accept                                              | Exiting a closed compartment is permitted            |
| `F2 Parent R -> F1a`          | Visible                      | Accept                                              | Closed origin can exit                               |
| `F1a Parent R -> G1`          | Unreachable                  | Reject with distinct roots                          | Roots do not connect implicitly                      |
| `M: P=F0, Q=F2`               | Visible                      | Accept                                              | Closed endpoint does not require expansion           |
| `M: P=F0, Q=F2a`              | Hidden                       | Reject with boundary `F2`                           | Closed intermediate node                             |
| `M: P=F2, Q=F2a`              | Visible                      | Accept                                              | Closed start is inside its own boundary              |
| `M: P=F1, Q=F2`               | No downward path             | Reject with endpoint/path evidence                  | Sibling connectivity is not descent                  |
| `M: P=F0, Q=G1`               | No downward path             | Reject with distinct roots                          | Cross-root bridge has no `H` path                    |
| `M: P=F2, Q=F2`               | Zero-length path by proposal | Reject native cycle `F2 -> M -> F2`                 | Native DAG overrides traversal admissibility         |
| `F2 Parent R -> F2`           | Zero-length path by proposal | Reject native self-cycle                            | No independent traversal acceptance evidence         |
| `F2 Parent R -> F2a`          | Visible by origin proposal   | Reject native cycle `F2 -> F2a -> F2`               | Do not use this case to test closed-start semantics  |

## Integration gaps and non-decisions

The supplied public interface brief identifies no semantic declaration API or
implemented semantic engine. Current `scribe.apply` is one operation, and RPC
request arrays do not establish a candidate transaction. Its reported cycle
coverage and save recovery must be qualified through native consumer probes.
These are integration findings to investigate, not reasons to weaken D11/D13 or
the global DAG constraint.

Backend, query language, graph/index storage, provider ABI, process arrangement,
and exact public API remain open. No backend selection or production engine
belongs to Gate 1. Initial provider/helper ownership is proposed as
consumer-side; promotion to the library is separately reviewed. Performance
workloads are not latency promises.

## Approval and subsequent changes

Record a user decision by decision ID, exact ruling, date, and affected
scenarios. Do not change this status based on worker interpretation. Approval
can accept, reject, or replace a proposal; only then may executable semantic
tests consume those expected outcomes.

After behavior approval, each change request records finding and evidence,
classification (implementation bug, interface gap, contradictory fixture, or new
requirement), exact proposed delta, affected cases/layers/artifacts, and a
pending/approved/rejected user decision. A missing API can justify changing an
interface while retaining behavior. Removing a failing expectation is not a
successful implementation.
