# Proposed consumer interface for Gate 2 review

Recommend preserving the existing StrictDoc grammar DSL and adding **policy
bundles beside grammars**, **public adapter registrations**, and **separately
selected validation boundaries**. Convenient declarations should resolve to
inspectable rule descriptors; direct Python, Rego, Datalog, and executable
authoring should remain useful without translation into a universal rule
language. Prefer a graph-library adapter near StrictDoc as the first
implementation candidate to review, with OPA as an optional direct policy
adapter. No backend is adopted by this recommendation.

This is independent workflow 2b's completed design proposal, dated 2026-09-13.
The [reviewed requirements](../../reviewed-requirements.md) authorize this Gate
2 work and override blanket `PENDING` notices in the older reference. They do
not approve the new API names below or fix every reference example as universal
policy. Production Gate 3 requires the next human review.
[examples.nix](examples.nix) is a concrete **PROPOSED, parse-only** artifact.
[coverage.md](coverage.md) maps all 44 numbered cases; [recipes.md](recipes.md)
contains draft human instructions and reusable steering text for every family.

## V2 evidence review

The original frozen design used `inputs/research` (v1); root independently
archived that output. This revision updates its evidence to
[research v2](../../research/evidence-corrections-v2.md), without changing the
interface or backend recommendation. The proposed Nix artifact is unchanged. The
existing contract already normalizes Parent as target-to-owner and Child as
owner-to-target, keeps native ownership, and compares captured protected
content. The corrections strengthen evidence for those requirements rather than
require new API machinery. Native cycle findings and all production
qualification limits remain unchanged.

V1's shared projection and Rego adjacency reversed every selected edge; its
kind-selector control excluded Child edges and did not prove a selected Child
hierarchy. V2 corrects direction handling and independently normalizes the path
oracle. It records **30 evaluator comparisons plus four capability records**
(v1: 24 plus four), including ten literal Child-hierarchy expectations and their
boundary-opening updates across all three backends. Wasm also passes the Child
expectations and open/close controls. CLI and Wasm now accept an unchanged
record under a nonempty protected snapshot before rejecting its changed
projection under that same snapshot. This closes an always-reject false-positive
gap in the narrow probe; full ownership-sensitive protection and acquisition
integration remain unqualified.

The supplied
[combined replay record](../../research/experiments/results/combined-v2.json)
reports `--all` exited 0 on the original host with existing dependencies,
including native, backend/provider, Wasm, cost and interop controls. Expected
bounded Cozo lock/cost timeouts remain reported, not hidden failures. The
corrected [replay instructions](../../research/reproduce.md) require copying
experiments to disposable scratch before setup/run; here the packet is
`inputs/research-v2`, not the example layout's `inputs/research`. Backend-only
replay avoids native/addon prerequisites; `--all` needs the explicitly recorded
native artifacts and host addon. New-host setup/platform qualification is still
unclaimed. This design review did not replay experiments, access that host
checkout, acquire tools or build anything.

## Why these tools change the recommendation

The existing
[public grammar DSL](../../../../../../packages/strictdoc-grammar/lib/dsl.nix)
already has `el`, `field.required`, `field.one`, `rel.parent`, `rel.child`, and
raw constructors. Its ordered native element list and normalized grammar
validation are useful consumer interfaces. Preserve them. Do not put semantic
keys inside values sent to the existing grammar checker; do not claim it already
exports a semantic API or a boolean constructor. Explicit `UID` declarations
remain necessary. The existing devenv `grammars.<name>.target/elements` flow
remains recognizable.

StrictDoc already normalizes Parent and Child connectivity and supports the
familiar compliance/adaptation record. The supplied research found a specific
gap: pinned StrictDoc 0.28.3 accepts named-role Parent-only, Child-only, and
mixed cycles, although corresponding unroled graphs reject. Its callbacks
forward `edge=None`; the underlying bucket needs `ALL_EDGES = ".all"` to include
named edges. The
[scope experiment](../../research/experiments/results/native-scope.json) shows
the existing detector rejects the mixed cycle with explicit all-edge selection.
Reuse/correct that capability through a qualified adapter and run it over the
**complete candidate**. Neither that prototype nor this proposal repairs Scribe.
Current node validation and serialized mutations still do not establish
whole-candidate validation or multi-operation transactions. These claims are
bounded to the revisions in [sources.md](../../research/sources.md); no upstream
or external repository was visited for this design.

