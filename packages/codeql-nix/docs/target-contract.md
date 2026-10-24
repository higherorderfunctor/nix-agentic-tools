# Target and observation contract

> **Last verified:** 2026-10-23 — M3n adds optional concrete context steps to
> metadata requests; root requests and the existing fact envelope remain usable.

## Purpose and fit

`schema/target-manifest.json` describes explicit named targets and bounded
requests. `schema/observation-protocol.json` carries the resulting F1 facts.
Both use JSON Schema Draft 2020-12. These contracts let future producers and QL
consumers share fixtures before evaluation exists. The
[database contract](database-contract.md) remains authoritative for relation
semantics; the [integration gate](integration-gate.md) records the production
replacement for the retired bootstrap proof.

## Explicit targets

Projects supply `.nixql/targets.nix`, a pure function receiving pinned inputs
and project source. Handles/arguments stay runtime-side; future E1 must bind
each opaque reference to its supplied handle/arguments without inferring from
labels. This JSON boundary specifies no binding-registry implementation and
transports no function or secret values.

The manifest is
`{ "manifestVersion": 1, "targets": { "stable.name": descriptor } }`. Names are
literal labels, never flake attribute selectors. Every descriptor requires:

- `adapter`, `adapterVersion` and explicit `system`.
- `argumentDescription`, containing `hash`, `moduleArgumentsRef` and
  `specialArgumentsRef`.
- `evaluation`, containing `kind` and opaque `reference`.
- `fingerprint`, containing `evaluatorVersion`, `libVersion`, `modelVersion`,
  `policyHash` and `sourceSnapshotHash`.
- Nonempty `inputIdentities` and `sourceRoots`.
- Nonempty `observationModes` and `requests`.
- Boolean `syntaxOnlyFallback`.

The adapter is `evalModules`; accepting a descriptor proves no adapter
implementation. Evaluation kinds are `arguments` and `rich-result`. References
identify admitted runtime handles or arguments; they do not serialize functions
or secrets wholesale. The argument-description hash records the admitted
description. `modelVersion` accepts the same exact-text identity form as the
other fingerprint fields. The installed coordinator requires a requested model
to match its run's generated builtin/module bundle fingerprint, otherwise
returning `unsupported-model`. Legacy `not-requested` remains accepted. See
[builtin-models.md](builtin-models.md) for model generation and compatibility.

Input identities map exact input names to identity strings. Each source root has
`logicalName`, `path` and `rootContentIdentity`. Logical name and content
identity supply F1 root identity; checkout path is mapping data. The fingerprint
fields combine with `adapterVersion`, the argument-description hash and `system`
to supply F1 evaluation-fingerprint components. Validation checks their
representation, not their derivation, source admission, hash authenticity or
runtime-reference resolution.

## Requests and authorization

Every request explicitly provides `domain`, `facet`, literal string-segment
`path`, and all five budgets: `maxBytes`, `maxDepth`, `maxMemoryMiB`, `maxNodes`
and `maxSeconds`. `["a.b"]` and `["a", "b"]` remain distinct. There is no
implicit traversal or value request. Optional `contextPath` selects concrete
instances; absent and explicit `[]` both select the root. Each step contains
`option` (exact parent-relative option segments), `memberKind` and `memberKey`.
Kinds are `attribute`, `index` and `submodule`: keys are respectively exact
strings, canonical nonnegative decimal text and `""`. The final request `path`
is relative to the selected context. No schema or sibling enumeration is
implied.

Every request uses the `option-metadata` domain and `metadata` observation mode.
Facets: `declarations`, `definitions`, `isDefined`, `priority`, `selection`.
Selection emits retained inputs, whether the option is defined, winning override
priority and explicit order under one request. Its capability is
`module-properties`; unsupported helper pins retain independently requested Step
0 metadata. Objects are closed to unknown fields; target and input maps permit
explicit names. Nested traversal uses capability `nested-metadata`; missing rich
type metadata yields request `unsupported`, reason `nested-metadata-unavailable`
and capability `unavailable`. Missing options or members instead fail with
`option-unavailable` or `instance-unavailable`. A failed traversal stays rooted
and publishes no concrete chain or provenance; independent requests survive.

