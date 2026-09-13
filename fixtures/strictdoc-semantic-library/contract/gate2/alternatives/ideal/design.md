# Ideal public policy interface — Gate 2 recommendation

Status: independent design proposal, 2026-09-13. No interface below is an
installed API, no backend has been selected, and no semantic execution has been
demonstrated. Sources are the reviewed requirements, public toolchain brief, and
neutral reference model/scenarios/decisions. The reviewed packet supersedes
older pending labels. Backend research and sibling designs were not consulted.

## Recommendation

Expose a small policy composition library beside the grammar library, plus
public extension registration. A consumer should be able to start with “this
relation targets these elements,” progress to named graph views and comparisons,
and eventually supply a program without changing the surrounding composition or
diagnostic contract. Grammar declarations stay recognizable StrictDoc
declarations. Policy helpers are optional libraries, including helpers shipped
with the engine.

Keep four public responsibilities distinct: author policy bundles, identify
evaluation inputs, execute a complete evaluation, and publish a candidate
through a selected integration. These responsibilities need not become four
processes or four implementation packages. In particular, scheduling a hook or a
transaction must not alter a rule's meaning.

Use ordinary Nix functions/builders for ergonomic construction and serializable
descriptors for direct authoring. Do not make consumers write a backend language
to use standard helpers. Do not require all extensions to compile through a
universal query language. A backend-specific rule is a first-class extension
with an explicit capability requirement and the same result envelope.

Proposed names in [examples.nix](examples.nix) are sketches. The important
commitments are scope, composition, input/result contracts, and equivalence
between helper and direct authoring.

## Authoring surface

A `policy.bundle` is an immutable value with a stable namespace, grammar
references, view declarations, rule declarations, input requirements, and
provenance. It does not launch services or fetch external data during Nix
evaluation. A grammar remains reusable without the policy bundle.

`policy.attach` associates a bundle with an existing grammar declaration. Its
convenience constructors accept relation handles near the grammar, so users do
not repeatedly type a stringly selector. This is an attachment rather than an
expansion of StrictDoc's grammar file syntax. The emitter writes native grammar
artifacts and a separately inspectable effective policy manifest. A consumer can
also keep all policy in a separate Nix file.

The first example attaches four target restrictions and a selected hierarchy to
a neutral grammar. `targets` accepts element handles, not a global element
spelling. `forest` selects explicitly scoped authored declarations, normalizes
their direction, and requires at most one selected incoming parent per record.
All other native Parent/Child links still participate in the complete native DAG
check. Multiple roots and isolated records are permitted.

Views are named reusable descriptions, such as a selected hierarchy or document
membership. Declaring a view does not make all its potential uses validity
rules. A forest helper supplies both its projection and the necessary forest
validity rule; consumers can instead request a general graph view. A dependent
traversal that cannot interpret an invalid forest reports a blocked dependency
while the forest rule supplies the actual counterexample.

Whole-graph, per-document, and change rules use the same bundle model. A rule's
`requires` explicitly names candidate, before, baseline, actor facts, or a view.
Document membership is available to a document-scoped rule but is never silently
substituted for graph ancestry. A document-scoped rule may read the entire model
when it declares that dependency. A rule evaluating transitions must retain both
snapshots, even in a fresh/full run.

The proposed devenv option accepts bundles, runtime registrations, and boundary
configurations. The same values must work through a standalone library runner
and Home Manager packaging when those integration surfaces are provided. The
option is wiring convenience, not the exclusive extension point.

## Scope and identity

Grammar identity is an explicit consumer-chosen stable namespace, distinct from
the digest of its current schema artifact. Element identity is
`(grammar namespace, element name)`. An authored relation selector is
`(grammar namespace, owner element, native type, role)`. Absent role is a
distinct value rather than a wildcard. This prevents a `Parent R` on BAZ from
inheriting the rule for `Parent R` on FOO. A relation handle retains this entire
tuple.

Record identity is `(model namespace, UID)` within one evaluation model.
Duplicate identities are input diagnostics; source paths do not disambiguate
duplicates automatically. Consumers combining models must define namespaces and
cross-model resolution explicitly. An external baseline declares the mapping
between its record identities and the candidate model. The neutral mapping uses
the same namespace and UID; UID replacement therefore appears as deletion plus
creation. Rename continuity and lifecycle identity require a consumer-supplied
mapping with its own ambiguity checks.

