/**
 * Conformance tests.
 *
 * The load-bearing suite is "vendor recipes" — the seven definitions inlined
 * in the engine bundle. The engine self-validates them at module init, so a
 * schema that rejects any of them is provably wrong, and a schema that
 * accepts all of them has been checked against every shape the vendor ships.
 */
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Either } from "effect";
import { analyze, parseStopWhen, precedes } from "../src/analyze.js";
import { validate } from "../src/index.js";
import { decodeWorkflow } from "../src/schema.js";

const VENDOR_DIR = join(
  import.meta.dir,
  "../../../../checks/fixtures/kiro-workflows/vendor",
);

const decodes = (v: unknown) => Either.isRight(decodeWorkflow(v));

const minimal = {
  name: "w",
  steps: [{ type: "step", id: "a", agent: "ag", prompt: "p" }],
} as const;

const withSteps = (steps: unknown) => ({ name: "w", steps });

describe("vendor recipes (the engine's own, guaranteed-conformant corpus)", () => {
  const files = readdirSync(VENDOR_DIR).filter((f) =>
    f.endsWith(".workflow.json"),
  );

  test("all seven are present", () => {
    expect(files.length).toBe(7);
  });

  for (const file of files) {
    test(`${file} decodes and has no engine-basis errors`, () => {
      const raw: unknown = JSON.parse(
        readFileSync(join(VENDOR_DIR, file), "utf8"),
      );
      const result = validate(raw);
      if (!result.ok) {
        throw new Error(
          result.reason === "decode"
            ? `decode failed: ${result.error}`
            : `analysis failed: ${result.analysis.errors.map((e) => `${e.code} ${e.message}`).join("; ")}`,
        );
      }
      expect(result.analysis.errors).toEqual([]);
    });
  }
});

describe("schema: per-node rules", () => {
  test("accepts a minimal workflow", () => {
    expect(decodes(minimal)).toBe(true);
  });

  test("rejects the REMOVED step-level `input` field", () => {
    expect(
      decodes(
        withSteps([
          { type: "step", id: "a", agent: "ag", prompt: "p", input: "x" },
        ]),
      ),
    ).toBe(false);
  });

  test("requires `prompt` on a step", () => {
    expect(decodes(withSteps([{ type: "step", id: "a", agent: "ag" }]))).toBe(
      false,
    );
  });

  test("accepts an EMPTY prompt, because the engine does (it tests only `undefined`)", () => {
    expect(
      decodes(withSteps([{ type: "step", id: "a", agent: "ag", prompt: "" }])),
    ).toBe(true);
  });

  const repeat = (extra: Record<string, unknown>) =>
    withSteps([
      {
        type: "repeat",
        id: "r",
        steps: [],
        onMaxIterations: "abort",
        ...extra,
      },
    ]);

  test.each([
    ["zero", 0, false],
    ["fractional", 2.5, false],
    ["over the ceiling", 1001, false],
    ["at the ceiling (autoresearch ships this)", 1000, true],
    ["one", 1, true],
  ])("maxIterations %s", (_label, value, ok) => {
    expect(decodes(repeat({ maxIterations: value }))).toBe(ok);
  });

  test("requires onMaxIterations — the engine's Zod gives it no default", () => {
    expect(
      decodes(
        withSteps([{ type: "repeat", id: "r", steps: [], maxIterations: 2 }]),
      ),
    ).toBe(false);
  });

  test("rejects BOTH stop forms on one repeat", () => {
    expect(
      decodes(
        repeat({
          maxIterations: 2,
          stopCondition: { containsText: "x" },
          stopWhen: "w.terminal",
        }),
      ),
    ).toBe(false);
  });

  test("accepts NEITHER stop form — legal, and autoresearch ships it", () => {
    expect(decodes(repeat({ maxIterations: 2 }))).toBe(true);
  });

  test("rejects an empty stop condition", () => {
    expect(
      decodes(
        withSteps([
          { type: "step", id: "a", agent: "ag", prompt: "p", completion: {} },
        ]),
      ),
    ).toBe(false);
  });

  test("rejects the JSONPath spelling of jsonPath", () => {
    const fileCheck = { path: "a.json", jsonPath: "$.drained", value: true };
    expect(
      decodes(
        withSteps([
          {
            type: "step",
            id: "a",
            agent: "ag",
            prompt: "p",
            completion: { fileCheck },
          },
        ]),
      ),
    ).toBe(false);
  });

  test("accepts a dotted property walk", () => {
    const fileCheck = {
      path: "a.json",
      jsonPath: "state.drained",
      value: true,
    };
    expect(
      decodes(
        withSteps([
          {
            type: "step",
            id: "a",
            agent: "ag",
            prompt: "p",
            completion: { fileCheck },
          },
        ]),
      ),
    ).toBe(true);
  });

  test.each([
    [
      "unknown handler",
      { type: "watch", id: "w", handler: "gitlab-mr", config: {} },
      false,
    ],
    [
      "github-pr with neither prRef nor url",
      { type: "watch", id: "w", handler: "github-pr", config: {} },
      false,
    ],
    [
      "github-pr with prRef",
      {
        type: "watch",
        id: "w",
        handler: "github-pr",
        config: { prRef: "pr.json" },
      },
      true,
    ],
    [
      "pollIntervalSec below the registry minimum",
      {
        type: "watch",
        id: "w",
        handler: "github-pr",
        config: { prRef: "p.json", pollIntervalSec: 5 },
      },
      false,
    ],
    [
      "crux-cr with a malformed crId",
      { type: "watch", id: "w", handler: "crux-cr", config: { crId: "123" } },
      false,
    ],
    [
      "crux-cr with a valid crId",
      { type: "watch", id: "w", handler: "crux-cr", config: { crId: "CR-12" } },
      true,
    ],
  ])("watch: %s", (_label, node, ok) => {
    expect(decodes(withSteps([node]))).toBe(ok);
  });

  test("inputs values must be strings", () => {
    expect(decodes({ ...minimal, inputs: { n: 5 } })).toBe(false);
    expect(decodes({ ...minimal, inputs: { n: "hint" } })).toBe(true);
  });
});

