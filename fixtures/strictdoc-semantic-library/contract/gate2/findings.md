# Current Gate 2 revision findings

Status: **Proposed contract reconciliation, no production implementation or new
runtime execution.** The 2026-09-15 handoff authorizes the changed scope.
[Interface](interface.md), [requirements](reviewed-requirements.md),
[closing plan](closing-plan.md) and
[scope reconciliation](scope-reconciliation.md) govern current reading; the old
[recommendation](recommendation.md) is historical. P1 blocks the corresponding
correctness claim, P2 concerns compatibility/qualification, P3 concerns
reviewability. “Resolved in proposal” is not an implemented fix.

## Current dispositions

| Finding                                         | Current disposition and smallest later evidence                                                                                                                                                                                                                                                                                                                                |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P1 F01 — Native named-role DAG gap              | Retain historical evidence below. Required complete all-role native rule remains independent of selected forest; qualify Parent-only/Child-only/mixed refusals on the actual candidate path.                                                                                                                                                                                   |
| P1 F02 — Record identity                        | Retain `(model, UID)` with grammar/element/field context and duplicate-UID error. C1 fixes exact extraction/coordinates/digests and metadata binding.                                                                                                                                                                                                                          |
| P1 F03 — Public invocation absent               | Resolved design direction: fully Nix-configured backend-agnostic JSON contract, registered implementations and consumer DSL contracts through the same route. C1/C2 still require compatible schemas and independent structured target witnesses.                                                                                                                              |
| P1 F04 — Candidate publication/isolation absent | Single-invocation ordered batch replaces cross-call transaction obligations. Current source does not provide shared atomic candidates, fixed readers, full validation, frozen bytes or restore-or-block. C3 retains real refusal/held-state/reload/fault evidence.                                                                                                             |
| P1 F05 — Authority                              | Authored/default identity is not principal evidence. Policy loading and fact verification remain trusted consumer bindings. No SSH keys, UI or generic approval system is added.                                                                                                                                                                                               |
| P1 F06 — Git check/use                          | Staged-tree checks retained as a separate consumer boundary. Qualify exact committed-tree binding and stale receipt refusal; local hook alone supplies no non-bypassability or authentication.                                                                                                                                                                                 |
| P2 F07 — Adapter coupling                       | Common registration/bindings separate contract meaning from implementation. Consumer DSL/native program and shipped helpers have the same route; unsupported contract/schema errors explicitly.                                                                                                                                                                                |
| P2 F08 — Lifecycle overreach                    | Superseded: public begin/stage/seal/abort, participant/readiness/membership/seal-authority mechanics are removed from initial scope. Preserve private candidate isolation, final-state validity and publication recovery.                                                                                                                                                      |
| P2 F09 — Field/native parity                    | Explicit field resolution, path and optional virtual union-DAG remain. No native link ownership/export equivalence is implied.                                                                                                                                                                                                                                                 |
| P2 F10 — Runtime pairing                        | Historical CPython 3.14.6/StrictDoc 0.28.3/rustworkx 0.17.1 import/synthetic controls remain unchanged, as do older benchmark versions. C4 still needs packaging/platform/native integration qualification.                                                                                                                                                                    |
| P2 F11 — Evidence labels                        | Original comparisons are capability evidence, not 44 integrated cases. New DFT/A contract cases are future controls. Prototype lowering or source inspection never establishes Scribe enforcement.                                                                                                                                                                             |
| P2 F12 — Incrementality/cache identity          | Full evaluation remains oracle. Validators may write derived caches; keys track each computation's actual metadata/config/version/snapshot dependencies. Rejected caches may survive but cannot become accepted state.                                                                                                                                                         |
| P2 F13 — Authority/read isolation               | Read-only authoritative snapshots, writable derived state. Fixed input identity and trusted-extension/isolation assumptions must be qualified; read-only JSON or a frozen wrapper does not protect arbitrary host state.                                                                                                                                                       |
| P3 F14 — Historical links                       | Original packet references below retain their historical layout and provenance. Current contracts distinguish retained evidence from proposed behavior; no historical evidence was re-created.                                                                                                                                                                                 |
| P3 F15 — Final delivery                         | Neutral cleanup, public repository-policy extension and verified human/steering recipes remain after qualification. No scope drift into docs/spec/plans or production now.                                                                                                                                                                                                     |
| P1 F16 — Semantic Boolean metadata              | Gap resolved in design by distinct validated type layer yielding native singleChoice plus identified metadata. Fix canonical codec/presence/multiplicity and version/digest; native placeholder acceptance must not bypass Boolean decoding.                                                                                                                                   |
| P1 F17 — Defaults and construction              | Typed literal/runtime script, newly created final absence only, preserve false/empty, once per candidate, no backfill/eval acquisition. Existing early required/empty checks need adaptation; native empty serialization remains untested.                                                                                                                                     |
| P1 F18 — Mutator/precheck/index coherence       | Per-field/node validation and current indexed reference checks can reject transient state or consult stale data. Audit construction and final-state validation over coherent candidate/indexes, without mandating rebuild per operation.                                                                                                                                       |
| P2 F19 — Readable DSL finite lowering           | Public proposed `s.grammar`, typed fields, new `c` callbacks, named constraints/views, explicit counts/singletons and contribution lists align with this contract. Final public shape synchronization incorporates normalized grammar/bundle/types, semantic field/default nesting, finite predicate IR and keyed identities; generic predicate runtime remains unimplemented. |

