Situation: the drawn base tree — F0 open root, F1 open with child F1a, closed F2
with F2a/F2b, G0/G1, isolated I0, BAZ Z0 — with the packet baseline S1
protecting I0 at FLAG ["false"]. Change: create N0 under F1 with NO FLAG key,
plus its created child N0a (FLAG ["false"]), and give old F1a a second owned
occurrence R -> N0a at occurrenceIndex 1. created = ["N0","N0a"]. Expected:
every rule satisfied and envelope satisfied. R.all emits both leaves for F1a
index 1 — target-type satisfied, and visible-target satisfied with path
["F1a","F1","N0","N0a"], the same walkedPath and boundary null. That descent
departs from N0, so it can only be permitted if N0's final absence was filled
with the canonical native "false", i.e. open. H.target-type gains N0 and N0a (8
findings); one-H-parent gains both at count 1 (11 findings). No envelope
field-validation finding exists for N0's required FLAG. Why: absent defaulted
fields on surviving created records are filled exactly once, after all explicit
batch edits and before any validation (contract.md:888-890); the FLAG default is
`{ "literal": false }` and encodes through the Boolean codec to native "false"
(contract.md:932, contract.md:972-974); a downward departure decodes the
departure node's FLAG and an open node may expand (contract.md:306-310).
Discriminator: with no fill, N0 carries an absent required FLAG — an envelope
field-validation error (contract.md:655-656) — and the needed departure is
instead blocked with code `input` (contract.md:310-311, contract.md:814), so a
non-defaulting backend cannot produce this envelope.

provenance: DFT01
