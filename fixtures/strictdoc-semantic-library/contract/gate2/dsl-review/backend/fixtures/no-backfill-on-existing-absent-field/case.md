Situation: the drawn base tree; I0 stays untouched under the packet baseline S1.
Change: remove the FLAG key from OLD record F0, which is not in created; make
the unrelated edit F2b.FLAG = ["true"]; add old F1a an owned R -> F2 at
occurrenceIndex 1. created = []. Expected: one envelope finding, uid F0, status
error, code `input`, evidence present false — F0 is never backfilled and no
default is acquired for it. R.all is blocked: target-type satisfied (F2 resolves
to FOO), visible-target blocked with code `input`, boundary "F0", path
["F1a","F1","F0","F2"], walkedPath ["F1a","F1","F0"], entry causes
["/findings/0"]. Every other rule keeps its base result, because neither
one-H-parent nor H-forest reads FLAG, and the F2b edit is inert with no path
through it. Envelope error: the final absence alone rejects the candidate. Why:
creation defaults never apply to old records (contract.md:891-892), and an old
candidate record still lacking required FLAG is invalid even when it matches the
baseline (contract.md:894-896); editing another field or moving a record does
not change that, since the absence is judged on the final state
(contract.md:449-450); the descent from F0 needs its FLAG and an absent value
blocks the occurrence (contract.md:310-311, contract.md:814); the envelope takes
the worst status and acceptance requires satisfied (contract.md:663-665).
Discriminator: contract.md:667-685 states this exact F1a R -> F2 occurrence as
SATISFIED when F0 carries ["false"], so a backend that backfills an old absence
turns this fixture green. Ambiguity: the envelope field-validation finding here
uses the same invented evidence key set {field, input, present, reason,
requires, values}, and the same candidate-record ordering of the envelope
findings list, as the sibling fixture
invalid-value-multiplicity-errors-never-defaulted, whose case.md states that
ambiguity in full: the contract declares the whole evidence object normative
(contract.md:575-578) while fixing neither those keys nor that order. Neither
fixture is the settled one; both carry the same unratified choice.

provenance: DFT05
