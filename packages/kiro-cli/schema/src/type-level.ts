/**
 * Compile-time enforcement of the whole-tree rules.
 *
 * The Effect schema in ./schema.ts proves everything decidable from one node.
 * These types prove the rules that need the WHOLE tree — the 20-step cap, the
 * depth-8 cap, global id uniqueness, and the one node-orientation rule — for a
 * workflow written as a literal (`as const`, or through `defineWorkflow`).
 * A violation is then a red squiggle in the editor rather than a runtime
 * failure, which is the point.
 *
 * ── Why every walker uses an explicit work-list ─────────────────────────────
 *
 * The obvious encoding recurses structurally: count a node, then recurse into
 * each child and sum. That is NOT tail-recursive, so TypeScript caps it at 50
 * levels of instantiation depth — and a workflow nests to 8 with up to 20
 * steps, which blows that budget on the *sum*, not on the depth.
 *
 * So each walker carries a flat QUEUE of pending nodes and an accumulator, and
 * every recursive call is the ENTIRE body of its conditional branch. That is
 * the shape TypeScript's tail-recursion elimination recognizes, which raises
 * the ceiling to ~1000 iterations — far beyond the 20-step cap these rules
 * enforce, so the walkers can never be the thing that runs out.
 *
 * Children are pushed onto the FRONT of the queue (`[...S, ...T]`) so the walk
 * order matches the Nix analyzer's depth-first order and the two report the
 * same first offender.
 *
 * ── Deliberate boundary ─────────────────────────────────────────────────────
 *
 * Template-reference validation (`{{a.output}}` must name an earlier producer)
 * is NOT done here, even though template-literal types could parse it. Doing
 * so means parsing every prompt in the tree at compile time, and prompts are
 * long free text — the cost is unbounded in the size of the prose, not in the
 * size of the graph. It runs at runtime in ./schema.ts instead, where it is
 * the same check the Nix analyzer performs. See HITL item P-09.
 */
import type { MaxNestingDepth, MaxStepNodes } from "./limits.js";

// ── Arithmetic on tuple lengths ─────────────────────────────────────────────

/** A tuple of exactly N elements. Tail-recursive. */
type Tuple<
  N extends number,
  A extends readonly unknown[] = [],
> = A["length"] extends N ? A : Tuple<N, [...A, unknown]>;

/**
 * `N <= Cap`. A Cap-tuple matches `[...Tuple<N>, ...unknown[]]` exactly when
 * it is at least N long, i.e. when Cap >= N.
 */
type Lte<N extends number, Cap extends number> =
  Tuple<Cap> extends [...Tuple<N>, ...unknown[]] ? true : false;

// ── Structural node probes ──────────────────────────────────────────────────
//
// Written as inline `extends` tests rather than against a declared union, so
// they match a caller's `as const` literal without it having to be widened to
// a nominal type first.

type OrderedContainer = { readonly type: "sequence" | "repeat" };
type ParallelContainer = { readonly type: "parallel" };

/** Pair every element of a tuple with a constant, preserving tuple-ness. */
type PairWith<S extends readonly unknown[], P> = {
  readonly [K in keyof S]: readonly [S[K], P];
};

// ── 1. Step-node count ──────────────────────────────────────────────────────

/**
 * Counts `step` nodes across the whole tree. Container nodes are free — this
 * mirrors the engine, which increments only in `walkStep`.
 */
export type CountStepNodes<
  Q extends readonly unknown[],
  Acc extends readonly unknown[] = [],
> = Q extends readonly [infer H, ...infer T]
  ? H extends { readonly type: "step" }
    ? CountStepNodes<T, [...Acc, unknown]>
    : H extends OrderedContainer & {
          readonly steps: infer S extends readonly unknown[];
        }
      ? CountStepNodes<[...S, ...T], Acc>
      : H extends ParallelContainer & {
            readonly branches: infer B extends readonly unknown[];
          }
        ? CountStepNodes<[...B, ...T], Acc>
        : CountStepNodes<T, Acc>
  : Acc["length"];

export type StepCapOk<Steps extends readonly unknown[]> = Lte<
  CountStepNodes<Steps>,
  MaxStepNodes
>;

// ── 2. Nesting depth ────────────────────────────────────────────────────────

type DepthQueue = readonly (readonly [unknown, readonly unknown[]])[];

/**
 * True when any node sits deeper than the cap. A top-level node has depth 1,
 * matching the engine's `lineage.length`.
 */
type ExceedsDepthQ<Q extends DepthQueue> = Q extends readonly [
  readonly [infer H, infer D extends readonly unknown[]],
  ...infer T extends DepthQueue,
]
  ? Lte<D["length"], MaxNestingDepth> extends false
    ? true
    : H extends OrderedContainer & {
          readonly steps: infer S extends readonly unknown[];
        }
      ? ExceedsDepthQ<[...PairWith<S, [...D, unknown]>, ...T]>
      : H extends ParallelContainer & {
            readonly branches: infer B extends readonly unknown[];
          }
        ? ExceedsDepthQ<[...PairWith<B, [...D, unknown]>, ...T]>
        : ExceedsDepthQ<T>
  : false;

