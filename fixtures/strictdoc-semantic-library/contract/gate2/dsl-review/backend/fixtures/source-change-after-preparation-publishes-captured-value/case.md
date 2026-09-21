Situation: the drawn base tree plus one created isolated FOO N0 with no FLAG
key, so a value must be prepared for it before validation. The provider is
stateful: its first invocation cats the local baseline.json — the packet
snapshot baseline-I0-open, protecting I0 at FLAG ["false"] — and drops a marker
file; every later invocation prints baseline-I0-closed instead, which protects
I0 at FLAG ["true"]. Change: nothing in the drawn records moves. I0 keeps
["false"] and created is ["N0"]. Expected: all eleven rules satisfied and the
envelope satisfied. baseline-preserved emits its one model finding with evidence
baseline "baseline-I0-open" and differences [], and the envelope baseline is
"baseline-I0-open". N0's absent FLAG is filled once and produces no envelope
field-validation finding; H.target-type stays at 6 findings and one-H-parent
gains N0 at count 0 (10 findings). Why: one identified immutable snapshot is
captured per evaluation and reused throughout, and a source change affects the
next evaluation, never a later rule in this one (contract.md:529-531); the
command is invoked once without stdin (contract.md:520); the captured identity
is echoed into the envelope (contract.md:568-570) and repeated inside the
preserve evidence (contract.md:638). Discriminator: the preparation sits between
capture and validation here, because the fill happens after all explicit batch
edits and before any validation (contract.md:888-890), so a backend that
re-consults the source while preparing the default, or once more when comparing,
captures baseline-I0-closed and reports a difference on I0 — before ["true"],
after ["false"] — giving a violated envelope and the wrong identity in both
places. The sibling fixture captured-snapshot-consistency-across-provider-switch
catches a re-consulting backend in the opposite direction, by false ACCEPT of an
edit that the first snapshot protects; this one catches it by false REJECT of a
record nobody touched, which is why both directions are kept. Mixed — the halves
this fixture does NOT cover: "a later explicit invocation is a new preparation"
needs a second harness run against the same working directory, since the marker
file is what carries the state and one results.json describes one evaluation.
The catalogue row is written about a default-value source, and the contract
binds no such provider — semanticTypes carries only `default: null` or
`{ "literal": false }` (contract.md:972-974) and the one external provider it
declares is the baseline snapshot (contract.md:500-531) — so the row's decidable
half is stated over the provider that exists.

provenance: DFT07
