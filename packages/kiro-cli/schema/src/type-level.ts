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
 * ── Why the scanner uses an explicit work-list ─────────────────────────────
 *
 * The obvious encoding recurses structurally: count a node, then recurse into
 * each child and sum. That is NOT tail-recursive, so TypeScript caps it at 50
 * levels of instantiation depth — and a workflow nests to 8 with up to 20
 * steps, which blows that budget on the *sum*, not on the depth.
 *
 * So one scanner carries a flat QUEUE of pending nodes and an accumulator, and
 * every recursive call is the ENTIRE body of its conditional branch. That is
 * the shape TypeScript's tail-recursion elimination recognizes, which raises
 * the ceiling to ~1000 iterations. That is far beyond an ordinary workflow and
 * keeps the type machinery out of the much lower non-tail instantiation limit.
 *
 * Children are pushed onto the FRONT of the queue (`[...S, ...T]`) so the walk
 * order matches the analyzers' depth-first order. When a queue contains a
 * widened array or union that cannot be enumerated, the scanner keeps scanning
 * every tuple element they can still prove and return `"indeterminate"` rather
 * than silently treating the unknown region as clean.
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

/** A proof result: unknown shapes are explicit rather than silently accepted. */
export type StaticCheckResult = true | false | "indeterminate";

type IsTuple<A extends readonly unknown[]> = number extends A["length"]
  ? false
  : true;

type IsUnion<T, Whole = T> = T extends Whole
  ? [Whole] extends [T]
    ? false
    : true
  : never;

type IsConcreteString<S extends string> = string extends S
  ? false
  : true extends IsUnion<S>
    ? false
    : S extends ""
      ? true
      : S extends `${infer _Head}${infer Tail}`
        ? string extends Tail
          ? false
          : IsConcreteString<Tail>
        : false;

// ── Structural node probes ──────────────────────────────────────────────────
//
// Written as inline `extends` tests rather than against a declared union, so
// they match a caller's `as const` literal without it having to be widened to
// a nominal type first.

type OrderedContainer = { readonly type: "sequence" | "repeat" };
type ParallelContainer = { readonly type: "parallel" };

type Equal<A, B> = [A] extends [B] ? ([B] extends [A] ? true : false) : false;

type IncludesExact<
  Ids extends readonly string[],
  Needle extends string,
> = Ids extends readonly [
  infer H extends string,
  ...infer T extends readonly string[],
]
  ? Equal<H, Needle> extends true
    ? true
    : IncludesExact<T, Needle>
  : false;

// ── One tail-recursive scan, four proofs ────────────────────────────────────

type Rule = "count" | "depth" | "ids" | "orientation";
type WorkItem = readonly [unknown, readonly unknown[], boolean];
type WorkQueue = readonly WorkItem[];

type WithContext<
  Nodes extends readonly unknown[],
  Depth extends readonly unknown[],
  InParallel extends boolean,
> = {
  readonly [K in keyof Nodes]: readonly [Nodes[K], Depth, InParallel];
};

type ScanState<
  Count extends readonly unknown[] = [],
  Ids extends readonly string[] = [],
  Duplicate extends string = never,
  Interactive extends string = never,
  TooDeep extends boolean = false,
  UnknownRules extends Rule = never,
> = {
  readonly count: Count;
  readonly duplicate: Duplicate;
  readonly ids: Ids;
  readonly interactive: Interactive;
  readonly tooDeep: TooDeep;
  readonly unknown: UnknownRules;
};

type AnyScanState = ScanState<
  readonly unknown[],
  readonly string[],
  string,
  string,
  boolean,
  Rule
>;

type MarkUnknown<S extends AnyScanState, R extends Rule> = ScanState<
  S["count"],
  S["ids"],
  S["duplicate"],
  S["interactive"],
  S["tooDeep"],
  S["unknown"] | R
>;

type NoteDepth<
  S extends AnyScanState,
  Depth extends readonly unknown[],
> = S["tooDeep"] extends true
  ? S
  : Lte<Depth["length"], MaxNestingDepth> extends false
    ? ScanState<
        S["count"],
        S["ids"],
        S["duplicate"],
        S["interactive"],
        true,
        S["unknown"]
      >
    : S;

