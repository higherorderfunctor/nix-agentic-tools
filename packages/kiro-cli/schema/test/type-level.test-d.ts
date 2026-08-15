/**
 * COMPILE-TIME tests. These are checked by `tsc --noEmit`, not by `bun test`
 * — bun strips types without checking them, so running the suite proves
 * nothing about this file.
 *
 * `@ts-expect-error` is the assertion: the build FAILS if the next line does
 * not produce an error. So each one is a real negative test, not a comment.
 */
import { defineWorkflow } from "../src/index.js";
import type {
  CountStepNodes,
  DepthOk,
  DuplicateId,
  InteractiveStepInParallel,
  StepCapOk,
  WorkflowViolations,
} from "../src/type-level.js";

const step = <const Id extends string>(id: Id) =>
  ({ type: "step", id, agent: "ag", prompt: "p" }) as const;

// ── the walkers, asserted directly ──────────────────────────────────────────

type Assert<T extends true> = T;

type WatchTuple<
  N extends number,
  Acc extends readonly unknown[] = [],
> = Acc["length"] extends N
  ? Acc
  : WatchTuple<
      N,
      [
        ...Acc,
        { readonly type: "watch"; readonly id: `watch-${Acc["length"]}` },
      ]
    >;

/** The scanner remains tail-recursive beyond TS's ordinary depth-50 limit. */
type _ScansSixtyFourNodes = Assert<
  CountStepNodes<WatchTuple<64>> extends 0 ? true : false
>;

type _CountsFlat = Assert<
  CountStepNodes<[{ type: "step" }, { type: "step" }]> extends 2 ? true : false
>;

/** Containers are free — only `step` nodes count against the cap. */
type _CountsNested = Assert<
  CountStepNodes<
    [
      { type: "sequence"; steps: [{ type: "step" }, { type: "step" }] },
      { type: "parallel"; branches: [{ type: "step" }] },
      { type: "watch" },
    ]
  > extends 3
    ? true
    : false
>;

type _FindsDuplicate = Assert<
  DuplicateId<
    [{ type: "step"; id: "a" }, { type: "step"; id: "a" }]
  > extends "a"
    ? true
    : false
>;

/** Matches the engine: the first second occurrence is the first diagnostic. */
type _DuplicateOrderUsesSecondOccurrence = Assert<
  DuplicateId<
    [
      { type: "step"; id: "a" },
      { type: "step"; id: "b" },
      { type: "step"; id: "b" },
      { type: "step"; id: "a" },
    ]
  > extends "b"
    ? true
    : false
>;

type _NoDuplicate = Assert<
  [
    DuplicateId<[{ type: "step"; id: "a" }, { type: "step"; id: "b" }]>,
  ] extends [never]
    ? true
    : false
>;

/** The orientation rule is an ANY-ancestor test, not a parent test. */
type _InteractiveDeepInParallel = Assert<
  InteractiveStepInParallel<
    [
      {
        type: "parallel";
        id: "p";
        branches: [
          {
            type: "sequence";
            id: "s";
            steps: [
              { type: "step"; id: "gate"; completion: { containsText: "x" } },
            ];
          },
        ];
      },
    ]
  > extends "gate"
    ? true
    : false
>;

/** The same step OUTSIDE a parallel is fine. */
type _InteractiveOutsideParallel = Assert<
  [
    InteractiveStepInParallel<
      [{ type: "step"; id: "gate"; completion: { containsText: "x" } }]
    >,
  ] extends [never]
    ? true
    : false
>;

// ── defineWorkflow: accepted ────────────────────────────────────────────────

export const valid = defineWorkflow({
  name: "review",
  steps: [
    step("materialize"),
    {
      type: "parallel",
      id: "fan",
      joinPolicy: "allSettled",
      branches: [step("lens-io"), step("lens-errors")],
    },
    step("fold"),
  ],
});