## New public source facts and limits

The independent public source report identifies revision
`6f529c7eef3650a14b6f8d56ff1bc3ceaa914d7f` and matches all five handoff blob
IDs. The report is source inspection, not runtime execution; no concurrency,
fault, empty serialization or new semantic enforcement test follows from it.

- Native public grammar exports only check/dsl/emit/normalized/render. Fields
  are ordered; `singleChoice` uses `choices`; semantic/default keys are absent.
  Empty relations lower to null/absence. Native emission alone supplies no
  semantic metadata transport.
- `scribe_ops.py:155–160,414–420` accepts initial relations and passes them to
  `g.add_node`. Each normal mutation calls `Workspace.write` once. JSON-RPC max
  batch eight dispatches independent `apply` calls; CLI constructs one
  subcommand, not one atomic ordered batch.
- `scribe_cmd.py:78–88,105` demands required fields before RPC.
  `sdoc_model.py:908–950` rejects missing required creation fields and every
  explicit empty string. Per-field set and relation add/remove validate the
  entire node immediately. Required construction and successful-empty defaults
  therefore need explicit integration work, not just a descriptor.
- Inspected installed `SDocValidator.validate_node` accepts `TBD`/`TBC` for
  choice fields, beyond declared choices. The semantic Boolean codec must reject
  them. That node validator does not check DAG, selected forest,
  target/cardinality/visibility or preservation; full reader/index-builder
  behavior was not exhaustively audited.
- `Workspace.current` returns held graph objects after releasing its lock.
  `write` mutates that same held graph; a frozen Generation dataclass does not
  freeze it. Clearing the workspace reference on discard cannot retract
  references readers already hold. Reads/show/list/check/export use mutable
  state; no snapshot isolation is established.
- Graph mutators update object lists while some incoming/reference lookups use
  graph_database indexes. Source shows a disagreement risk between walk-based
  and indexed state after mutation. Moving a reference precheck to the end
  without updating/rebuilding its inputs is insufficient. This is not a
  reproduced runtime case.
- `_move` previews the old document with `dry_run=True` then renames separately.
  Final path/membership is outside that candidate validation. `_prove_renders`
  reparses touched files, not the whole candidate graph. `Graph.save` computes
  pending/rendered content again, so inspected bytes are not one frozen
  publication artifact.
