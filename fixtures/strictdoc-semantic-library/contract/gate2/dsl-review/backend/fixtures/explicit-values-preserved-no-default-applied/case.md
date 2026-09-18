Situation: the drawn base tree with the packet baseline S1 protecting I0.
Change: create N0 (explicit FLAG ["true"]) under F1 with created child N0a
(["false"]), and N1 (explicit FLAG ["false"]) under F1 with created child N1a
(["false"]); old F1a owns R -> N0a at occurrenceIndex 1 and R -> N1a at
occurrenceIndex 2. created lists all four. Expected: R.all violated, so the
envelope is violated and the candidate is rejected. Its four findings run in
occurrenceIndex then predicatePath order: index 1 target-type satisfied; index 1
visible-target VIOLATED with code closed-boundary, path ["F1a","F1","N0","N0a"],
walkedPath ["F1a","F1","N0"] and boundary "N0"; index 2 target-type satisfied;
index 2 visible-target satisfied with the full walkedPath and boundary null.
Why: the violated arm exists only if N0 kept its authored "true" — a present
list is never overwritten, even when empty or invalid (contract.md:890-891) —
and a closed departure that excludes the original origin violates the path rule
and is its boundary (contract.md:311-313). The satisfied arm shows an explicitly
authored "false" is neither re-defaulted nor treated differently from a
materialized one (contract.md:306-310). Rule status aggregates the subjects'
expression statuses (contract.md:589-590); finding order is contract.md:580-583.
Contract conflict: the catalogue's "explicit empty string on a string field"
(scenarios.md:128) is not expressible in this packet. UID is the only declared
string field, contract.md:439 forces `fields.UID` to be the one-item list
containing `uid`, and contract.md:434 requires that uid to be nonempty; FLAG
[""] would be an unlisted choice (contract.md:962-964), an input error, carried
by the sibling fixture invalid-value-multiplicity-errors-never-defaulted, not a
preserved explicit value. That arm is dropped rather than faked. "Later explicit
assignment after creation" is carried by N1's final present value, because only
the final batch state is evaluated (contract.md:449-450).

provenance: DFT02
