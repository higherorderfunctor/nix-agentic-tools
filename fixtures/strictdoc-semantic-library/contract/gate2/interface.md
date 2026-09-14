**Proposed public contract — entirely unimplemented.** This document specifies
minimum behavior for the [recommended declaration](recommended.nix). Names,
signatures, schemas and protocol messages here are proposals, including those in
code blocks. Existing `grammar.dsl` native constructors are the only current
library operations used by that declaration. Parsing Nix does not resolve any
proposed function or establish an integration capability.

The [review](README.md) recommends Python/rustworkx for the first
implementation, with native StrictDoc reuse and an optional OPA adapter. Neither
backend choice nor the experiment JSON becomes the public model. The governing
inputs are the [reviewed requirements](reviewed-requirements.md) and
[reference model](../model.md).

**Authoring and options.** The proposed `policy` library, abbreviated `p`, is
separate from `grammar.dsl`, abbreviated `g`. All builders are pure Nix-to-data
functions; runtime acquisition never happens during Nix evaluation. The proposed
`native =` input accepts existing normalized grammar elements, including values
authored with `g.el`; it is not a faithful-constructor or validation bypass. The
current DSL already preserves this normalized authoring layer. See the
[public-surface controls](normalized-authoring/README.md).

| Proposed signature                                                           | Result and required meaning                                                                                                                                                         |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `p.element { native; policies = self: [Rule]; }`                             | Element wrapper. Within `p.grammar`, `self.parent role` and `self.child role` produce selectors with the enclosing grammar and native owner tag; `null` means absent role.          |
| `p.grammar { id; elements; }`                                                | `{ elements; bundle; }`, stripping wrappers from native elements and collecting adjacent rules into a bundle. Plain native elements are also accepted. Grammar imports stay native. |
| `p.bundle { id; includes ? []; rules ? []; views ? []; }`                    | Bundle of identified definitions, with inclusion provenance.                                                                                                                        |
| `p.compose { bundles; edits ? []; }`                                         | Checked effective manifest; expanded definitions, original/effective digests, origins, dependencies, edits and required contracts. No execution.                                    |
| `p.targets { id; select; allowed; }`                                         | One Rule: `sdoc-policy.targets/v1`, model scope, candidate input, resolved-endpoint capability, config `{select; allowed;}`. Exact direct form is in N2.                            |
| `p.forest { id; nodes; select; }`                                            | `{ view = {id; schema;}; bundle; }`. Exports view `id` of `sdoc-policy.forest/v1` and rule `id + "/valid"`. Select is a list of contextual Parent/Child selectors.                  |
| `p.visible { id; select; hierarchy; boundary; }`                             | One Rule: `sdoc-policy.visible/v1`, candidate plus validated forest, same-tree undirected path, original owner as origin.                                                           |
| `p.bridge { id; records; upper; lower; hierarchy ? null; boundary ? null; }` | Bundle with `id + "/upper-count"`, `"/lower-count"` (exactly one) and, only when hierarchy is provided, `"/path"` (downward). Uses public count/path descriptors below.             |
| `p.preserve { id; baseline; projection; }`                                   | One Rule: `sdoc-policy.preserve/v1`, candidate plus named complete baseline; no implicit exceptions.                                                                                |

`ElementRef = {grammar; element;}`.
`Selector = {grammar; ownerElement; nativeType; role;}` matches every component
exactly; there is no implied wildcard. A field reference is
`{grammar; element; name;}`. These are plain data and need no handle
constructor. Selectors are interpreted within an explicitly bound model; a
bundle reused on another model has a distinct evaluation binding.

Proposed module options:

```text
ai.strictdoc.policy = { model; effective; nativeRule; }
ai.policyRuntime = { registrations = [Registration]; bindings = [Binding];
                     mode = "full"; }
ai.validation.boundaries = { <name> = Boundary; ... }
```

Existing `ai.strictdoc.grammars.<name>.{target,elements}` continues to emit
native grammar. `policy.effective` is the composed manifest. `nativeRule` names
the required complete all-role DAG rule for this reviewed profile. Removing that
rule fails profile preflight. Optional policies can be explicitly disabled. The
standalone host accepts these same three values without Nix modules. Document
inclusion/root, grammar selection and installed/project packaging remain
consumer configuration; these options do not silently discover scope.

