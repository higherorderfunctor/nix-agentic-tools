Historical audit of evidence version 1. Line references describe that frozen
version; links locate current packet counterparts. See the
[v2 resolution review](evidence-v2-review.md) and
[retained v1 checksums](../research/evidence-v1-sha256.json).

The packet supports a bounded Gate2 capability demonstration, with two
medium-priority evidence/reproduction findings and one low-priority control
improvement below. No critical defect was established. The existing
Parent-selected traversal results remain useful; they should not be generalized
to selected Child authoring. This review makes no interface or backend
selection.

**1. P2 — Selected Child hierarchy edges are reversed; the comparison does not
cover that required authoring direction.**

Claim: [research.md](../research/research.md), lines 31 and 42, describes
reference traversal and contextual-selector controls across rustworkx, Cozo and
OPA. The reviewed requirements allow native Parent and Child authoring and
require their direction to determine connectivity.

Evidence: [finalists.py](../research/experiments/scripts/finalists.py), line 55,
always projects a selected relation as `(target, owner)`. The NetworkX oracle,
rustworkx evaluator and Cozo parameter preparation all use this same helper.
[policy.rego](../research/experiments/scripts/policy.rego), lines 13 and 17,
independently makes the same Parent-only assumption. Every comparison keeps
`hierarchy.kind = "Parent"`; the `selector_context_kind` control only verifies
exclusion of a Child relation. Correct Child normalization appears separately in
the rustworkx cycle control at line 175 and in the native scope probe, but
neither feeds the traversal evaluators.

A concrete counterexample follows directly from the code, without execution:
select `kind = "Child"`, with one authored relation owned by open `upper`
targeting open `lower`. Downward `upper -> lower` should succeed. Both
projections instead create `lower -> upper`, so all three evaluators and the
shared oracle would answer false. Agreement therefore cannot establish Child
traversal correctness. The oracle is independent in its path algorithm, not its
input normalization.

Disposition: explicitly scope the current equivalence evidence to
Parent-selected hierarchies. Before claiming selected Child support, add an
equivalent Child-authored hierarchy with independently stated downward and
boundary expectations, and apply the appropriate direction in each projection.
This is a small capability-probe correction, not a request for a production
adapter or full policy implementation.

**2. P2 — The frozen packet lacks a working reproduction entry point for its own
layout.**

Claim: [reproduce.md](../research/reproduce.md), lines 13–28, instructs
execution “From this workflow directory” using
`outputs/experiments/scripts/setup.sh` and `outputs/experiments/scripts/run.sh`,
followed by a native package lookup through `./inputs/toolchain#strictdoc`.

Evidence: the frozen scripts are actually under
`inputs/research/experiments/scripts`; neither documented script path nor
`inputs/toolchain` exists in this workspace. The scripts derive their writable
experiment root from their own location. Simply changing the command to point
into `inputs/research` would therefore install dependencies and overwrite copied
inputs/results there. The original execution paths retained in `native.json`
confirm that these commands describe the producer's layout. Syntax checks cannot
catch this relocation problem.

Disposition: add explicit packet relocation instructions, such as copying
`inputs/research/experiments` into a disposable `outputs/experiments` before
using the documented commands. Identify how to obtain the exact filtered
toolchain and native Python environment separately from the standalone backend
probes. Preserve the already stated host-addon prerequisites and the disclosure
that the composed runner has not been executed. The finding is the missing
packet entry point, not the explicitly deferred portable packaging
qualification. No reproduction commands were executed during this review.

**3. P3 — Protection controls do not distinguish comparison from rejecting every
protected record.**

Claim: [research.md](../research/research.md), line 33, describes a captured
baseline comparison.
[finalists.py](../research/experiments/scripts/finalists.py), lines 182–190,
tests a changed protected record and empty snapshots.
[opa-bun.cjs](../research/experiments/scripts/opa-bun.cjs) likewise tests only a
changed protected record.

Evidence: there is no nonempty protected snapshot whose candidate projection is
unchanged. A policy returning every key in `snapshot.records`, without comparing
the projection, would satisfy these recorded protection assertions. The actual
Rego does contain a comparison; this is a missing discriminating control, not an
observed incorrect verdict or a demand for the deferred full ownership-sensitive
projection.

Disposition: add one unchanged protected-record case expecting no violation,
preferably alongside the changed case using the same snapshot. Treat this as a
nonblocking improvement to the narrow Gate2 protection demonstration.

The remainder of the inspected evidence is appropriately bounded:

