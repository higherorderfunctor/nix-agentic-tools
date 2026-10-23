# Handwritten database contract

> **Last verified:** 2026-10-23 — X1 adds typed observation subjects to the 25
> Step 0 relations; F1 validates their identity and scope, while E2a remains the
> metadata producer slice.

## Purpose and ownership

`schema/contract.json` owns the version-one relation inventory, column types,
primary keys, enums and serialization encodings. `schema/abi.py` supplies
reference encoders and validates unordered fact collections. Its `dbscheme()`
renders the committed `schema/evaluation.dbscheme`; the ABI check rejects
divergence. All 25 handwritten relations are independent of generated AST entity
types, so later syntax and evaluation producers can contribute to one database
without manufacturing raw kit labels.

F0 proves the prerequisites in [integration-gate.md](integration-gate.md). F1
defines the shared ABI; later producers and QL consumers preserve it rather than
infer semantics from missing rows.

## Durable identity

Global keys use `nixql:v1:<namespace>:` followed by
`<UTF-8-byte-length>:<component>` for each component. Namespace and component
boundaries distinguish equal-looking concatenations; empty components remain
present. No Unicode normalization, path resolution or worktree-prefix insertion
occurs in this encoder.

The frozen semantic components are:

- Root: logical name and root content identity.
- File: root key, root-relative path and file content digest. Absolute checkout
  locations are mapping data.
- Anchor: file key, decimal start byte, exclusive end byte, grammar kind and
  canonical ordered structural child-index path. Equal spans with different
  kinds or child paths remain distinct.
- Evaluation fingerprint: evaluator, lib, adapter and model versions;
  manifest-arguments hash; source-snapshot hash; policy hash; and system.
  Context, option-path segments, observation facet and occurrence distinctions
  must survive in the identities built on that fingerprint.

The validator reconstructs file and anchor keys and checks their components.
Other entity keys are checked for namespace and framing, not reconstructed from
their semantic inputs. The component list freezes the producer obligation;
accepting a well-framed target key is not evidence that its fingerprint was
computed correctly.

Option/request paths are compact canonical JSON arrays of exact string segments:
`["a.b"]` differs from `["a","b"]`. Contexts are root-only with instance path
`[]`; structural child paths contain nonnegative integer indexes. Canonical JSON
uses UTF-8 text, no optional whitespace and no ASCII-only escaping. Source paths
must be nonempty, relative and free of `..` segments; this lexical check does
not resolve symlinks or authenticate filesystem contents.

## Priority and exact text

Native relation integers are nonnegative and at most `2147483647`, rejecting
Python Booleans. Enum columns accept only the listed contract values. Unknown
optional information belongs in an absent auxiliary relation, rather than an
invented enum value or default false.

Option priority holds canonical signed decimal text over
`[-9223372036854775808,9223372036854775807]`. Zero is `0`; a nonzero magnitude
has no leading zero, plus sign or exponent. Negative override priorities are
valid. Consumers must retain decimal precision rather than narrow priorities to
a native QL integer. `priority-domain-unsupported` identifies an unsupported
range. An option priority also requires same-option `isDefined = true` metadata
and an observed `pre-apply-metadata` witness from an `option-metadata` request
with facet `priority`, the exact option path and context, and a `complete` or
`partial` result. Step 0 observations use only the `pre-apply-metadata` stage
and requests use only the `option-metadata` domain. The sole option metadata
field is `isDefined`.

Every text column is limited to **1,048,576 UTF-8 bytes**, measured before TRAP
quote doubling. JSON payloads and path arrays are checked after JSON encoding,
including escaping expansion. Invalid UTF-8 and oversized fields raise
`ValueError`; no truncation or chunk protocol exists. Global key framing itself
is exempt; keys repeated in text columns still obey the ceiling.

A later producer must reject an oversized file/projection transaction and report
`text-field-too-large` using representable enclosing identities. It must publish
no clipped facts or successful observations from that transaction. F1 validates
facts supplied to it; it does not implement atomic publication, automatically
manufacture failure rows or preflight the generated syntax writer. F0 documents
the pinned kit's separate preflight evidence.

## Scope, admission and completeness

Primary keys are unique per relation, definition ordinals are unique per option,
foreign entities must exist with the declared type. `nx_observations` contains
only observation, request, stage and state. Every observation in every state has
exactly one subject row in total: `nx_observation_options(observation, option)`
or `nx_observation_definitions(observation, definition)`. Both columns are typed
entity references; text subject kind/key columns are removed. Missing,
duplicate, wrong-type, dangling and simultaneous option/definition links are
invalid.

Requests belong to their context's target. The linked option, or a linked
definition's parent option, must belong to that exact context and hence target.
A request path need not equal its subject's option path except for the priority
witness above. Consumers must join typed subjects, rather than infer identity
from request paths or metadata presence. A definition observation identifies
only its linked definition, not every sibling definition of its option.

`nx_target_inputs` admits a file to the source snapshot of its target's run. For
origins used by declarations or definitions, an `nx_origin_files` link must have
admission for every referencing run's snapshot. Admission is supplied evidence:
F1 neither hashes source bytes nor authenticates labels, roots or symlink
policy. Diagnostics link directly to requests and targets; no diagnostic-origin
relation is retained. File-level links do not establish expression-to-value
edges or unique syntax associations.

Every `observed` observation requires its own `complete` or `partial` request
result. Missing rows alone prove neither failure nor absence. Definition
completion checks return with E2a's metadata producer.

A complete request cannot carry a timeout/text refusal reason or a linked
diagnostic with either code. Failed discovery can be represented before any
target exists. The validator checks these recorded consistency rules; it does
not prove that all phases/results were reported, that a budget was obeyed, that
a completion claim is true, or that all unobserved facts are false.

## Validation and changes

`checks/fixtures/abi/golden.py` supplies independent serialization expectations
and a graph covering every relation. `test_abi.py` checks identity,
enum/reference/scope rules, priority witnesses, refusal and UTF-8/JSON-expansion
boundaries. `checks/abi.nix` runs these tests, checks schema projection
equality, compiles against the standalone handwritten schema and imports/checks
typed golden TRAP. This does not prove production extraction.

Change the contract first, update validation and independent ABI/F2/supervisor
fixtures, regenerate `evaluation.dbscheme` through `dbscheme()` and the combined
schema through S1, then format affected files. Run the owner ABI, contracts, raw
inventory and evaluation-isolation checks through CI. Preserve typed-schema
import coverage, scope rejection tests and adversarial subject-link controls. An
ABI change requires full database regeneration; version one promises no in-place
upgrade or migration path.

## Deferred consumers

Increment 3 restores context-parent/module graph tables, definition-order
priorities, nested contexts and their scope validators and native Boolean
encoding. Increment 4 restores value/scalar/member/string-context tables,
encodings, value observations and their validators. Additional option metadata
fields return with their named consuming query; schema contexts are dropped
because increment 3 selects concrete instances only. The diagnostic-origin
relation is permanently dropped. These surfaces have no Step 0 producer or
consumer.
