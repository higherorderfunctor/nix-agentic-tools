Situation: drawn base corpus; the baseline provider returns S0, the empty
complete snapshot
{"model":"reference","identity":"baseline-empty","complete":true,"records":[]}
(contract.md:526-528), which protects nothing. Change: the same edit as the
rejected case — set I0.FLAG to ["true"]; `created` stays empty. Expected:
baseline-preserved is satisfied vacuously — one model finding (uid null), code
`preserve`, evidence baseline "baseline-empty" and differences []. All other
rules match the all-satisfied base sample, and the envelope is satisfied. Why: a
complete snapshot with no records "is valid and protects nothing"
(contract.md:526-528), and preserve only "Compare[s] every baseline-listed uid"
(contract.md:245) — with no listed uid there is nothing to compare;
`complete: true` "requires a complete protected set, not a nonempty set"
(contract.md:497-498); satisfied preserve evidence is `differences: []`
(contract.md:601-602). provenance: E02