export type DepthOk<Steps extends readonly unknown[]> =
  ExceedsDepthQ<PairWith<Steps, [unknown]>> extends true ? false : true;

// ── 3. Global id uniqueness ─────────────────────────────────────────────────

type CollectIds<
  Q extends readonly unknown[],
  Acc extends readonly string[] = [],
> = Q extends readonly [infer H, ...infer T]
  ? H extends OrderedContainer & {
      readonly id: infer I extends string;
      readonly steps: infer S extends readonly unknown[];
    }
    ? CollectIds<[...S, ...T], [...Acc, I]>
    : H extends ParallelContainer & {
          readonly id: infer I extends string;
          readonly branches: infer B extends readonly unknown[];
        }
      ? CollectIds<[...B, ...T], [...Acc, I]>
      : H extends { readonly id: infer I extends string }
        ? CollectIds<T, [...Acc, I]>
        : CollectIds<T, Acc>
  : Acc;

/** The first id seen twice, or `never`. `[H] extends [Seen]` blocks distribution. */
type FirstDuplicate<
  Ids extends readonly string[],
  Seen = never,
> = Ids extends readonly [
  infer H extends string,
  ...infer T extends readonly string[],
]
  ? [H] extends [Seen]
    ? H
    : FirstDuplicate<T, Seen | H>
  : never;

export type DuplicateId<Steps extends readonly unknown[]> = FirstDuplicate<
  CollectIds<Steps>
>;

// ── 4. The one node-orientation rule ────────────────────────────────────────

type FlagQueue = readonly (readonly [unknown, boolean])[];

/**
 * The id of the first step that declares `completion` beneath a `parallel`,
 * or `never`.
 *
 * The flag is sticky: once inside a parallel, every descendant is inside it.
 * That mirrors the engine's `lineage.some(kind === "concurrent")`, which is
 * an ANY-ancestor test rather than a parent test — a step three levels down
 * inside a branch still violates it.
 *
 * `completion: {}` matches any present, non-nullish value; an absent
 * `completion` fails the test, which is what makes non-interactive steps pass.
 */
type FindInteractiveInParallel<Q extends FlagQueue> = Q extends readonly [
  readonly [infer H, infer P extends boolean],
  ...infer T extends FlagQueue,
]
  ? H extends {
      readonly type: "step";
      readonly id: infer I extends string;
      readonly completion: {};
    }
    ? P extends true
      ? I
      : FindInteractiveInParallel<T>
    : H extends OrderedContainer & {
          readonly steps: infer S extends readonly unknown[];
        }
      ? FindInteractiveInParallel<[...PairWith<S, P>, ...T]>
      : H extends ParallelContainer & {
            readonly branches: infer B extends readonly unknown[];
          }
        ? FindInteractiveInParallel<[...PairWith<B, true>, ...T]>
        : FindInteractiveInParallel<T>
  : never;

export type InteractiveStepInParallel<Steps extends readonly unknown[]> =
  FindInteractiveInParallel<PairWith<Steps, false>>;

// ── Assembling the verdict ──────────────────────────────────────────────────

/**
 * Every tree-level violation of W, as a union of human-readable strings.
 * `never` means clean.
 */
export type WorkflowViolations<
  W extends { readonly steps: readonly unknown[] },
> =
  | (StepCapOk<W["steps"]> extends true
      ? never
      : `too many step nodes: ${CountStepNodes<W["steps"]>} exceeds the maximum of ${MaxStepNodes} (only 'step' nodes count)`)
  | (DepthOk<W["steps"]> extends true
      ? never
      : `nesting is deeper than the maximum of ${MaxNestingDepth}`)
  | ([DuplicateId<W["steps"]>] extends [never]
      ? never
      : `duplicate node id '${DuplicateId<W["steps"]>}': ids must be unique across the whole tree`)
  | ([InteractiveStepInParallel<W["steps"]>] extends [never]
      ? never
      : `step '${InteractiveStepInParallel<W["steps"]>}' declares 'completion' beneath a 'parallel': an interactive step cannot be resumed while sibling branches keep the run loop busy`);

/** Carrier for a compile-time failure, so the message lands in the error text. */
export declare const WorkflowErrorTag: unique symbol;
export type WorkflowError<M extends string> = {
  readonly [WorkflowErrorTag]: M;
};

/**
 * `unknown` (a no-op in an intersection) when W is clean, otherwise an
 * unsatisfiable brand carrying the reason.
 */
export type CheckWorkflow<W extends { readonly steps: readonly unknown[] }> = [
  WorkflowViolations<W>,
] extends [never]
  ? unknown
  : WorkflowError<WorkflowViolations<W>>;