- Writes use `_held` without a final disk/base freshness check.
  Source/config/metadata identity must join the proposed base/receipt contract.
  Save captures old text and attempts restoration, but restoration can fail and
  no recovery-required latch is present. Per-file replace and deletion are not
  crash-atomic multi-file publication.
- Textual native `check` return code is dropped by the RPC rendering route; a
  successful CLI/RPC response is not the proposed RuleResult/admission contract.
  Existing external-file extractor caches use path/mtime/size, not complete
  candidate/content/config identity. File relation validation reads live disk
  and needs an explicit captured-file contract when relevant.
- The audited installed CLI has no alternate document-write route outside
  Workspace, but direct low-level Graph.save and external filesystem/upstream
  commands remain outside the Scribe boundary. The report did not globally audit
  repository-specific clients, private semantics, full native builder/export
  internals or trust rules.

These findings refine C1–C4 and the dependency-ordered plan. They do not mandate
a general filesystem transaction service, blanket full graph rebuilding per
operation or a new security subsystem. No historical number, version or archived
alternative has been changed.

## DSL synchronization

The supplied public DSL vocabulary names `g = grammar.dsl`, proposed
`s = schema` and new `c = constraint`; ordered fields;
`s.field.boolean "FLAG" { required = true; default = s.default.literal false; }`;
keyed `relations.<role>.parent/child`; `c.isNodeType`, `c.forest`,
`c.boundaryVisibility`, `c.fieldValue`, `c.exactly`, `c.only`, `canDescend`,
external `c.on` and contribution lists. This contract adopts that vocabulary. No
initial fluent/functor surface is required.

The public DSL shape specifies: schema returns
`{elements; views; normalized; rendered;}`, only normalized/rendered serialize;
types use `{schema; digest; fields = [{field; native; semantic; default;}];}`;
defaults use literal/script variants; keyed IDs and `{op; args;}` predicate IR
are recorded in the interface. The prototype supports adjacent/external/direct
target specialization and rejects unsupported reversed visibility/endpoint
patterns. Its generic predicate interpreter, script execution and arbitrary
custom dependency compatibility remain unimplemented; bounded lowering evidence
does not establish those runtime capabilities.

Remaining C1/C2 choices are cross-language digest canonicalization, source
coordinates, reserved-ID escaping, exact generic operator/operand schemas and
the small default runtime ABI, not accepted behavior. Exact spellings remain
proposals, with bounded prototype evidence distinct from production
qualification.

## Historical evidence record (unchanged)

The record below is retained verbatim from the supplied findings, including
historical first-person verification statements and original links. Those
describe the original comparison worker, not work performed in this revision.
Old lifecycle/readiness/next-review references in this historical record are
superseded by the current dispositions above. Measurements and evidence
boundaries remain intact.

**Native evidence supporting F01/F04.**
[Actual source documents](research/experiments/native/combined_role_cycle/input.sdoc)
and [native_probe.py](research/experiments/scripts/native_probe.py) show that
the expected semantic rejection and observed CLI acceptance are stored
separately. The runner intentionally expects those known acceptances so that a
successful probe run does not falsely mark the reviewed invariant satisfied.
[Native results](research/experiments/results/native.json) mark
`satisfies_required_behavior=false` for the three named-cycle cases. A named
self-loop fails via insertion assertion, separately from whole-cycle traversal.