/** Nested repeats are legal — the engine has no rule against them. */
export const nestedRepeats = defineWorkflow({
  name: "loops",
  steps: [
    {
      type: "repeat",
      id: "outer",
      maxIterations: 2,
      onMaxIterations: "abort",
      steps: [
        {
          type: "repeat",
          id: "inner",
          maxIterations: 2,
          onMaxIterations: "abort",
          steps: [step("s")],
        },
      ],
    },
  ],
});

// ── defineWorkflow: rejected at COMPILE time ────────────────────────────────

// @ts-expect-error duplicate node id 'a'
export const duplicateId = defineWorkflow({
  name: "dup",
  steps: [step("a"), step("a")],
});

// @ts-expect-error step 'gate' declares 'completion' beneath a 'parallel'
export const interactiveInParallel = defineWorkflow({
  name: "gate",
  steps: [
    {
      type: "parallel",
      id: "p",
      joinPolicy: "allSettled",
      branches: [
        {
          type: "step",
          id: "gate",
          agent: "ag",
          prompt: "p",
          completion: { containsText: "go" },
        },
      ],
    },
  ],
});

// @ts-expect-error 21 step nodes exceeds the maximum of 20
export const tooManySteps = defineWorkflow({
  name: "wide",
  steps: [
    step("s01"),
    step("s02"),
    step("s03"),
    step("s04"),
    step("s05"),
    step("s06"),
    step("s07"),
    step("s08"),
    step("s09"),
    step("s10"),
    step("s11"),
    step("s12"),
    step("s13"),
    step("s14"),
    step("s15"),
    step("s16"),
    step("s17"),
    step("s18"),
    step("s19"),
    step("s20"),
    step("s21"),
  ],
});

/** Exactly 20 must still be accepted — an off-by-one here is a real bug. */
export const exactlyTwentySteps = defineWorkflow({
  name: "at-cap",
  steps: [
    step("s01"),
    step("s02"),
    step("s03"),
    step("s04"),
    step("s05"),
    step("s06"),
    step("s07"),
    step("s08"),
    step("s09"),
    step("s10"),
    step("s11"),
    step("s12"),
    step("s13"),
    step("s14"),
    step("s15"),
    step("s16"),
    step("s17"),
    step("s18"),
    step("s19"),
    step("s20"),
  ],
});