describe("stopWhen grammar — exactly two shapes parse", () => {
  test.each([
    ["wait.terminal", { form: "watchTerminal", watchId: "wait" }],
    [
      "{{a.output}} contains DONE",
      { form: "contains", template: "a.output", text: "DONE" },
    ],
  ] as const)("%s parses", (input, expected) => {
    expect(parseStopWhen(input)).toEqual(expected);
  });

  test.each([
    ["a.b.terminal", "dotted watch id"],
    ["wait.done", "wrong suffix"],
    ["{{a.output}} contains ", "empty literal"],
    ["{{a.output}}contains X", "no spaces around the infix"],
    ["a.output contains X", "left side is not a template"],
    ["prefix {{a.output}}.terminal", "template not at offset 0"],
    ["{{a.output contains X", "unclosed template"],
  ])("%s is rejected (%s)", (input) => {
    expect(typeof parseStopWhen(input)).toBe("string");
  });
});

describe("precedes — the engine's happens-before", () => {
  const seg = (kind: "ordered" | "concurrent", index: number) => ({
    kind,
    index,
  });

  test("earlier ordered sibling precedes a later one", () => {
    expect(precedes([seg("ordered", 0)], [seg("ordered", 1)])).toBe(true);
  });

  test("later sibling does not precede an earlier one", () => {
    expect(precedes([seg("ordered", 1)], [seg("ordered", 0)])).toBe(false);
  });

  test("cross-branch inside a parallel is NEVER an ordering", () => {
    expect(
      precedes(
        [seg("ordered", 0), seg("concurrent", 0)],
        [seg("ordered", 0), seg("concurrent", 1)],
      ),
    ).toBe(false);
  });

  test("an ancestor does not precede its descendant", () => {
    expect(
      precedes([seg("ordered", 0)], [seg("ordered", 0), seg("ordered", 0)]),
    ).toBe(false);
  });

  test("a step INSIDE a parallel precedes a later sibling of the whole parallel", () => {
    // Divergence is at the ordered segment, not the concurrent one — so this
    // is legal, which is what makes an aggregation step after a fan-out work.
    expect(
      precedes([seg("ordered", 0), seg("concurrent", 1)], [seg("ordered", 1)]),
    ).toBe(true);
  });
});

const diagnosticsOf = (w: unknown) => {
  const decoded = decodeWorkflow(w);
  if (Either.isLeft(decoded)) throw new Error(`decode failed: ${decoded.left}`);
  return analyze(decoded.right).diagnostics;
};

const codesOf = (w: unknown): string[] =>
  diagnosticsOf(w).map((diagnostic) => diagnostic.code);

const step = (id: string, extra: Record<string, unknown> = {}) => ({
  type: "step",
  id,
  agent: "ag",
  prompt: "p",
  ...extra,
});

