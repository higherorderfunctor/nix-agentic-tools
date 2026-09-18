# Tooling research

Status: evidence v2, corrected and rerun after independent review on 2026-09-13.
No backend is adopted. No production implementation or ideal-interface outputs
were read.

The leading implementation option to carry into interface design is a
graph-library adapter close to StrictDoc, with OPA as an optional public policy
adapter. An embedded recursive database is technically capable, but current Cozo
lifecycle and transaction caveats weaken its default case. These are
recommendations to evaluate, not adoption decisions.

## Verified native boundary

Pinned StrictDoc 0.28.3 (`7cf8183498ec87be531499230602df33523ed058`) accepts
multiple roots, multiple native parents, and an authored Parent/Child bridge.
Its CLI rejects unroled Parent-only, Child-only and mixed cycles; it accepts all
three named-role equivalents. A named self-loop rejects separately via a graph
insertion assertion. See `experiments/results/native.json` and the reproducible
`native_probe.py`.

The cycle callbacks omit the edge selector. `GraphDatabase.get_link_values`
defaults to `edge=None`, then explicitly forwards that to `ManyToManySet`; the
bucket requires `ALL_EDGES = ".all"` for all roles. Consequently the cycle
detector follows only absent-role edges. The builder, detector and graph wrapper
are identical at current upstream main
`b56ebb266c0a58f016c3be6ed5337c8a9833be0e`. Parent/Child normalization is
present. This is an upstream role-filtering gap, not missing native Parent/Child
support. Scribe also appends relations and validates a node without invoking
whole-candidate graph validation; integration remains necessary even after the
native gap is fixed.

Upstream user guide explicitly documents compliance matrices and immutable OTS
adaptation: a compliance/adaptation statement owns Parent to the upper
standard/user requirement and Child to the lower project/OTS requirement. The
bridge remains a graph record. The illustrative upstream grammar omits its own
UID; consumer examples must add an explicit UID for addressable graph records.

## Fresh candidate evaluation

| Family                                      | Assessment                                                                                                                                                                                                                                                                                 |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Python graph libraries: rustworkx, NetworkX | Finalist. Native adjacency/cycle/path algorithms, typed edge payloads, straightforward Python integration. Consumer semantics and dependencies remain custom code. No automatic incremental semantic maintenance.                                                                          |
| Rust graph libraries: petgraph              | Strong alternative for a reusable kernel or future shared Bun/Python core. Requires binding/packaging work; graph algorithms do not provide policy composition or publication recovery.                                                                                                    |
| OPA/Rego executable or embedded Wasm        | Finalist. Captured JSON input, reusable policy modules, comprehensions, graph reachability, structured decisions. Origin-aware graph can be constructed per query. No arbitrary recursive Rego rules; no free cross-update maintenance or file transactions.                               |
| Cozo embedded Datalog (memory storage)      | Finalist capability challenge. Recursive origin-carrying rules, transactions, public Python custom fixed rules all exercised. Release 0.7.6 is from 2023; upstream last code push observed December 2024. In-memory independent read during active write transaction blocked in the probe. |
| Soufflé executable/compiler                 | Credible batch recursive Datalog with provenance and C/C++ extension hooks. Good logic authoring, extra executable/toolchain/FFI integration; no demonstrated live delete maintenance or Scribe atomicity. Not expanded to a fourth prototype.                                             |
| Ascent Rust library                         | Compile-time Datalog and Rust expressions, stratified negation, aggregates, reusable macros and custom relation structures. Attractive for compiled consumer libraries; not a runtime hot-loaded policy language or proven incremental retraction engine.                                  |
| Differential Dataflow / Salsa               | Possible later incremental execution/cache machinery, not turnkey semantic policy engines. Dataflow deletions and fixed points need deliberate graph encoding; Salsa query dependencies need deliberate provider/policy inputs. Start with full evaluation as correctness oracle.          |
| Cedar / CEL                                 | Useful specialized authorization or expression adapters; neither replaces the origin-sensitive graph evaluator on its documented native authoring surface. Identity authentication remains external.                                                                                       |
| Graph/document databases and SQLite         | A persistent index is not required by the reviewed semantics; no measured benefit justifies a database dependency by default. SQLite is strongly disfavored. No JVM candidate was considered viable.                                                                                       |

## Experimental evidence

`finalists.py` checks twenty explicit truth rows across Parent-selected and
Child-selected hierarchies, with an independently normalized NetworkX
unique-path oracle against rustworkx, Cozo recursion and OPA graph built-ins.
Opening a boundary, moving a subtree, nested closure, and all four
selector-context changes are controlled. Tests preserve external bridge
connectivity as unselected hierarchy edges. A separate rustworkx control detects
the named mixed cycle and retains authored Child ownership.