// @ts-expect-error nesting is deeper than the maximum of 8
export const tooDeep = defineWorkflow({
  name: "deep",
  steps: [
    {
      type: "sequence",
      id: "d1",
      steps: [
        {
          type: "sequence",
          id: "d2",
          steps: [
            {
              type: "sequence",
              id: "d3",
              steps: [
                {
                  type: "sequence",
                  id: "d4",
                  steps: [
                    {
                      type: "sequence",
                      id: "d5",
                      steps: [
                        {
                          type: "sequence",
                          id: "d6",
                          steps: [
                            {
                              type: "sequence",
                              id: "d7",
                              steps: [
                                {
                                  type: "sequence",
                                  id: "d8",
                                  steps: [step("leaf")],
                                },
                              ],
                            },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
    },
  ],
});

// ── widened and union-shaped boundaries ────────────────────────────────────

type DynamicWatch = { readonly type: "watch"; readonly id: string };
type UnknownChildren = readonly DynamicWatch[];

/** A broad earlier id is not proof that a later concrete id is duplicated. */
type _BroadIdIsNotAFalseDuplicate = Assert<
  [
    DuplicateId<
      [
        { readonly type: "watch"; readonly id: string },
        { readonly type: "watch"; readonly id: "review" },
      ]
    >,
  ] extends [never]
    ? true
    : false
>;

/** A proper-supertype union is likewise indeterminate, not a duplicate. */
type _UnionIdIsNotAFalseDuplicate = Assert<
  [
    DuplicateId<
      [
        { readonly type: "watch"; readonly id: "review" | "setup" },
        { readonly type: "watch"; readonly id: "review" },
      ]
    >,
  ] extends [never]
    ? true
    : false
>;

/** An open template-literal pattern is not one concrete runtime id. */
type _TemplatePatternIsNotAFalseDuplicate = Assert<
  [
    DuplicateId<
      [
        { readonly type: "watch"; readonly id: `review-${string}` },
        { readonly type: "watch"; readonly id: `review-${string}` },
      ]
    >,
  ] extends [never]
    ? true
    : false
>;

type UnknownThenDuplicate = [
  {
    readonly type: "sequence";
    readonly id: "dynamic";
    readonly steps: UnknownChildren;
  },
  { readonly type: "watch"; readonly id: "known" },
  { readonly type: "watch"; readonly id: "known" },
];

/** An unknown child list cannot hide a later, statically known duplicate. */
type _ContinuesPastUnknownChildrenForIds = Assert<
  DuplicateId<UnknownThenDuplicate> extends "known" ? true : false
>;

/** Leading-rest tuples are scanned from their known suffix. */
type _ContinuesPastLeadingRestForIds = Assert<
  DuplicateId<
    readonly [
      ...DynamicWatch[],
      { readonly type: "watch"; readonly id: "tail" },
      { readonly type: "watch"; readonly id: "tail" },
    ]
  > extends "tail"
    ? true
    : false
>;

type UnknownThenInteractive = [
  {
    readonly type: "sequence";
    readonly id: "dynamic";
    readonly steps: UnknownChildren;
  },
  {
    readonly type: "parallel";
    readonly id: "fan";
    readonly branches: [
      {
        readonly type: "step";
        readonly id: "gate";
        readonly completion: { readonly containsText: "go" };
      },
    ];
  },
];

type _ContinuesPastUnknownChildrenForOrientation = Assert<
  InteractiveStepInParallel<UnknownThenInteractive> extends "gate"
    ? true
    : false
>;

type UnknownThenTwentyOne = readonly [
  {
    readonly type: "sequence";
    readonly id: "dynamic";
    readonly steps: UnknownChildren;
  },
  ...typeof tooManySteps.steps,
];

/** A known lower bound over the cap is still a proof of failure. */
type _KnownStepLowerBoundStillFails = Assert<
  StepCapOk<UnknownThenTwentyOne> extends false ? true : false
>;

type UnknownThenTooDeep = readonly [
  {
    readonly type: "sequence";
    readonly id: "dynamic";
    readonly steps: UnknownChildren;
  },
  ...typeof tooDeep.steps,
];

/** A known over-depth suffix is still a proof of failure. */
type _KnownDepthViolationStillFails = Assert<
  DepthOk<UnknownThenTooDeep> extends false ? true : false
>;

type SmallOrLarge =
  | { readonly type: "sequence"; readonly id: "small"; readonly steps: [] }
  | {
      readonly type: "sequence";
      readonly id: "large";
      readonly steps: typeof tooManySteps.steps;
    };

/** A union branch cannot pass merely because its smaller member fits. */
type _UnionCountIsExplicitlyIndeterminate = Assert<
  StepCapOk<[SmallOrLarge]> extends "indeterminate" ? true : false
>;

type ShallowOrDeep =
  | { readonly type: "watch"; readonly id: "shallow" }
  | (typeof tooDeep.steps)[0];

/** A shallow/deep union cannot collapse to the shallow member. */
type _UnionDepthIsExplicitlyIndeterminate = Assert<
  DepthOk<[ShallowOrDeep]> extends "indeterminate" ? true : false
>;

/** The verdict exposes uncertainty and every later known violation together. */
type _UnknownDoesNotSuppressKnownViolation = Assert<
  "duplicate node id 'known': ids must be unique across the whole tree" extends WorkflowViolations<{
    readonly steps: UnknownThenDuplicate;
  }>
    ? true
    : false
>;

declare const dynamicSteps: readonly ReturnType<typeof step>[];

// @ts-expect-error widened arrays require runtime validation instead of a static pass
export const widenedNeedsRuntimeValidation = defineWorkflow({
  name: "dynamic",
  steps: dynamicSteps,
});