**Rule, view and binding descriptors.** All fields below are proposed. A rule
has one result covering its complete selected subject set, including zero
subjects. A document rule is invoked over the declared document subjects and may
read the complete model; a change rule reads before and candidate.

```text
Rule = { id; scope = "model" | "document" | "change";
         contract; config; inputs = { <localName> = InputBinding; ... };
         needs = [Capability]; after ? [RuleId]; }
InputBinding = { from = "candidate" | "before" | "fact:<id>" | "view:<id>";
                 schema; }
View = { id; contract; config; inputs; needs; after ? [RuleId]; schema; }
Binding = { contract; implementation; entry; }
       or { rule; implementation; entry; }  # explicit per-rule selection
```

A per-rule binding takes priority only because it explicitly names that rule; it
must implement its declared contract. Multiple bindings at either specificity
are errors. Every rule/view gets exactly one assignment. A view implementation
returns identified disposable data; `after` results must be satisfied before its
dependent operation can claim success. No circular dependencies or implicit
cross-backend private-object access are permitted.

Helper lowering is public, versioned and inspectable. All standard rules read
candidate `sdoc-policy.model/v1`; additional inputs are listed here. The shipped
adapter has no reserved route to implement these contracts.

| Proposed contract              | Config and evaluation obligations                                                                                                                                                                                                                                       |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sdoc-policy.native-dag/v1`    | Empty config; normalize **all** authored Parent/Child declarations across roles and elements. Require complete native resolution; report cycle and authored-edge witnesses. Native parse/resolution errors remain input errors.                                         |
| `sdoc-policy.targets/v1`       | `{select; allowed = [ElementRef];}`; check each matched declaration's resolved target. A wrong but resolved type violates; missing target is an input error.                                                                                                            |
| `sdoc-policy.forest-valid/v1`  | `{nodes = ElementRef; select = [Selector];}`; selected normalized endpoints must be members, no cycles, at most one distinct incoming selected parent; multiple/isolated roots permitted. Duplicate authored declarations remain separately subject to native validity. |
| `sdoc-policy.forest-view/v1`   | Same config, `after = [id + "/valid"]`; output the versioned forest view, never silently repair an invalid projection.                                                                                                                                                  |
| `sdoc-policy.visible/v1`       | `{select; boundary;}` plus `hierarchy` input; check original owner to declared endpoint in one selected tree.                                                                                                                                                           |
| `sdoc-policy.count/v1`         | `{records = ElementRef; select = Selector; min; max;}`; count matched owned declarations for every selected record in the final candidate. Zero counts are observable.                                                                                                  |
| `sdoc-policy.endpoint-path/v1` | `{records; upper = Selector; lower = Selector; boundary;}` plus hierarchy; after both count rules, require downward path from upper target to lower target.                                                                                                             |
| `sdoc-policy.preserve/v1`      | `{projection;}` plus `baseline` input of `sdoc-policy.baseline/v1`; listed identities must exist and equal their old projections.                                                                                                                                       |

`forest` exports the valid rule and a dependent view descriptor. Visibility
requires that view, not merely a claim that some arbitrary graph is a forest.
Its serialized value is
`{nodes = [NodeRef]; edges = [{parent; child; declarations = [RelationRef];}]; roots = [{node; root;}];}`.
Edges use normalized direction; every node has exactly one root entry, including
itself if isolated. The schema validator checks coverage, references and
consistency with the selected candidate. Independent producers must satisfy the
same contract.

`Boundary = {field = FieldRef; open = ["false"]; closed = ["true"];}` in the
reference. Sets must be disjoint; missing, multiple or unknown field values are
input errors. On the unique hierarchy path, ascent is unrestricted. Descent may
visit a closed node, but may expand it only if the **original origin** lies in
its selected subtree, including itself. Check every nested boundary. Visibility
allows ascent/descent; endpoint-path allows descent only. Neither uses other
roles or a semantic depth cap. A closed origin can exit or reach internal peers.
An invalid forest blocks path evaluation with a causal reference to its finding.

`bridge` does not add or flatten edges: native connectivity remains upper →
statement → lower. Native tailoring can use only endpoint target/count rules; a
common hierarchy/path is optional consumer policy. Equal endpoints make a native
cycle independently of conceptual zero-length reachability.

The proposed preservation projection is a whitelist:

```text
Projection = { id; fieldsWhenPresent = [FieldRef];
               elementType = true; ownedRelations = "set"; }