| Tool affordance                                                        | Consequence for the consumer surface                                                                                 | Evidence and limit                                                                                                                                                                                         |
| ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Python/rustworkx preserves payloads and offers graph algorithms        | Permit ordinary callbacks over immutable native facts plus reusable forest/path views; do not require a database     | [Research](../../research/research.md) exercised rustworkx 0.18.1 on CPython 3.13.15; no public runtime integration yet                                                                                    |
| OPA has direct Rego modules, `graph.reachable`, CLI and Wasm execution | Expose artifact, entrypoint, input binding and output validation directly; a consumer can own a complete Rego policy | [Executed policy](../../research/experiments/scripts/policy.rego), [Bun results](../../research/experiments/results/opa-bun.json); no arbitrary recursive Rego or portable path-witness built-in guarantee |
| Cozo has recursive relations and `register_fixed_rule`                 | Allow native Datalog artifacts and consumer callback registrations inside its adapter configuration                  | [Handoff](../../research/handoff-for-design.md); memory transactions block independent reads during writes; old release/activity and deep-query costs weaken its default case                              |
| External programs return captured structured output                    | Make executable acquisition and checking first-class public extension routes, with completeness and error contracts  | [Provider controls](../../research/experiments/results/providers.json); no authenticated identity service was tested                                                                                       |
| Bun/Rust/Python interop returns health and propagates errors           | Allow independent runtime registration, rather than binding every backend to the Scribe interpreter                  | Supplied research reports health only; no graph, cancellation, concurrent-safety, or platform qualification                                                                                                |

The v2 cost evidence continues to favor starting with full graph-library
evaluation, without promising incremental execution. Median milliseconds from
the supplied combined rerun are:

| Nodes / shape | rustworkx + Python |     Cozo memory Datalog |                 OPA CLI |
| ------------- | -----------------: | ----------------------: | ----------------------: |
| 1,000 deep    |               1.96 | process budget exceeded |                   47.01 |
| 1,000 wide    |               0.86 |                   20.07 |                1,425.98 |
| 10,000 deep   |              75.14 | process budget exceeded |                  369.16 |
| 10,000 wide   |              10.03 |                  242.03 | process budget exceeded |

Each eight-second worker budget covers three runs plus controls, not one
measured latency. The generalized Rego projection's 1,000-wide result is about
1,426 ms, versus about 268 ms in v1; this reinforces the existing optional-OPA
performance caveat, not an optimized backend ceiling. The same three cost cells
exceed the budget. Warm Bun/Wasm's **0.24 ms median and 2.53 ms load** concern a
different, tiny ten-query base workload. V2 retains twenty samples and uses the
mean of the two middle sorted samples, replacing v1's upper-middle statistic
without retained samples. See the
[cost evidence](../../research/experiments/results/cost.json) and
[Wasm result](../../research/experiments/results/opa-bun.json). These exclude
Scribe parsing, providers, Git and publication; none establishes a production
threshold or incremental algorithm.

Python with rustworkx is therefore a leading candidate for the next review
because of measured capability and proximity to StrictDoc. Rust/petgraph or
Bun/Graphology remain credible alternatives with missing execution/packaging
evidence. Soufflé and Ascent can be independently registered compiled logic
adapters. Differential Dataflow and Salsa may later support maintenance; they
are not the consumer policy surface. No JVM is allowed. No measured need
justifies SQLite or a persistent graph database here.

## Entry points and ownership

Propose a small library provisionally called `contracts`, separately supplied to
the consumer from the existing `grammar` library. The name is open. Its builders
produce plain checked data with explicit semantic identities; they do not
execute external programs during Nix evaluation.

