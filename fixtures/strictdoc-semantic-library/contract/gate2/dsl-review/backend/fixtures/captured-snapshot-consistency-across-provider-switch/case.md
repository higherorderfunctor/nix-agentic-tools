Situation: drawn base corpus. The provider is stateful within one evaluation:
its first invocation prints S1 from baseline.json (identity baseline-I0-open,
complete, protecting I0 with FLAG ["false"]) and marks a scratch directory
OUTSIDE the packet; any further invocation from the same parent process prints
S0, the empty complete snapshot (identity baseline-empty). Change: set I0.FLAG
to ["true"]; `created` stays empty. Only the provider binding differs from the
plain rejected-edit case.

Expected: this evaluation captures S1 once and uses it throughout.
baseline-preserved is violated — one model finding (uid null), code
`difference`, evidence baseline "baseline-I0-open" and one difference on uid I0
for model:reference/element:FOO/field:FLAG, before present ["false"], after
present ["true"]. Envelope `baseline` is "baseline-I0-open" and envelope status
is violated. The other ten rules keep their base-sample results.

Why: "Capture one identified immutable snapshot per evaluation and reuse it
throughout; a provider change affects the next evaluation, never a later rule in
this one" (contract.md:529-531), and the command is invoked "once without stdin"
(contract.md:520). Only baseline-preserved declares this input, so S0 is never
seen here even though the script would now answer it. What the switch buys over
the plain rejected-edit case is a detectable failure for a backend that invokes
the command more than once and keeps the later snapshot: it would capture S0,
find nothing protected, and report baseline-preserved satisfied with envelope
`baseline` "baseline-empty". candidate.json, baseline.json and results.json
already match flag-change-rejected-under-protecting-baseline byte for byte apart
from the `evaluation` string, so invocation.json is the whole of this fixture's
independent discriminating power and a non-switching S1 provider would collapse
it into that case.

Harness requirement: the marker is a directory at
${TMPDIR:-/tmp}/gate2-provider-switch-$PPID, honored only while it is under two
minutes old. The packet directory is therefore never written to, and a later
evaluation in a fresh process captures S1 again, so re-running this packet in
place is idempotent. Two properties the harness must supply: each evaluation of
this packet runs in its own process, because the state key is the provider's
parent pid; and this packet is not evaluated twice from one parent process
within two minutes. When the first property does not hold, the provider answers
S1 every time and the authored expectation still passes — the fixture loses
discriminating power rather than reporting a false failure. When the second does
not hold, the repeat evaluation captures S0 and fails spuriously.

Contract gap — not a result-shape defect, recorded here because contract.md is
read only for this section: contract.md:515-516 fixes the invocation working
directory as the packet directory, and invocation.json carries exactly `command`
and `timeoutSeconds` (contract.md:511-517). Nothing obliges the runner to give
each evaluation a fresh copy of the packet, and no field lets a fixture declare
a writable scratch path. Any provider that must remember something across
invocations therefore either writes into the read-only contract tree or keys its
state outside the packet, as this one does. The durable fix belongs in the
harness contract: copy each packet to a fresh temporary directory per
evaluation, or add a per-evaluation scratch path to the invocation schema. An
earlier form of this fixture ran `: > provider-state` in the packet directory;
it returned baseline-empty on every run after the first, so its authored
results.json was wrong from run 2 onward, and it left an untracked file inside
the contract tree.

Mixed — not covered here: the second, intentionally retried evaluation that
would capture S0 and commit. Under this binding it needs the marker to already
exist, fresh, for that evaluation's provider parent pid — no packet field can
arrange that, and one results.json describes one evaluation anyway. This fixture
therefore asserts only the reject-using-S1 half.

provenance: E06