OPA CLI and Wasm accept an unchanged protected record and reject its changed
projection under the same nonempty snapshot. Protection comparison also detects
a captured baseline change, preserves the old captured result after source
replacement, and accepts a new complete empty snapshot. Cozo transaction
abort/commit and custom Python sum/failing callbacks pass. An attempted
independent read during an active memory-engine write blocked beyond ten seconds
and was killed at twenty seconds; a separate three-second bounded reproducer
confirms the behavior. No filesystem/Git transaction was attempted. See
[Cozo memory locking source](https://github.com/cozodb/cozo/blob/v0.7.6/cozo-core/src/storage/mem.rs#L40).

`interop.sh` loaded the existing effect-tui native addon with Bun 1.4.2 at
revision `d0d72543a79424242933ecfd557c4d5cbb27351d`. The call crosses N-API ->
Rust -> PyO3 -> Python JSON dispatch and returns health; an unsupported
operation propagates a Python error. The adapter reports `backend=unconfigured`,
capabilities only `health`. It establishes that interop route on this host, not
StrictDoc graph operations, concurrent safety, asynchronous cancellation, or
cross-platform packaging.

## Recommendations and their limits

Prefer a **library-first implementation candidate**: retain StrictDoc parsing,
ownership and native validation, then use a public graph adapter for custom
projections/traversal and host-language policy callbacks. Python plus rustworkx
is the shortest measured route into the existing Python runtime. A pure Rust
petgraph core with Python/Bun bindings is a credible alternative if reuse across
runtimes merits its packaging cost; Graphology is a credible Bun-native graph
alternative. Neither alternative was executed here, so the measured result
favors the current Python route without making runtime choice a policy
requirement.
[rustworkx API](https://www.rustworkx.org/apiref/rustworkx.PyDAG.html),
[petgraph](https://docs.rs/petgraph/0.8.3/petgraph/),
[Graphology](https://graphology.github.io/).

Expose **OPA as an optional, equally public policy backend**, with direct Rego
authoring and typed input/output validation. It can implement the reference
traversal without a separate reachability service: the experiment creates a
query-specific adjacency and calls `graph.reachable`. Its data
representation/comprehensions introduce overhead and need optimization for
larger graphs. The same program compiled to Wasm and executed under Bun; a
native-process sidecar is therefore an option, not a requirement.
`graph.reachable_paths` is a separate SDK-dependent built-in; do not infer its
availability from successful reachability.
[OPA graph support](https://www.openpolicyagent.org/docs/policy-reference/builtins/graph),
[Wasm SDK](https://github.com/open-policy-agent/npm-opa-wasm).

Keep **Cozo as an alternative with explicit reservations**, not the recommended
default. It expresses origin-carrying recursive rules elegantly and offers a
real public custom-rule interface. Its old release/code activity, memory-engine
locking, and slow deep-query prototype matter for this workload. The probe uses
memory storage and requires neither SQLite nor RocksDB; choosing a persistent
engine would require a new operational justification. Soufflé and Ascent remain
credible specialized compiler/library alternatives for consumers who prefer
Datalog, but the current need does not justify imposing their native languages
universally. [Cozo release](https://github.com/cozodb/cozo/releases/tag/v0.7.6),
[Ascent](https://docs.rs/crate/ascent/0.8.0),
[Soufflé interface](https://souffle-lang.github.io/interface).

Repair/reuse the **native cycle algorithm through a correctly scoped adapter**
before adding a permanent second generic DAG implementation.
`native_scope_probe.py` constructs the same native graph and calls the existing
`TreeCycleDetector`: default selection sees no named edges; explicit `ALL_EDGES`
sees `A -> Z -> B -> A` and rejects. This is a verified narrow capability, not
an implemented Scribe fix. Future integration must validate the complete final
candidate, not only a touched node.
[Native scope results](experiments/results/native-scope.json),
[source explanation](sources.md).

All candidates leave the following integration responsibilities to the semantic
host:

- **Input authority and snapshots:** capture one identified, complete immutable
  evaluation input; authenticate identity through a consumer-selected trusted
  source; retain before/baseline where required. The supplied request's `actor`
  label is not authentication. Re-evaluate policy/provider changes even without
  document edits. The seven executable provider controls distinguish complete
  empty, protected, nonzero, timeout, malformed, incomplete and missing-identity
  results; this is harness behavior, not a backend-provided identity system.
- **Validation boundaries:** consumers may choose daemon transactions, Git
  index/commit validation, or both. Parallel writers need explicit candidate
  membership and completion; a hook must validate the staged candidate rather
  than an unrelated worktree snapshot. Rules have the same meaning at either
  boundary. Scheduling does not create transaction semantics.
- **Recovery:** a database transaction, Wasm instance or daemon mutex does not
  make Scribe/files/Git atomic. Stage privately; validate; publish with a
  recoverable protocol. Semantic refusal leaves authored/observable state
  unchanged. Publication errors must restore it or block further writes pending
  recovery. No candidate here supplies that protocol.
- **Public registration:** shipped helpers/adapters and consumer ones must use
  the same extension route; include stable rule identity, origin, requirements
  and capability declarations. Explicit replace/disable and
  conflicting-definition rejection belong at composition. Rego's rule union and
  backend module order are not that contract. Unknown capabilities must fail
  before publication.
- **Diagnostics and invalid input:** keep native parse/resolution errors, policy
  violations and operational failures distinct; return contextual selector,
  owner, target and location, plus blocked boundary/path or conflicting parent
  witnesses when relevant. These probes compare verdicts and only selected
  witnesses; no complete diagnostic API exists yet. Invalid candidates remain
  inspectable; a consumer may select a repair strategy.

## Bounded cost measurements

V2 rerun on one host, serial workers, three full evaluations per cell, one
visibility query; each deep workload also closes an interior boundary and
requires the unchanged query to reject. Values are median milliseconds including
each adapter's graph/database construction; OPA includes process startup,
serialization and parsing. This is not a fair kernel microbenchmark or
production latency promise. Inputs were approximately 136 KB and 1.39 MB JSON.
No Scribe parsing, external acquisition, publication or Git work was measured.
[Raw measurements](experiments/results/cost.json).

| Nodes / shape | rustworkx + Python |     Cozo memory Datalog |                 OPA CLI |
| ------------- | -----------------: | ----------------------: | ----------------------: |
| 1,000 deep    |               1.96 | process budget exceeded |                   47.01 |
| 1,000 wide    |               0.86 |                   20.07 |                 1425.98 |
| 10,000 deep   |              75.14 | process budget exceeded |                  369.16 |
| 10,000 wide   |              10.03 |                  242.03 | process budget exceeded |

The process budget was eight seconds for three evaluations plus controls; a
timeout is not a measured per-evaluation latency. These straightforward
encodings are not optimized backend ceilings. They do establish that choosing a
recursive/query engine does not automatically make origin-sensitive graph rules
cheap. No semantic depth bound is imposed; successful 10,000-node deep
rustworkx/OPA controls go beyond recursion-limited toy cases.

Separately, ten base queries in a warm Bun Wasm instance took a median 0.24 ms
over twenty evaluations, with about 2.53 ms initial load. That result has
different workload/process boundaries from the table and cannot be used as a
10,000-node projection. [Bun result](experiments/results/opa-bun.json).

## Incremental/full parity and untested behavior

No finalist prototype implements incremental semantic maintenance. Opening,
moving, changing selector context and replacing snapshots were evaluated through
fresh complete inputs and an independent path oracle. OPA Wasm also reuses a
loaded policy instance while receiving changed complete inputs. That checks
absence of stale per-call answers, **not incremental/full equivalence of a
future engine**.

A full evaluator should remain the reference while dependency-aware invalidation
is introduced. Cache keys/dependencies must include selected hierarchy, owned
relations, node fields, policy artifact/configuration, external snapshot and
required before state. A closed boundary or subtree move may invalidate many
unchanged links. Arbitrary executable callbacks either declare a safe dependency
contract or conservatively invalidate the relevant complete candidate.
Differential Dataflow offers real insert/delete propagation and recursive fixed
points; Salsa offers query dependency tracking, but neither makes opaque
external programs incremental or deterministic.
[Differential Dataflow](https://github.com/TimelyDataflow/differential-dataflow/blob/master/README.md),
[Salsa](https://salsa-rs.github.io/salsa/overview.html).

Still unimplemented/unqualified: Scribe transaction/group lifecycle; staged-Git
capture; publication crash/failure recovery; authenticated identity providers;
full ownership-sensitive baseline projection; target/cardinality production
rules; complete structured diagnostics; public registration/composition;
arbitrary consumer adapter equivalence; cache rebuild; incremental/full
differential testing and realistic mixed-workload costs. The evidence supports
interface design and backend choice review, not Gate 3 completion.

See [design handoff](handoff-for-design.md), [primary source pins](sources.md),
and [reproduction/publication boundary](reproduce.md). End-of-plan clean-fixture
and recipe obligations are explicitly carried in the handoff.

## Packaging entry checks

Narrow read-only evaluation of the filtered StrictDoc toolchain's locked nixpkgs
(`f13ff45afd1bb73e640eaa08a7066dbed07e3238`, Linux x86_64) reports: OPA 1.16.2,
top-level `cozo` attribute absent (`null`), Python 3.13 rustworkx 0.17.1, Python
3.14 rustworkx 0.17.1, Python 3.13 NetworkX 3.6.1, Soufflé 2.5, Bun 1.3.13.
These are evaluated attribute versions, not built/tested closures, and that
upstream lock does not necessarily control a consumer-supplied `pkgs`. Probe
versions intentionally differ where newer packages were acquired in the isolated
environment.
[Recorded evaluation](experiments/results/nix-package-versions.json).

Only the pinned StrictDoc CLI was exercised from its Nix output. rustworkx/Cozo
used Python 3.13 wheels; OPA used an official static binary; the Bun Wasm SDK
used a local npm install. Before implementation adoption, qualify the actual
supported platforms, native dependencies, CPython version, package hash/closure,
cancellation and resource limits in the chosen devenv integration. A successful
source/wheel/addon probe does not establish those properties.
