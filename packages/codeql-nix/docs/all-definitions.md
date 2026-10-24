# Bounded all-definition inventory

> **Last verified:** 2026-10-23 — M3d adds source-backed candidates alongside
> upstream retained metadata, using the existing authenticated adapter,
> collection boundary and transactional protocol.

## What and why

`option-metadata` facet `all-definitions`, mode `metadata`, inventories one
exact requested option path. “All” covers bounded enumerable admitted module
bodies. It includes losing overrides and inactive leaf bindings without
traversing every config value or forcing inactive payloads. Existing
`nx_definitions` and `SelectedDefinition` still mean upstream retained inputs
before type merging and `apply`.

`ql/queries/LosingDefinitions.ql` returns exactly
`(target, contextPathJson, optionPathJson, candidateOrigin, candidatePriority, winningPriority, active, selected, wrapperChainJson)`.
Its Boolean columns are true and false respectively. It reports only active
candidates with a known effective override priority strictly greater than the
observed winner. Inactive and unknown candidates remain accessible through
`Modules::DefinitionCandidate` and extraction health, without a losing claim.
Order priorities never determine override losers. One shared signed-decimal
comparator in `internal/Evaluation.qll` preserves endpoint precision without QL
integer conversion.

## Integration and authority

The supervisor derives source plans in `src/eval/definitions.py` from admitted
exact bytes and authenticated S2 anchors. Literal option paths, nested attrsets,
explicit `config.<path>` bindings and literal merge lists are enumerable.
Helpers and lexical aliases must resolve through the existing pinned module
model. Closed wrapper records preserve outer-to-inner `if`, `merge`, `override`
and `order` structure and merge indexes. Ordinary leaves use a safe constructor
allowlist, including lexically unshadowed `true`/`false`/`null` and unary-minus
integer/float literals. Dotted locals, recursive bindings, function parameters
and inherit aliases retain shadowing; computed expressions and custom property
records are opaque.

`src/eval/nix/adapters/evalModules.nix` applies the existing module wrappers and
asks the pinned library's `modules.collectModules` for enabled unique-key
modules. Only collected source plans become evaluated candidates; unreachable,
disabled and duplicate occurrences do not add candidates. M3g still exposes its
separate occurrence graph. Collection transports plans in its unused config
field, never through value merging. A clean evaluation of the same pinned
library supplies the internal module's declaration identity; a matching
collection root preserves upstream key collisions without reserving user keys.
Internal `key == _file` equivalence is source-verified only for this pinned
library and must be checked again when its pin changes. The ordinary
argument-support root stays intact.

This uses a deprecated exported upstream collector. Its warning consumes the
supervisor's stderr-inclusive byte budget. A pin removing the API fails the
request rather than establishing empty completion. Do not add a parallel
collector to hide this dependency.

The adapter captures optional `unsafeGetAttrPos` points on original applied,
source-proven wrapper-free binding paths before sanitization reconstructs attrs.
Wrapped or opaque payloads are not traversed for runtime positions. Coordinates
identify bindings in UTF-8 bytes, not RHS causation; source snapshots still
authenticate files. Root-file library/formal bindings retain M3p's coverage and
are emitted on successful selection and inventory transactions. Missing library
descriptors or `specialArguments.lib` suppress helper-dependent candidates and
make the inventory partial.

`src/eval/nix/modules.nix` emits upstream retained definitions, `isDefined` and
winning priority in the same request as candidates. Candidate ordinals follow
enabled collection order, source byte order and merge-index order. Identity
frames request, option, collected module key, binding anchor and merge-group
path; it is distinct from retained-definition identity and ordinal.

The four added relations are `nx_candidates`,
`nx_definition_candidate_priorities`, `nx_definition_selections` and
`nx_observation_candidates`. `schema/contract.json` owns their types;
`schema/abi.py` validates admitted anchors, closed canonical wrappers, group
identity, contiguous ordinals, typed observations and same-request
correspondence. Each selected correspondence is unambiguous on both sides.
Positive correspondence requires one eligible authenticated source occurrence
and one retained record with its exact label; same-file ambiguity stays unknown.
A matching basename is insufficient.

## Boundaries and limits

Activity and selection are independent tri-states. A supported enclosing false
guard establishes inactive; enabled modules with all supported guards true
establish active. A guard hidden beneath order or override is unknown because
upstream discharge does not see through that barrier. False guarded leaf
payloads may stay unforced. Dynamic guard truth stays unknown. Effective
override priority is absent for unsupported nesting; source spelling alone
cannot select an override.

Known defect R3-LM1: an inactive opaque leaf without a visible override
currently receives ordinary priority `100`; the contract requires absent
priority. Safe literal leaves and visible override priorities remain valid. This
cannot produce a losing row because the candidate is inactive.

Selected false needs inactivity or a known worse effective override plus
winning-priority witness. Selected true needs authenticated retained
correspondence. Absence from retained files proves neither. An incomplete
inventory suppresses positive correspondence; it may still publish known
candidates and retained metadata.

Generated/unanchorable modules, dynamic keys or list spines, computed bodies and
free-floating `mkDefinition`/custom properties produce `partial` with
`definition-body-opaque`. Upstream may force an opaque config body before
metadata and fail; preserve that failure. Supporting arbitrary inactive bodies
or universal correspondence needs a separately approved evaluator
instrumentation contract.

`observedCount` and `maxNodes` count option + candidates + retained definitions;
wrappers are not nodes. Root-only `maxDepth=0` refuses any candidate or retained
child. Producer and supervisor both enforce this boundary. Existing byte, text,
time and memory limits still apply, and refusals publish no successful
transaction. Complete empty inventories need an observed option witness; missing
rows do not prove emptiness. Exact-pin capability checks apply to coordinated
real extraction. Trusted synthetic command fixtures test transport independently
of real producer/model support.

## Changes and validation

Extend the existing contract, validator, supervisor, source planner, adapter and
thin QL library together; preserve one collection authority and one decimal
comparator. Regenerate schema/model projections with existing generators.
Register notes in the owner registry and regenerate instruction projections with
`devenv tasks run --mode before generate:all`. Preserve independent
original-byte anchor expectations and upstream Nix oracles when extending
recognition.

Linux `codeql-nix-modules` runs
`checks/fixtures/inc3/all-definitions/test_all_definitions.py` for ABI,
transport, source admission, correspondence and budget refusal. Its domain
runner prints `test_all_definitions.py: N tests, N executed`. These synthetic
cases do not prove the production planner or installed QL.

On x86_64-linux, `codeql-nix-step0` runs `test_installed_all_definitions.py`
against the installed producer and queries, reviewed qltest rows and independent
`oracle.nix`. Look for `test_installed_all_definitions.py: N tests, N executed`
and evidence text
`M3d all-definitions with direct oracles and reviewed losing rows`. Cases cover
baseline/priority flip, ties/ambiguity, wrapper boundaries, opaque bodies,
disabled/duplicate closure, original UTF-8 points, helper suppression and signed
endpoints. `codeql-nix-abi`, `codeql-nix-contracts` and
`codeql-nix-raw-inventory` retain schema/import/transport/drift coverage. These
are registered checks and expected markers, not a claim that CI passed.
