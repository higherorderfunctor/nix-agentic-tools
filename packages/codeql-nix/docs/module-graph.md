# Observed module graph

> **Last verified:** 2026-10-23 — M3g observes the rich evalModules graph,
> preserving occurrence order, direct disabled flags and atomic completion; F2
> reserves `closure` for graph requests before admission or execution.

## What and why

`ql/queries/DisabledModules.ql` reports every observed module occurrence,
including false disabled flags. Its exact columns are
`(target:text, contextPathJson:text, occurrencePathJson:text, moduleKey:text, originLabel:text, disabled:bool)`.
`Modules::ModuleOccurrence` exposes the reported key, origin, context, target
and Boolean flag; it derives occurrence path JSON from ordered root/import
edges. These are evaluation observations, separate from syntax import edges and
source `disabledModules` expressions. They establish no
declaration-to-disabled-module causal relation.

The producer walks the actual pinned library's rich result `.graph`, whose
collection comes from upstream `collectModules`; it does not reconstruct import
resolution or disabled-key matching. Every exposed root and descendant is
included, even the adapter's appended `{ _module.args = moduleArguments; }`
support root. Internal roots omitted upstream are outside this observation. The
adapter retains its existing authentication and argument injection.

Identity is framed `key("module", [requestID, contextID, occurrencePathJson])`.
The path starts with a zero-based root ordinal, then zero-based import ordinals.
Repeated keys and labels remain distinct occurrences. Root/import list order is
upstream order. `disabled` copies upstream direct membership in its disabled-key
set: a disabled parent's child can be false. It does not describe effective
contributions or final merging. Support-module key collisions retain upstream
behavior; no key is reserved or repaired by the extractor.

Fixture G reports root `[0]` (`root`, `root.nix`, false), children `[0,0]` and
`[0,1]` (both `child`, `child.nix`, true), and support root `[1]` (`:anon-2`,
`<unknown-file>`, false). Removing disabling preserves both child occurrences
with false flags; disabling `root` makes only the root true. Giving the second
child key `other` leaves only the first child disabled. These positions and
support labels are fixture facts, not universal anonymous-key defaults.

## Contract and limits

A request uses domain `module-graph`, facet `closure`, mode `metadata` and
`path=[]`, in the root context only. Capability is `module-graph`. The manifest
schema refuses a graph request with any other facet or a nonempty path before
target admission or execution, and refuses `closure` for `option-metadata`;
discovery rejects multiple graph requests for one context before running
producers; F1 independently enforces request shape and uniqueness on imported
facts. Nested contexts are outside this cut. The supervisor advertises the graph
capability as supported; a rich result without `.graph` returns state `failed`,
reason `graph-unavailable`. This names runtime field absence using the existing
result enum; it does not establish support for every possible library pin.

`nx_modules` holds key, origin and native Boolean flag per occurrence;
`nx_module_roots` and `nx_module_imports` retain contiguous ordinals. Every
occurrence has exactly one root-or-child position and is reachable from roots. A
complete transaction has exactly one observed context witness through
`nx_observation_contexts`, plus one per occurrence through
`nx_observation_modules`, all belonging to that context's closure request. A
context holding module rows must carry that closure request, so these witness
and count checks cannot be skipped by omitting the request. Each observation has
exactly one typed subject. A context witness creates no option observation;
graph requests emit no retained definitions.

`maxNodes` counts the context witness plus every occurrence. Depth counts edges
from a root; `maxDepth=0` permits root leaves. A finite empty exposed graph is
complete with `observedCount=1`; its proof uses independent synthetic protocol
facts because the real adapter appends a support root. Missing rows alone never
prove an empty complete graph or a false flag.

The producer refuses node/depth excess before serialization, preserving
`node-limit`/`depth-limit` instead of a later byte refusal. The supervisor
rechecks graph budgets and applies existing byte, time and memory isolation.
Incomplete closure publishes status/diagnostics without successful observations
or module rows. An imported throw, even below a disabled module, can fail
collection; it must not become empty completion. Cyclic or unbounded import
expansion fails or times out. See
[evaluation-isolation.md](evaluation-isolation.md).

Boolean columns accept only JSON true/false, rejecting integers and strings. The
physical dbscheme uses integer references; TRAP writes `0`/`1` and QL compares
with `1` to expose Booleans. Origins retain reported labels; linking an origin
to source bytes still requires target admission and authentication. See
[database-contract.md](database-contract.md).

## How to change and verify

Keep the existing authorities together: `schema/contract.json` and
`schema/abi.py` define and validate relations; `src/eval/protocol.py` renders
TRAP; `src/eval/nix/modules.nix` emits occurrences; the supervisor authorizes
publication. Update generated schema projections with their existing generator,
then the thin `ql/lib/nix/Modules.qll` and query. Do not change the adapter's
support module to simplify graph expectations. Regenerate instructions through
`devenv tasks run --mode before generate:all` after changing this registered
note. See [module-adapter.md](module-adapter.md).

`checks/fixtures/inc3/graph/oracle.nix` independently invokes `lib.evalModules`
and `lib.modules.collectModules` on original modules with the identical explicit
support module. It imports no extractor or serializer. Installed tests compare
both oracles with query rows, covering repeated keys, root order, path/relative
disabling, support-key collisions, disabled import throws and target isolation.

The existing owner entry `checks.nix` wires Linux `codeql-nix-modules` to
protocol/regression/ownership tests, including typed witnesses, empty
completion, forgeries, uniqueness, budget refusal, malformed-manifest discovery
refusal and module-row closure ownership. Its runner prints
`test_graph_protocol.py: 7 tests, 7 executed`,
`test_graph_regressions.py: 14 tests, 14 executed` and
`test_graph_ownership.py: 9 tests, 9 executed`. The independent O2 regression
prints `test_facet_admission.py: 1 tests, 1 executed`, proving option metadata
cannot use `closure` before admission or execution. The x86_64-linux
`codeql-nix-graph` check runs installed qltests against reviewed expected rows;
find `test_graph.py: 9 tests, 9 executed` and its evidence suffix
`M3g module-graph installed qltest passed`. `codeql-nix-abi` imports native
Booleans through the real schema; `codeql-nix-contracts` covers protocol
sentinels. These are CI entry points and expected log markers, not a claim that
CI has run for this worktree.
