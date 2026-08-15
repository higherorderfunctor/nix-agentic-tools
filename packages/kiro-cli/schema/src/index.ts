/**
 * Typed Kiro workflow definitions, in Effect `Schema`.
 *
 * Three layers, the same split as the Nix side:
 *   ./schema.ts     what one node proves about itself (decode a real file)
 *   ./analyze.ts    what only the whole tree proves + policy lints
 *   ./type-level.ts  the subset of tree rules that fit at COMPILE time
 */
export * from "./analyze.js";
export * from "./limits.js";
export * from "./schema.js";
export * from "./type-level.js";

import { Either } from "effect";
import { type Analysis, analyze } from "./analyze.js";
import { decodeWorkflow, type Workflow } from "./schema.js";
import type { CheckWorkflow } from "./type-level.js";

/**
 * Author a workflow with the tree rules checked AT COMPILE TIME.
 *
 * `const W` keeps a direct object literal narrow. Deeply readonly imported
 * JSON-shaped literals work too. Widened arrays and union-shaped subtrees are
 * rejected as statically indeterminate instead of silently passing; decode and
 * `validate` those values at runtime. Known tuple suffixes are still checked,
 * so an unknown subtree cannot hide a later provable violation.
 *
 * A violation surfaces as a type error on the argument whose text carries the
 * reason, e.g.
 *   `duplicate node id 'fold': ids must be unique across the whole tree`
 *
 * This covers the four rules that are decidable from the graph's SHAPE. It
 * does NOT cover template references — those need the prompt text, and
 * parsing free prose at compile time costs unboundedly more than it buys.
 * Run `validate` for those.
 */
export const defineWorkflow = <const W extends Workflow>(
  workflow: W & CheckWorkflow<W>,
): W => workflow;

export type ValidationResult =
  | {
      readonly ok: true;
      readonly workflow: Workflow;
      readonly analysis: Analysis;
    }
  | { readonly ok: false; readonly reason: "decode"; readonly error: string }
  | {
      readonly ok: false;
      readonly reason: "analysis";
      readonly analysis: Analysis;
    };

/**
 * Decode an unknown value as a workflow, then run the whole-tree analysis.
 *
 * `strict` promotes policy lints to failures, matching contract.jq's
 * `--strict`. Default is engine rules only, because a policy rule would
 * reject definitions that really do run.
 */
export const validate = (
  input: unknown,
  options: { readonly strict?: boolean } = {},
): ValidationResult => {
  const decoded = decodeWorkflow(input, { errors: "all" });
  if (Either.isLeft(decoded)) {
    return { ok: false, reason: "decode", error: String(decoded.left) };
  }
  const workflow = decoded.right;
  const analysis = analyze(workflow);
  const fatal =
    options.strict === true ? analysis.diagnostics : analysis.errors;
  return fatal.length === 0
    ? { ok: true, workflow, analysis }
    : { ok: false, reason: "analysis", analysis };
};
