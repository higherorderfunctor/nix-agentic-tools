Situation: drawn base corpus; isolated old record I0 carries FLAG ["false"]; the
baseline provider returns S1 (identity baseline-I0-open, complete, protecting I0
with FLAG ["false"]). Change: set I0.FLAG to ["true"]. No record is created or
deleted, so `created` stays empty. Expected: baseline-preserved is violated —
one model finding (uid null) reporting a FLAG difference on protected uid I0,
before present ["false"] and after present ["true"], under baseline identity
baseline-I0-open. Every other rule keeps its base-sample result: I0 owns no
relations, so H.target-type, one-H-parent, native-dag and H-forest are
unaffected, and the envelope is violated. Why: preserve compares "every
baseline-listed uid with the final candidate; missing records and changed
projected facts violate" (contract.md:245); the projection selects FLAG and
"Compare present field lists exactly as native strings, without defaulting or
semantic coercion" (contract.md:347-348); the violated code is `difference`
"with nonempty differences" (contract.md:812); the envelope status is the worst
across findings and rule entries (contract.md:663-664).

Also covers the catalogue's identity-switch row (scenarios.md:72), and only
partly. That row starts from a candidate already accepted under S0 (successful,
complete, empty) and switches the provider to S1 without an SDoc edit; it
asserts that the mismatch is reported under the new source identity and that the
prior S0 success is invalidated. With the switch already applied, the evaluation
that row describes has exactly this packet's inputs — same candidate bytes,
captured identity baseline-I0-open — so the same violated verdict and the same
evidence. Nothing in the contract carries an earlier verdict forward: the
envelope records "the captured baseline identity" (contract.md:569-570) and
preserve compares the candidate against whatever snapshot this evaluation
captured (contract.md:245, contract.md:529-531). "Prior success is invalidated"
is therefore a statement about a SEPARATE earlier evaluation, and one
results.json describes one evaluation. A dedicated fixture for that row existed
and was byte-identical to this one apart from its `evaluation` string, so it
read as coverage while discriminating nothing; it was removed and folded in
here. Asserting the invalidation itself needs an ordered pair of envelopes over
one working directory, which the packet shape — one candidate, one binding, one
results.json (contract.md:511-517, contract.md:565-573) — cannot carry.

provenance: E01; E03