Pinned normalization handles both authored directions; cycle callbacks omit the
selector. `GraphDatabase` forwards `None` while its bucket's all-role behavior
requires `ALL_EDGES`. The
[scope script](research/experiments/scripts/native_scope_probe.py) constructs a
native graph from the same authored input and calls the existing detector with
default versus explicit all-role selection. Its
[result](research/experiments/results/native-scope.json) has empty default
adjacency and the explicit cycle witness A,Z,B. This supports the narrow repair
direction, not a patched upstream builder or Scribe integration.
[Pinned builder](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/traceability_index_builder.py#L650),
[forwarder](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph_database.py#L56),
[bucket](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph/many_to_many_set.py#L43),
[sentinel](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph/abstract_bucket.py#L6).

The packet's [source verification](provenance/native-source-verification.json)
corroborates hashes at immutable observed-main revision
`b56ebb266c0a58f016c3be6ed5337c8a9833be0e`. Execution used pin
`7cf8183498ec87be531499230602df33523ed058`, CLI 0.28.3; no current-main
execution or live web verification was performed by this comparison worker.
Native multiple-root, multiple-parent and owned Child-tailoring support are
positive controls. Whole-candidate custom checks, reload after their refusal and
file/Git publication are separate obligations in the
[public-toolchain brief](public-toolchain.md).

**Backend evidence supporting F07/F10/F12.** The
[research recommendation](research/research.md) is persuasive because its
graph-library route covers the required traversal while retaining native
ownership and avoiding a mandatory storage lifecycle. rustworkx supplies graph
algorithms; Python implements consumer boundary semantics. This is a supported
engineering inference from probes, not a claim of built-in policy support.
[Executed implementation](research/experiments/scripts/finalists.py),
[rustworkx version metadata](https://pypi.org/pypi/rustworkx/0.18.1/json),
[graph API](https://www.rustworkx.org/apiref/rustworkx.PyDAG.html).

**Separate factual runtime-pairing follow-up.** After the original proposal was
frozen, the coordinator executed the mechanical worker's unchanged
[pinned expression](runtime-pairing/outputs/probe.nix) with max-jobs 1, cores 2
and a 480-second cap, then ran its
[Python probe](runtime-pairing/outputs/probe.py). Both exited zero
([execution record](runtime-pairing/outputs/host-execution.json),
[build log](runtime-pairing/outputs/host-build.log)). The
[raw result](runtime-pairing/outputs/host-probe-result.json) records StrictDoc's
CPython 3.14.6 interpreter loading StrictDoc 0.28.3 and rustworkx 0.17.1 with a
temporary combined-closure site-packages `PYTHONPATH`; CLI dependency imports
also succeed. The probe itself normalizes synthetic Parent/Child tuples in
Python, then checks rustworkx acyclicity, cycle detection and positive,
reverse-unreachable and isolated-unreachable paths. It does not call native
StrictDoc parsing or validation.
[Store identities](runtime-pairing/outputs/identities.json) identify this
x86_64-linux pairing. Initial import/graph compatibility is now observed;
production packaging, other supported platforms and native integration remain
unqualified. No earlier benchmark was repeated or reattributed to these
versions, and no Scribe behavior follows. This comparison worker inspected the
new evidence without executing it; it is separate from the frozen research
packet.

OPA's actual policy computes per-origin adjacency and calls `graph.reachable`;
its native Rego authoring deserves a public adapter without universal
translation. The Python/Cozo projections and Rego normalize Parent and Child
separately in v2. Warm Bun 1.4.2 with SDK 1.10.0 evaluates the compiled policy
on both literal hierarchies. `graph.reachable_paths` remains SDK-dependent. The
probe's boolean answers do not satisfy a future full witness contract.
[Rego](research/experiments/scripts/policy.rego),
[Wasm harness](research/experiments/scripts/opa-bun.cjs),
[OPA graph built-ins](https://www.openpolicyagent.org/docs/policy-reference/builtins/graph),
[Wasm SDK](https://github.com/open-policy-agent/npm-opa-wasm).

Cozo's `register_fixed_rule` callback succeeds and propagates a deliberate
exception. Memory transaction abort/commit work. The independent read while a
writer remains active exceeds the bounded lock-probe deadline; this is a
specific memory-engine observation, not evidence against every Cozo engine. The
old recorded release/activity and deep-query costs add risk. There is no
measured need to adopt a persistent graph database or overcome the user's strong
SQLite preference. No JVM is eligible. Rust/petgraph and Bun/Graphology remain
credible but unmeasured alternatives; binding/packaging them first would need a
concrete benefit beyond language preference.
[Callback/transaction controls](research/experiments/scripts/finalists.py),
[bounded lock script](research/experiments/scripts/cozo_lock_probe.py),
[pinned memory lock](https://github.com/cozodb/cozo/blob/v0.7.6/cozo-core/src/storage/mem.rs#L40),
[public fixed-rule bridge](https://github.com/cozodb/cozo/blob/v0.7.6/cozo-lib-python/src/lib.rs#L279).

**V1/v2 corrections preserved; no silent result changes.** The previous
[evidence review](provenance/evidence-v2-review.md) and
[producer correction](research/evidence-corrections-v2.md) are consistent with
inspected scripts and retained results:

- V1 reversed all selected edges. Its Child-kind exclusion control did not
  select a Child hierarchy. V2 branches by authored direction and independently
  normalizes the oracle; ten literal Child expectations distinguish the mistake.
  The 30 graph records agree across all three backends. The four extra records
  concern cycle/ownership, snapshots, transaction state and custom callbacks.
- V1 lacked an unchanged positive under a nonempty protected snapshot. V2 CLI
  and Wasm produce `[]` for unchanged I0, then `["I0"]` after its projected
  field changes under the same snapshot. This defeats an always-reject false
  positive but does not qualify the full owned-record projection or trusted
  facts.
- V2 OPA 1,000-wide median is 1,425.9833 ms; v1 was 268.4934 ms. The three
  budget-exceeded cells remain explicit. All nine completed cost medians match
  the retained three samples. Eight seconds bounds the whole worker including
  three evaluations and deep controls; no per-evaluation timeout latency
  follows.
- V2 retains twenty Wasm samples and the usual median 0.2412045 ms, load
  2.529705 ms. V1 stored an upper-middle statistic without samples. This tiny
  warm workload cannot be compared directly to the 10,000-node CLI cells.
- [Replay instructions](research/reproduce.md) now copy experiments to
  disposable scratch. The supplied composed `--all` record exited zero on the
  original dependencies, with expected lock/cost timeouts. That replay did not
  qualify new-host setup or production integration; the separate later
  runtime-pairing result above is a narrower compatibility check.

Original [finalist](research/experiments/results/finalists-v1.json),
[cost](research/experiments/results/cost-v1.json) and
[Wasm](research/experiments/results/opa-bun-v1.json) data remain frozen. The
[v2 results](research/experiments/results/finalists.json),
[costs](research/experiments/results/cost.json) and
[Wasm samples](research/experiments/results/opa-bun.json) were read and
arithmetically checked, not replayed or edited. The evidence review records
formatting/reserialization nuance for two v1 hash comparisons; this worker does
not relabel those copies as original byte-identical files.

**Decision boundary.** The three human choices are in [review.md](README.md).
C1–C4 in [interface.md](interface.md) define the smallest model/protocol/native
integration/closure follow-ups. No missing evidence forces a different backend
recommendation; missing implementation contracts forbid calling this runnable.
Trust verification schemas, document continuity/classification, publication
threat/crash scope, Git merge-before and readiness/admission policies must be
settled before their respective slices. Optimizations, extra languages and
process sharing can remain open. The separate numeric extension remains tracked
only in later [playbook obligations](playbooks.md).

The original proposal review used frozen workspace inputs and installed tools,
with no web, experiment replay, builds, installation, delegates, Git writes or
publication. All 85 files covered by the three freeze manifests matched their
supplied hashes (4 ideal, 5 tool-informed, 76 research). Original artifact
verification consisted of Nix syntax parsing, Markdown link and coverage checks,
retained-result arithmetic and required treefmt formatting. No library stubs or
production changes exist.