| Entry point                                                    | Proposed result and use                                                                                                                  |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `c.element { native; policies = self: [...]; }`                | A native element plus adjacent policy declarations; `self.parent "R"` captures grammar, owner element, native type and role              |
| `c.grammar { id; elements; }`                                  | `{ elements; bundle; }`; `elements` contains only existing normalized native grammar values                                              |
| `c.targets`, `c.forest`, `c.visible`, `c.bridge`, `c.preserve` | Opinionated, parameterized helpers; each exposes expanded rule/view IDs and its effective definition                                     |
| `c.bundle { id; includes; rules; views ? []; }`                | Whole-model, document and change rules collected for composition; inclusion is a set of identified definitions, not rule execution order |
| `c.compose { bundles; edits; }`                                | Validated effective policy with explicit replace/disable actions and provenance                                                          |
| Plain rule/view/registration descriptors                       | Equally supported authoring; usable without helpers or devenv                                                                            |
| `ai.strictdoc.contracts`                                       | Proposed convenience attachment for the model's bundle; current `grammars` options continue to hold native grammar only                  |
| `ai.policyRuntime.registrations`                               | Public list of runtime/backend/facts/publisher descriptors                                                                               |
| `ai.validation.boundaries`                                     | Named daemon/Git/custom validation boundary selections, independent of policy meaning                                                    |

These are proposed additional options, not installed exports. A CLI or embedded
caller can pass the same effective bundle and registration manifest without Nix
modules. `examples.nix` sections `N1`–`N11` demonstrate both paths. Its
`proposedModule` selects only the reference policy; `lifecyclePolicy`, Rego
replacement, and alternative field tailoring are separately exposed examples,
not silently enabled consumer decisions.

`c.forest` returns `view` and `bundle`: the view identifies selected directional
connectivity, while its bundle declares target prerequisites, selected-parent
cardinality and forest validity. `c.bridge` expands into stable endpoint
cardinality rules and a traversal rule. Helper IDs are predictably derived, such
as `fixture/bridge/upper-count`, `fixture/bridge/lower-count`, and
`fixture/bridge/path`; `inspect` must list them. Named helper presets can change
only through a versioned artifact and explicit policy review. The global native
DAG rule covers every authored Parent/Child relation, including other roles and
other element types; its binding must not inherit the hierarchy selector.

Scopes describe subjects and diagnostic grouping. A model rule sees the complete
configured model, not a single file. A document rule has a document subject but
may declare whole-model and captured before/baseline dependencies. A change rule
can compare before/candidate/external facts. Scopes do not restrict graph
visibility or imply that only touched documents need checking. Preserve document
identity/location even when a particular policy excludes it. One record per
document remains consumer packaging.

## Native facts and selected views

Expose versioned immutable `ModelSnapshot` facts: model/root and grammar
identities, grammar artifact identity, ordered document records, addressable
nodes with native element and raw fields, authored relation records, and
diagnostic source spans. Node identity is contextual `(grammar, UID)` with an
explicit model namespace; endpoints resolve to node references, not whichever
matching string happens to load first. Cross-grammar references require an
explicit resolver contract; ambiguous UIDs are input errors. The reference only
needs one grammar.

Each authored relation retains owner, target, owner element, native
`Parent`/`Child` type, nullable role, reverse display role and source.
Connectivity is a separate view: an owned Parent points from target to owner; an
owned Child points from owner to target. Reverse display labels create no
additional authored facts. File relations remain available as native data but
are not silently inserted into Parent/Child DAG checks. Missing endpoints,
duplicate/ambiguous identities and malformed fields must remain distinguishable
from a custom target-type refusal.

The reference helpers explicitly bind `FOO/H`, `FOO/R`, `BAR/P`, and `BAR/Q`;
the engine contains none of these names. `BAZ/Parent/R` is an unrestricted
context control. At most one selected H parent permits other native parents.
Forests may have several roots, and native bridge records stay in the complete
graph even though their edges are not selected H edges. Consistent renaming
changes no rule meaning.

For reference visibility the required `FLAG` string maps `false` to open and
`true` to closed. Absence or other values are input errors. After proving the
selected graph is a forest, find the unique path in that tree. R traversal may
ascend and then descend. Descent may visit a closed endpoint; it may expand a
closed node only when the **original origin** is in that node's subtree,
including itself. A closed origin can leave, visit internal peers or start a
downward bridge. Other nested boundaries still apply. No traversal follows a
shortcut from an unselected role, crosses independent roots, or has a semantic
depth cap. Invalid hierarchy prerequisites produce a blocked dependent-rule
result, not an invented path.

