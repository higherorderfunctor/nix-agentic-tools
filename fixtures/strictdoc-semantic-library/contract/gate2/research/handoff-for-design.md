# Tool-informed design handoff

Evidence v2 supersedes v1 only as the factual corrections recorded in
[evidence-corrections-v2.md](evidence-corrections-v2.md). The backend
recommendation is unchanged.

This is the complete independent tooling-research handoff for a fresh workflow
2b designer. Read the shared reviewed requirements as authority. No
ideal-interface drafts, old semantic surfaces, repository grammar values,
docs/spec/plans or coordinator scratchpad informed this research. Exact public
names and decomposition remain yours to design. No backend or Gate 3 production
implementation is approved.

## What the evidence changes

1. **Parent and Child are native and both matter.** Native CLI controls accept a
   bridge record owning Parent to an upper endpoint and Child to a lower
   endpoint, multiple roots, and multiple native parents. Native ownership must
   be preserved independently of directional connectivity and reverse display
   labels.
2. **Native whole-graph cycle coverage currently has a role bug.** Pinned
   StrictDoc 0.28.3 accepts named Parent-only, Child-only and mixed cycles; the
   same graphs without roles reject. `GraphDatabase` forwards default
   `edge=None`; the bucket requires `ALL_EDGES=".all"` to include named roles.
   Current upstream main has identical relevant source. The existing native
   cycle algorithm detects the mixed cycle when explicitly given all roles.
   Prefer correcting/reusing native coverage instead of assuming no native DAG
   facility exists.
3. **Scribe integration is independently incomplete.** Current relation mutation
   appends authored relations then validates a node; it does not establish
   complete final-candidate graph validation or multi-operation atomicity.
   Existing individual writes/RPC arrays do not supply consumer-selected
   transaction groups.
4. **Graph semantics need not select a database.** rustworkx, OPA graph
   built-ins and Cozo recursion each implement the origin-sensitive traversal
   truth table. Their representations and costs differ; none provides
   Scribe/files/Git publication recovery.

Sources and exact revisions are in [sources.md](sources.md); measured native
controls are in [native.json](experiments/results/native.json) and
[native-scope.json](experiments/results/native-scope.json).

## Recommended options to design against

Carry forward a graph-library implementation close to StrictDoc as the leading
option; Python/rustworkx is already exercised, while a shared Rust/petgraph
kernel or Bun/Graphology remains a reasonable alternative requiring its own
integration proof. Treat OPA/Rego as an optional public adapter and direct
authoring route. It can run as an executable or as compiled Wasm under Bun;
neither process arrangement should define the public semantic model. Keep Cozo
as a capable alternative with maintenance, locking and deep-query cost
reservations. Soufflé/Ascent may suit consumers wanting compiled Datalog. Do not
impose a universal backend-native language.

The effect-tui route is real but narrow: at
`d0d72543a79424242933ecfd557c4d5cbb27351d`, Bun 1.4.2 loads a N-API addon that
calls Rust/PyO3/Python and returns JSON. Health succeeds; unsupported graph
operation fails. The adapter explicitly reports backend unconfigured. It proves
interop for this host, not a graph implementation, async cancellation,
concurrency or portable builds.
[Executed interop result](experiments/results/interop.txt).

## Tool-native authoring affordances

These are actual experiment/native tool syntax, **not proposed library API
names**.

### Grammar and native tailoring

The existing public grammar DSL has these constructors; there is no
semantic-policy API yet:

```nix
(el "ADAPTATION" {} {
  fields = [
    (field.required (field.str "UID"))
    (field.str "STATEMENT")
  ];
  relations = [
    (rel.parent "Adapts" "AdaptedBy")
    (rel.child "AppliesTo" "AppliedBy")
  ];
})
```

An adaptation statement can own:

```text
[ADAPTATION]
UID: ADAPT-1
STATEMENT: Apply the selected standard requirement to the OTS component.
RELATIONS:
- TYPE: Parent
  VALUE: STANDARD-1
  ROLE: Adapts
- TYPE: Child
  VALUE: OTS-1
  ROLE: AppliesTo
```