```

Existence is always checked for listed NodeRefs. Element type includes grammar
identity. Field presence differs from an explicit empty value; selected values
are compared exactly. Owned relation sets compare
`(owner, resolved target, nativeType, role, owner grammar/model context)`;
order, reverse labels, incoming relations, file placement and temporary
bookkeeping are excluded. Raw duplicate relations are not erased from native
validation. Schema-incompatible baseline projections error; schema/identity
migration needs an explicit mapping contract. This limited helper need not
absorb arbitrary consumer projections: custom rules can read complete snapshots
and define richer equality.

**Minimum shared model and captured inputs.** These are proposed required
fields, not a verified interchange schema. Serialization and native extraction
must be frozen as entry condition C1 below before implementing an adapter.

```text
NodeRef = {model; uid;}            # grammar is metadata, not a UID disambiguator
RelationRef = {snapshot; id;}     # snapshot-local occurrence, not persistent ID
Location = {document; path; start; end;}  # coordinates fixed by C1
ModelSnapshot = {
  schema = "sdoc-policy.model/v1"; model; digest; complete;
  grammarArtifacts = [{id; digest;}]; parserArtifact;
  documents = [{id; path; bytesDigest; nodes = [NodeRef]; native;}];
  nodes = [{ref; element = ElementRef; document;
            fields = {<name> = [String]; ...}; locations; native;}];
  authoredRelations = [{id; owner = NodeRef; declaredTarget;
    target = NodeRef; nativeType; role; reverseRole; location; native;}];
}
Baseline = {schema = "sdoc-policy.baseline/v1"; model; projectionDigest;
            records = [{ref = NodeRef; value = ProjectedRecord;}];}
ProjectedRecord = {element = ElementRef; fields = {<name> = [String]; ...};
                   ownedRelations = [CanonicalRelation];}
```

Baseline fields follow the projection whitelist. Duplicate baseline or candidate
NodeRefs error. Ordinary native UID resolution is model-wide; separate grammars
do not make duplicate UIDs safe. Multi-model or renamed-UID continuity needs an
explicit resolver/mapping; no first-match or basename fallback. Grammar
namespaces are stable logical identities, distinct from schema artifact digests.
Native Parent normalizes target → owner; Child owner → target. Reverse labels
create no authored facts. Preserve document membership and fields for consumer
logic without making document layout ancestry. File/other native relations
remain available under tagged native data and are not silently inserted into the
DAG. An unsupported native form must block a rule that requires it, not
disappear.

Model `complete=true` requires successful extraction and resolution for its
advertised schema. Invalid authored input still has a separate inspection report
with available partial facts and source diagnostics; partial facts cannot be
passed as a complete model. Structurally invalid but resolved graphs can be
complete snapshots and then violate DAG/forest rules.

An `Evaluation` binds
`{id; candidate; before?; policyDigest; registryDigest; grammarDigests; facts; context;}`.
Each snapshot/fact is immutable and retained, not just a mutable path/ref. A
receipt binds all of those plus implementation, parser, projection, config and
binding identities and the complete report. Before is the replaced state; main
is a separate baseline, never a substitute. Source/policy/config changes
invalidate dependent results without SDoc edits. Locations are refreshed after
moves even when a logical result can be reused.

**Public implementations and tools.** Proposed registrations share
`{kind; id; artifact; runner;}`; artifact identifies executable/module and
config content, not a trusted display name. Runner is a versioned call ABI or
`{protocol = "sdoc-policy.runner/v1"; argv; limits = {timeoutMs; outputBytes;};}`.
Bundled factories return these public descriptors without implicit privileges.

| Kind             | Additional proposed required fields and operations                                                                                                                                                          |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `implementation` | `entries = [{name; contract; inputSchemas; configSchema; resultSchema; capabilities; mode = "full";}];` supports `describe`, `plan`, `evaluate`. A single library or external tool can own several entries. |
| `source`         | `schema; config; dependencies = [SourceId]; trust;` supports `capture`. Inputs may include candidate/before and earlier captured facts.                                                                     |
| `model`          | `schema; capabilities;` supports `capture` and `inspect` over identified document/grammar bytes. Resolves native facts and reports extraction errors.                                                       |
| `boundary`       | `capabilities;` supports candidate capture, status and the chosen staging/publication operations below. Neither it nor an evaluator may bypass required policy.                                             |

The first process transport uses one UTF-8 JSON request on stdin and one JSON
response on stdout per invocation, exit zero on protocol success. Stderr is
bounded diagnostic text; nonzero, timeout, extra/malformed stdout, wrong request
ID and output overflow error. Long-lived/in-process runners must expose the same
message semantics; they are optional delivery choices, not compulsory services.

```text
Request = {protocol; requestId; operation; payload;}
Response = {protocol; requestId; status = "ok"; value;}
        or {protocol; requestId; status = "error";
            error = {code; message; details;};}
