# Public authoring surfaces for review

Status: **SKETCHES — not implemented APIs and not approved signatures.**
Existing grammar generation is usable independently. Semantic
source/derive/check primitives, helpers, provider ABI, and runtime attachment
are proposals. The backend remains unselected.

## Existing public assembly

The supplied public interface finding at repository revision
`8c6aa9bc648b00809502f765a860cbc2c79ac114` identifies the devenv module
`devenvModules.nix-agentic-tools`, the grammar library
`lib.ai.strictdocGrammar { inherit lib; }`, and the StrictDoc package
`packages.${system}.strictdoc`. The retained fixture must record its actual
filtered-input resolution and invocation separately.

The grammar library exports `check`, `dsl`, `emit`, `normalized`, and `render`.
Its public constructors include `dsl.el`, `dsl.field.required`, `dsl.field.one`,
`dsl.field.str`, `dsl.rel.parent`, and `dsl.rel.child`. A `faithful` attribute
and a boolean field constructor are not public exports. SDoc FLAG is therefore
authored with explicit string choices; the semantic interpretation remains D01.

```nix
# Existing grammar constructor shape; the chosen model remains a draft.
dsl.el "FOO" {} {
  fields = [
    (dsl.field.required (dsl.field.one "FLAG" ["false" "true"]))
    (dsl.field.required (dsl.field.str "UID"))
  ];
  relations = [
    (dsl.rel.parent "H" "H_back")
    (dsl.rel.parent "R" "R_back")
  ];
}
```

This short shape omits the actual fixture's runtime bookkeeping fields. The
explicit UID declaration is necessary for addressable nodes and grammar-derived
`--uid`; it was established by consumer probing. `ai.strictdoc.grammars.fixture`
can render the real elements to `grammar.sgra`. Installed Scribe is enabled via
the public devenv module, with `scribeSource = "installed"`; the fixture
configuration must supply grammar alias `repo` for existing Scribe-created
document skeletons. Generation remains separate from daemon startup.

## Opinionated helpers: readable proposals

The following notation is pseudocode. It is deliberately not a loadable Nix
module, so a reader cannot mistake these names for already exposed options.

```text
targetIs(selector = fooParentR, targetModel = foo)
forest(selector = fooParentH)
visibleVia(relation = fooParentR, hierarchy = fooParentH,
           origins = insideMayExit, roots = sameRoot)
bridge(parent = barParentP, child = barChildQ,
       hierarchy = fooParentH, endpoints = exactlyOneEach,
       closedStart = inside)
preserveBaseline(source = baseline, projection = modeledAuthoredRecord)
```

`fooParentR` is a model/role reference including grammar, element, native type,
and role, not a raw display-name interpolation. A consumer should be able to
write these helpers through public lower layers. A built-in helper requiring
private evaluator privileges would expose an interface defect.

Initially keeping helpers/provider with the consumer makes the extension
boundary visible; adopting useful pieces into the library is a separate
ownership decision. Representative equivalent definitions should reuse the same
approved scenario suite, rather than maintaining four copies of each document.

## Shared compositional contract: proposal

| Primitive | Author declares                                             | Evaluated result                                                                          |
| --------- | ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `source`  | Identity, schema/fact contract, provider and capture inputs | Facts with namespace, completeness, provenance and snapshot identity                      |
| `derive`  | Identity, named input contracts, output contract, evaluator | Derived facts with declared ownership                                                     |
| `check`   | Identity, named input contracts, evaluator                  | Zero/more structured violations after successful execution, or a distinct execution error |

```text
baseline = source(identity, baselineRecordContract, provider)
hierarchy = derive(identity, [candidate.authoredRelations], hierarchyContract,
                   selectedHierarchyComputation)
visibility = check(identity, [candidate.nodes, hierarchy, candidate.relations],
                   reviewedOriginSensitiveTraversal)
preservation = check(identity, [before, candidate, baseline],
                     reviewedPreservationProjection)
```

Inputs must distinguish before, candidate, and external baseline. Required
comparison inputs are not optional simply because evaluation starts from a saved
workspace. Declaring an opaque executable does not promise selective
invalidation, determinism, bounded execution, or native incremental maintenance.
Conservative reevaluation is acceptable; silently omitting a rule is not.

Attachment at field, relation, element, grammar, or module scope may supply
defaults and local bindings. It must not restrict a declared dependency to the
edited element. T04/T05/E03/X06 expose nonlocal invalidation requirements.
Proposed D14 makes extension, replacement, disabling, and conflict explicit and
exposes the effective rule and its origin through diagnostics or generated
artifacts.

## Backend-specific layers remain unfilled

The selected evaluator should have a public normalized surface for its
capabilities and a faithful/native surface for its own configuration. Those
surfaces are backend-specific siblings, not a universal `sem.native`. Their
exact examples cannot be honestly written before backend selection and
capability experiments at Gate 2.

The shared layer need not translate arbitrary native programs between backends.
Unsupported traversal/lowering produces a capability error or an explicitly
supported equivalent path. Filtering the final visited set after crossing a
forbidden boundary is not evidence of equivalent expansion semantics.

## Provider and result review points

A candidate executable-provider convention is structured request on stdin,
complete identified facts on stdout, operational diagnostics on stderr, and
process status for acquisition success/failure. Schema/version, required
environment, resources, and legal inputs still need review. No provider ABI is
implemented in Gate 1. Acquisition happens at runtime, not during Nix
evaluation. Providers acquire facts; they do not mutate StrictDoc, commit
repairs, or choose preservation policy.

Results should distinguish native validation, custom violations, and execution
errors. Candidate structured fields are rule identity, producer/category, code,
subjects, source location, and witness containing the relevant path/boundary or
external snapshot. Exact envelope and code spelling remain open. Tests should
assert these meaningful facts instead of brittle prose.

## Gate boundary

Review these shared/helper sketches with the behavior tables first. Then
evaluate backend alternatives and review their two lower surfaces. A functioning
grammar fixture proves the existing public assembly; it does not demonstrate any
semantic authoring layer. Missing APIs remain explicit interface gaps until
exposed and exercised through real Scribe candidate operations.
