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
  DuplicateId,
  InteractiveStepInParallel,
} from "../src/type-level.js";

const step = <const Id extends string>(id: Id) =>
  ({ type: "step", id, agent: "ag", prompt: "p" }) as const;

// ── the walkers, asserted directly ──────────────────────────────────────────

type Assert<T extends true> = T;

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