describe({}) -> {entries; operations; schemas; capabilities; artifactDigest;}
plan({manifestDigest; invocations; inputSchemas; requestedCapabilities;})
  -> {planId; accepted = [{id; entry; dependencies;}]; rejected = [{id; reason;}];}
evaluate({planId; evaluation; invocations = [{id; entry; config; inputs;}];})
  -> {evaluationId; complete = true; results = [RuleResult]; views = [ViewResult];}
capture({evaluationId; candidateDigest; beforeDigest?; policyDigest;
         context; dependencies; config;})
  -> {schema; snapshotId; complete = true; data; provenance;}
```

Planning must account for every assigned invocation exactly once. Any rejection,
unknown entry/schema, unsupported witness or unsatisfied capability prevents a
complete evaluation. Static descriptors and `describe` must agree. Capabilities
are claims requiring conformance evidence, not certificates of correctness. No
fixture tags or shipped IDs may be recognized specially by the host.

An external Bash/Rust/Bun/Python tool can implement this protocol. OPA can
instead receive its own native module/entrypoint through an OPA registration,
translating only input/result envelopes; consumers need not translate Rego into
shared expressions. Datalog/fixed callbacks work similarly through their own
adapter. OPA CLI requires strict built-in errors; an undefined decision is an
error, never an empty satisfied result. Wasm error/witness handling needs
separate qualification.
[Executed Rego](research/experiments/scripts/policy.rego),
[primary CLI documentation](https://www.openpolicyagent.org/docs/cli),
[Cozo public Python callbacks](https://github.com/cozodb/pycozo/blob/main/README.md#custom-fixed-rules).

Providers may return complete empty `data`, but incomplete data must return an
error. Host validation distinguishes declared incomplete, nonzero exit, timeout,
malformed, missing identity, schema error and trust failure. It computes content
digests, so a reused snapshot label cannot alias changed content. The successful
capture becomes an immutable fact for this evaluation. Joint coherence requires
an explicit matching revision/attestation across sources; parallel acquisition
is not global atomicity. Later source changes affect later evaluations.

`trust` chooses a consumer authority/verifier registration and provenance
binding. An untrusted declaration cannot install its own verifier. The concrete
verifier entry/authority-evidence schema is a required design clarification
before any source depending on that trust can run; the Nix argument
`consumerTrustRegistration` is a consumer-supplied proposed descriptor, not an
implemented authentication service. Even the reference source needs a selected
trust policy (for example trusted fixture producer), not implicit package trust.
A trusted main source resolves a configured local or remote-tracking ref once to
a commit object and records extraction/grammar/mapping identities; it does not
silently fetch. Verified principal capture must bind the actual
daemon/SSH/session or enforcing commit context. Authored labels, Git author
strings and caller-selected names are never evidence of authentication. Approval
facts bind candidate, before, main, policy, principal and action; consumer rules
define authority, expiry, revocation, classifications and exceptions. Empty
complete approvals can cause `approval-required`; failed lookup causes error.
The future UI/SSH integration is unimplemented. Policy-loading authority comes
from trusted boundary setup; candidate policy changes cannot authorize their own
protection removal.

**Results, composition and repair.** Proposed result fields:

```text
RuleResult = {id; evaluationId; status = "satisfied" | "violated" | "blocked" | "error";
              findings = [Finding]; causes = [RuleIdOrInputId];}
Finding = {producer; code; rule; subjects = [NodeRefOrDocumentRef];
           locations; message; evidence;}
