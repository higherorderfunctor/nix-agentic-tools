Situation: the drawn base tree plus one created isolated FOO N0 with no FLAG
key, so a value must be prepared for it before validation. The candidate is
byte-identical across all seven variants; only the provider binding moves.
Change: invocation.json's binding for model:reference/input:baseline changes per
subdirectory — empty-complete-snapshot-is-a-value (success),
provider-nonzero-exit-refuses, provider-timeout-refuses,
provider-malformed-output-refuses, provider-empty-stdout-refuses,
provider-non-object-json-refuses, provider-missing-identity-refuses. Expected
(success): an empty complete snapshot is a real captured value, not a failure
and not absence — baseline-preserved satisfied with evidence baseline
"baseline-empty" and differences [], envelope baseline "baseline-empty",
envelope satisfied (contract.md:526-528). Expected (each failure):
baseline-preserved is error, never violated and never vacuously satisfied, with
causes ["model:reference/input:baseline"] and one non-leaf finding whose uid,
occurrence, occurrenceIndex, predicatePath and kind are all null, code
`execution`, evidence naming the input ID, a reason and requires []. Envelope
baseline null, envelope error, and the other ten rules keep their results
because they declare only `candidate` (contract.md:523-525, contract.md:660-661,
contract.md:569-570, contract.md:817, contract.md:757-760). Why this mapping:
the contract defines NO script-sourced default. semanticTypes carries only
`default: null` or `{ "literal": false }` (contract.md:972-974), and the one
external provider it binds is the baseline snapshot (contract.md:500-531). The
family therefore states the decidable halves — "empty is a value, not absence"
and "a refused acquisition refuses preparation with provider evidence rather
than substituting a default" — over the provider that exists, and asserts that a
refusal publishes nothing, since acceptance requires a satisfied envelope
(contract.md:665). Mixed — the runtime obligation this fixture does NOT cover:
that a default-source script is actually executed, that {status:ok,value:""}
stores the empty string as the field value, and that its native empty
serialization round-trips. Its default kind, its wire shape and its
provider-evidence fields are undefined in the contract, so no expected envelope
can be written for them. Overlap to dedupe: the sibling fixture
provider-execution-error-family already covers nonzero-exit, timeout and
malformed-output over a different candidate; the three variants here restate
them over a created record that is awaiting a default. Disputed: the verifier
reads those three as removable, because the union of the two families would
still cover every provider mode and any one remaining variant carries the
fill-while-acquisition-fails content. They are kept. The catalogue row this
family is graded against enumerates nonzero exit and timeout by name
(scenarios.md:130), while the sibling family is graded against a different row
over a candidate with no record awaiting a fill, so deleting them would leave
this row's two named modes resting on a fixture that does not assert them. The
contract says nothing about redundancy between fixtures, so this is a curation
call and not a contract question. Ambiguity: `reason` sits inside a normative
evidence object (contract.md:575-578) but the contract never fixes its text, so
the six failure variants differ normatively only by a string this packet
invents. The rule-level finding itself is also inferred: the contract mandates
the error status and causes but not that an erroring rule emits a finding, and
the execution evidence of contract.md:639 can only travel inside one.

provenance: DFT04