Each relation fact preserves owner, declared target, native type, role, model
and grammar context, and source location. Normalized connectivity is separate:
Parent authored on C toward P contributes `P -> C`; Child authored on P toward C
contributes `P -> C`. Reverse display names are display metadata, not additional
authored facts. Native connectivity is never flattened through an adaptation
statement.

Logical rule identity is a stable bundle-qualified name, distinct from its
current artifact digest. Diagnostic identity refers to the logical name and
records the current digest. Locations belong to observations and can change when
records move files. Semantic identity must not depend on location unless a rule
explicitly declares document-sensitive semantics.

For comparison projections, define relation equality explicitly. The neutral
projection is a sorted set of
`(owner, declared target, native type, role, grammar/model context)` with
presentation and order excluded. Native validation independently diagnoses
forbidden duplicate declarations; a set projection is not permission to create
them.

## Selected hierarchy and visibility

A reusable consumer helper takes a forest view, an explicit closed predicate,
and an origin/target mapping. Missing FLAG or values other than the explicit
strings `false` and `true` are input errors; no default opens an invalid
boundary.

For an ordinary selected reference, origin is the declaration owner and target
is its declared endpoint. Require a common selected root, then follow the unique
undirected hierarchy path. Ascent is unrestricted. During descent, a closed node
may be visited, but it may be expanded only when the original origin belongs to
that node's subtree, including the node itself. Other nested boundaries still
apply. No arbitrary depth limit is part of validity.

For a native adaptation statement, origin is the statement's selected Parent
target and destination is its selected Child target. Require one of each
authored endpoint and a downward selected-hierarchy path with the same boundary
predicate. The statement remains an actual node between them in native
connectivity. Equal endpoints create a native cycle independently of a helper's
zero-length reachability convention.

A concrete truth subset, in the neutral forest, is:

| Candidate                                | Result under reviewed rules | Witness                       |
| ---------------------------------------- | --------------------------- | ----------------------------- |
| F1a owns Parent R to F2                  | Valid                       | Closed F2 is the endpoint     |
| F1a owns Parent R to F2a                 | Invalid                     | F2 blocks expansion           |
| F2a owns Parent R to F2b                 | Valid                       | Origin is inside F2           |
| F2a owns Parent R to F1a                 | Valid                       | Leaving F2 is allowed         |
| M owns Parent P to F2 and Child Q to F2a | Valid                       | Closed start counts as inside |
| M owns Parent P to F1 and Child Q to F2  | Invalid                     | No downward H path            |
| M owns Parent P to F2 and Child Q to F2  | Invalid native graph        | Cycle F2 -> M -> F2           |

An implementation may evaluate all references after every edit. An incremental
implementation must discover unchanged references affected by closing F2, moving
a subtree, changing policy, or refreshing an external input. Performance choices
cannot weaken these outcomes.

## Familiar tailoring and the alternative representation

A consumer can declare `REQUIREMENT` records with a selected Parent hierarchy
and a closure field, and `ADAPTATION` records with Parent `source` and Child
`implementation`. An adaptation statement A42 owns Parent `source` to standard
requirement STD-1 and Child `implementation` to project or immutable OTS
requirement OTS-9. Its statement text explains the tailoring. Native
connectivity remains `STD-1 -> A42 -> OTS-9`. The selected hierarchy
independently places OTS-9 below STD-1 through its chosen requirement-role
links; the adaptation links do not manufacture that hierarchy.

This design uses the familiar native Parent/Child tailoring pattern without
asserting current upstream UI or compliance-matrix export behavior. Target
restrictions, cardinality, selected path, and protection of the OTS record are
independently composable consumer policies. They are not inherent meanings of an
element named ADAPTATION.

An alternative consumer declares a statement with string fields `SOURCE_UID` and
`IMPLEMENTATION_UID`, then registers a program that resolves those fields and
checks the same endpoint/path policy. These field references do not become
native Parent/Child edges. If that consumer wants equivalent whole-graph cycle
behavior, it must explicitly request additional connectivity and a rule
validating the union; it cannot claim native graph equivalence merely because
endpoint verdicts agree. The program can alternatively check a different domain
rule, with an honestly different equivalence claim. Direct field/custom logic is
supported without requiring the engine to interpret every UID-looking string as
a link.

## External comparisons and authenticated context

An evaluation envelope identifies the complete candidate snapshot, optional
before snapshot, named comparison baselines, effective policy artifact,
parser/grammar artifacts, and captured external facts. Required inputs must be
present and complete before any dependent rule can pass. A baseline and before
have different roles: a Git main baseline may be months older than the immediate
before state. Neither may be silently substituted for the other.

