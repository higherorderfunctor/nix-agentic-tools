Situation: drawn base corpus with the rejected edit applied; the baseline
provider binding is ["sleep", "5"] with timeoutSeconds 1. Change: candidate sets
I0.FLAG to ["true"] (the edit that would violate preserve against S1); the
provider fails before any snapshot is usable. Expected: baseline-preserved is
`error` with causes ["model:reference/input:baseline"] and one non-leaf finding,
code `execution`, uid/occurrence/occurrenceIndex/predicatePath/kind all null,
evidence {input, reason, requires: []}. Envelope `baseline` is null, envelope
status is error, and the preserve verdict for the FLAG edit is never reached.
Why: "timeout ... is an execution error for every rule declaring that input"
(contract.md:523-525); timeoutSeconds is "a positive finite number of seconds"
(contract.md:513-514). Input acquisition is checked before dependencies, "so
every rule declaring a failed external input reports error"
(contract.md:756-758); "Missing candidate data or unusable required values must
report cannot-evaluate findings, never satisfied by omission"
(contract.md:758-759). Note: the other ten rules do not list this input, so they
keep their base-sample results; only the envelope status changes. provenance:
E05
