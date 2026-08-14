/**
 * Engine constants, re-exported from the SHARED json so the TypeScript and
 * Nix schemas cannot drift from each other.
 *
 * The json lives with the Nix side because that is where it is re-derived
 * from the shipped KAS bundle; see its `_comment` for the resolver. Do not
 * copy values out of it into either language.
 */
import engineLimits from "../../lib/workflow/engine-limits.json" with {
  type: "json",
};

export const ENGINE = engineLimits;

export const MAX_NESTING_DEPTH = ENGINE.limits.maxNestingDepth;
export const MAX_STEP_NODES = ENGINE.limits.maxStepNodes;
export const MAX_REPEAT_ITERATIONS = ENGINE.limits.maxRepeatIterations;

/**
 * Compile-time mirrors of the two caps.
 *
 * They have to be written as literals: a json import widens to `number` in
 * the type domain, and the type-level walkers in ./type-level.ts can only
 * count against a literal. So `satisfies` cannot bridge the two — it fails
 * with "Type 'number' does not satisfy the expected type '20'".
 *
 * The agreement is therefore enforced at MODULE LOAD instead of at compile
 * time. That is strictly better than a unit test: it cannot be forgotten, and
 * it fires in every consumer rather than only under `bun test`. Bumping a cap
 * in engine-limits.json without bumping the literal here is a loud crash, not
 * a schema that quietly checks the wrong bound.
 */
export type MaxStepNodes = 20;
export type MaxNestingDepth = 8;

const TYPE_LEVEL_MAX_STEP_NODES = 20;
const TYPE_LEVEL_MAX_NESTING_DEPTH = 8;

if (MAX_STEP_NODES !== TYPE_LEVEL_MAX_STEP_NODES) {
  throw new Error(
    `kiro workflow schema: engine-limits.json says maxStepNodes=${MAX_STEP_NODES} but the compile-time type MaxStepNodes is ${TYPE_LEVEL_MAX_STEP_NODES}. Update the literal in src/limits.ts.`,
  );
}
if (MAX_NESTING_DEPTH !== TYPE_LEVEL_MAX_NESTING_DEPTH) {
  throw new Error(
    `kiro workflow schema: engine-limits.json says maxNestingDepth=${MAX_NESTING_DEPTH} but the compile-time type MaxNestingDepth is ${TYPE_LEVEL_MAX_NESTING_DEPTH}. Update the literal in src/limits.ts.`,
  );
}
