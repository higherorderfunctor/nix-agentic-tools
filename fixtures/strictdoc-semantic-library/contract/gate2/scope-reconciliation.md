# Scope reconciliation

The 2026-09-15 user handoff supersedes conflicting older Gate 2 scope. The
revised contracts preserve the reviewed behavior while changing authoring,
types, defaults and invocation boundaries. Exact interface spellings remain
proposed. Gate 2 ends with human review; production implementation and
advancement to Gate 3 require a subsequent user decision.

## Superseded obligations

- Public cross-call begin/stage/seal/abort, participant registration, readiness,
  seal authority, membership/takeover, revisioned contributor coordination and a
  generic lifecycle framework are removed from the initial requirement. One
  invocation carries an ordered atomic operation list.
- The old prohibition on a common mandatory Nix configuration boundary is
  replaced by fully Nix-configurable backend-agnostic contracts, registrations,
  inputs and results. Consumer DSLs and shipped helpers use the same public
  route.
- The unresolved Boolean-gap-only posture and requirement to preserve the old
  upper policy DSL are replaced by a distinct validated semantic-type layer and
  a new readable constraint DSL. Existing native grammar normalization/emission
  remain.
- Validation side-effect bans are replaced by read-only identified authoritative
  inputs and writable derived caches/scratch with dependency-precise identity.
- Rejection-as-document-rollback wording is replaced by discard of an
  unpublished private candidate. Restore-or-block applies to actual publication
  failure.
- Combined README teaching/setup and old `p` helper spellings are superseded by
  separate tutorial, setup and interface responsibilities and provisional
  `s`/`c` authoring.

## Retained and newly explicit obligations

- Preserve the native all-role Parent/Child DAG, contextual ownership/type/role,
  multiple selected roots, selected forest cardinality, original-origin nested
  visibility, unchanged-reference invalidation, BAR connectivity and
  endpoint/path rules, and explicit field/custom alternatives.
- Keep before, candidate, complete identified baseline and captured facts
  distinct. Retain model/document/change checks, explicit trust, consumer
  protection projections and Git staged-tree checks.
- Preserve RuleResult/Finding statuses, useful evidence, complete result
  accounting, aggregate/admission distinction, checked composition, explicit
  replace/disable and independent implementations.
- Capture a stable base, apply ordered mutations privately, default newly
  created still-absent fields, freeze effective inputs, complete native and
  semantic validation, then report dry-run or publish exactly that candidate. Do
  not replay operations or rerun defaults; include move paths and document
  membership.
- Typed literal/runtime-script creation defaults preserve false/empty, reject
  invalid supplied values and provider failure, resolve once per candidate,
  never backfill existing records and never acquire values during Nix
  evaluation.
- Refuse stale bases. Ordinary refusal and dry-run leave authoritative files and
  observable model unchanged. Publication failure restores or blocks, with
  explicit crash and external-reader limits.
- C1–C4 retain schema/conformance, public backend equivalence, real
  Nix-to-Scribe refusal/reload/publication and packaging/native integration
  intent, with revised dependency-ordered implementation scope.
- Historical measurements and archived alternatives remain unchanged. Retain the
  Python/rustworkx direction and optional OPA/Cozo consideration without
  reopening the research comparison. Include dependencies only for enabled
  implementations; syntax/prototypes do not prove runtime integration.
- Final neutral cleanup and verified human/steering recipes remain later
  obligations. This revision covers proposed contracts and bounded design
  evidence, not production implementation or automatic advancement beyond
  Gate 2.

## Evidence limits and retained findings

The public source report identifies revision
`6f529c7eef3650a14b6f8d56ff1bc3ceaa914d7f` and reports matches for all five
handoff blob IDs. Source inspection is distinct from runtime execution. It does
not establish the new candidate path, concurrency isolation, publication
recovery or semantic enforcement.

The later implementation plan retains the observed construction and validation
seams: required-field/empty-string creation incompatibilities, native
`TBD`/`TBC` acceptance requiring explicit Boolean rejection, mutable
reader/index state, move outside the publication boundary and repeated rendering
at save. These are source findings, not reproduced runtime failures.

The public DSL vocabulary uses `g`/`s`/`c`, semantic Boolean fields/defaults,
contextual named constraints, explicit bridge counts/singletons, named
forest/visibility views and contribution lists. Metadata/default nesting,
key-derived identities, finite predicate IR and specialized lowering are
recorded in the interface. Evaluated lowering remains distinct from installed
exports and complete runtime implementation. The historical recommendation and
findings retain their original measurements and evidence boundaries behind
explicit historical notices.

## Implementation review and coverage

Remaining implementation freeze questions concern cross-language digest
canonicalization, source coordinates, ID escaping, generic predicate operand
schemas and the small runtime default ABI. They do not reopen accepted behavior.
C1–C4 preserve their intent with the new type/default/candidate dependencies;
the closing plan orders later implementation and qualification.

The scenario catalogue retains all 44 original case IDs and all 15 visibility
truth rows. DFT01–DFT07 and A01–A11 add 18 future contract controls, not
integration claims. The next human review determines whether to revise the
examples further or authorize a later gate. A successful prototype or completed
review packet does not authorize that transition.
