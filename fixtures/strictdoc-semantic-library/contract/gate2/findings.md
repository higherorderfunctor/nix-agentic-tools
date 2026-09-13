**Gate 2 adjudication findings and dispositions.** Recommendation: public policy
contracts beside grammar, Python/rustworkx first with native StrictDoc reuse,
optional OPA, and explicit consumer-selected invocation boundaries. No finding
requires another broad tooling survey. The unresolved contract/integration items
below are entry conditions for later implementation, not claims that this
recommendation is already deployable.

Priorities: P1 blocks the corresponding correctness/authority/publication claim;
P2 affects public compatibility or qualification; P3 concerns reviewability or
scope. “Resolved in proposal” means a documented design decision, never an
implemented fix. The governing authority is the
[reviewed packet](reviewed-requirements.md), including its override of old
reference pending labels.

| Priority / finding                                        | Evidence and exact concern                                                                                                                                                                                                                     | Disposition / smallest follow-up                                                                                                                                                                                                              |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1 F01 — Native role-cycle gap                            | Pinned CLI accepts three named-cycle controls and rejects corresponding unroled graphs. It is not missing Parent/Child support.                                                                                                                | Open integration defect. Require complete all-role DAG rule; prefer native detector reuse. Qualify Parent-only, Child-only and mixed refusals through the actual candidate/Scribe path.                                                       |
| P1 F02 — Snapshot identity disagreement                   | Ideal keys records by model/UID; tool-informed uses grammar/UID within model and omits model from its projection key. Probes use flat UID maps and do not arbitrate cross-grammar semantics.                                                   | Resolved in proposal: `(model, UID)`, grammar retained as metadata/type/selector context. C1 must fix extraction/resolver/schema and duplicate-UID behavior before Gate 3 implementation.                                                     |
| P1 F03 — Public ABI still absent                          | Both designs name model/protocol schemas but provide no complete interoperable implementation. The health bridge reports only `health`, backend unconfigured.                                                                                  | C1/C2 entry conditions. Freeze one complete target snapshot, descriptor, runner request/result and witness, then consume it through shipped and independent implementations. No fabricated API evaluation.                                    |
| P1 F04 — No Scribe transaction or recovery proof          | Native exports leave their input bytes unchanged, but no proposed mutation occurred there. Current Scribe arrays can partially persist. Cozo commits cover database state only.                                                                | C3: specify capture/refusal/publication before the first publishing slice. Real G02 unchanged files/held model/reload first; grouped candidates and failure injection later.                                                                  |
| P1 F05 — Identity and policy-loading authority            | Provider probe checks process output shape; it authenticates no actor. Mutable candidate config could otherwise disable its own protection.                                                                                                    | Keep authority/verifier and trusted policy loading explicit. Before identity slice: define authority→session→principal binding and approval verification request/result; test forged labels, wrong authority and stale bindings.              |
| P1 F06 — Git check/use boundary                           | A captured index and later identity check do not themselves bind the actual commit tree; local hooks can be bypassed.                                                                                                                          | Require `commit.bind-validated-tree/v1` only from a qualified enforcing adapter. Smallest integration control: change index after validation and prove receipt refusal or exact validated-tree commit. No Git atomicity claim now.            |
| P2 F07 — Helpers coupled to default adapter               | Tool-informed raw target embeds `graph-library/targets`; ideal separates contract identity from assignment. Both promise public replacement.                                                                                                   | Adopt public contract-to-entry bindings and explicit per-rule bindings. N3's independent target entry implements the same contract without a shipped ID.                                                                                      |
| P2 F08 — Lifecycle hardening by example                   | Tool-informed example requires all participants ready; ideal allows readiness as group policy. Ideal tailoring example always selects a hierarchy; tool-informed correctly separates it from familiar tailoring.                               | Core revisioned private stage/seal; optional all-ready. Tailoring counts/targets work without selected path. These are consumer choices, not accidental engine policy.                                                                        |
| P2 F09 — Field/native equivalence                         | Fields create no authored native links. Even a virtual union graph does not make exports or owned-link preservation identical.                                                                                                                 | N6/P05 specify endpoint/path parity and optional union-DAG; native exports and protection need separate mappings/evidence.                                                                                                                    |
| P2 F10 — Runtime pairing; remaining qualification         | Original Python 3.13.15/rustworkx 0.18.1 benchmarks remain unchanged. Separate later [raw pairing evidence](runtime-pairing/outputs/host-probe-result.json) passes with CPython 3.14.6, StrictDoc 0.28.3 and rustworkx 0.17.1 on x86_64-linux. | Initial compatibility check resolved; C4 remains open for production packaging, supported platforms and native parser/validator integration. Temporary combined-closure PYTHONPATH and synthetic graph controls establish no Scribe behavior. |
| P2 F11 — Prototype coverage narrower than labels          | Thirty graph comparisons are three backends on ten variants, not 30 independent reference cases. Forest validity is asserted by the oracle; full target/count/projection/publication APIs are not tested.                                      | Report capability only. P01–P13 map all 44 cases plus additions to actual later delivery; T11 retains all 15 reference rows.                                                                                                                  |
| P2 F12 — Incrementality/cost not qualified                | Every query probe reconstructs complete inputs; loaded Wasm receives full input. Cost cells have one query, not all policies over realistic mixed documents.                                                                                   | Full evaluation first. Gate 6 differential mutation/source/policy tests and representative costs remain required. Do not mandate depth limits, persistence or an incremental backend.                                                         |
| P2 F13 — Strong execution restrictions                    | Read-only input objects do not stop a callback/executable from writing published files. Neither design's proposed guarantees establish runtime isolation.                                                                                      | Publish profile must declare trusted-extension versus isolated-execution threat model and qualify write restriction for every adapter. Until then, no strong publication capability advertisement.                                            |
| P3 F14 — Frozen links assume producer layout              | Tool-informed links refer to absent `../inputs/research-v2` and toolchain paths; shared closing plan references `../shared`. These are copied artifact context, not evidence removal.                                                          | Frozen artifacts left untouched. New outputs link to available `../inputs/research`, shared files and primary source URLs; new links checked locally.                                                                                         |
| P3 F15 — Closure obligations can vanish behind prototypes | Current reference grammar retains generic-runtime accommodations; clean proposed examples alone do not remove coupling.                                                                                                                        | Track P13 and closing obligations: generic field-policy removal, zero forbidden fields anywhere in final neutral scope, public repository policies, verified recipes, no SDoc migration.                                                      |

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