ViewResult = {id; evaluationId; schema; digest; data;}  # only for successful views
```

Every invoked rule must return exactly one result; omissions, duplicate/unknown
IDs and invalid schemas are protocol errors. Empty findings alone do not mean
success. A satisfied rule has no violations/errors/causes. A violated rule has a
structured violation; `approval-required` is one such code, with a review action
hint. Blocked results name causal unsatisfied rules/inputs. The aggregate is
`valid` only when every required rule is satisfied, `invalid` for known policy
violations and their blocked dependents without operational errors, and `error`
when configuration/input/execution incompleteness remains. Keep all known
findings even when an error dominates. Admission is a separate result.

Target evidence includes selector, declaration owner and target, expected/actual
element. Forest evidence lists conflicting parents or cycle declarations.
Visibility evidence identifies roots or path, original origin and first blocked
descent boundary. Preservation shows baseline identity and projected old/new
diff, including deletion. Evidence keeps authored direction separate from graph
direction. Incidental ordering is not equivalence; relevant contextual findings
must agree across helper/direct and full/incremental variants.

Compose definition **lists** before Nix merge can hide duplicates. Same ID and
canonical definition deduplicate with all origins retained; differing
definitions error. Edits are `{action = "replace"; id; expect; rule; reason;}`
or `{action = "disable"; id; expect; reason;}` against the original expanded
set. `expect` is its definition digest; replacement retains the targeted logical
ID. Unknown/stale/competing edits error independent of ordering. Disabling a
needed rule/view without a compatible replacement errors. Rule replacement
changes policy identity; switching a binding changes registry/receipt identity.
Neither module precedence nor Rego union constitutes semantic override.

The reference admission is `complete-validity`. Another consumer can bind an
explicit admission implementation over before/report/candidate to allow assessed
progressive repair; it cannot relabel invalidity as valid, hide missing required
inputs or claim this reference profile while omitting its required invariants.
Invalid inputs stay inspectable and private repairs may be incomplete until
seal.

**Boundaries, transactions and recovery.** A boundary selects
capture/scheduling; rules retain their meaning over that selected
candidate/change. Model capture and policy loading are trusted bindings. The
proposed minimum operations are:

```text
begin({baseRevision; participants; sealAuthority;}) -> {group; revision = 0;}
stage({group; expectedRevision; contributor; patch;}) -> {revision;}
seal({group; expectedRevision; authority;}) -> {candidateDigest; beforeDigest;}
inspect({group;}) -> {phase; revision; candidate; findings;}
abort({group; expectedRevision;}) -> {phase = "aborted";}
publish({transactionId; sealedCandidate; validationReceipt; admissionReceipt;
         expectedBase;}) -> PublicationResult
