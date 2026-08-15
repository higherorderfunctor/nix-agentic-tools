# Kiro workflow schema (Effect)

An [Effect `Schema`](https://effect.website) for the Kiro workflow definition
format, plus a whole-tree analyzer and compile-time enforcement of the tree
rules.

This is the TypeScript half of a pair. The Nix half lives in
[`../lib/workflow/`](../lib/workflow/) and the two share their engine constants
through
[`../lib/workflow/engine-limits.json`](../lib/workflow/engine-limits.json), so
they cannot drift from each other.

## Where the contract comes from

The workflow format appears in **no public Kiro documentation** — a full
download of the docs corpus (194 pages) contains zero occurrences of every
schema identifier, and workflows are absent from the CLI 3.0 feature table, the
experimental-feature register, and the ACP extension list. The feature is
dark-shipped.

So the shipped KAS engine bundle is the only spec, and every rule here traces to
a read of it. `engine-limits.json` carries the resolver for re-deriving the
constants on a version bump.

## Layers

| Module              | Proves                                                  |
| ------------------- | ------------------------------------------------------- |
| `src/schema.ts`     | what one node proves about itself — decodes a real file |
| `src/analyze.ts`    | what only the whole tree proves, plus policy lints      |
| `src/type-level.ts` | the subset of tree rules that fit at **compile** time   |

`src/analyze.ts` is a deliberate twin of `../lib/workflow/analyze.nix` for graph
shapes both ports represent: shared diagnostic codes, the same `basis` taxonomy,
and the same walk order. TypeScript additionally reports `E-STOP-WHEN-SYNTAX`
for malformed assembled strings the authored Nix sum type makes unrepresentable.
The suites are parallel but no cross-language runner compares them.

## Usage

Decode and analyze an existing definition:

```ts
import { validate } from "./src/index.js";

const result = validate(JSON.parse(await Bun.file("x.workflow.json").text()));
if (!result.ok) {
  // result.reason === "decode"   -> shape is wrong
  // result.reason === "analysis" -> shape is fine, the TREE is not
}
```

Author one with the tree rules checked at compile time:

```ts
import { defineWorkflow } from "./src/index.js";

const wf = defineWorkflow({
  name: "review",
  steps: [
    { type: "step", id: "a", agent: "reviewer", prompt: "…" },
    { type: "step", id: "a", agent: "reviewer", prompt: "…" },
    //                  ^ type error: duplicate node id 'a'
  ],
});
```

Pass the object literal **directly**, or use a generated TypeScript module or
loader that preserves a JSON-shaped value as a deeply readonly literal. Plain
`resolveJsonModule` imports widen string discriminants and cannot recover the
literal proof. Send those through `validate` at runtime instead. Exact tuples
receive exact proofs for the step cap, depth cap, id uniqueness, and
interactive-step placement. Widened arrays and union-shaped subtrees are not
silently accepted: `defineWorkflow` reports the affected rule as statically
indeterminate. The scanner still inspects every known tuple suffix, so an
unknown subtree cannot hide a later violation that is provable.

## Checking it

Nothing in the flake builds this package, deliberately: wiring it in would mean
vendoring an npm lockfile, adding a cache-parity row, and entering the required
CI `build` job — a real cost for a schema whose consumer is not yet decided.
`treefmt`/biome already format it for free. The checks are manual:

```bash
cd packages/kiro-cli/schema
nix shell nixpkgs#bun -c bun install
nix shell nixpkgs#bun -c bun test          # 80 runtime tests
nix shell nixpkgs#typescript -c tsc --noEmit  # types + compile-time tests
```

**Both are needed and neither subsumes the other.** `bun test` strips types
without checking them, so it proves nothing about `test/type-level.test-d.ts`;
`tsc` never executes, so it proves nothing about the analyzer. The compile-time
negative tests are `@ts-expect-error` directives, which FAIL the build when the
next line does _not_ error — so they are real assertions rather than comments.

The Nix side's equivalents run in CI as `nix flake check`, including the
vendor-recipe conformance corpus.

## The corpus that matters

`../../../checks/fixtures/kiro-workflows/vendor/` holds the seven workflow
definitions inlined in the engine bundle. The engine shape-parses them at module
init but does not run its structural analyzer until launch. They are the
highest-fidelity available corpus rather than an oracle: a failure warrants
checking both the local rule and the vendor recipe. Both halves of this pair
check against all seven. The Nix half additionally parses each recipe into its
authored shape and renders it back, checking the result equals the original
attribute set with `planRevision` dropped — runtime state the authored shape has
no option for.

They are also a useful map of what the vendor actually uses: no `sequence` node
anywhere, no nested repeats, no nested parallels, max observed depth 3 against a
cap of 8, and max 10 step nodes against a cap of 20.