Connectivity is `STANDARD-1 -> ADAPT-1 -> OTS-1`. This follows upstream's
documented compliance/OTS-tailoring pattern. The example presumes endpoint
records and grammar are present; it is a design illustration, not an executed
Scribe recipe. Keep both relation-owner and model/type/role context available. A
consumer-defined selected hierarchy need not include either adaptation relation.

An alternative consumer can author endpoint identifiers, lifecycle facts or
classifications as ordinary fields and implement lookup/comparison logic in a
custom callback/tool. Such field references do not silently become authored
native Parent/Child relations. Expose fields and document context publicly so
that a helper or consumer can define that mapping or a field-only check
explicitly. Equivalent high/lower-layer expressions must mean the same thing;
different consumer models need not manufacture native links for convenience.

### Direct Rego

The actual [policy.rego](experiments/scripts/policy.rego) uses complete
contextual selectors, derives selected parents/children, and constructs
adjacency per original origin. Expansion allows open nodes or a boundary
containing that original origin. It calls:

```rego
inside(origin, boundary) if boundary in graph.reachable(parents, {origin})
```

The full program distinguishes reaching a closed endpoint from expanding it. It
also compares a captured baseline projection and returns structured sets.
Invocations exercised:

```bash
opa eval --strict-builtin-errors --stdin-input --data policy.rego data.gate2.result
opa build --target=wasm --entrypoint=gate2/result policy.rego
```

Bun loads the resulting bytes with `loadPolicy(bytes)` from
`@open-policy-agent/opa-wasm@1.10.0`, then calls `evaluate(input)`.
[Executed CLI/library controls](experiments/results/finalists.json),
[Bun Wasm controls](experiments/results/opa-bun.json). Built-in errors can
otherwise become undefined; an adapter must reject missing/malformed/incomplete
required results. Rego rule merging does not implement explicit public rule
replacement/disable semantics.

### Direct library callbacks and Datalog

The rustworkx experiment constructs `PyDiGraph`, stores authored relations as
edge payloads, uses native ancestors/path/cycle algorithms, and retains original
query origin. Python owns policy-specific decisions and snapshot handling; that
division is explicit in [finalists.py](experiments/scripts/finalists.py).

The actual [Cozo program](experiments/scripts/traversal.cozo) carries query
identity through recursive facts:

```text
inside[id, origin] := query[id, origin, _, _]
inside[id, p] := inside[id, c], edge[p, c]
expand[id, n] := inside[id, n]
reach[id, c] := reach[id, p], edge[p, c], expand[id, p]
```

Its full file adds open expansion, initial nodes and optional ascent. This
syntax is attractive for recursive relations, but the straightforward deep-chain
prototype exceeded its bounded process budget. No depth cap is a rule. Cozo's
public `register_fixed_rule("ConsumerSum", 1, callback)` was exercised with an
independently supplied Python sum and a failing callback. Both normal result and
operational error propagate. Its `multi_transact(True)`, `run_script`, `abort`,
and `commit` work for database state; memory-engine independent reads block
behind an active writer. It does not make a convenient indefinitely open shared
staging area without further design.

### External programs

[providers.py](experiments/scripts/providers.py) acquires an executable's JSON
output and distinguishes complete empty, protected records, nonzero exit,
timeout, malformed JSON, incomplete output and missing snapshot identity. Its
wire shape is a test harness choice. A public command/process adapter should
accept consumer-selected executables and expose explicit acquisition failure,
completion and snapshot identity. Capture once for one evaluation; changed
external state affects the next. Latest-at-publication is a separate stronger
option, not an established guarantee. No authenticated SSH provider or UI was
implemented.

## Public-interface obligations the tools do not solve

Design grammar-adjacent convenient declarations alongside
document/whole-graph/change policy composition and lower-level extension.
Packaged helpers and adapters must register exactly as independent consumers
can. Rule identities, origins, explicit disable/replace, conflicting duplicate
rejection and capability negotiation remain host responsibilities. Do not let
backend module order silently settle semantics or silently omit unsupported
rules.

Model validity over coherent before/candidate/policy/external inputs; design
invocation separately. Consumers must be able to use a daemon transaction, a Git
commit boundary, or a transaction followed by commit validation. Parallel agents
need deliberate group membership and an explicit finalization decision. Validate
complete final candidates while allowing private incomplete staging. For Git,
identify the actual staged tree and appropriate comparison baseline, rather than
reading an unrelated worktree state. Hooks do not authenticate a caller by
themselves.