This can be implemented with a path library, origin-specific Rego adjacency, or
origin-carrying recursive Datalog. A global graph with all closed outgoing edges
deleted is incorrect for the closed-origin/internal-peer cases. Helper expansion
declares this precise behavior as a capability requirement; it does not silently
downgrade to simpler reachability.

The reference bridge record owns one Parent to U and one Child to D, leaving
`U -> M -> D`. Its helper requires exactly one of each endpoint in a completed
candidate and a downward H path under the same boundary policy. Equal endpoints
violate the native DAG regardless of conceptual zero-length reachability.
Similarly, an ancestor's Parent R to its descendant closes a native cycle. Such
refusals cannot prove visibility rejection.

## Tailoring in two consumer models

Use native `ADAPTATION` records for the documented compliance/immutable OTS
pattern. An adaptation statement owns `Parent Adapts -> STANDARD-1` and
`Child AppliesTo -> OTS-1`. Both endpoint records can remain unchanged. The
helper can enforce endpoint types or approval of the adaptation. The reference
bridge's downward-H requirement is optional consumer policy here: a standard/OTS
model without a common selected hierarchy must not inherit it accidentally. The
[tailoring recipe](recipes.md#r03-native-child-tailoring) includes actual draft
SDoc content and explains this choice.

For a field-oriented consumer, `ADAPTATION_FIELDS` carries `UPPER_UID` and
`LOWER_UID`; its custom callback resolves each exactly once, checks selected
endpoint types and any explicitly selected path/boundary policy, and reports the
fields as witness locations. The `N6` example additionally requests a virtual
`U -> adaptation -> D` graph union for a DAG check. Those are derived edges with
field provenance; they do not become authored native links. This prevents
falsely accepting equal-endpoint loops when comparing against reference bridge
decisions.

Equivalence is conditional. With identical resolvers, endpoint multiplicity,
path semantics, union-DAG rules and projection mapping, the two representations
can agree on endpoint/path decisions. They do not inherently agree on native
StrictDoc traceability, reverse navigation, exports, compliance matrices, link
editing, or authored-ownership protection. A field-only representation without
the virtual DAG check has still weaker equivalence. Materializing native links
would be an explicit authored change validated and published through the chosen
boundary, not a side effect of checking fields. No universal backend language or
compulsory field naming is required.

## Direct rules and tool-native authoring

The raw `N2` target descriptor is a meaningful alternative to `c.targets`: it
names the complete selector, permitted element references, candidate
dependencies, execution backend/entry and diagnostic schema. Its normalized
semantic definition must match the helper version; provenance may identify
different authoring locations. Supporting direct descriptors is a documented
compatibility obligation, not an internal escape hatch.

A raw view descriptor similarly names `id`, input requirements,
backend/entry/config, result schema and invalidation strategy. For example
`fixture/H` can invoke `graph-library:selected-forest/v1` over the contextual H
selector. Consumers may instead produce the same `forest-view/v1` with their own
backend and validate it. The host rejects cycles in the dependency graph and
missing/incompatible view schemas. Views are disposable data, never extra
authored edges.

For callbacks, propose `check(evaluation, config) -> RuleResult` with immutable
facts and schema helpers. A full consumer callback can be written without
graph-helper syntax. For example, the following draft Python body enforces the
raw target rule; its result constructors belong to a future consumer SDK:

```python
def check(evaluation, config):
    findings = []
    for link in evaluation.candidate.authored_relations:
        if not matches_context(link, config["select"]):
            continue
        target = evaluation.candidate.resolve(link.target)
        if target.element_ref not in config["allowed"]:
            findings.append(target_type_finding(link, target, config["allowed"]))
    return complete_result(evaluation.id, findings)
```

`matches_context` compares all four selector components. Resolution failure is
an input error under the prerequisite schema, not a wrong-target finding. An
external Rust/Bun/Bash program can implement the same operation over serialized
facts. The host validates its output even when its input contract was accepted.

OPA authors should register a Rego artifact and entrypoint directly (`N5`). The
supplied program already demonstrates `inside(origin, boundary)` via
`graph.reachable(parents, {origin})`, and per-origin down-expansion, so a direct
visibility rule need not call a hidden host traversal service. The adapter binds
immutable model data and consumer configuration to input, validates required
output, and associates findings with host rule IDs. A consumer Rego result can
use this shape:

```rego
package consumer.targets
import rego.v1
violations contains {"owner": r.owner, "target": r.target, "code": "target-type"} if {
    some r in input.candidate.authoredRelations
    r.grammar == input.config.select.grammar
    r.ownerElement == input.config.select.ownerElement
    r.nativeType == input.config.select.nativeType
    r.role == input.config.select.role
    target := input.candidate.nodes[r.target]
    not target.elementRef in input.config.allowed
}
result := {"evaluation": input.id, "complete": true, "findings": violations}
```

This is draft consumer code over the proposed JSON binding; it was not run.
Contextual node references use adapter-issued canonical map keys here.
Resolution prerequisites ensure the target exists; otherwise a missing lookup
could incorrectly disappear from a Rego set. The adapter supplies rule
identity/location from the matched relations and validates completeness. OPA CLI
must use strict built-in errors. Undefined result documents, missing expected
query results, invalid output and unsupported built-ins are execution/capability
failures, never empty success. Wasm needs independently qualified error and
output handling; successful `graph.reachable` does not prove
`graph.reachable_paths` support. Boundary/path witnesses must be produced
explicitly or supplied by a declared compatible witness provider; boolean-only
output cannot satisfy that required capability.

A Cozo adapter may expose native program parameters and
`fixedRules = [{ name; arity; callbackArtifact; }]`. The measured
`register_fixed_rule("ConsumerSum", 1, callback)` shows a real consumer
affordance. Keep query identity/origin in recursive relations as in the supplied
[Datalog program](../../research/experiments/scripts/traversal.cozo). Callback
failures remain operational failures. Cozo transaction state belongs to that
backend's cache lifecycle, not the Scribe publication lifecycle. Do not leave a
database write transaction open while several agents stage work. A consumer may
choose a compiled Soufflé/Ascent tool in the same executable route; no automatic
cross-language compilation is promised.

## Public registration contract

All packaged adapters must return the same descriptors an independent consumer
can write by hand. There is no privileged package-name dispatch or registration
reserved for fixture helpers. `N4` gives raw runtime/backend/facts examples and
a packaged graph descriptor factory beside them. Registry entries have
namespaced IDs, immutable artifact identity, protocol/schema versions and
provenance. Fact executable identity and configuration are included by the host
in the effective registry identity even when the concise Nix declaration only
supplies an executable path.

| Registration kind | Required public interface                                                                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runtime           | `protocol`, immutable runner identity, transport, execution/cancellation capabilities and resource limits; opens/closes sessions without owning publication |
| Backend           | runtime reference, artifact/format, named entrypoints, accepted fact/config schemas, result schemas, provided capabilities and full/incremental support     |
| Facts             | executable/callback acquisition, requested schema, dependencies on other captures, authority binding, completeness/identity protocol and time/output limits |
| Publisher         | candidate/base receipt inputs, qualified refusal and recovery capabilities, publish/status/recover operations; no policy bypass                             |

Proposed runtime operations are `describe`, `prepare`, `evaluate`, `cancel`, and
`close`. `describe` negotiates protocol and capability versions; `prepare`
validates artifacts and entries; `evaluate` takes an identified immutable
evaluation plus configured rule invocations; `cancel` acknowledges cancellation
or returns a bounded failure; `close` drops disposable state. Process transport
frames requests/results with lengths or equivalent unambiguous framing. Protocol
stdout is separate from bounded diagnostic stderr. Python in-process and
Bun/Wasm adapters may use an equivalent call ABI rather than stdio. These are
design contracts, not implementation claims about the current interop addon.

A strong publication profile also requires checks/providers to have no write
access to published authored state. Immutable input objects alone do not isolate
an arbitrary executable. A runtime must qualify this restriction through its
process isolation/capability arrangement; if it cannot, the strong profile is
unsupported. Consumer tools can perform authorized external reads, but checking
must not silently mutate authored files or use external side effects as a
transaction. That restriction is part of the public runtime contract, including
packaged adapters, and has not been established by the supplied health/provider
probes.

For facts, `capture(request)` returns either
`{status: "complete", id, schema, data, provenance}` or a typed error. Empty
`data` is meaningful only in a complete success. The host computes a content
digest and binds provider artifact/configuration so a provider reusing an ID for
different content cannot poison the cache. Identity/provenance must meet the
consumer trust configuration; self-asserted provenance is not authentication.
Deadlines, output limits, process-tree cancellation and isolation need platform
qualification. A timeout is inability to evaluate, never semantic invalidity or
a graph depth limit. An adapter cannot claim termination/determinism simply
because it wraps an executable.

For rules, `RuleResult` includes rule/evaluation identity, completeness,
findings, and optional validated dependency/witness data. Findings distinguish
policy violation, needs-review and diagnostics. Host statuses distinguish
configuration error, input error, execution error, blocked prerequisite and
fully evaluated valid/invalid. A result must account for every invoked
rule/query; omission cannot mean pass. Diagnostics retain producer, selector
context, subjects, owner/type/role/target, source spans and useful witnesses
such as all selected parents, roots, blocked boundary/path, or baseline diff.
Ordering of independent findings is not semantic.

Registration cannot silently fulfill an unmet requirement with a weaker adapter.
Native `all-role-DAG`, whole-candidate checking, origin-sensitive traversal,
path witnesses, authenticated capture, or restore-or-block publication each
require explicit advertised support and later conformance evidence. The present
stock Scribe adapter cannot honestly advertise the strong capabilities.
Preflight must reject the strong boundary configuration until the implementation
is qualified. An explicitly configured full evaluator is an acceptable fallback
for absent incremental support; automatic rule dropping or fallback to stale
results is not.

## Policy composition and consumer lifecycle

Distinct rule IDs compose conjunctively across model, document and change
bundles. A violation or unmet approval in any required rule prevents
publication; operational failures prevent a complete validity claim.
Document-level permission does not override model-level refusal. Warnings
require an explicit severity policy and cannot downgrade mandatory structural
constraints in a boundary advertised as implementing the reviewed contract.

Compose **lists of definitions**, retaining origins before Nix module merging
can erase them. Repeated inclusion of the same canonical definition may
deduplicate with all origins recorded; differing definitions under the same
identity are errors. Ordinary `mkForce`, module ordering, Rego unions and `//`
are not semantic override mechanisms. `replace`/`disable` requires target ID,
expected definition identity and reason; unknown IDs, stale expectations,
competing replacements, replacement-plus-disable, duplicate backend IDs and
incompatible view definitions fail composition. Process actions against the
original effective set, not sequential list precedence. Explicit replacement
that weakens an approved profile makes a different profile; required native
safety capabilities remain prerequisites for publishing under the reference
profile. Inspect output must show effective rule IDs, expanded helpers,
disabled/replaced definitions, origins and capabilities.

`N3` deliberately separates reference preservation from illustrative lifecycle
choices. The reference projection freezes baseline-listed existence, element
type, `FLAG` if applicable and **owned** modeled native relation sets. Incoming
relations, file placement, reverse display labels and runtime bookkeeping are
excluded. UIDs remain contextual identities. Changes to an owned H parent
violate preservation; a new incoming edge owned elsewhere does not, subject to
all other rules. Projection identity and canonicalization version are inputs.
Supersession grants no exception in this example.

A separate consumer can choose a trusted main-snapshot provider, verified actor,
document classifications and approval facts. `consumer/main-llm` illustrates
denying LLM revisions to main-listed records; `consumer/human-review`
illustrates requiring a human decision for protected/human-authored document
changes. Both are consumer code using public facts. Neither rule is a universal
engine default, and their projections need not equal the neutral record
projection. A later supersession workflow can explicitly allow selected
transitions through a replacement policy; it must also deliberately resolve any
still-active preservation rule. An approval does not implicitly waive structural
validity or another rule's denial.

Separate SSH identities can establish principals through a trusted host/session
attestation provider, but a request's `actor=human` label and a commit author
string do not. No key management, private-key reading or UI is proposed here. A
future TUI/web UI can supply a verified approval tied to candidate, before,
effective policy, captured main and principal identities, with approver
authority, decision ID and consumer-defined expiry/revocation rules. Missing
approval yields `needs-review`, blocking publication. Failed approval
acquisition yields execution error. Request edits after approval invalidate its
binding; the UI approves a concrete candidate, never an unbounded future change.

## Coherent evaluation inputs

An `Evaluation` binds identified before and candidate snapshots, effective
grammar/policy/registration artifacts, named fact snapshots, trust context and
invocation boundary. `N10` is illustrative data. The host captures bytes/content
and identities; a path or mutable ref alone is insufficient. A provider can
depend on earlier captures, for example approval on resolved main and principal,
but cyclic dependencies fail preflight. Every required fact is acquired once and
pinned for the evaluation. Cross-source consistency requirements are explicit:
when a provider says it classified main revision A, it must match the captured
main A. There is no claim that independent external systems were read at one
globally atomic instant.

`before` is the state this transition proposes to replace; `baseline` is an
independently identified policy input, often main, which may differ from before.
`candidate` is the complete selected final state. Never substitute candidate for
absent before or assume failed baseline acquisition means empty. State-only
rules can still return useful diagnostic results when a change rule is blocked,
but the overall required evaluation remains incomplete and cannot authorize
publication.

For daemon staging, capture a base revision and freeze final candidate bytes at
finalization. For Git, capture the index tree (including additions/deletions and
relevant grammar/policy artifacts), explicit before tree, and resolved main
revision through the consumer provider. Do not read unstaged files as the
candidate. Unmerged index entries are input errors. A trusted policy-loading
configuration must govern which candidate policy changes are authorized; a
candidate must not self-disable protection by supplying its own untrusted
policy. Policy artifact changes are themselves reviewable inputs.

The reference timing rule captures snapshots per evaluation. If S1 becomes S0
while a check runs, that run uses S1; an intentional retry may capture S0. This
is not latest-at-publication consistency. A stronger consumer option would need
revalidation and appropriate source leases/CAS support, with bounded retries;
unsupported sources must reject that option. At publication the local
base/candidate/policy binding still must match. Receipt reuse is allowed only
for identical relevant inputs and an admissible trust/freshness policy; a Git
hook may require a new approval capture even after a daemon pass.

## Validation boundaries, parallel work and recovery

Rules define validity; boundaries select the captured transition and when
evaluation occurs. Offer named daemon transaction, Git commit and combined
profiles (`N8`), plus public custom boundary adapters. A daemon profile can
validate a final candidate after private incomplete staging. A Git-only profile
validates already-authored staged content and blocks commit on refusal; it
leaves the user's index and worktree edits intact. Thus Git-only does not
provide unchanged worktree bytes relative to before editing. Reference
`Unchanged` assertions for refused mutations apply to the strong private-staging
publisher, while a hook's unchanged boundary state means it performs no mutation
or commit. This difference must be explicit in qualification and UI wording.

The proposed group lifecycle is
`begin -> stage -> ready -> finalize -> evaluate -> publish`, with `abort`,
inspection and recovery branches. `N10` shows agent A creating M/P and agent B
adding Q under one group. Each participant is authorized for that group;
membership is explicit, not inferred from shared files or clock proximity. Stage
requests carry expected group revisions to detect overlapping updates. Readiness
binds to the current revision; later staging clears readiness. A coordinator
finalizes only when required participants are ready at the same revision. A
stalled participant leaves inspectable staging; timeout cannot imply consent.
Coordinator replacement, membership removal and abort are explicit audited
actions under consumer policy. Staging is private to the group; regular readers
see published state.

Validate the complete final candidate, regardless of intermediate zero/two
endpoint counts or staging order. Concurrent published-base change yields
`stale-candidate`; rebase/merge the private candidate explicitly and validate
again. A mutex serializes publication but cannot substitute for this group
lifecycle. Git users can group agent patches by assembling an index/tree and
declaring it ready, but filesystem conflicts and partial staging still require
deliberate resolution. A transaction followed by commit can reuse a receipt only
under the identity rules above.

Separate `valid` from `published`. A proposed publication receipt records
transaction, before/candidate identities, validation receipt and observed
installed state. The publisher must qualify: no authored or observable change on
semantic refusal; on publication failure, restore prior bytes/model or enter
`recovery-required` with writes blocked. A likely later design needs an intent
journal, exact before/after manifests, publication exclusion and reload
verification, but this review does not choose a filesystem protocol. A Cozo
transaction, daemon mutex, or atomic rename of one file proves none of
multi-file/Scribe/Git atomicity. External readers bypassing the publisher and
crash windows require explicit qualification.

Recovery exposes transaction status, changed paths, before/after identities,
last completed phase and safe restore/reload actions. After uncertain failure,
do not automatically retry non-idempotent publication; query its transaction ID
first. Only clear the block after authored and observable state agree and
validation has the required captured inputs. Failed or timed-out publication
never returns success. Reload/cold restart must reproduce reported accepted
state; rejected candidates remain inspectable separately. Disposable caches can
be discarded during recovery but are not evidence that authored files were
restored.

Invalid input stays readable and diagnosable. The reference repair profile
requires a fully valid final candidate, and missing before/baseline cannot be
bypassed as “repair.” Another consumer could explicitly define progressive
repair against before violations, but that requires violation identity and
protected invariants; it is not implied by this proposal and is not silently
enabled. Hooks and daemon staging use the same chosen repair policy over their
selected snapshots.

## Full evaluation, maintenance and remaining review choices

Start with full evaluation as the oracle. Incremental mode must return identical
validity and meaningful witness semantics for identical
before/candidate/policy/facts. The cache key includes model/grammar identities,
native facts and selector context, policy/configuration and adapter artifacts,
before when read, external snapshots, authority bindings and projection
versions. Relocating a document may preserve a semantic result but still
requires refreshed diagnostic locations; document-sensitive rules must
invalidate.

A changed closed flag, subtree move, role, endpoint, insertion/deletion or
policy artifact can affect unchanged links. Provider-only changes must
invalidate dependent results. Opaque executable rules default to
whole-evaluation invalidation; narrower dependencies require a sound, versioned
contract, including collection membership and negative lookups. Fresh Wasm
inputs and repeated full probes establish no incremental maintenance.
Time-dependent policy must consume a captured clock fact; nondeterministic
providers must be captured or disable unsafe reuse. Cache/index deletion must
rebuild identical results without changing authored state.

For later qualification, compare helper/raw/backend variants on G02/T07/E01, all
context renames, declaration reordering/document movement, full versus
incremental operation sequences, policy/source-only changes, missing-input
errors, and cache rebuild. Measure 1,000/10,000-node shallow/wide and
deep/narrow workloads with parsing, serialization, providers, initialization,
local edits, subtree moves, source revisions and publication costs separately.
Record cancellation/failure limits without inventing latency targets. X07
remains an optional separately approved numeric extension challenge.

The next human review should settle names and bundle placement, the preferred
implementation candidate and runtime delivery, trusted policy-loading rules,
actual main/merge-before semantics, lifecycle projections and supersession
exceptions, approval authority/expiry, supported boundary profiles, and the
exact publication/recovery guarantee. Group coordinator takeover and any
progressive-repair policy also need consumer decisions. None blocks completing
this Gate 2 proposal.

Source gaps remain for authenticated SSH/session capture, approval service/UI,
staged-Git integration, robust publication/recovery, portable dependency
closures, cancellation and resource isolation, direct adapter diagnostic
equivalence, and incremental maintenance. The supplied package availability
probe used the filtered toolchain's lock (OPA 1.16.2, rustworkx 0.17.1, Bun
1.3.13), which differs from experiment versions. It is not a built supported
closure. No network, installs, builds or new backend experiments were used here.

After the final qualification gate and before folding into trial, generic Scribe
must lose mandatory `AUTHORED_BY`/`PARENT_FP` policy. Neutral fixtures must
contain neither declarations/content nor renamed substitutes; historical
evidence must be outside their final boundary. The proposed neutral grammar
intentionally omits them and consequently is not claimed runnable on stock
Scribe today. Repository protection must be demonstrated through the same public
extensions as a consumer. All recipes and generated steering must be made
runnable and verified against the final implementation before landing; steering
placement is deferred. No SDocs, production code, repository specifications or
plans are changed by this delivery.