The neutral preservation helper compares baseline-listed records against
candidate records using a consumer projection: existence, type, FLAG when
present, and owned modeled relations. It excludes incoming links owned
elsewhere, physical location, reverse labels, and runtime bookkeeping. Complete
empty baseline means no listed records are frozen. Supersession does not add an
exception. The example exposes this projection as ordinary consumer
configuration, not a core lifecycle model.

A more realistic consumer bundle captures an explicitly configured Git main ref
to a commit object and parses records from that commit into the same model
identity space. The acquisition result records the ref name, resolved object,
model mapping, extraction/grammar revision, completeness, and content digest.
Configuration chooses local main versus a fetched remote reference; silently
fetching or treating a moving ref name as an immutable snapshot is forbidden.
Capturing a ref once provides snapshot consistency, not a latest-at-publication
guarantee.

Actor facts arrive from a trusted integration, for example the daemon's
authenticated transport principal or an attested Git/CI identity. An arbitrary
RPC `actor=human`, author field, or Git author string is not authentication. The
consumer explicitly binds an identity provider/trust authority; when the
selected integration cannot establish required identity, the rule is
unevaluable. No SSH key management or approval UI is designed here.

A consumer program can express: an authenticated LLM principal cannot alter the
projection of records listed on main; changes to separately classified
human/protected documents require a verified approval bound to candidate digest,
baseline digest, policy digest, and action. Another consumer can define explicit
supersession exceptions or human editing powers. The neutral preservation bundle
grants neither automatically. Required approval missing with a successfully
acquired complete empty approval set is a policy violation; a failed approval
lookup is an input acquisition error.

An executable provider is an ordinary public adapter. Invoke a configured
executable with argv and a versioned request on stdin, never interpolated shell
text. Its response distinguishes complete success, complete empty success,
declared incomplete data, malformed data, nonzero exit, and timeout. Only
complete success becomes an input. Record provider identity, executable/config
digest, snapshot identity and diagnostic status. Bound runtime and output size
through invocation settings; limits cause operational error, not a smaller
semantic dataset.

Sources are captured into immutable values for one evaluation. Providers that
cannot offer a single coherent dataset must fail or identify a consumer-accepted
coherence contract. Independent sources may represent independently captured
times; a policy requiring joint coherence must declare and verify a shared
revision/attestation, not infer it from simultaneous launch. Later source
changes affect later evaluations. An optional publication freshness requirement
may trigger re-acquisition and re-evaluation; it is a boundary policy, not the
reference timing guarantee.

The following illustrative JSON is a complete-empty provider response. Names are
proposed protocol fields; it is not an existing executable response format.

```json
{
  "data": [],
  "schema": "example:modeled-record-baseline/v1",
  "snapshot": {
    "complete": true,
    "digest": "sha256:<content-digest>",
    "id": "S0",
    "model": "example:model",
    "provider": "consumer:baseline/v1"
  },
  "status": "ok"
}
```

A result for failed acquisition instead contains a classified error and no
usable snapshot. The host may synthesize this envelope for a nonzero exit or
timeout. An exit-zero process returning malformed JSON is still an acquisition
error. A valid complete snapshot whose records violate policy remains a
successful acquisition and yields a separate rule violation.

```json
{
  "error": {
    "code": "provider-timeout",
    "provider": "consumer:baseline/v1",
    "requestId": "evaluation-42/main"
  },
  "status": "error"
}
```

## Composition and explicit replacement

Bundles extend one another by union of distinct qualified declarations. Exact
repeated inclusion of the same declaration identity and digest is idempotent.
Two different definitions of one identity are configuration errors even if Nix
option merge order could pick a value. The effective manifest shows each origin
and resolved definition.

A consumer overrides imported behavior with an explicit `replace` or `disable`
operation targeting a qualified identity and expected imported digest/version.
Unknown targets, stale expectations, multiple competing replacements, and
incompatible disable/dependency combinations fail configuration. Replacing
visibility while retaining its logical rule name changes its artifact digest and
invalidates results. Replacement does not silently remove sibling target or
cardinality rules.

Dependencies refer to exported interfaces and schemas, not private generated
rule IDs. If a helper emits several rules, it documents their exported names;
disabling a forest rule while retaining a traversal requiring validated-forest
capability must either provide an equivalent rule or fail configuration.

Native validity is a required input/integration contract for this reviewed
model, not an imported rule that a routine bundle override can erase.
Consumer-defined optional policies remain replaceable. Future support for
inspect-only nonnative models would be a separately named mode with a different
validity claim.