Deferred surfaces return with their consuming queries: increment 3 restores
module graph requests and metadata enumeration; increment 4 restores
selected-value/member/string-context modes and scalar fixtures; increment 5
restores framework adapters, config-only handles and schema requests. Other
metadata facets return with the increment 3 module queries that consume them.
The `reusable` cache control returns in increment 8. Explicit input, argument,
root, system and fingerprint identities remain required now.

## Mandatory validation layers

Consumers must register and enable all three custom formats. A validator that
ignores formats does not enforce this contract:

- `nixql-exact-text`: a string must encode as UTF-8 and occupy at most 1,048,576
  bytes. Character count alone is insufficient.
- `nixql-native-int`: budgets must be native integers in `0..2147483647`,
  excluding Booleans and floats. Parsed JSON `1.0` is rejected even though
  ordinary JSON Schema `integer` accepts it; consumers must retain this
  distinction while decoding.
- `nixql-path`: a path must contain exact string segments, and its compact JSON
  serialization with `ensure_ascii=False` must fit the same UTF-8 byte ceiling,
  including brackets, quotes and escaping.

`checks/fixtures/protocol/test_protocol.py` implements independent format
oracles with Python `jsonschema.FormatChecker`. These are fixture checks, not a
new production validator.

The observation envelope is
`{ "protocolVersion": 1, "facts": [["nx_relation", [arguments]], ...] }`.
Mapping to F1 tables is identity: retain relation names, positional arguments
and values without renaming, coercion or defaults. Each observation carries
exactly one typed subject row through `nx_observation_options` or
`nx_observation_definitions`; text subject fields are removed. The link is
mandatory for every observation state and must remain in its request context and
target, as enforced by F1. The schema checks the envelope and string/array tuple
shape. Then the complete unordered fact collection **must** pass
`schema/abi.py`'s `validate`; envelope acceptance alone is insufficient. F1 owns
relation names, arity, types, identity framing, canonical encodings, references,
uniqueness and scope. Empty facts are representable but cannot serve as a
passing extraction oracle.

## States and exact metadata

Capabilities, phases, targets, request results, observations, syntax results and
diagnostics use their existing F1 relations and separate status vocabularies. A
discovery failure can precede any target. Partial metadata work can record
failed observations without manufacturing a successful result. Missing facts
never imply false or completion.

`text-field-too-large` is an explicit refusal; an affected request cannot claim
completion. Priority transport preserves canonical signed decimal strings over
the F1 signed 64-bit domain, including negative priorities; unsupported range
uses `priority-domain-unsupported`. Native QL integers cannot substitute for
those strings.

These fixtures prove metadata representation and exact text only. They do not
prove authentic source admission, budget enforcement or atomic publication.

## Verification and changes

Run from the repository root in a Python environment containing `jsonschema`:

```bash
python packages/codeql-nix/checks/fixtures/protocol/test_protocol.py
```

The tests check required descriptors, nested source roots and input identities,
retained metadata facets, rejection of deferred controls, literal paths and
budgets, all 28 relation mappings, status families and pre-target failures,
priorities, and UTF-8/JSON-expansion boundaries. They use independent fixtures
and F1 validation without invoking Nix evaluation or the CodeQL engine.
`checks.nix` imports `checks/contracts.nix`, whose `codeql-nix-contracts` runs
this entry point through the nonempty domain runner with the existing health/ABI
sentinels. Nested producer and installed-query coverage additionally runs
through `codeql-nix-step0`.

Change the relevant schema and independent fixture expectations together,
preserve all three enabled format checks and the F1 validation layer, then
format changed files and rerun the standalone suite. Update F1 first for
relation or metadata-semantic changes rather than duplicating its validator
here. Update this note when the transport or validation obligations change;
future runtime acceptance must separately establish evaluator isolation and
source admission.
