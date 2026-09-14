# Delivery obligations across the remaining gates

This is the coordinator's sequencing and completeness record, not an interface
design or implementation authority. Gate 2 is authorized. Each later gate still
requires human review. The final comparison must preserve these obligations
without presenting unimplemented examples as working APIs.

The complete [reviewed requirements](reviewed-requirements.md) remain governing
input at every gate. This plan incorporates them by reference; its grouped
checklist does not replace their detailed truth tables, projections, failure
distinctions, or work boundaries. Earlier requirements remain in force unless
the user explicitly changes them. Report unresolved semantic ambiguities in the
review package.

Workers use fresh contexts and explicit read boundaries, not a claimed
filesystem sandbox. Their only semantic inputs are the approved packet, neutral
reference cases, and filtered public toolchain; no prior grammar, semantic
module, spec/plan corpus, or coordinator scratchpad. Ideal and tool-informed
paths cannot exchange prompts, drafts, research, or outputs before comparison.
Use Astra with explicit effort, save milestones, format edited files, and
coordinate serial Nix builds. No broad builds, JVM, SSH key management, approval
UI implementation, or private-key reads. SQLite remains strongly disfavored
rather than prohibited; Python, Node with Bun preferred, and Rust remain
eligible. Workers do not publish externally; the coordinator handles the already
authorized review branch.

## Additional user requirements for design review

- Make the review README self-contained with inline examples that explain the
  recommended declaration and its behavior; linked supporting files do not
  substitute for that walkthrough.
- Preserve the existing normalized upper DSL as the authoring surface. Resolve
  the Boolean document-field declaration, encode/decode and metadata contract at
  design review, including the proposed all-String snapshot representation.
  Grammar booleans for `required` and `isComposite` do not satisfy that
  requirement. Do not invent an API while recording the gap; use the
  [public-surface evidence](normalized-authoring/README.md).
- Include runtime dependencies only for enabled backends, and verify the
  resulting dependency closures during implementation and qualification.
- Retain the Cozo experiments for consideration as an optional adapter. The user
  is open to additional backends; this does not adopt Cozo or change the current
  backend recommendation.

## Current review package

- Preserve the ideal interface proposal before comparing it with tooling
  research. Preserve the tool-informed proposal with evidence that its worker
  did not receive the ideal proposal.
- Provide a concrete recommended consumer declaration and public extension
  contract, with the alternative proposals available for comparison.
- Explain the backend recommendation using measured experiments, exact versions,
  primary sources, positive and negative controls, and unresolved limits.
  Separate upstream guarantees from installed Scribe integration behavior.
- Show how every packaged adapter uses the same public extension mechanism
  available to a consumer. Identify any proposed privileged path or missing
  equivalent lower-layer route explicitly.
- Map all reviewed behavior families to interface examples and later executable
  evidence. A missing behavior cannot disappear because a candidate tool does
  not support it.
- Prepare human-readable recipes and steering-ready content for every family.
  Mark proposed syntax and unimplemented behavior clearly. Final runnable
  recipes are a later delivery obligation.
- Save experiment commands and small inputs/results needed for reproduction.
  Exclude downloaded dependency trees, build outputs, private environment
  details, and unrelated source from any tracked review package.
- End with the next human review. Do not implement Gate 3 based on a successful
  prototype.

## Gate 3: first complete slice

Implement through a fresh-context workflow after approval: declare a target-type
restriction through public Nix configuration, generate the necessary artifacts,
exercise a real Scribe mutation, observe rejection with a useful diagnostic,
prove unchanged authored and held state on refusal, and verify reload. A
JSON-only validator or private function call is insufficient integration
evidence.

Reconcile the recommended API with the reviewed declaration before
implementation. An implementation constraint can produce a proposed interface
change; it cannot silently redefine the approved behavior.

## Gate 4: hard semantic and boundary slices

Track the selected forest and contextual roles, origin-sensitive visibility,
unchanged-edge revalidation after moves/closures, native Parent/Child tailoring,
alternative field/custom logic, grouped final-candidate validation, external
snapshots, and provider failures. Native full-graph acyclicity remains an
integration obligation even if upstream already supplies the check.

Retain authored owner, target, type, role, and model context separately from
normalized connectivity. Reverse display names create no authored facts.
Document packaging creates no implicit ancestry. Preserve multiple selected
roots, nonselected native parents, and traversal without an arbitrary depth
bound. No fixture names or consumer policies may become core dispatch keys.

