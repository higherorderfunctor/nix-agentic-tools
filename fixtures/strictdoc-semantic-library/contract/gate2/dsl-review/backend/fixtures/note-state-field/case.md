Situation: a second model, authored by `model.nix` beside this note and lowered
into the `bundle.json` every member is evaluated against. One element NOTE
carries a required UID and an OPTIONAL STATE choice field over draft, final and
retired, plus one parent relation SOURCE. A note cites the source it replaces.
There is no view, no external input and no projection, so nothing in this family
can be blocked by a prerequisite and every verdict is attributable to the leaf
under test.

Situation: STATE is optional on purpose. A required absent field is already an
envelope input error and blocks (contract.md:298-302), so a required STATE could
never exercise the leaf's `absentSatisfies` flag, which is the one outcome no
envelope finding describes.

Change: each member is a whole candidate of its own rather than a change to a
shared base corpus. Every candidate carries model "notes" and `created: []`, and
uses at most two record uids: `report`, the citing note, and `outline`, the note
it cites.

Expected: three rules, in bundle order. `SOURCE.field-value` reads the EDGE
TARGET's STATE over the SOURCE occurrences and admits final, retired or absence.
`retired-notes-cite-a-source` filters the NOTE records to STATE retired with a
field-value `where` and then counts SOURCE occurrences at least one.
`drafts-cite-nothing` takes `any` of a negated field-value on draft and a SOURCE
count of zero. Each rule has `requires: []` and `inputs: ["candidate"]`.

Expected: every member's envelope `baseline` is null. This bundle declares no
external input, so there is no capture to report (contract.md:624-625).

Why: the leaf, its five JSON fields and its codes are the field-value row of the
named-leaf table; the subject tokens record, owner and target are the ones
`from` and `to` already use (contract.md:286-288, contract.md:830-833).

Disputed: the bundle resolves by nearest ancestor, so these members inherit the
`bundle.json` and the `{"inputs": {}}` invocation configuration authored in this
directory rather than the packet's. contract.md:565-573 describes one packet and
says nothing about a tree carrying more than one model. The empty inputs object
is load-bearing: without it these members would inherit the packet binding for
`model:reference/input:baseline`, an input this bundle does not declare.

Disputed: `note-without-a-state-is-not-retired-accepted` records an entry as
satisfied while its own filter finding is violated, reading contract.md:661-662
together with contract.md:647-648. `results.json` exercises no `where`
(contract.md:768-773), so this family is the first to pin it.

provenance: field-value leaf design, gate 2 DSL review