## Backend and tool registration

Publish a registry interface available equally to bundled adapters and
independent consumer libraries. Registration supplies a stable extension
ID/version, supported descriptor kinds and their versioned schemas, required
host/model capabilities, planning/validation entry point, evaluator entry point,
diagnostic mapping, and declared execution properties. Two registrations
claiming the same dispatch key require explicit selection or fail; plugin order
does not select an implementation.

A backend's plan response must accept every assigned rule or explicitly reject
it with a capability diagnostic. The orchestrator confirms that every effective
rule has exactly one evaluator assignment and satisfied dependencies before
execution. Whole-graph DAG enforcement and parser/model fidelity likewise
require a declared and qualified native integration capability; the supplied
brief's mixed-cycle gap cannot be papered over by calling it native.

The portable core needs a versioned snapshot interchange contract and
evaluation/result envelopes. It does not need a universal backend language.
Registered descriptor kinds may carry structured helper parameters, a script
artifact, or a backend-native module. Cross-backend sharing of named derived
values requires an explicitly declared versioned interchange schema. Otherwise
keep that value private to its backend and export only the rule result.

A packaged opinionated helper lowers to these same registered descriptors. The
direct target-restriction example specifies precisely the same selector and
expected elements as the helper; their normalized descriptors should compare
equal before execution. A direct custom-program rule binds whole snapshots and
returns ordinary diagnostics. A backend-native module bypasses a helper but
still declares input/output schemas, rule identities, scope, and capabilities.
Its consumer accepts backend dependence explicitly.

Registration is not a promise that all implementations are equally fast or
deterministic. Unknown dependency footprint means conservative full
invalidation. Incremental capability is optional; correctness is mandatory.
Nondeterministic or uncaptured providers disable reusable result caching unless
the consumer provides a stable captured observation. Cyclic view/input
dependencies are configuration errors. No evaluator may silently truncate
traversal because of depth or execution limits.

## Evaluation and result contracts

A composite helper or program declares its exported child rule identities before
evaluation. Every child must return a result; undeclared result identities are
protocol errors. This is how the repository-policy program exports separate
main-protection and approval rules while retaining one implementation artifact.

Separate configuration failure, input acquisition/parsing failure, policy
invalidity, and publication failure. Each rule result is `satisfied`,
`violated`, or `unevaluable`; the aggregate report is `valid`, `invalid`, or
`error`. A report containing both a violation and a provider failure remains an
error with all known diagnostics retained. A skipped required rule cannot
produce valid. Inspection may return partial findings with explicit
incompleteness.

A useful diagnostic carries producer category, stable code, logical rule ID and
artifact digest, subject identities, authored selector, source locations,
related records, and structured evidence. Evidence may be a cycle, hierarchy
path and blocked boundary, two selected parents, missing endpoint count, old/new
projected fields, or provider failure. Separate authored relation ownership from
connectivity direction in every witness. Messages are human-readable; consumers
should not parse their prose.

An evaluation receipt binds the report to candidate/before/baseline digests,
captured facts, effective policy, grammar/parser and evaluator versions,
configuration, and execution context required by rules. Optional fields are
explicitly absent, not fabricated. Reordering diagnostics need not invalidate
semantic equivalence, but rules and relevant witnesses must agree between
helper/direct and full/incremental evaluation.

Evaluation itself is read-only and must not rewrite authored input to make it
valid. Invalid input remains loadable enough for inspection and diagnostics
wherever parsing permits. Parse failure provides source diagnostics and blocks
rules needing unavailable facts. Candidate validity is judged over the entire
selected scope, not just the edited records.

## Validation boundaries and grouped work

A boundary configuration says what candidate is evaluated, when, with which
captured inputs, and how success is consumed. A daemon transaction and a Git
hook can use the same bundle with different candidate acquisition. Neither
boundary changes forest, visibility, or preservation mathematics.

A proposed transaction API creates a private workspace with an explicit before
digest, group identity, and authorized contributors. Parallel agents stage
changes against numbered workspace revisions; conflicts require resolution
before sealing. `seal` closes the group at a particular revision, so no
contributor can change the candidate during evaluation. Missing approvals or
required contributors may be group policy, separate from semantic validity. A
session containing serialized direct writes is not a transaction.