Validate consumer-selected daemon transactions, staged Git-tree hooks, and their
composition as distinct invocation boundaries. Preserve complete candidate
validity, explicit errors, before/baseline distinction, conflict handling for
parallel contributors, and honest rollback/recovery behavior. A database
transaction or serialized request list alone cannot satisfy the Scribe
publication contract.

Scheduling changes candidate capture and invocation, not rule meaning. Private
staging may be incomplete. Invalid inputs remain inspectable; the reference
requires complete valid repair, while alternative repair admission remains an
explicit consumer choice. Publication failure restores prior state or blocks
writes pending recovery, never reports false success. Per-evaluation snapshots
do not imply latest-at-publication freshness.

Identity, main-baseline protection, supersession, and human approval are
consumer policies. Required trusted facts must have an explicit
acquisition/trust contract. Do not treat an authored field, ordinary Git author
string, or request label as authenticated identity. SSH identity and a future
approval UI must fit the public extension design without becoming mandatory
engine policy.

## Gate 5: independent consumer challenge

Use a fresh worker with public interfaces and approved contracts only. Exercise
equivalent helper/direct/native authoring where equivalence is claimed, an
independently supplied backend/tool, and a consumer-owned helper. Record when a
representation deliberately changes native connectivity instead of claiming
false equivalence.

The older D15/X07 numeric descendant/external-limit challenge remains a separate
later review item. Keep it out of tonight's user-facing recap; do not silently
add fields to the retained core fixture.

## Gate 6: qualification

Run differential full/incremental mutation sequences with identical captured
inputs, reload/rebuild and cache deletion controls, provider/policy invalidation
without document edits, publication failure injection, and representative scale
measurements. Record cold and warm work separately. Performance is evidence, not
permission to weaken validity or omit rules.

Complete the acceptance matrix with results and honest gaps. Verify recipes
against actual exported APIs and normal consumer commands. Keep experimental
backend capability evidence distinct from production acceptance.

## Closure after the final gate, before folding back into trial

- Remove mandatory repository-specific field policy from generic Scribe.
  Exercise the intended repository policies through the public consumer
  extension interface.
- Remove every `AUTHORED_BY` and `PARENT_FP` declaration and content occurrence
  from the neutral fixtures. Do not substitute renamed equivalents of the same
  repository policy. Move historical evidence outside neutral fixture scope when
  necessary; preserve provenance elsewhere.
- Prove a neutral consumer works with neither field and no hidden repository
  grammar, semantic module, or spec/plan dependency.
- Deliver verified human Markdown playbooks and corresponding steering-ready
  content for every reviewed behavior family, including both native tailoring
  and a field/custom-logic example. Do not wire steering placement now.
- Keep the lightweight clean toolchain/fixture pattern suitable for future
  semantic examples and tests. Recheck its refresh and exclusion controls after
  changing its public implementation inputs.
- Do not migrate these documents into the SDoc canon yet. A later session can
  adopt repository semantics once the machinery exists.
- Provide a reviewable web diff of the completed branch chain. No merge occurs
  in this session.

## Review completeness matrix

| Behavior family                                | Gate 2 content                                                            | Later evidence                                                 |
| ---------------------------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------- |
| Target types and contextual relation selection | Concrete helper and direct declaration                                    | Real Nix-to-Scribe rejection and reload                        |
| Native graph and selected forest               | Distinguish native guarantees from selected constraints                   | Native/mixed-link controls and selected-parent counterexamples |
| Origin-sensitive visibility                    | Closed endpoint, inside-origin, nested boundary and move/closure examples | Nonlocal revalidation and full/incremental parity              |
| Intermediate tailoring record                  | Native Parent/Child ownership and downward-path example                   | Preserved authored ownership and graph witnesses               |
| Alternative field/custom logic                 | Explicit extension and limited equivalence claim                          | Consumer program through public registration                   |
| External facts and identity                    | Complete snapshot, failure, trust and baseline examples                   | Missing/empty/error controls and captured-input parity         |
| Consumer protection and approval               | Main baseline, human-protected documents, supersession extension points   | Repository policy outside generic runtime                      |
| Transactions, hooks and recovery               | Candidate acquisition and publication responsibilities                    | Grouping, conflicts, refusal, reload and failure injection     |
| Composition and replaceable backends           | Explicit replacement, capabilities, diagnostics and public registration   | Independent adapter/helper challenge                           |
| Documentation and neutral fixture              | Draft human/steering recipes and closure plan                             | Verified recipes and absence of repository-specific fields     |
