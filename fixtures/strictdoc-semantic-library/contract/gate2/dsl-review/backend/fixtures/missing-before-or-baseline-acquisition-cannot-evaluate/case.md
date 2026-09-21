Situation: the drawn base corpus, unmodified and otherwise valid, with
`created: []`. `bundle.inputs` declares `model:reference/input:baseline` with
`required: true` and `complete: true`, and `baseline-preserved` lists it in
`inputs`. Change: `invocation.json` is `{"inputs": {}}` — the required baseline
input has no command binding at all, and no `baseline.json` is supplied. No
candidate record changes. Expected: `baseline-preserved` reports rule-level
`error` with `causes: ["model:reference/input:baseline"]` and one non-leaf
finding whose uid, occurrence, occurrenceIndex, predicatePath and kind are all
null, status `error`, code `execution`, and evidence naming the missing binding
in `reason`, the input ID in `input`, and `requires: []`. The envelope's
`baseline` is null because no capture succeeded. The ten candidate-only rules
are unaffected and keep the base expectation: `H.target-type` and `one-H-parent`
satisfied over all nine FOO records, `H-forest` and `native-dag` satisfied,
`R.all` and the four BAR rules vacuously satisfied with `findings: []`. Envelope
error. Nothing is silently substituted for the missing snapshot, and nothing
reports satisfied by omission. Why: "a missing command binding is also an
execution error." (contract.md:525); "Provider failures make each
input-consuming rule error with the input ID in causes." (contract.md:660);
"Check a rule's own input acquisition errors before dependencies, so every rule
declaring a failed external input reports error." (contract.md:756); "`baseline`
is the captured baseline identity, or null if capture failed or no baseline
input exists." (contract.md:569); "Independent rules continue, retaining their
own results." (contract.md:759). Reading taken: the execution failure is
recorded on the `baseline-preserved` entry and not duplicated as an envelope
finding, because the contract reserves envelope `findings` for candidate
preparation, shape and native field validation errors (contract.md:655) and
assigns provider failures to the input-consuming rule. Mixed scope: only the
missing-baseline-acquisition half is expressible. The row's other half —
invoking a transition comparison with no `before` snapshot — has no input
declaration, no leaf kind and no result field anywhere in this bundle or
contract, so no fixture can assert it until a `before` input is declared.

provenance: B09