type NoteStep<S extends AnyScanState> = ScanState<
  [...S["count"], unknown],
  S["ids"],
  S["duplicate"],
  S["interactive"],
  S["tooDeep"],
  S["unknown"]
>;

type NoteId<S extends AnyScanState, I extends string> =
  IsConcreteString<I> extends true
    ? IncludesExact<S["ids"], I> extends true
      ? ScanState<
          S["count"],
          S["ids"],
          [S["duplicate"]] extends [never] ? I : S["duplicate"],
          S["interactive"],
          S["tooDeep"],
          S["unknown"]
        >
      : ScanState<
          S["count"],
          [...S["ids"], I],
          S["duplicate"],
          S["interactive"],
          S["tooDeep"],
          S["unknown"]
        >
    : MarkUnknown<S, "ids">;

type NoteNodeId<S extends AnyScanState, H> = [H] extends [
  { readonly id: infer I extends string },
]
  ? NoteId<S, I>
  : MarkUnknown<S, "ids">;

type NoteInteractive<
  S extends AnyScanState,
  H,
  InParallel extends boolean,
> = InParallel extends false
  ? S
  : [H] extends [{ readonly completion: {} }]
    ? [H] extends [{ readonly id: infer I extends string }]
      ? ScanState<
          S["count"],
          S["ids"],
          S["duplicate"],
          [S["interactive"]] extends [never] ? I : S["interactive"],
          S["tooDeep"],
          S["unknown"]
        >
      : MarkUnknown<S, "orientation">
    : true extends IsUnion<H>
      ? MarkUnknown<S, "orientation">
      : "completion" extends keyof H
        ? MarkUnknown<S, "orientation">
        : S;

type MarkUnknownChildren<S extends AnyScanState> = MarkUnknown<
  S,
  "count" | "depth" | "ids" | "orientation"
>;

type Advance<Q extends WorkQueue, S extends AnyScanState> = {
  readonly queue: Q;
  readonly state: S;
};

type AdvanceContainer<
  H,
  Children extends readonly unknown[],
  ChildDepth extends readonly unknown[],
  ChildParallel extends boolean,
  T extends WorkQueue,
  S extends AnyScanState,
> =
  NoteNodeId<S, H> extends infer WithId extends AnyScanState
    ? true extends IsUnion<H>
      ? Advance<T, MarkUnknownChildren<WithId>>
      : IsTuple<Children> extends true
        ? Advance<
            [...WithContext<Children, ChildDepth, ChildParallel>, ...T],
            WithId
          >
        : Advance<T, MarkUnknownChildren<WithId>>
    : never;

type AdvanceNode<
  H,
  Depth extends readonly unknown[],
  InParallel extends boolean,
  T extends WorkQueue,
  S extends AnyScanState,
> =
  NoteDepth<S, Depth> extends infer AtDepth extends AnyScanState
    ? [H] extends [
        {
          readonly type: "step";
        },
      ]
      ? Advance<
          T,
          NoteInteractive<NoteNodeId<NoteStep<AtDepth>, H>, H, InParallel>
        >
      : [H] extends [
            {
              readonly type: "watch";
            },
          ]
        ? Advance<T, NoteNodeId<AtDepth, H>>
        : [H] extends [
              OrderedContainer & {
                readonly steps: infer Children extends readonly unknown[];
              },
            ]
          ? AdvanceContainer<
              H,
              Children,
              [...Depth, unknown],
              InParallel,
              T,
              AtDepth
            >
          : [H] extends [
                ParallelContainer & {
                  readonly branches: infer Children extends readonly unknown[];
                },
              ]
            ? AdvanceContainer<
                H,
                Children,
                [...Depth, unknown],
                true,
                T,
                AtDepth
              >
            : Advance<T, MarkUnknownChildren<AtDepth>>
    : never;

type ScanQ<
  Q extends WorkQueue,
  S extends AnyScanState = ScanState,
