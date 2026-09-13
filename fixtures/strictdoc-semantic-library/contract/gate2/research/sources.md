# Primary sources and measured revisions

Accessed 2026-09-13. Mutable documentation is supporting context; executed
versions and source pins below bound the claims. No third-party comparison
article is used as technical authority.

## StrictDoc and consumer

- Consumer revision: `8563ca852ae083609f97fb52a46c0b07272897ee`; portable batch
  `2d28787d`. Approved filtered artifact:
  `/nix/store/121pk8i5nzhrpm34fv97f7mywin6k1r0-strictdoc-toolchain-source`. Only
  its public implementation was inspected.
- [Pinned StrictDoc source](https://github.com/strictdoc-project/strictdoc/tree/7cf8183498ec87be531499230602df33523ed058):
  installed CLI reports 0.28.3, package
  `/nix/store/qc5w0rnlr2pl8zvaaq5gi6jfhm7h50im-strictdoc`. Build lookup was
  `nix build --max-jobs 1 --no-link --print-out-paths ./inputs/toolchain#strictdoc`;
  existing store output, no broad build.
- [Observed upstream main](https://github.com/strictdoc-project/strictdoc/commit/b56ebb266c0a58f016c3be6ed5337c8a9833be0e):
  latest commit returned by GitHub MCP, dated 2026-09-12. Main was
  source-audited, not installed and run separately.
- [Parent/Child normalization and cycle callbacks](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/traceability_index_builder.py#L650):
  both authored directions populate inverse adjacency; later callbacks omit an
  edge selector.
- [GraphDatabase forwarding default](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph_database.py#L56),
  [bucket all-edge behavior](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph/many_to_many_set.py#L43),
  and
  [ALL_EDGES sentinel](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/graph/abstract_bucket.py#L6)
  explain the measured named-role cycle gap.
  [Iterative cycle detector](https://github.com/strictdoc-project/strictdoc/blob/7cf8183498ec87be531499230602df33523ed058/strictdoc/core/tree_cycle_detector.py)
  has no Python recursion-depth traversal limit. Four relevant source files are
  byte-identical on main/pin; hashes are in
  `experiments/results/native-source-evidence.json`.
- [Current upstream Parent vs Child tailoring documentation](https://github.com/strictdoc-project/strictdoc/blob/b56ebb266c0a58f016c3be6ed5337c8a9833be0e/docs/strictdoc_01_user_guide.sdoc#L2347)
  documents compliance statements and immutable OTS adaptation.
  [Rendered user guide](https://strictdoc.readthedocs.io/en/stable/stable/docs/strictdoc_01_user_guide-TABLE.html)
  corroborates it. These examples describe modeling, not this consumer's
  publication guarantees.
- Filtered `dev/scripts/sdoc_model.py:534` appends a relation and calls node
  validation; `:981` calls `SDocValidator.validate_node`; `:1011` starts
  per-file save. These are separate from whole-candidate graph validation and
  multi-file publication. Existing input packet already reports RPC arrays can
  partially persist.

## Finalists

- [OPA 1.20.2 release](https://github.com/open-policy-agent/opa/releases/tag/v1.20.2),
  released 2026-09-03. Executed official Linux amd64 static asset; SHA-256
  `69da5179ee403d10fa11bab6cfb4ffb0d23dba5f9b682fa977db772a1da5670f`, checked
  against GitHub release metadata. CLI reports build
  `b2c26708e9d55645d7f837db495031f7e4152594-dirty`, Go 1.27.1, Rego v1.
- [OPA graph built-ins](https://www.openpolicyagent.org/docs/policy-reference/builtins/graph):
  `graph.reachable` supports Wasm; `graph.reachable_paths` is SDK-dependent. Our
  actual origin-specific Rego program was compiled and run under Bun. This does
  not establish arbitrary recursive Rego support.
- [OPA language](https://www.openpolicyagent.org/docs/policy-language),
  [error guide](https://www.openpolicyagent.org/docs/errors),
  [CLI flags](https://www.openpolicyagent.org/docs/cli): undefined documents and
  built-in errors require deliberate adapter handling. Division-by-zero control
  returns an empty JSON object by default; `--strict-builtin-errors` returns an
  evaluation error.
- [OPA Wasm JavaScript SDK](https://github.com/open-policy-agent/npm-opa-wasm),
  package `@open-policy-agent/opa-wasm` 1.10.0 from
  [npm metadata](https://registry.npmjs.org/@open-policy-agent/opa-wasm/1.10.0).
  Executed `loadPolicy` and `evaluate` on Bun 1.4.2; local lockfile records
  resolution.
- [rustworkx package metadata](https://pypi.org/pypi/rustworkx/0.18.1/json),
  executed 0.18.1 with CPython 3.13.15;
  [graph/cycle API](https://www.rustworkx.org/apiref/rustworkx.PyDAG.html) and
  [DFS visitor API](https://www.rustworkx.org/dev/apiref/rustworkx.digraph_dfs_search.html).
  Experiments use payload-preserving `PyDiGraph`, ancestors, path and cycle
  calls. Online docs display older/development labels; executed API behavior is
  authoritative for the probes.
- [NetworkX shortest path](https://networkx.org/documentation/stable/reference/algorithms/generated/networkx.algorithms.shortest_paths.generic.shortest_path.html),
  oracle executed on 3.6.1. A different path-based algorithm supplies expected
  decisions; explicit base truth rows are an additional independent control.
- [Cozo 0.7.6 release](https://github.com/cozodb/cozo/releases/tag/v0.7.6),
  published 2023-12-11; executed `cozo-embedded==0.7.6` memory engine.
  [Current repository metadata](https://api.github.com/repos/cozodb/cozo)
  observed `archived=false`, last push 2024-12-04;
  [latest main commit](https://github.com/cozodb/cozo/commit/481af058abac9444ea8c9c52c78f096ed4b5bfc4)
  has that date. Stale release/activity is a maintenance risk, not proof of
  abandonment.
- [Cozo queries](https://docs.cozodb.org/en/dev/queries.html),
  [transactions](https://docs.cozodb.org/en/dev/stored.html),
  [Python fixed-rule examples](https://github.com/cozodb/pycozo/blob/main/README.md#custom-fixed-rules)
  and
  [pinned Python bridge](https://github.com/cozodb/cozo/blob/v0.7.6/cozo-lib-python/src/lib.rs#L279).
  Public `register_fixed_rule(name, arity, callback)` and callback failures were
  exercised.
- [Cozo pinned memory storage](https://github.com/cozodb/cozo/blob/v0.7.6/cozo-core/src/storage/mem.rs#L40):
  transactions hold a shared read guard or exclusive write guard. This explains
  the independently reproduced blocked read while a write transaction is open.
  RocksDB/SQLite engines were not tested.

## Other families considered

- [petgraph 0.8.3](https://docs.rs/petgraph/0.8.3/petgraph/) offers typed graph
  storage and algorithms. [Graphology](https://graphology.github.io/) offers a
  native JavaScript graph alternative. Both still need the semantic layer,
  dependency tracking and publication integration; neither was benchmarked here.
- [Soufflé 2.5 release](https://github.com/souffle-lang/souffle/releases/tag/2.5),
  [tutorial](https://souffle-lang.github.io/tutorial),
  [C/C++ interfaces](https://souffle-lang.github.io/interface),
  [user functors](https://souffle-lang.github.io/functors),
  [provenance](https://souffle-lang.github.io/provenance). Recursive batch
  logic/provenance are useful; no live-deletion maintenance claim is made.
- [Ascent 0.8.0](https://docs.rs/crate/ascent/0.8.0),
  [Ascent source documentation](https://github.com/s-arash/ascent): Rust macros
  provide Datalog, stratified negation, aggregation, composition and custom
  relation structures. No executed incremental retraction claim.
- [Differential Dataflow](https://github.com/TimelyDataflow/differential-dataflow/blob/master/README.md)
  documents changing collections, joins, iteration and insert/delete updates.
  [Salsa overview](https://salsa-rs.github.io/salsa/overview.html) documents
  query dependency tracking. These are incremental machinery candidates, not
  adopted policy languages.
- [Cedar entities](https://docs.cedarpolicy.com/policies/syntax-entity.html),
  [Cedar grammar](https://docs.cedarpolicy.com/policies/syntax-grammar.html),
  [CEL overview](https://cel.dev/overview/cel-overview): authorization/entity
  hierarchy and bounded expressions have useful narrower roles. Custom graph
  preprocessing remains necessary for these requirements.

## Existing Bun/Rust/Python route

Read-only effect-tui audit at revision
`d0d72543a79424242933ecfd557c4d5cbb27351d`, clean worktree. No AGENTS.md existed
at the project/ancestor locations checked or under its scoped packages. Relevant
files: `Cargo.toml:12` pins N-API 3.12.2 and PyO3 0.29.2;
`packages/strictdoc-napi/src/lib.rs:4` forwards a string;
`packages/strictdoc-python/src/lib.rs:18` attaches to Python and calls
`dispatch`; `packages/strictdoc-adapter/src/effect_tui_strictdoc/protocol.py:8`
implements health only; `devenv.nix:93` selects Python 3.13 and module path.
[Bun Node-API documentation](https://bun.sh/docs/runtime/node-api) is broader
compatibility context, not a substitute for these executed controls.

Pinned nixpkgs package attribute versions were evaluated without builds; see
`experiments/results/nix-package-versions.json`. This is availability evidence
for the upstream StrictDoc lock, not qualification of a future consumer closure.

Evidence v2 corrects local probe normalization/coverage and replay instructions;
no upstream version or source claim changed. See `evidence-corrections-v2.md`.
The combined runner used existing dependencies and performed no new source
acquisition or build.