status({transactionId;}) -> PublicationResult
recover({transactionId; expectedPhase; action;}) -> PublicationResult
```

Patches are integration-native authored changes, not a universal semantic edit
language. Stage is private; revision mismatch conflicts rather than overwrites.
Seal freezes exact bytes and prevents late staging. Contributors and seal
authority are authenticated by boundary policy. A consumer may add
revision-bound `ready` messages and all-ready sealing; changing a revision
invalidates readiness. The core does not demand every participant's readiness or
infer it from timeout. Membership changes/takeover are explicit authorized
actions. A changed published base requires a newly merged/rebased candidate and
fresh evaluation.

Semantic refusal performs no publication: authored bytes and observable model
remain before. Private rejected candidates can remain for diagnosis. Evaluation
must not modify published state. A strong boundary must establish that access
restriction for **every** callback/tool, either through its qualified trusted
extension model or appropriate execution isolation. Read-only JSON by itself
proves no isolation; do not advertise resistance to malicious extensions without
it. Process cancellation/resource failure yields error, never semantic
truncation.

`PublicationResult` contains transaction ID, phase (`published`, `refused`,
`restored`, `recovery-required` or `in-progress`), before/candidate IDs,
validation receipt, affected paths, last completed step and observed
installed-state identity. Only acknowledged file/model agreement yields
`published`. Failure restores before or explicitly blocks writes pending
recovery. An uncertain timeout first requires `status`; never blindly repeat
non-idempotent publication. Recovery clears a block only after
restored/installed bytes and held/reloaded model agree. Crash journal, locking
and external-reader scope require a concrete integration plan and fault
qualification; no database transaction supplies them.

A staged-tree boundary captures the index (including additions/deletions and
relevant grammar/config bytes), separately identified before and main. Unmerged
entries error. Merge commits require a chosen before interpretation; no silent
parent choice. Refusal blocks this commit and preserves already edited index and
worktree. A hook rechecks the index/tree identity before consuming its receipt;
a plain local hook alone neither authenticates actors nor guarantees
non-bypassable/atomic commit enforcement. The enforcing adapter must bind the
validated tree to the actual commit if that capability is requested.

Daemon-then-commit is two boundaries. A hook may reuse a receipt only when all
required snapshots, policy, registrations, trust and freshness bindings match;
otherwise re-evaluate. Refused commit does not undo a published daemon
transaction. Per-evaluation source snapshots are the reference guarantee.
Stronger latest-at-publication behavior needs source-specific
revalidation/lease/CAS capabilities and is an optional explicit policy, not an
automatic promise.

**Implementation entry conditions and open work.** No evidence gap prevents the
bounded recommendation; these gaps prevent claiming implementation readiness or
capabilities merely by naming them:

- **C1 — before Gate 3 implementation:** freeze model JSON, canonical digest
  rules, UID resolution, native-field representation, source coordinates,
  selector validation and error mapping for the first slice. Smallest
  clarification: one FOO/BAZ candidate with duplicate UID, missing endpoint and
  valid wrong-type alternatives, plus the exact extracted snapshots/diagnostics.
  Add documents and native forms losslessly; unsupported forms must remain
  visible. The snapshot and projected-record sketches above currently represent
  all document fields as `[String]`. Resolve their relationship to typed Boolean
  document fields, including declaration, encode/decode and metadata
  preservation, before claiming the user-requested normalized field support.
  Current booleans for grammar `required`/`isComposite` do not settle this
  contract; no new constructor is established here.
- **C2 — before Gate 3 implementation:** freeze runner request/result schemas,
  helper target lowering, assignment and capability negotiation. Show one
  shipped target entry and an independent process entry consuming the same
  snapshot and returning the same specified target witness. This is a
  schema/conformance example first; integrated execution belongs to the
  authorized next slice.
- **C3 — before any publishing slice:** specify complete-candidate capture,
  required all-role native check, refusal and publish/recovery scope. Gate 3
  must demonstrate actual public Nix-to-Scribe G02 rejection, unchanged authored
  and held state, and reload with G01/G03 controls. Group and staged-tree
  guarantees require their own later qualification; current serialized RPC
  writes cannot be relabeled to satisfy them.
- **C4 — before runtime adoption; initial compatibility check now passed:** the
  separate later [host result](runtime-pairing/outputs/host-probe-result.json)
  records CPython 3.14.6, StrictDoc 0.28.3 and rustworkx 0.17.1 loading together
  on x86_64-linux with StrictDoc's interpreter and a temporary combined-closure
  site-packages `PYTHONPATH`. CLI dependency imports, synthetic Python
  Parent/Child normalization, rustworkx acyclic/cycle and
  positive/reverse/isolated path controls pass. The coordinator's unchanged
  pinned expression build and probe both exited zero
  ([execution record](runtime-pairing/outputs/host-execution.json),
  [expression](runtime-pairing/outputs/probe.nix),
  [probe](runtime-pairing/outputs/probe.py)). This satisfies the initial bounded
  pairing check, not C4 as a whole. Production packaging, supported-platform
  qualification and native StrictDoc parser/validator integration remain
  required before adoption; no Scribe behavior is established. Earlier Python
  3.13.15/rustworkx 0.18.1 benchmarks are unchanged and were not repeated for
  this pairing. This evidence postdates the frozen research packet.

Exact process sharing, optimized forest storage, additional native-language
adapters, general cross-model resolution, migration continuity, progressive
repair and diagnostic witness ordering can remain open if unsupported contracts
fail explicitly. Trust authorities, repository lifecycle projections, approval
expiry, Git merge-before and readiness profiles must be chosen before their
respective slices, not invented as engine defaults. Publication crash scope
cannot remain unspecified when claiming strong publication.

Full evaluation is the initial oracle; opaque tools default to complete-input
invalidation. Incremental support is optional until implemented, then must match
full results over identical before/candidate/policy/facts. Policy/provider
changes, negative lookups and collection membership can invalidate unchanged
edges. Caches/indexes are disposable; no index, daemon mutex, warm Wasm instance
or health-only interop result proves incremental maintenance or publication
safety.