For the reference strong boundary: begin, stage incomplete M, add Parent P, add
Child Q, seal, evaluate complete final candidate, then publish conditionally
against the before revision. Removing then re-adding Q is valid if the sealed
result contains exactly one Q, irrespective of intermediate order. Semantic
refusal discards the private candidate and leaves authored files and observable
graph unchanged. The publication adapter must restore prior state or enter an
explicit recovery-required mode blocking further writes if publication fails.
Success follows acknowledged publication/model consistency, never merely
successful evaluation.

The daemon integration must advertise and qualify this publication contract. A
separate sidecar cannot confer atomicity on Scribe, authored files, Git, or
arbitrary direct filesystem writers. Stale before revision refuses publication
or restarts evaluation against a new candidate; it never reuses approval of
different bytes. Crash recovery guarantees require later integration
experiments.

A Git commit hook evaluates the staged tree, not a mixture of the worktree and
index. Its before is explicitly chosen, ordinarily the parent commit; its main
comparison remains a separately captured baseline. The hook refuses the commit
on invalid/error and leaves the user's already edited files/index available for
repair. This refusal guarantee differs from a private transaction's unchanged
authored state: the hook did not perform the preceding edits. Local hooks alone
cannot establish trusted identity or non-bypassable enforcement; an enforcing
integration must provide those capabilities when the consumer's rule requires
them.

A transaction followed by a commit has two boundaries. The hook may reuse the
transaction receipt only if candidate bytes/tree, before where required, policy,
captured sources, and required context match its evaluation contract. Otherwise
it evaluates again. A successful transaction does not promise a successful
commit, and a refused commit does not retrospectively undo the published
transaction.

Invalid-base repair defaults in the reference recipe to complete final validity.
A consumer can select a different explicit repair admission policy, such as an
assessed waiver for known violations, through the same public rule/result API.
The report must retain underlying invalidity; do not relabel a waived invalid
graph as mathematically valid. Do not allow a repair policy to conceal missing
required before/baseline inputs.

## Context boundaries

Keep authored documents/grammar, compiled policy configuration, captured
external facts, authenticated actor context, invocation scheduling, and
disposable indexes conceptually distinct. Fields containing “human” are authored
data; trusted principal claims are integration inputs. Model namespace
identifies records; a source path is a diagnostic location. A Git hook
configures candidate capture; it does not redefine an edge. A cache accelerates
evaluation; it is never an authority for facts missing from its immutable
envelope.

Configuration, rule artifact, provider configuration/revision, identity/approval
context, or grammar/parser changes invalidate relevant receipts even without
SDoc edits. Cache deletion and complete rebuild must preserve decisions. Full
evaluation is the reference equivalence oracle for identical envelopes;
incremental execution must retain enough dependency information or
conservatively rerun.

## Unresolved tradeoffs and later evidence

1. How much of the snapshot interchange should mirror upstream structures versus
   provide a smaller stable contract? Ownership, direction, model context,
   document membership, and location cannot be lost either way.
2. Should helper composition lower to a few public standardized descriptor kinds
   or primarily plugin-owned kinds? Too many standard kinds can become a
   universal language by accident; too few can make equivalent direct authoring
   awkward.
3. How should expected replacement revisions be expressed for an evolving
   consumer helper: digest, interface version plus digest, or a pinned bundle
   lock? Silent overwrite remains unacceptable.
4. Which integration can actually provide sealed multi-agent staging and the
   required publish/recovery contract? No current-runtime claim or backend
   selection answers this.
5. Which trust authority provides actor/approval facts in local hooks, daemon
   use, and later server enforcement? Separate SSH identities express intent,
   but the authenticated binding must be demonstrated by the eventual
   integration.
6. Does a consumer want UID migration continuity, projection equality across
   schema revisions, or latest-main-at-publication? All need explicit additional
   contracts; the neutral recipe deliberately uses stable UIDs, compatible
   projections, and captured snapshots.
7. Which witness equality is required for multiple valid paths in general
   graphs? The selected forest has a unique path, but custom graph helpers may
   need normalized witness equivalence rather than byte equality.
8. How should an admission policy report permitted repairs that leave known
   violations? Keep validity and publication authorization separate, and retain
   the reference complete-validity recipe until another policy is chosen.
9. Performance and language/runtime choice remain open. No JVM; SQLite is
   disfavored by the reviewed requirements. No package builds, backend
   comparisons, or costs were measured in this design.

The next review should judge consumer ergonomics and these tradeoffs against the
independent tool-informed design. Gate 3 implementation, final runnable recipes,
and removal of generic Scribe's mandatory repository fields remain later
obligations; none is represented as completed here.
