# Concrete nested metadata

> **Last verified:** 2026-10-23 — M3n follows explicitly requested concrete
> instances through rich pre-apply metadata, preserving request-local evidence.

## What it answers

`ql/queries/SubmoduleOrigins.ql` reports retained definitions for a concrete
submodule selected by an `option-metadata/selection` request in `metadata` mode.
Its seven columns are target, context path JSON, option path JSON, selected
ordinal, origin label, winning override priority text and stage. Stage is always
`pre-apply-metadata`. Selection means retained before type merging and `apply`;
origin labels do not establish expression causation.

An optional `contextPath` is an array of steps with `option`, `memberKind` and
`memberKey`. Absent or explicit `[]` selects the root. Each step's option is
relative to its parent; the request's `path` is relative to the final context.
Direct submodules use kind `submodule` and key `""`; attributes use `attribute`
and an exact key, including dots or empty strings; lists use `index` and
canonical nonnegative decimal text. No dot splitting or integer narrowing
defines identity.

For example, context
`[{"option":["services"],"memberKind":"attribute","memberKey":"a.b"}]` and path
`["answer"]` select the declared answer in the concrete `services."a.b"`
instance, separately from `services.other` or nested keys `a`/`b`.

## How it fits

The existing `src/eval/nix/modules.nix` adapter selects each parent option from
rich `options`, then follows `valueMeta.configuration`,
`valueMeta.attrs.<exact-key>.configuration` or
`valueMeta.list[index].configuration`. Recursion uses that configuration's
options. It does not use post-apply config, `getSubOptions`, placeholder
instances or a second schema evaluation. Outer `apply` may change shape or throw
while metadata remains available. Only the requested member is demanded; sibling
values are not enumerated.

This extends M3p selection and the existing supervisor, ABI and transport. It
adds `nx_context_parents`, the `concrete-submodule` context kind and exact
instance paths; it adds no value serializer, graph evaluator or new observation
stage. Unsupported rich metadata shapes and freeform keys without declared
options cannot supply provenance. Module graph and candidate-definition cuts are
not prerequisites.

Request identity is framed from target, existing root context, canonical request
descriptor including any `contextPath`, and ordinal. Each child context frames
request ID, parent context ID, request-qualified parent option ID, member kind
and member key. Successful requests point to the final child; failures point to
the existing root and retain the requested path in identity and diagnostics.
Root IDs and identities of old requests omitting `contextPath` keep their
original formulas.

Each request owns a separate physical chain, even repeated requests or different
facets for the same instance. Join semantic instances across requests using
target, `instancePathJson` and option path JSON, never physical context ID
alone. Parent traversal options receive no fabricated observations; typed final
option/definition witnesses stay in the final context. ABI validation checks
parent target, parent-option ownership, exact step prefix and one parent per
child; prefix length excludes cycles.

`Modules.qll` exposes root/concrete `ModuleContext` views, parent accessors and
context-qualified `ObservedOption`. `SubmoduleOrigins.ql` requires a concrete
context and selection-qualified retained definitions. Its semantic output
deduplicates identical repeated rows; the underlying request, context and
observation entities remain distinct. Root priority joins remain root-scoped.

## Refusals and bounds

`nested-metadata` capability is `unavailable` when requested traversal
encounters unavailable rich metadata; missing options/members and ordinary
runtime failures retain `supported`. Requests have no `unavailable` state.
Selection also requires the existing supported `module-properties` capability.

| Cause                                            | Request state / reason                            |
| ------------------------------------------------ | ------------------------------------------------- |
| Absent declared traversal or final option        | `failed` / `option-unavailable`                   |
| Missing attribute or out-of-range list index     | `failed` / `instance-unavailable`                 |
| Unsupported type/library metadata shape          | `unsupported` / `nested-metadata-unavailable`     |
| Evaluation throw or memory-limited child failure | `failed` / `projection-failed`                    |
| Source-policy refusal                            | `blocked` / `evaluation-blocked`                  |
| Node or depth overflow                           | `failed` / `node-limit` or `depth-limit`          |
| Per-field or aggregate output overflow           | `failed` / `text-field-too-large` or `byte-limit` |
| Deadline expiry                                  | `failed` / `timeout`                              |

A generic child failure does not establish a memory-specific cause. Each
failed/unsupported request has diagnostic and health facts and zero nested
provenance. Failed traversal publishes no concrete context, parent link or
traversal-option chain; independent root requests remain valid.

`maxNodes` counts each child context and parent traversal option, plus the final
option and retained definitions. `maxDepth` bounds context-step count; selection
with definitions also requires nonzero depth. The supervisor checks step depth
and unavoidable chain-plus-final node cost before constructing child identities.
During construction, traversal-option and child-context identity bytes also
consume `maxBytes`; excess refuses with `byte-limit` before publishing rows. It
validates complete producer facts, source links and text bounds before
publication. Existing child memory/deadline controls and exact UTF-8 field
ceiling of 1,048,576 bytes apply; aggregate output has its own byte budget. No
clipped facts or successful partial chain escape refusal.

## Verification and changes

`checks.nix` imports `checks/step0.nix`; `checks.x86_64-linux.codeql-nix-step0`
runs `checks/fixtures/inc3/nested/test_nested.py` through the nonempty domain
runner, alongside Step 0 and M3p. ABI and protocol fixtures retain their
existing owner checks. Installed acceptance must pair reviewed
`ql/test/inc3/nested/SubmoduleOrigins.expected` rows with an independent
`oracle.nix` importing the pinned upstream library; producer traversal helpers
must not supply oracle expectations. Packet fixtures independently construct
request/context/typed-observation chains.

These are CI obligations, not a claim that an installed check passed locally.
Preserve separate direct upstream metadata and forced-value witnesses, exact
member paths, repeated-request physical counts and semantic query deduplication
when changing traversal. Missing rows alone never prove false or completion.

Change the contract and ABI validator before producers/consumers; update
target/protocol schemas and independent fixtures together. Regenerate
handwritten and combined schema projections through existing generators,
preserve supervisor publication/source authentication and extend the registered
owner suite. Keep origin quality separate from value causation. Format changed
files and update these notes and their registered instruction projections when
boundaries change.