describe("analyze: whole-tree rules", () => {
  test("E-STEP-NODES-MAX at 21 steps, silent at 20", () => {
    const mk = (n: number) =>
      withSteps(Array.from({ length: n }, (_, i) => step(`s${i}`)));
    expect(codesOf(mk(20))).not.toContain("E-STEP-NODES-MAX");
    expect(codesOf(mk(21))).toContain("E-STEP-NODES-MAX");
  });

  test("E-NESTING-DEPTH past 8", () => {
    const nest = (n: number): unknown =>
      Array.from({ length: n }).reduce<unknown>(
        (inner, _, i) => ({ type: "sequence", id: `d${i}`, steps: [inner] }),
        step("leaf"),
      );
    expect(codesOf(withSteps([nest(7)]))).not.toContain("E-NESTING-DEPTH");
    expect(codesOf(withSteps([nest(8)]))).toContain("E-NESTING-DEPTH");
  });

  test("E-NODE-DUPLICATE-ID is global, not per-parent", () => {
    expect(
      codesOf(
        withSteps([
          { type: "sequence", id: "s", steps: [step("dup")] },
          {
            type: "parallel",
            id: "p",
            joinPolicy: "allSettled",
            branches: [step("dup")],
          },
        ]),
      ),
    ).toContain("E-NODE-DUPLICATE-ID");
  });

  test("duplicate ids use last-wins lineage and any-occurrence producer status", () => {
    const producerFirst = withSteps([
      step("dup"),
      step("dup", { captureOutput: false }),
      step("consumer", { prompt: "{{dup.output}}" }),
    ]);
    const producerLast = withSteps([
      step("dup", { captureOutput: false }),
      step("dup"),
      step("consumer", { prompt: "{{dup.output}}" }),
    ]);
    const lastIsLater = withSteps([
      step("dup"),
      step("consumer", { prompt: "{{dup.output}}" }),
      step("dup"),
    ]);

    expect(codesOf(producerFirst)).not.toContain("E-TEMPLATE-REF-NOT-PRODUCER");
    expect(codesOf(producerLast)).not.toContain("E-TEMPLATE-REF-NOT-PRODUCER");
    expect(codesOf(lastIsLater)).toContain("E-TEMPLATE-REF-NOT-PRECEDING");
  });

  test("E-INTERACTIVE-STEP-IN-PARALLEL — the only orientation rule, checked on ANY ancestor", () => {
    expect(
      codesOf(
        withSteps([
          {
            type: "parallel",
            id: "p",
            joinPolicy: "allSettled",
            branches: [
              {
                type: "sequence",
                id: "s",
                steps: [step("gate", { completion: { containsText: "go" } })],
              },
            ],
          },
        ]),
      ),
    ).toContain("E-INTERACTIVE-STEP-IN-PARALLEL");
  });

  test("nested repeats are LEGAL — there is no rule against them", () => {
    const codes = codesOf(
      withSteps([
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
      ]),
    );
    expect(codes.filter((c) => c.startsWith("E-"))).toEqual([]);
  });

  test("E-STOP-WHEN-WATCH-ID on a dangling watch reference", () => {
    expect(
      codesOf(
        withSteps([
          {
            type: "repeat",
            id: "r",
            maxIterations: 2,
            onMaxIterations: "abort",
            stopWhen: "nope.terminal",
            steps: [step("s")],
          },
        ]),
      ),
    ).toContain("E-STOP-WHEN-WATCH-ID");
  });

  test.each([
    ["E-TEMPLATE-REF-UNKNOWN", [step("a", { prompt: "{{ghost.output}}" })]],
    [
      "E-TEMPLATE-REF-NOT-PRECEDING",
      [step("a", { prompt: "{{b.output}}" }), step("b")],
    ],
    [
      "E-TEMPLATE-REF-NOT-PRODUCER",
      [
        step("a", { captureOutput: false }),
        step("b", { prompt: "{{a.output}}" }),
      ],
    ],
    ["E-ARTIFACT-REF-UNKNOWN", [step("a", { prompt: "{{artifacts.nope}}" })]],
    ["W-UNDECLARED-INPUT-REF", [step("a", { prompt: "{{nobody}}" })]],
  ])("%s", (code, steps) => {
    expect(codesOf(withSteps(steps))).toContain(code);
  });

  test("per-node diagnostic locations use node ids at every depth", () => {
    const diagnostics = diagnosticsOf(
      withSteps([
        step("top", { prompt: "{{ghost.output}}" }),
        {
          type: "sequence",
          id: "s",
          steps: [step("deep", { prompt: "{{ghost2.output}}" })],
        },
      ]),
    ).filter((diagnostic) => diagnostic.code === "E-TEMPLATE-REF-UNKNOWN");

    expect(diagnostics.map((diagnostic) => diagnostic.where)).toEqual([
      "top",
      "deep",
    ]);
  });

  test("empty template references are ignored", () => {
    expect(
      codesOf(withSteps([step("empty", { prompt: "{{}}" })])),
    ).not.toContain("W-UNDECLARED-INPUT-REF");
    expect(
      codesOf(withSteps([step("space", { prompt: "{{ }}" })])),
    ).not.toContain("W-UNDECLARED-INPUT-REF");
  });

  test("a declared input reference is clean", () => {
    const decoded = decodeWorkflow({
      name: "w",
      inputs: { pace: "hint" },
      steps: [step("a", { prompt: "go {{pace}}" })],
    });
    if (Either.isLeft(decoded)) throw new Error("decode failed");
    expect(analyze(decoded.right).diagnostics).toEqual([]);
  });

  test("artifacts resolve forward but not backward", () => {
    const ok = withSteps([
      step("a", { artifacts: { r: "r.json" } }),
      step("b", { prompt: "{{artifacts.r}}" }),
    ]);
    const bad = withSteps([
      step("b", { prompt: "{{artifacts.r}}" }),
      step("a", { artifacts: { r: "r.json" } }),
    ]);
    expect(codesOf(ok)).toEqual([]);
    expect(codesOf(bad)).toContain("E-ARTIFACT-REF-NOT-PRECEDING");
  });

  test("stop-context artifacts must be declared and visible", () => {
    const fileCheck = (path: string) => ({
      path,
      jsonPath: "done",
      value: true,
    });
    const missing = withSteps([
      step("a", {
        completion: { fileCheck: fileCheck("{{artifacts.nope}}") },
      }),
    ]);
    const later = withSteps([
      step("a", {
        completion: { fileCheck: fileCheck("{{artifacts.later}}") },
      }),
      step("b", { artifacts: { later: "later.json" } }),
    ]);
    const self = withSteps([
      step("a", {
        artifacts: { own: "own.json" },
        completion: { fileCheck: fileCheck("{{artifacts.own}}") },
      }),
    ]);
    const descendant = withSteps([
      {
        type: "repeat",
        id: "r",
        maxIterations: 2,
        onMaxIterations: "abort",
        stopCondition: { fileCheck: fileCheck("{{artifacts.child}}") },
        steps: [step("child", { artifacts: { child: "child.json" } })],
      },
    ]);

    expect(codesOf(missing)).toContain("E-STOP-CONTEXT-ARTIFACT-UNKNOWN");
    expect(codesOf(later)).toContain("E-STOP-CONTEXT-ARTIFACT-NOT-VISIBLE");
    for (const valid of [self, descendant]) {
      expect(codesOf(valid)).not.toContain("E-STOP-CONTEXT-ARTIFACT-UNKNOWN");
      expect(codesOf(valid)).not.toContain(
        "E-STOP-CONTEXT-ARTIFACT-NOT-VISIBLE",
      );
    }
  });

  test("W-STOP-WHEN-TEMPLATE-BRACES — parses, but can never match", () => {
    const mk = (template: string) =>
      withSteps([
        {
          type: "repeat",
          id: "r",
          maxIterations: 2,
          onMaxIterations: "abort",
          stopWhen: `{{${template}}} contains DONE`,
          steps: [step("s")],
        },
      ]);
    expect(codesOf(mk("a{b"))).toContain("W-STOP-WHEN-TEMPLATE-BRACES");
    // A brace-free template is clean; `s` is a producing step inside the body,
    // which a repeat's stop context may reference.
    expect(codesOf(mk("s.output"))).not.toContain(
      "W-STOP-WHEN-TEMPLATE-BRACES",
    );
  });

  test("W-ABORT-BRANCH-STRANDS-DOWNSTREAM catches the measured stranded-verify defect", () => {
    expect(
      codesOf(
        withSteps([
          {
            type: "parallel",
            id: "p",
            joinPolicy: "allSettled",
            branches: [
              {
                type: "repeat",
                id: "r",
                maxIterations: 2,
                onMaxIterations: "abort",
                stopCondition: { containsText: "done" },
                steps: [step("s")],
              },
            ],
          },
          step("verify"),
        ]),
      ),
    ).toContain("W-ABORT-BRANCH-STRANDS-DOWNSTREAM");
  });

  test("strict mode promotes policy lints to failures", () => {
    const w = withSteps([
      { type: "parallel", id: "p", joinPolicy: "all", branches: [step("a")] },
    ]);
    expect(validate(w).ok).toBe(true);
    expect(validate(w, { strict: true }).ok).toBe(false);
  });
});
