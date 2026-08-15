/**
 * Conformance tests.
 *
 * The load-bearing suite is "vendor recipes" — the seven definitions inlined
 * in the engine bundle. The engine shape-parses them at module init but does
 * not run its structural analyzer until launch. They are the highest-fidelity
 * corpus available, and accepting all of them checks every shape the vendor
 * ships.
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

describe("vendor recipes (the engine's shipped corpus)", () => {
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

  test("accepts an empty optional description", () => {
    expect(decodes({ ...minimal, description: "" })).toBe(true);
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

  /**
   * Deliberately stricter than the engine, which filters empty segments out
   * and resolves all of these. See the `JsonPath` comment in src/schema.ts for
   * why an authoring tool refuses them anyway. `state.drained` above is the
   * positive control for this table.
   */
  test.each([
    ["leading", ".drained"],
    ["trailing", "drained."],
    ["internal", "state..drained"],
    ["all-empty (empty string)", ""],
    ["all-empty (dots only)", "..."],
  ])("rejects an empty %s jsonPath segment", (_label, jsonPath) => {
    const fileCheck = { path: "a.json", jsonPath, value: true };
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

  /**
   * The message is the product surface here: this port is where generated
   * input lands, so a rejection has to say what was expected, not only that
   * something was wrong.
   */
  test("names the expected jsonPath form when a segment is empty", () => {
    const result = validate(
      withSteps([
        {
          type: "step",
          id: "a",
          agent: "ag",
          prompt: "p",
          completion: {
            fileCheck: {
              path: "a.json",
              jsonPath: "state..drained",
              value: true,
            },
          },
        },
      ]),
    );
    expect(result.ok).toBe(false);
    if (result.ok || result.reason !== "decode") {
      throw new Error("expected a decode failure");
    }
    expect(result.error).toContain("empty '.'-separated segment");
    expect(result.error).toContain('"state.done"');
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
    [
      "crux-cr with crRef and an empty crId — the empty id falls through to crRef",
      {
        type: "watch",
        id: "w",
        handler: "crux-cr",
        config: { crId: "", crRef: "cr.json" },
      },
      true,
    ],
    [
      "crux-cr with an empty crId and NO crRef — resolveCrId can only throw",
      { type: "watch", id: "w", handler: "crux-cr", config: { crId: "" } },
      false,
    ],
    [
      "crux-cr with neither crRef nor crId",
      { type: "watch", id: "w", handler: "crux-cr", config: {} },
      false,
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
    [
      "{{{{a.output}}}} contains X",
      "doubled braces — the wire spelling authored into a field that wraps it",
    ],
    ["wait\u00a0for\u00a0it.terminal", "Unicode whitespace in watch id"],
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

/**
 * A stop-context `fileCheck`. `path` is the only field `analyze` reads
 * templates from, so it is the parameter; `jsonPath` and `value` are fixed at
 * a shape the schema accepts.
 */
const fileCheck = (path: string, value: unknown = true) => ({
  path,
  jsonPath: "done",
  value,
});

const repeatNode = (id: string, extra: Record<string, unknown> = {}) => ({
  type: "repeat",
  id,
  maxIterations: 2,
  onMaxIterations: "abort",
  steps: [step(`${id}-body`)],
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

  test("duplicate diagnostics follow second-occurrence order", () => {
    const messages = diagnosticsOf(
      withSteps([step("a"), step("b"), step("b"), step("a")]),
    )
      .filter((diagnostic) => diagnostic.code === "E-NODE-DUPLICATE-ID")
      .map((diagnostic) => diagnostic.message);

    expect(messages).toEqual([
      "duplicate node id 'b'; ids must be unique across the WHOLE tree, not just among siblings",
      "duplicate node id 'a'; ids must be unique across the WHOLE tree, not just among siblings",
    ]);
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

  test("mixed stop-condition message reflects short-circuit OR semantics", () => {
    const messages = diagnosticsOf(
      withSteps([
        step("a", {
          completion: {
            completionSignal: "success",
            containsText: "DONE",
          },
        }),
      ]),
    )
      .filter(
        (diagnostic) => diagnostic.code === "W-STOP-CONDITION-SIGNAL-FIRST",
      )
      .map((diagnostic) => diagnostic.message);

    expect(messages).toEqual([
      "step 'a' sets completionSignal alongside another stop form; the signal is tested first and may bypass the others when it matches",
    ]);
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

  test("braced stopWhen templates — one brace warns, two are an engine error", () => {
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
    // A DOUBLE brace is a different rule, not a louder version of this one.
    // `{{{{p.output}}}} contains DONE` is what the Nix renderer emits when the
    // authored template already carries the wire spelling, and the engine's
    // parser refuses it: slicing on the first `}}` leaves `}} contains DONE`,
    // which fails the ` contains ` infix. So it is an engine-basis ERROR here
    // rather than the policy warning above.
    expect(
      diagnosticsOf(mk("{{p.output}}")).map((d) => [
        d.code,
        d.severity,
        d.basis,
      ]),
    ).toEqual([["E-STOP-WHEN-SYNTAX", "error", "engine"]]);
  });

  test("empty and whitespace stopWhen templates stay literal forever", () => {
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
    for (const template of ["", " ", "\u00a0"]) {
      expect(codesOf(mk(template))).toContain("W-STOP-WHEN-LITERAL-TEMPLATE");
    }
  });

  test("bare stopWhen templates must name a declared input", () => {
    const mk = (declared: boolean) => ({
      name: "w",
      inputs: declared ? { target: "string" } : {},
      steps: [
        {
          type: "repeat",
          id: "r",
          maxIterations: 2,
          onMaxIterations: "abort",
          stopWhen: "{{target}} contains DONE",
          steps: [step("s")],
        },
      ],
    });
    expect(codesOf(mk(false))).toContain("W-UNDECLARED-INPUT-REF");
    expect(codesOf(mk(true))).not.toContain("W-UNDECLARED-INPUT-REF");
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

/**
 * Positive-emission coverage for the codes the suite above never named.
 *
 * Every case here provokes exactly one named code, and where the rule has a
 * boundary the SILENT control sits next to it — a positive fixture on its own
 * cannot distinguish "the rule fires" from "the rule always fires", which is
 * how a rule can be deleted outright with the suite still green.
 */
describe("analyze: {{previous.output}} rules", () => {
  test("E-TEMPLATE-PREVIOUS-IN-PARALLEL — a branch has no guaranteed prior sibling", () => {
    const inBranch = withSteps([
      {
        type: "parallel",
        id: "p",
        joinPolicy: "allSettled",
        branches: [step("a", { prompt: "{{previous.output}}" })],
      },
    ]);
    expect(codesOf(inBranch)).toContain("E-TEMPLATE-PREVIOUS-IN-PARALLEL");
    // The two `previous` arms are exclusive: a branch is reported as a branch,
    // not additionally as a missing producer.
    expect(codesOf(inBranch)).not.toContain("E-TEMPLATE-PREVIOUS-NO-PRODUCER");
    // Silent control — the same reference one level out, after a producer.
    expect(
      codesOf(
        withSteps([step("q"), step("a", { prompt: "{{previous.output}}" })]),
      ),
    ).not.toContain("E-TEMPLATE-PREVIOUS-IN-PARALLEL");
  });

  test("E-TEMPLATE-PREVIOUS-NO-PRODUCER — an earlier sibling must also PRODUCE", () => {
    const noSibling = withSteps([step("a", { prompt: "{{previous.output}}" })]);
    const nonProducer = withSteps([
      step("q", { captureOutput: false }),
      step("a", { prompt: "{{previous.output}}" }),
    ]);
    const producer = withSteps([
      step("q"),
      step("a", { prompt: "{{previous.output}}" }),
    ]);

    expect(codesOf(noSibling)).toContain("E-TEMPLATE-PREVIOUS-NO-PRODUCER");
    expect(codesOf(nonProducer)).toContain("E-TEMPLATE-PREVIOUS-NO-PRODUCER");
    expect(codesOf(producer)).not.toContain("E-TEMPLATE-PREVIOUS-NO-PRODUCER");
  });
});

describe("analyze: stop-context reference rules", () => {
  const completionRef = (path: string) => ({
    completion: { fileCheck: fileCheck(path) },
  });

  test("E-STOP-CONTEXT-PREVIOUS fires even where a producer really does precede", () => {
    // This is the case the analyzer's own comment calls "never legal there",
    // so a preceding producer must NOT rescue it.
    expect(
      codesOf(
        withSteps([
          step("q"),
          step("a", completionRef("{{previous.output}}/report.json")),
        ]),
      ),
    ).toContain("E-STOP-CONTEXT-PREVIOUS");
    // Silent control — same shape, a named producer instead. The rule is about
    // `previous`, not about stop contexts carrying references at all.
    expect(
      codesOf(
        withSteps([
          step("q"),
          step("a", completionRef("{{q.output}}/report.json")),
        ]),
      ),
    ).not.toContain("E-STOP-CONTEXT-PREVIOUS");
  });

  test("E-STOP-CONTEXT-PREVIOUS also covers the assembled stopWhen template", () => {
    expect(
      codesOf(
        withSteps([
          repeatNode("r", { stopWhen: "{{previous.output}} contains DONE" }),
        ]),
      ),
    ).toContain("E-STOP-CONTEXT-PREVIOUS");
  });

  test("E-STOP-CONTEXT-REF-UNKNOWN names no node at all", () => {
    expect(
      codesOf(withSteps([step("a", completionRef("{{ghost.output}}"))])),
    ).toContain("E-STOP-CONTEXT-REF-UNKNOWN");
  });

  test("E-STOP-CONTEXT-REF-NOT-PRODUCER — the node exists but captures nothing", () => {
    expect(
      codesOf(
        withSteps([
          step("q", { captureOutput: false }),
          step("a", completionRef("{{q.output}}")),
        ]),
      ),
    ).toContain("E-STOP-CONTEXT-REF-NOT-PRODUCER");
  });

  test("E-STOP-CONTEXT-REF-NOT-VISIBLE — later sibling only; self and own body are visible", () => {
    const later = withSteps([
      step("a", completionRef("{{b.output}}")),
      step("b"),
    ]);
    const earlier = withSteps([
      step("b"),
      step("a", completionRef("{{b.output}}")),
    ]);
    const itself = withSteps([step("a", completionRef("{{a.output}}"))]);
    const ownBody = withSteps([
      repeatNode("r", {
        stopCondition: { fileCheck: fileCheck("{{child.output}}") },
        steps: [step("child")],
      }),
    ]);

    expect(codesOf(later)).toContain("E-STOP-CONTEXT-REF-NOT-VISIBLE");
    for (const visible of [earlier, itself, ownBody]) {
      expect(codesOf(visible)).not.toContain("E-STOP-CONTEXT-REF-NOT-VISIBLE");
    }
  });
});

describe("analyze: policy lints", () => {
  /**
   * Three separate arms emit this one code, so all three are exercised — a
   * fixture for one of them leaves the other two deletable.
   */
  const container = (kind: string, children: ReadonlyArray<unknown>) =>
    kind === "repeat"
      ? repeatNode("c", {
          stopCondition: { containsText: "x" },
          steps: children,
        })
      : kind === "sequence"
        ? { type: "sequence", id: "c", steps: children }
        : {
            type: "parallel",
            id: "c",
            joinPolicy: "allSettled",
            branches: children,
          };

  test.each([["repeat"], ["sequence"], ["parallel"]])(
    "W-CONTAINER-EMPTY on an empty %s",
    (kind) => {
      expect(codesOf(withSteps([container(kind, [])]))).toContain(
        "W-CONTAINER-EMPTY",
      );
      expect(codesOf(withSteps([container(kind, [step("a")])]))).not.toContain(
        "W-CONTAINER-EMPTY",
      );
    },
  );

  test("W-REPEAT-NO-STOP-FORM — legal, but nothing reports why the loop ended", () => {
    expect(codesOf(withSteps([repeatNode("r")]))).toContain(
      "W-REPEAT-NO-STOP-FORM",
    );
    expect(
      codesOf(
        withSteps([
          repeatNode("r", { stopCondition: { containsText: "DONE" } }),
        ]),
      ),
    ).not.toContain("W-REPEAT-NO-STOP-FORM");
    expect(
      codesOf(
        withSteps([
          {
            type: "watch",
            id: "w",
            handler: "github-pr",
            config: { prRef: "pr.json" },
          },
          repeatNode("r", { stopWhen: "w.terminal" }),
        ]),
      ),
    ).not.toContain("W-REPEAT-NO-STOP-FORM");
  });

  test("onMaxIterations lints: continue and pause warn, abort is silent", () => {
    const codesFor = (onMaxIterations: string) =>
      codesOf(
        withSteps([
          repeatNode("r", {
            onMaxIterations,
            stopCondition: { containsText: "DONE" },
          }),
        ]),
      ).filter((code) => code.startsWith("W-ON-MAX-ITERATIONS-"));

    expect(codesFor("continue")).toEqual(["W-ON-MAX-ITERATIONS-CONTINUE"]);
    expect(codesFor("pause")).toEqual(["W-ON-MAX-ITERATIONS-PAUSE"]);
    expect(codesFor("abort")).toEqual([]);
  });

  test("joinPolicy lints: any and all warn, allSettled is silent", () => {
    const codesFor = (joinPolicy: string) =>
      codesOf(
        withSteps([
          { type: "parallel", id: "p", joinPolicy, branches: [step("a")] },
        ]),
      ).filter((code) => code.startsWith("W-JOIN-POLICY-"));

    expect(codesFor("any")).toEqual(["W-JOIN-POLICY-ANY"]);
    expect(codesFor("all")).toEqual(["W-JOIN-POLICY-ALL"]);
    expect(codesFor("allSettled")).toEqual([]);
  });

  test("W-FILE-CHECK-VALUE-ARRAY on both fileCheck sites; a scalar is silent", () => {
    const onStep = (value: unknown) =>
      withSteps([
        step("a", { completion: { fileCheck: fileCheck("r.json", value) } }),
      ]);
    const onRepeat = (value: unknown) =>
      withSteps([
        repeatNode("r", {
          stopCondition: { fileCheck: fileCheck("r.json", value) },
        }),
      ]);

    expect(codesOf(onStep(["a", "b"]))).toContain("W-FILE-CHECK-VALUE-ARRAY");
    expect(codesOf(onRepeat(["a", "b"]))).toContain("W-FILE-CHECK-VALUE-ARRAY");
    expect(codesOf(onStep(true))).not.toContain("W-FILE-CHECK-VALUE-ARRAY");
    expect(codesOf(onRepeat(true))).not.toContain("W-FILE-CHECK-VALUE-ARRAY");
  });

  test.each([
    ["a templated", "{{setup.output}}/report.json"],
    ["an absolute", "/srv/report.json"],
    ["a tilde-prefixed", "~/report.json"],
    ["an escaping", "../report.json"],
  ])("W-FILE-CHECK-PATH-UNSAFE on %s path", (_label, path) => {
    expect(
      codesOf(
        withSteps([step("a", { completion: { fileCheck: fileCheck(path) } })]),
      ),
    ).toContain("W-FILE-CHECK-PATH-UNSAFE");
  });

  test.each([
    ["a plain relative path", "state/report.json"],
    ["'..' inside a segment rather than as one", "state/a..b.json"],
  ])("W-FILE-CHECK-PATH-UNSAFE is silent on %s", (_label, path) => {
    expect(
      codesOf(
        withSteps([step("a", { completion: { fileCheck: fileCheck(path) } })]),
      ),
    ).not.toContain("W-FILE-CHECK-PATH-UNSAFE");
  });
});
