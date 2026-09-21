Situation: the drawn base tree with the packet baseline S1 protecting I0.
Change: create six FOO records — N1 (FLAG ["maybe"]) under F1 with created child
N2 (["false"]), and isolated N3 (["TBD"]), N4 (["TBC"]), N5 (FLAG []), N6 (FLAG
["false","true"]) — and give old F1a an owned R -> N2 at occurrenceIndex 1. All
six are in created. Expected: five envelope findings in candidate record order
(N1, N3, N4, N5, N6), each status error with code `input` and the offending
values in evidence — never a substituted "false" and never a replacement
default. R.all is blocked: target-type satisfied, visible-target blocked with
code `input`, boundary "N1", path ["F1a","F1","N1","N2"] and walkedPath
["F1a","F1","N1"]; the entry carries causes ["/findings/0"]. The other ten rules
keep base results, only gaining count findings for the six new records. Envelope
error, so nothing is accepted. Why: `[]` and multiple strings are present values
and a scalar present list must hold exactly one string (contract.md:436-439); a
required singleChoice needs one listed choice (contract.md:962-964); a present
list is never overwritten by the creation default (contract.md:890-891); field
errors are recorded even where no rule reads them, and only subjects needing the
value are blocked (contract.md:655-659); an invalid FLAG at a needed departure
blocks that occurrence under code `input` (contract.md:310-311,
contract.md:814); causes may be envelope JSON Pointers to candidate input
findings (contract.md:625-628). Ambiguity: the contract fixes neither the
evidence key set of a field-validation finding nor the order of the envelope
findings list, while declaring the whole evidence object normative
(contract.md:575-578). These fixtures use {field, input, present, reason,
requires, values} — the blocked/input evidence row (contract.md:639) plus the
present/values pair the preserve row already uses (contract.md:638) — and order
envelope findings by candidate record position, by analogy with
contract.md:580-581.

provenance: DFT03
