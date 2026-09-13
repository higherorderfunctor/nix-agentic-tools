# Gate 2 contract consistency review

**No actionable findings.** The recommended declaration and public contract are
consistent for this bounded review. This conclusion covers proposed interfaces
and preservation of the reviewed constraints, not implementation readiness.

All six supplied input files were read in full. Linked research, repositories,
other workspaces and external sources were not consulted. Playbooks are still
being prepared and were not supplied; their absence is not a finding here.

## Contract correspondence checked

- **First target-type slice and lower-layer parity:** the helper's contextual
  selector and allowed element references match the direct rule's contract,
  configuration, candidate schema and resolved-endpoint capability
  (`inputs/interface.md:20–35,77–84`;
  `inputs/recommended.nix:24–29,61–65,153–165`). Wrong resolved types violate;
  unresolved endpoints are input errors. The independent target entry accepts
  that same candidate schema, and the explicit per-rule binding takes precedence
  over the graph contract binding without creating two assignments
  (`inputs/interface.md:63–75`;
  `inputs/recommended.nix:199–207,285–304,550–572`).
- **Identity and schema/result shapes:** model-wide `(model, uid)` identity is
  distinct from contextual grammar/owner/type/role selection. Parent and Child
  retain authored direction while normalizing connectivity; reverse labels add
  no edges. Complete snapshots, baseline projections, identified captures,
  per-rule statuses, coverage checks and target witness contents are specified
  consistently (`inputs/interface.md:133–181,202–220,234–240,258–282`). The Nix
  entry distinguishes input, config and result schema identifiers
  (`inputs/recommended.nix:187–207`). Exact serialization and concrete target
  request/witness examples remain explicitly assigned to C1/C2, rather than
  being claimed as delivered (`inputs/interface.md:369–381`).
- **Graph, boundary and preservation semantics:** the selected forest remains
  separate from the mandatory all-role native DAG; the bridge remains a record
  in connectivity. Origin-sensitive closure permits visiting an external closed
  endpoint, internal peer access and exit, with nested boundaries still checked.
  Preservation covers existence/type/selected fields/owned relation sets and
  excludes incoming links and placement (`inputs/interface.md:46–49,83–131`;
  `inputs/recommended.nix:92–145`). These preserve
  `inputs/reviewed-requirements.md:9–14,22–24` and the corresponding reference
  semantics (`inputs/reference-model.md:88–158`).
- **Public extensions and consumer authority:** independent implementations use
  public registrations and explicit assignments. Native Child tailoring and the
  field/custom-rule alternative are separate examples, with no claim of native
  export or owned-link equivalence for derived field edges
  (`inputs/recommended.nix:306–449`; `inputs/review.md:59–64,78–79`). Trust
  comes from boundary-selected verification, not request labels; lifecycle
  policy is optional consumer composition. The verifier's concrete schema/entry
  is explicitly deferred before identity use (`inputs/interface.md:242–254`;
  `inputs/recommended.nix:240–283,574–580`).
- **Validation and recovery constraints:** private revisioned staging and
  authorized sealing, complete final validation, refusal without publication,
  restore-or-block failure handling, staged-index validation and two-boundary
  receipt reuse preserve the reviewed transaction and hook requirements
  (`inputs/interface.md:294–363`; `inputs/recommended.nix:502–529,587–629`;
  `inputs/reviewed-requirements.md:28–32`). The text does not equate serialized
  writes or a database transaction with atomic Scribe/files/Git publication.
- **Scope and later obligations:** full evaluation precedes optional incremental
  support. Python/native reuse and optional OPA remain recommendations. The
  final neutral-fixture cleanup and human/agent recipe verification remain
  tracked (`inputs/interface.md:388–408`; `inputs/review.md:163–193`;
  `inputs/reviewed-requirements.md:38–50`).

## Unverified integration behavior

The only executable check was `nix-instantiate --parse inputs/recommended.nix`,
which passed. No proposed library was evaluated and no fake library was created.
Actual helper lowering, registry negotiation, model extraction, target witnesses
and cross-implementation decisions remain unverified. C1/C2 explicitly require
their schemas and conformance examples before implementation.

Scribe target refusal, unchanged bytes/held state and reload controls remain C3
integration work. Group staging, commit enforcement, callback isolation,
publication/recovery, trusted fact acquisition, runtime closure compatibility
and incremental equivalence were not exercised. The packet's backend/native
experiment claims were not independently verified. These are disclosed entry
conditions or later qualification work, not contradictions in this proposal
(`inputs/interface.md:365–408`; `inputs/review.md:163–184`).