> = Q extends readonly [
  readonly [
    infer H,
    infer Depth extends readonly unknown[],
    infer InParallel extends boolean,
  ],
  ...infer T extends WorkQueue,
]
  ? AdvanceNode<H, Depth, InParallel, T, S> extends infer A extends Advance<
      WorkQueue,
      AnyScanState
    >
    ? ScanQ<A["queue"], A["state"]>
    : never
  : Q extends readonly [
        ...infer T extends WorkQueue,
        readonly [
          infer H,
          infer Depth extends readonly unknown[],
          infer InParallel extends boolean,
        ],
      ]
    ? AdvanceNode<H, Depth, InParallel, T, S> extends infer A extends Advance<
        WorkQueue,
        AnyScanState
      >
      ? ScanQ<A["queue"], A["state"]>
      : never
    : IsTuple<Q> extends true
      ? S
      : MarkUnknownChildren<S>;

type Scan<Steps extends readonly unknown[]> = ScanQ<
  WithContext<Steps, [unknown], false>
>;

type RuleIsUnknown<S extends AnyScanState, R extends Rule> = [R] extends [
  S["unknown"],
]
  ? true
  : false;

/** Exact count for a literal tree, or `number` when part of the tree is unknown. */
export type CountStepNodes<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState
    ? RuleIsUnknown<S, "count"> extends true
      ? number
      : S["count"]["length"]
    : never;

export type StepCapOk<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState
    ? Lte<S["count"]["length"], MaxStepNodes> extends false
      ? false
      : RuleIsUnknown<S, "count"> extends true
        ? "indeterminate"
        : true
    : never;

export type DepthOk<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState
    ? S["tooDeep"] extends true
      ? false
      : RuleIsUnknown<S, "depth"> extends true
        ? "indeterminate"
        : true
    : never;

export type DuplicateId<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState ? S["duplicate"] : never;

type IdUniquenessOk<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState
    ? [S["duplicate"]] extends [never]
      ? RuleIsUnknown<S, "ids"> extends true
        ? "indeterminate"
        : true
      : false
    : never;

export type InteractiveStepInParallel<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState ? S["interactive"] : never;

type InteractivePlacementOk<Steps extends readonly unknown[]> =
  Scan<Steps> extends infer S extends AnyScanState
    ? [S["interactive"]] extends [never]
      ? RuleIsUnknown<S, "orientation"> extends true
        ? "indeterminate"
        : true
      : false
    : never;

// ── Assembling the verdict ──────────────────────────────────────────────────

/**
 * Every tree-level violation of W, as a union of human-readable strings.
 * `never` means clean.
 */
export type WorkflowViolations<
  W extends { readonly steps: readonly unknown[] },
> =
  | (StepCapOk<W["steps"]> extends infer R extends StaticCheckResult
      ? R extends true
        ? never
        : R extends false
          ? Scan<W["steps"]> extends infer S extends AnyScanState
            ? `too many step nodes: at least ${S["count"]["length"]} exceeds the maximum of ${MaxStepNodes} (only 'step' nodes count)`
            : never
          : "step-node count is not statically decidable: validate the widened or union-shaped workflow at runtime"
      : never)
  | (DepthOk<W["steps"]> extends infer R extends StaticCheckResult
      ? R extends true
        ? never
        : R extends false
          ? `nesting is deeper than the maximum of ${MaxNestingDepth}`
          : "nesting depth is not statically decidable: validate the widened or union-shaped workflow at runtime"
      : never)
  | (IdUniquenessOk<W["steps"]> extends infer R extends StaticCheckResult
      ? R extends true
        ? never
        : R extends false
          ? `duplicate node id '${DuplicateId<W["steps"]>}': ids must be unique across the whole tree`
          : "node-id uniqueness is not statically decidable: validate the widened or union-shaped workflow at runtime"
      : never)
  | (InteractivePlacementOk<W["steps"]> extends infer R extends
      StaticCheckResult
      ? R extends true
        ? never
        : R extends false
          ? `step '${InteractiveStepInParallel<W["steps"]>}' declares 'completion' beneath a 'parallel': an interactive step cannot be resumed while sibling branches keep the run loop busy`
          : "interactive-step placement is not statically decidable: validate the widened or union-shaped workflow at runtime"
      : never);

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