A semantic refusal must preserve authored files and observable state.
Publication failure must restore prior state or enter explicit recovery-required
mode that blocks writes. Choose a recoverable multi-file publication strategy
later; a sidecar transaction is no proof of filesystem or Git atomicity.
Preserve invalid input for inspection and diagnostics. The reference
complete-repair policy is one consumer policy/boundary choice; do not hardcode
it as the only possible lifecycle.

Structured diagnostic expectations include stable rule identity, full selector
context, relation owner/target/type/role, source/document location, blocked
boundary and path, or all conflicting selected parents. Missing
acquisition/before/baseline must report inability to evaluate, not policy
success. Identity/external projections and baseline freeze ownership are
consumer-defined. Incoming native connectivity is not automatically an
owned-record revision.

## Evidence boundary and costs

Thirty evaluator comparisons cover ten Parent-selected and ten explicitly
Child-authored hierarchy truth rows, Child-boundary opening, opening a boundary,
nested closure from an internal origin, each contextual selector component, and
subtree movement. Additional controls cover mixed cycles/Child ownership,
snapshots, Cozo transaction abort/commit, custom fixed rules and executable
failures. The path oracle independently normalizes authored directions and uses
a different path algorithm. Literal Child downward and boundary expectations
prevent agreement through a shared reversal mistake. CLI and Wasm protection
controls now include unchanged and changed projections under the same nonempty
snapshot. These tests do not implement all reviewed behavior families or
production diagnostics.

The 1,000/10,000-node synthetic probes demonstrate cost, not latency guarantees.
V2 rustworkx full evaluation medians ranged 0.86–75.14 ms. OPA CLI ranged
47.01–1,425.98 ms on completed cells, but 10,000-wide exceeded the eight-second
process budget for three evaluations. Cozo completed wide cells at 20.07/242.03
ms; deep cells exceeded that budget. Warm Bun Wasm on only the ten-query base
fixture measured about 0.24 ms and is not comparable to a 10,000-node CLI
result. [Raw cost data](experiments/results/cost.json).

No incremental semantic evaluator was implemented. Fresh recomputation agrees
across mutations; a loaded Wasm instance sees changed inputs correctly. Future
incremental results must match a full evaluator for identical inputs, including
changes to policy/provider configuration with no SDoc edit. Cache/index state
remains disposable; opaque external programs need explicit safe dependencies or
conservative re-evaluation. Neither a general graph library nor an executable
escape hatch automatically maintains those dependencies.

## Delivery and qualification still required

- Gate 3 and later must implement/qualify actual Scribe target restrictions,
  selected hierarchy cardinality, origin-sensitive visibility/bridge rules,
  consumer protection/identity policies, validation boundaries, and publication
  recovery.
- Demonstrate a consumer-defined backend/tool through public registration, then
  the same decisions through direct/lower-level and convenient grammar-adjacent
  layers. Include explicit unsupported-capability and conflicting-rule controls.
- Qualify rename/context independence, ownership-based projections,
  unchanged-link revalidation, missing before/baseline, reload/restart, cache
  deletion/rebuild, policy/source-only changes and full/incremental parity.
- After the final qualification gate and before folding into trial, remove
  mandatory repository-specific guarded fields from generic Scribe. Neutral
  fixtures must have no `AUTHORED_BY` or `PARENT_FP` declarations/content,
  including renamed substitutes. Historical notes must not contaminate the clean
  fixture boundary.
- Prepare readable Markdown recipes and material suitable for generated agent
  steering for **every behavior family**, beyond fixtures. Include native Child
  tailoring and field/custom-logic alternatives; external identity/baseline
  acquisition; protected/human approval policy; explicit transaction groups; Git
  hooks; recovery; direct backend/tool authoring; diagnostics and cache/rebuild.
  Gate 2 examples remain honest design illustrations; runnable recipes must be
  verified against implementation before landing. Steering placement is
  deferred; no SDocs or docs/spec/plans edits now.

The experiment input shapes, provider JSON envelope and file names are
deliberately local probe choices. They do not constrain your public interface.
The recommendation is for the next human review, not an implementation mandate.

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
