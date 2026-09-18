Historical initial review. All findings below were resolved in the
[final review](consumer-readme-review.md).

# Consumer README review

Reviewed `/tmp/strictdoc-consumer-walkthrough-20260914/README.md`, frozen at
SHA-256 `23799030ac4259a531a6e31ee92ce8b94dbadbbf017162203d5c3fa29fe4a722`. Line
numbers below refer to that version. This is a bounded documentation review, not
an implementation or semantic design review.

## Findings

1. **P2 — the Rego lesson still depends on hidden program definitions (lines
   700–721, 765–773).** The visible rules reference `parents` and `children`,
   but neither is defined inline. The JSON result additionally includes
   `protected_changes` and `snapshot`, whose result construction is absent from
   the shown program. Line 719 explicitly delegates these definitions to the
   linked program. Calling the fence “core rules” avoids falsely claiming it can
   run alone, but does not meet the user's stronger requirement that complete
   teaching inputs and outputs be understandable from the README itself. Include
   the complete small program needed to derive this exact result from this exact
   JSON, with the linked experiment serving as provenance. No proposed public
   adapter or schema is needed to fix this gap.

2. **P2 — preservation has no visible policy definition connecting its example
   to evaluation (lines 862–916, 961–974).** The README teaches the desired
   projection in prose and registers a source whose `projection` is an input,
   but never shows the existing proposed `p.preserve` call or the corresponding
   projection descriptor. Composition later takes `preservationRule` as an
   unexplained supplied value. Consequently a reader can understand the truth
   table but must leave the page to discover how the declared `protected` source
   becomes that rule's baseline or how to express the whitelist. Inline the
   already-proposed projection and preservation helper binding from the allowed
   contract, keeping the typed Boolean extraction limitation explicit. This
   requires neither inventing Boolean syntax nor claiming a working adapter.

3. **P2 — native tailoring omits its constructible grammar despite describing
   the document and bundle as complete (lines 429–470).** The adaptation SDoc
   and policy bundle are shown, but their grammar exists only as a prose list of
   fields and relations. This is an avoidable missing input: this example uses
   only currently supported string fields and Parent/Child constructors, so the
   unresolved Boolean API does not prevent a full normalized grammar snippet.
   Include REQUIREMENT and ADAPTATION elements with explicit required UID,
   STATEMENT, and the two native relation constructors. Omit `relations` for
   REQUIREMENT, consistent with the README's normalized validation warning at
   lines 172–173; do not copy the declaration catalog's empty-list form.

## Other conclusions and limits

The reviewed visibility and bridge outcome rows agree with the allowed contract.
The text retains authored ownership separately from normalized connectivity, the
all-role DAG obligation, immutable per-evaluation inputs, before/main
distinction, complete final-candidate validation, and qualified recovery. It
does not invent a Boolean field API, substitute grammar metadata booleans for
document values, or promote Cozo to a supported adapter. Enabled-only dependency
packaging is explicit and honestly marked as unfinished.

The independent Python snippet clearly distinguishes educational local data from
the public protocol. Proposed and existing capabilities are generally separated
carefully. I found no additional material behavior change or unsupported
integration claim within the permitted evidence.

Read scope: the four authorized Gate 2 contract files; neutral fixture
devenv.nix, devenv.yaml, grammar.nix, and seed.sdoc; the normalized surface
evidence; the frozen README and its EVIDENCE.md handoff. No historical grammar,
semantic implementation, spec/plan corpus, or coordinator scratchpad was read.
No Git, network, builds, broad tests, or snippet execution was performed. The
parent is separately checking snippet execution/syntax and links. References
outside the allowed source list were not opened or independently verified; the
planned recommendation.md destination is intentionally pending publication.