- **Native cycles:** all 11 result rows are internally consistent. The unroled
  Parent-only, Child-only and mixed rejection logs explicitly report cycles.
  Named equivalents are recorded as accepted, with required-behavior failures
  retained. The self-loop log identifies graph insertion failure; missing target
  has a distinct resolution error. `native-scope.json` records empty default
  adjacency and an all-role `A -> Z -> B -> A` cycle. This supports the stated
  narrow all-role rejection capability. It does not yet qualify an adapter on
  acyclic named multi-parent graphs or cycles combining named and absent roles;
  the report already avoids claiming a complete fix.
- **Origin-sensitive traversal:** eight cases provide 24 matching backend answer
  maps, including ten explicit base expectations, boundary opening, nested
  rejection from inside the outer boundary, subtree relocation and four selector
  exclusions. The three traversal algorithms retain the original origin when
  deciding which closed boundaries can expand. Cross-tree and unselected-bridge
  shortcuts are rejected. These are fresh full-input decisions, with additional
  warm-Wasm open/close controls, not incremental/full parity evidence.
- **External input and failures:** `providers.py` and `providers.json`
  distinguish complete empty/protected snapshots from nonzero exit, timeout,
  malformed JSON, incomplete output and missing snapshot ID. The ID control
  concerns snapshot identification, not authenticated actor identity. Provider
  capture and OPA evaluation are separate probes; an integrated
  acquisition-to-verdict failure path is not demonstrated. The report identifies
  host responsibilities accordingly. Captured default/strict OPA division errors
  show undefined output versus explicit error. Cozo callback success/failure and
  transaction abort/commit assertions match the captured summary. The separate
  lock probe provides bounded evidence of a read blocked behind an active
  writer; the historical ten-/twenty-second observation is only narrated in this
  packet.
- **Interop:** the script and captured output assert `backend=unconfigured`,
  capabilities limited to `health`, and unsupported-operation error propagation.
  They provide no graph-backend result. The research explicitly preserves that
  distinction.
- **Cost and packaging:** all nine numeric medians recompute exactly from the
  retained three samples and round to the table values; three other cells record
  process-budget exhaustion. Timings cover each adapter's
  construction/evaluation, with additional OPA serialization and CLI startup.
  Closed-boundary evaluations are assertions outside the timed samples but
  inside the worker budget. No timeout is converted into per-call latency. The
  warm ten-query Wasm measurement is explicitly separated; its individual twenty
  samples are not retained for median recomputation. Package-version differences
  between probes and evaluated nixpkgs attributes are disclosed. No material
  benchmark-comparison or packaging-equivalence error was found within those
  limits.

Some consequential external claims remain **unverified by this review** because
their primary-source bytes are outside the frozen packet. Exact verification
needed before treating them as independently confirmed:

- For [sources.md](../research/sources.md)'s extension of the native diagnosis
  to main, obtain the four files named in `native-source-evidence.json` at
  StrictDoc pins `7cf8183498ec87be531499230602df33523ed058` and
  `b56ebb266c0a58f016c3be6ed5337c8a9833be0e`, recompute the recorded hashes, and
  inspect callback/default/bucket behavior plus `abstract_bucket.py`'s sentinel.
  Supplied equal hashes alone cannot establish source contents.
- For the Scribe whole-candidate validation claim, inspect the cited
  `dev/scripts/sdoc_model.py` relation append, node validation and save paths at
  consumer revision `8563ca852ae083609f97fb52a46c0b07272897ee`.
- For Cozo maintenance and locking explanations, verify the linked v0.7.6
  release metadata, repository metadata/main revision
  `481af058abac9444ea8c9c52c78f096ed4b5bfc4`, and `cozo-core/src/storage/mem.rs`
  at v0.7.6. The local timeout result supports the observed behavior without
  independently proving its source-level cause or current maintenance status.

Audit scope: read the reviewed requirements, research, source ledger,
reproduction instructions, relevant experiment scripts, neutral/native fixtures,
dependency declarations and captured results/logs. No interface proposal, design
handoff, coordinator material, prior repository specification/history, external
source checkout or network content was consulted. No experiment, build,
installation, delegate, Git operation or production edit was performed. Actual
checks were Python AST parsing for six scripts, `bash -n` for three scripts,
`node --check` for the Wasm harness, parsing 13 result JSON files, and local
result/arithmetic/path inspection. Details are retained in
[inspection-checks.json](inspection-checks.json). Markdown/JSON outputs were
formatted with the requested treefmt configuration. Deferred Scribe
transactions, authenticated identity, incremental/full parity and platform
qualification are not new findings.
