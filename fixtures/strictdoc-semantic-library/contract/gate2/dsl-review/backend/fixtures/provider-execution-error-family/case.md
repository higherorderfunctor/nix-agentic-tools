Situation: the candidate is the rejected-edit candidate (I0.FLAG ["true"]) that
would violate baseline-preserved against S1, a successful complete snapshot
protecting isolated FOO I0 with FLAG ["false"] (identity baseline-I0-open). No
variant here delivers S1: the baseline provider fails, four ways. Change:
candidate.json is unchanged across the four variants; only invocation.json's
binding for model:reference/input:baseline changes. One subdirectory per
variant: nonzero-exit, timeout, malformed-output, incomplete-snapshot. Expected
(all four): baseline-preserved is `error`, never `violated` and never vacuously
satisfied. Its entry carries causes ["model:reference/input:baseline"] and one
non-leaf finding — uid, occurrence, occurrenceIndex, predicatePath and kind all
null — with code `execution` and evidence naming the input ID, the failure
reason, and requires []. Envelope `baseline` is null and envelope status is
error. The other ten rules do not declare this input, so they keep their
base-sample results.

Why: "Nonzero exit, timeout, malformed JSON or shape, missing identity, or
missing/false complete is an execution error for every rule declaring that
input" (contract.md:523-525); "Provider failures make each input-consuming rule
error with the input ID in causes" (contract.md:660-661); the code is
`execution` (contract.md:817); `baseline` is "null if capture failed"
(contract.md:569-570); error dominates the envelope status
(contract.md:663-664).

Ambiguity: the contract mandates the rule status and the causes list but never
says a rule-level error emits a finding. These fixtures emit one, because the
evidence table requires `reason`, `input` and `requires` for an execution
failure (contract.md:639) and evidence can only travel inside a finding; the
non-leaf shape follows contract.md:621-622.

Disclosed gap: the catalogue asks for "provider/source identity and failure
kind" (scenarios.md:74), and these fixtures report the source identity only as
the input ID `model:reference/input:baseline`, never as a snapshot identity. The
failure kind travels in `reason`, which is free text under contract.md:639 and
therefore not itself a normative discriminator between the four variants; `code`
is `execution` for all four. Only the incomplete-snapshot variant ever produced
a snapshot identity at all — its baseline.json declares "baseline-partial" — and
that string is discarded: the execution evidence row lists `reason`, `input`,
`requires` "plus available record/field/occurrence details" (contract.md:639), a
snapshot identity is none of those, and evidence is compared whole
(contract.md:575-577), so adding an `identity` key would require it of every
conforming backend on the strength of a row that does not list it. The envelope
cannot carry it either: `baseline` is null whenever capture fails
(contract.md:569-570). This is a deliberate choice, not an oversight — closing
it needs a contract change (an `identity` entry in the execution evidence row),
not a fixture edit.

provenance: E05
