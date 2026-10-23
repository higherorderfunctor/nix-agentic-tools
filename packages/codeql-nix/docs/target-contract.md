# Target and observation contract

> **Last verified:** 2026-10-23 — F2 fixes the JSON transport and its fixture
> validation; it implements no evaluator.

## Purpose and fit

`schema/target-manifest.json` describes explicit named targets and bounded
requests. `schema/observation-protocol.json` carries the resulting F1 facts.
Both use JSON Schema Draft 2020-12. These contracts let future producers and QL
consumers share fixtures before evaluation exists. The
[database contract](database-contract.md) remains authoritative for relation
semantics; the [integration gate](integration-gate.md) establishes only the
earlier bootstrap prerequisites.

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
- Boolean `reusable` and `syntaxOnlyFallback`.

Adapter names are `devenv`, `evalModules`, `flake-parts`, `home-manager` and
`nixos`; accepting a descriptor proves no adapter implementation. Evaluation
kinds are `arguments`, `config-only` and `rich-result`. References identify
admitted runtime handles or arguments; they do not serialize functions or
secrets wholesale. The argument-description hash records the admitted
description. External inputs that cannot be recorded require `reusable = false`;
schema validation cannot establish that decision's truth.

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
implicit traversal or value request. The fixture's metadata baseline explicitly
selects a prefix; `all-declarations` is separate opt-in enumeration bounded by
`maxNodes`.

| Domain                                       | Permitted facets                                                                                           | Required observation mode |
| -------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------- |
| `config`, `definition-value`, `option-value` | `members`, `string-context`, `value`                                                                       | `selected-value`          |
| `graph`                                      | `modules`                                                                                                  | `graph`                   |
| `option-metadata`                            | `all-declarations`, `declarations`, `internal`, `isDefined`, `priority`, `readOnly`, `typeName`, `visible` | `metadata`                |
| `schema`                                     | `declarations`                                                                                             | `schema`                  |

The `string-context` facet additionally requires the `string-context` mode. A
`config-only` target can request only the `config` domain; it cannot claim
option declarations. Objects are closed to unknown fields; target and input maps
permit explicit names.

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
and values without renaming, coercion or defaults. The schema checks the
envelope and string/array tuple shape. Then the complete unordered fact
collection **must** pass `schema/abi.py`'s `validate`; envelope acceptance alone
is insufficient. F1 owns relation names, arity, types, identity framing,
canonical encodings, references, uniqueness and scope. Empty facts are
representable but cannot serve as a passing extraction oracle.

## States and exact values

Capabilities, phases, targets, request results, observations, syntax results and
diagnostics use their existing F1 relations and separate status vocabularies. A
discovery failure can precede any target. Partial membership can record a known
child whose observation failed without linking a successful value. Missing facts
never imply false, null, absence or completion.

`text-field-too-large` is an explicit refusal; an affected request cannot claim
completion. Priority transport preserves canonical signed decimal strings over
the F1 signed 64-bit domain, including negative priorities; unsupported range
uses `priority-domain-unsupported`. Native QL integers cannot substitute for
those strings.

Path values use kind `path` and `evaluated-path-json-v1`, containing canonical
JSON string text for an evaluated absolute path. Equal-spelling ordinary strings
use kind `string` and `string-json-v1`. Null and false remain explicit
successful values; integers retain decimal precision, floats use canonical
hexadecimal text, and functions/derivations remain opaque without scalar
payloads. These fixtures prove typed representation and exact text only. They do
not prove runtime path conversion avoids copying, source admission is authentic,
budgets are enforced or transactions publish atomically.

## Verification and changes

Run from the repository root in a Python environment containing `jsonschema`:

```bash
python packages/codeql-nix/checks/fixtures/protocol/test_protocol.py
```

The nine tests check required descriptors, modes/facets, literal paths and
budgets, all 35 relation mappings, status families and pre-target failures,
priorities, typed scalar distinctions, and UTF-8/JSON-expansion boundaries. They
use independent fixtures and F1 validation without invoking Nix evaluation or
the CodeQL engine. F3 must integrate this standalone entry point into the
owner's checks with nonempty health/ABI sentinels; F2 adds no check
registration.

Change the relevant schema and independent fixture expectations together,
preserve all three enabled format checks and the F1 validation layer, then
format changed files and rerun the standalone suite. Update F1 first for
relation or scalar-semantic changes rather than duplicating its validator here.
Update this note when the transport or validation obligations change; future
runtime acceptance must separately establish evaluator isolation, source
admission and non-copying path serialization.
