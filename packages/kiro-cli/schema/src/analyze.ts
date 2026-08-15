/**
 * Whole-tree analysis — the TypeScript twin of
 * packages/kiro-cli/lib/workflow/analyze.nix.
 *
 * For graph shapes both ports can represent, they intentionally share
 * diagnostic codes, the `basis` taxonomy, and depth-first walk order. The
 * sibling suites exercise those contracts independently; there is currently no
 * cross-language comparison runner. TypeScript additionally diagnoses
 * malformed assembled `stopWhen` syntax (`E-STOP-WHEN-SYNTAX`) that the
 * authored Nix sum type makes unrepresentable, so literal whole-code-set
 * equality is neither claimed nor possible.
 *
 * `basis` (adopted from fixtures/kiro-primitives/workflows/contract.jq):
 *   engine      the engine performs an equivalent check and will refuse
 *   policy      the engine ACCEPTS this; the rule exists because acceptance
 *               is silent and the consequence expensive
 *
 * Match on `code`, never on `message`.
 */
import { MAX_NESTING_DEPTH, MAX_STEP_NODES } from "./limits.js";
import type { Workflow, WorkflowNode } from "./schema.js";

export type Basis = "engine" | "policy";
export type Severity = "error" | "warning";

export interface Diagnostic {
  readonly code: string;
  readonly basis: Basis;
  readonly severity: Severity;
  readonly where: string;
  readonly message: string;
}

type Segment = {
  readonly kind: "ordered" | "concurrent";
  readonly index: number;
};

interface Entry {
  readonly node: WorkflowNode;
  readonly id: string;
  readonly lineage: ReadonlyArray<Segment>;
  readonly siblings: ReadonlyArray<WorkflowNode>;
  readonly siblingIndex: number;
}

const childrenOf = (
  n: WorkflowNode,
): { kids: ReadonlyArray<WorkflowNode>; kind: Segment["kind"] } =>
  n.type === "sequence" || n.type === "repeat"
    ? { kids: n.steps, kind: "ordered" }
    : n.type === "parallel"
      ? { kids: n.branches, kind: "concurrent" }
      : { kids: [], kind: "ordered" };

/**
 * Depth-first flatten with an explicit stack rather than recursion, matching
 * the shape of the Nix walker and of the compile-time walkers in
 * ./type-level.ts. A top-level node has `lineage.length === 1`, which is what
 * the engine's depth cap compares against.
 */
export const flatten = (
  steps: ReadonlyArray<WorkflowNode>,
): ReadonlyArray<Entry> => {
  const out: Entry[] = [];
  const stack: Array<{
    nodes: ReadonlyArray<WorkflowNode>;
    parent: ReadonlyArray<Segment>;
    kind: Segment["kind"];
  }> = [{ nodes: steps, parent: [], kind: "ordered" }];

  while (stack.length > 0) {
    const frame = stack.pop()!;
    // Reverse so that popping yields left-to-right order.
    for (let i = frame.nodes.length - 1; i >= 0; i -= 1) {
      const node = frame.nodes[i]!;
      const lineage = [...frame.parent, { kind: frame.kind, index: i }];
      out.push({
        node,
        id: node.id,
        lineage,
        siblings: frame.nodes,
        siblingIndex: i,
      });
      const { kids, kind } = childrenOf(node);
      if (kids.length > 0) stack.push({ nodes: kids, parent: lineage, kind });
    }
  }
  // The stack order above emits parents before children but siblings in
  // reverse; sort by lineage to restore document order.
  return out.sort((a, b) => compareLineage(a.lineage, b.lineage));
};

const compareLineage = (
  a: ReadonlyArray<Segment>,
  b: ReadonlyArray<Segment>,
): number => {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    if (a[i]!.index !== b[i]!.index) return a[i]!.index - b[i]!.index;
  }
  return a.length - b.length;
};

const isProducer = (n: WorkflowNode): boolean =>
  n.type === "watch" || (n.type === "step" && n.captureOutput !== false);

/**
 * The engine's happens-before. Divergence inside a `concurrent` container is
 * never an ordering, and an ancestor/descendant pair does not precede either.
 */
export const precedes = (
  a: ReadonlyArray<Segment>,
  b: ReadonlyArray<Segment>,
): boolean => {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    if (a[i]!.index !== b[i]!.index) {
      if (a[i]!.kind === "concurrent") return false;
      return a[i]!.index < b[i]!.index;
    }
  }
  return false;
};

const isDescendantOf = (
  ancestor: ReadonlyArray<Segment>,
  candidate: ReadonlyArray<Segment>,
): boolean =>
  candidate.length > ancestor.length &&
  ancestor.every(
    (s, i) => candidate[i]!.index === s.index && candidate[i]!.kind === s.kind,
  );

/**
 * The engine's template grammar is one regex: `{{`, a run with no braces,
 * `}}`. No nesting, no filters, no escaping.
 */
const REFERENCE_PATTERN = /\{\{\s*([^{}]*?)\s*\}\}/g;

export const refsIn = (s: string): ReadonlyArray<string> =>
  [...s.matchAll(REFERENCE_PATTERN)]
    .map((m) => m[1]!)
    .filter((x) => x.length > 0);

export type Reference =
  | { readonly kind: "previous" }
  | { readonly kind: "output"; readonly target: string }
  | { readonly kind: "artifact"; readonly target: string }
  | { readonly kind: "bare"; readonly target: string };

/**
 * Ordered exactly as the engine's if-chain. `artifacts.` is tested BEFORE the
 * generic `.output` suffix, so `{{artifacts.foo.output}}` is the artifact
 * named "foo.output", not an output reference.
 */
export const classify = (expr: string): Reference => {
  if (expr === "previous.output") return { kind: "previous" };
  if (expr.startsWith("steps.") && expr.endsWith(".output")) {
    return {
      kind: "output",
      target: expr.slice("steps.".length, -".output".length),
    };
  }
  if (expr.startsWith("artifacts.")) {
    return { kind: "artifact", target: expr.slice("artifacts.".length) };
  }
  if (expr.endsWith(".output")) {
    return { kind: "output", target: expr.slice(0, -".output".length) };
  }
  return { kind: "bare", target: expr };
};

/**
 * `stopWhen` has exactly two recognized shapes and nothing else parses.
 * Returns the parsed form, or a reason string.
 */
export type StopWhen =
  | { readonly form: "watchTerminal"; readonly watchId: string }
  | {
      readonly form: "contains";
      readonly template: string;
      readonly text: string;
    };

export const parseStopWhen = (input: string): StopWhen | string => {
  if (input.startsWith("{{")) {
    const close = input.indexOf("}}");
    if (close === -1) return "the '{{' template is never closed with '}}'";
    const template = input.slice(2, close);
    const rest = input.slice(close + 2);
    if (!rest.startsWith(" contains ")) {
      return "expected ' contains ' (exactly one space each side) after the template";
    }
    const text = rest.slice(" contains ".length);
    if (text.length === 0) return "the text after ' contains ' is empty";
    return { form: "contains", template, text };
  }
  if (input.includes(" contains ")) {
    return "the left side of ' contains ' must be a '{{...}}' template at the very start";
  }
  if (input.includes("{{") || input.includes("}}")) {
    return "a '{{...}}' template is only allowed at the very start";
  }
  if (!input.endsWith(".terminal")) {
    return "expected '<watchId>.terminal' or '{{expr}} contains <text>'";
  }
  const watchId = input.slice(0, -".terminal".length);
  if (watchId.length === 0 || watchId.includes(".") || /\s/.test(watchId)) {
    return "the watch id before '.terminal' must be one segment with no '.' and no whitespace";
  }
  return { form: "watchTerminal", watchId };
};

// ── The analysis ────────────────────────────────────────────────────────────

export interface Analysis {
  readonly diagnostics: ReadonlyArray<Diagnostic>;
  readonly errors: ReadonlyArray<Diagnostic>;
  readonly warnings: ReadonlyArray<Diagnostic>;
  readonly stepCount: number;
  readonly maxDepth: number;
}

export const analyze = (workflow: Workflow): Analysis => {
  const entries = flatten(workflow.steps);
  const byId = new Map(entries.map((e) => [e.id, e]));
  // The engine overwrites nodeById/lineageById on every occurrence, so the
  // Map deliberately keeps the LAST node carrying an id. Producer status is
  // independent: its monotone set keeps an id if ANY occurrence produces.
  const producerIds = new Set(
    entries.filter((e) => isProducer(e.node)).map((e) => e.id),
  );
  const stepEntries = entries.filter((e) => e.node.type === "step");
  const watchIds = new Set(
    entries.filter((e) => e.node.type === "watch").map((e) => e.id),
  );
  const declaredInputs = new Set(Object.keys(workflow.inputs ?? {}));

  const artifactProducers = new Map<string, Entry[]>();
  for (const e of stepEntries) {
    if (e.node.type !== "step" || e.node.artifacts === undefined) continue;
    for (const name of Object.keys(e.node.artifacts)) {
      const list = artifactProducers.get(name) ?? [];
      list.push(e);
      artifactProducers.set(name, list);
    }
  }

  const d: Diagnostic[] = [];
  const err = (code: string, where: string, message: string) =>
    d.push({ code, basis: "engine", severity: "error", where, message });
  const pol = (code: string, where: string, message: string) =>
    d.push({ code, basis: "policy", severity: "warning", where, message });

  // ── counts, ids, depth ────────────────────────────────────────────────
  const stepCount = stepEntries.length;
  if (stepCount > MAX_STEP_NODES) {
    err(
      "E-STEP-NODES-MAX",
      "workflow",
      `workflow has ${stepCount} step nodes, exceeding the maximum of ${MAX_STEP_NODES}; only 'step' nodes count, wrappers are free`,
    );
  }

  for (const e of entries) {
    if (e.lineage.length > MAX_NESTING_DEPTH) {
      err(
        "E-NESTING-DEPTH",
        e.id,
        `node sits at nesting depth ${e.lineage.length}, exceeding the maximum of ${MAX_NESTING_DEPTH}`,
      );
    }
  }

  const seen = new Set<string>();
  const reported = new Set<string>();
  for (const e of entries) {
    if (seen.has(e.id) && !reported.has(e.id)) {
      reported.add(e.id);
      err(
        "E-NODE-DUPLICATE-ID",
        "workflow",
        `duplicate node id '${e.id}'; ids must be unique across the WHOLE tree, not just among siblings`,
      );
    }
    seen.add(e.id);
  }

  // ── the one node-orientation rule ─────────────────────────────────────
  for (const e of entries) {
    if (
      e.node.type === "step" &&
      e.node.completion !== undefined &&
      e.lineage.some((s) => s.kind === "concurrent")
    ) {
      err(
        "E-INTERACTIVE-STEP-IN-PARALLEL",
        e.id,
        `step '${e.id}' declares \`completion\` beneath a \`parallel\`; an interactive step cannot be resumed while sibling branches keep the run loop busy`,
      );
    }
  }

  // ── stopWhen grammar + watch resolution ───────────────────────────────
  for (const e of entries) {
    if (e.node.type !== "repeat" || e.node.stopWhen === undefined) continue;
    const parsed = parseStopWhen(e.node.stopWhen);
    if (typeof parsed === "string") {
      err(
        "E-STOP-WHEN-SYNTAX",
        e.id,
        `repeat '${e.id}' has an invalid stopWhen='${e.node.stopWhen}': ${parsed}`,
      );
      continue;
    }
    if (parsed.form === "contains" && parsed.template.trim().length === 0) {
      pol(
        "W-STOP-WHEN-LITERAL-TEMPLATE",
        e.id,
        `repeat '${e.id}' has an empty or whitespace-only stopWhen template; the engine resolves it as literal {{}} text, so the condition can never match`,
      );
    } else if (
      parsed.form === "contains" &&
      (parsed.template.includes("{") || parsed.template.includes("}"))
    ) {
      // The engine's reference grammar is `[^{}]`, so a braced expression can
      // never match it — but `parseStopWhen` slices on the first `}}` rather
      // than using that regex, so the stopWhen still PARSES. The expression
      // then classifies as a BARE reference, which is never an error and
      // resolves to literal text, so the condition compares that literal
      // against the needle forever.
      //
      // The Nix port refuses this outright, because its AUTHORED shape takes
      // the expression as its own field and can reject it before the string
      // is ever built. Here the input is the already-assembled wire string
      // from a file the engine will happily run, so it is a policy diagnostic
      // rather than a decode failure. Same defect, different direction.
      pol(
        "W-STOP-WHEN-TEMPLATE-BRACES",
        e.id,
        `repeat '${e.id}' has a stopWhen template '{{${parsed.template}}}' containing a brace; the engine's reference grammar excludes braces, so it resolves as literal text and the condition can never match`,
      );
    }
    if (parsed.form === "watchTerminal" && !watchIds.has(parsed.watchId)) {
      err(
        "E-STOP-WHEN-WATCH-ID",
        e.id,
        `repeat '${e.id}' stops on watch id '${parsed.watchId}', which names no \`watch\` node in this workflow`,
      );
    }
  }

  // ── template references in prompts and artifact values ────────────────
  for (const e of stepEntries) {
    if (e.node.type !== "step") continue;
    const surfaces = [e.node.prompt, ...Object.values(e.node.artifacts ?? {})];
    const exprs = [...new Set(surfaces.flatMap(refsIn))];
    for (const expr of exprs) {
      const c = classify(expr);
      if (c.kind === "previous") {
        const parentKind = e.lineage[e.lineage.length - 1]!.kind;
        if (parentKind === "concurrent") {
          err(
            "E-TEMPLATE-PREVIOUS-IN-PARALLEL",
            e.id,
            `step '${e.id}' uses {{previous.output}} inside a parallel branch, where there is no guaranteed prior sibling`,
          );
        } else if (!e.siblings.slice(0, e.siblingIndex).some(isProducer)) {
          err(
            "E-TEMPLATE-PREVIOUS-NO-PRODUCER",
            e.id,
            `step '${e.id}' uses {{previous.output}} but no earlier sibling produces output`,
          );
        }
      } else if (c.kind === "output") {
        const t = byId.get(c.target);
        if (t === undefined) {
          err(
            "E-TEMPLATE-REF-UNKNOWN",
            e.id,
            `step '${e.id}' references {{${expr}}}, but no node has id '${c.target}'`,
          );
        } else if (!producerIds.has(c.target)) {
          err(
            "E-TEMPLATE-REF-NOT-PRODUCER",
            e.id,
            `step '${e.id}' references {{${expr}}}, but '${c.target}' produces no output`,
          );
        } else if (!precedes(t.lineage, e.lineage)) {
          err(
            "E-TEMPLATE-REF-NOT-PRECEDING",
            e.id,
            `step '${e.id}' references {{${expr}}}, but '${c.target}' does not run strictly before it — a later sibling, an ancestor/descendant, or a different parallel branch`,
          );
        }
      } else if (c.kind === "artifact") {
        const declarers = artifactProducers.get(c.target);
        if (declarers === undefined) {
          err(
            "E-ARTIFACT-REF-UNKNOWN",
            e.id,
            `step '${e.id}' references {{${expr}}}, but no step declares artifact '${c.target}'`,
          );
        } else if (!declarers.some((p) => precedes(p.lineage, e.lineage))) {
          err(
            "E-ARTIFACT-REF-NOT-PRECEDING",
            e.id,
            `step '${e.id}' references {{${expr}}}, but no step declaring artifact '${c.target}' runs strictly before it`,
          );
        }
      } else if (!declaredInputs.has(c.target)) {
        pol(
          "W-UNDECLARED-INPUT-REF",
          e.id,
          `step '${e.id}' references {{${expr}}}, which is not a declared input; it stays LITERAL in the prompt at runtime rather than erroring`,
        );
      }
    }
  }

  // ── stop-context references (relaxed rule set) ────────────────────────
  for (const e of entries) {
    const templates: string[] = [];
    let includeDescendants = false;
    if (e.node.type === "step" && e.node.completion?.fileCheck !== undefined) {
      templates.push(e.node.completion.fileCheck.path);
    } else if (e.node.type === "repeat") {
      includeDescendants = true;
      if (e.node.stopCondition?.fileCheck !== undefined) {
        templates.push(e.node.stopCondition.fileCheck.path);
      }
      if (e.node.stopWhen !== undefined) {
        const parsed = parseStopWhen(e.node.stopWhen);
        if (typeof parsed !== "string" && parsed.form === "contains") {
          templates.push(`{{${parsed.template}}}`);
        }
      }
    }
    for (const expr of [...new Set(templates.flatMap(refsIn))]) {
      const c = classify(expr);
      const visible = (target: Entry): boolean =>
        target.id === e.id ||
        precedes(target.lineage, e.lineage) ||
        (includeDescendants && isDescendantOf(e.lineage, target.lineage));
      if (c.kind === "previous") {
        err(
          "E-STOP-CONTEXT-PREVIOUS",
          e.id,
          `'${e.id}' uses {{previous.output}} in a stop condition, which is never legal there`,
        );
      } else if (c.kind === "output") {
        const t = byId.get(c.target);
        if (t === undefined) {
          err(
            "E-STOP-CONTEXT-REF-UNKNOWN",
            e.id,
            `'${e.id}' stop condition references {{${expr}}}, but no node has id '${c.target}'`,
          );
        } else if (!producerIds.has(c.target)) {
          err(
            "E-STOP-CONTEXT-REF-NOT-PRODUCER",
            e.id,
            `'${e.id}' stop condition references {{${expr}}}, which produces no output`,
          );
        } else if (!visible(t)) {
          err(
            "E-STOP-CONTEXT-REF-NOT-VISIBLE",
            e.id,
            `'${e.id}' stop condition references {{${expr}}}, which is neither itself, nor earlier, nor inside its own body`,
          );
        }
      } else if (c.kind === "artifact") {
        const declarers = artifactProducers.get(c.target);
        if (declarers === undefined) {
          err(
            "E-STOP-CONTEXT-ARTIFACT-UNKNOWN",
            e.id,
            `'${e.id}' stop condition references {{${expr}}}, but no step declares artifact '${c.target}'`,
          );
        } else if (!declarers.some(visible)) {
          err(
            "E-STOP-CONTEXT-ARTIFACT-NOT-VISIBLE",
            e.id,
            `'${e.id}' stop condition references {{${expr}}}, but no declaring step is itself, earlier, or inside its own repeat body`,
          );
        }
      } else if (!declaredInputs.has(c.target)) {
        pol(
          "W-UNDECLARED-INPUT-REF",
          e.id,
          `'${e.id}' stop condition references {{${expr}}}, which is not a declared input; it stays LITERAL at runtime and the condition can never match`,
        );
      }
    }
  }

  // ── policy lints ──────────────────────────────────────────────────────
  for (const e of entries) {
    const n = e.node;
    if (n.type === "repeat") {
      if (n.stopCondition === undefined && n.stopWhen === undefined) {
        pol(
          "W-REPEAT-NO-STOP-FORM",
          e.id,
          `repeat '${e.id}' defines neither stop form. This IS legal — the vendor's own \`autoresearch\` recipe ships this way — but the loop then runs to maxIterations with nothing reporting why`,
        );
      }
      if (n.onMaxIterations === "continue") {
        pol(
          "W-ON-MAX-ITERATIONS-CONTINUE",
          e.id,
          `repeat '${e.id}' uses onMaxIterations = "continue", which marks an EXHAUSTED loop *completed* — unfinished work scores as success`,
        );
      }
      if (n.onMaxIterations === "pause") {
        pol(
          "W-ON-MAX-ITERATIONS-PAUSE",
          e.id,
          `repeat '${e.id}' uses onMaxIterations = "pause"; resuming grants no further iterations, it re-pauses immediately, and a paused run cannot be retried`,
        );
      }
      if (n.steps.length === 0) {
        pol(
          "W-CONTAINER-EMPTY",
          e.id,
          `repeat '${e.id}' has no children and would loop doing nothing`,
        );
      }
    }
    if (n.type === "parallel") {
      if (n.joinPolicy === "any") {
        pol(
          "W-JOIN-POLICY-ANY",
          e.id,
          `parallel '${e.id}' uses joinPolicy = "any", which CANCELS its siblings on the first completion`,
        );
      }
      if (n.joinPolicy === "all") {
        pol(
          "W-JOIN-POLICY-ALL",
          e.id,
          `parallel '${e.id}' uses joinPolicy = "all", which aborts every sibling on the first branch FAILURE; "allSettled" structurally cannot cancel`,
        );
      }
      if (n.branches.length === 0) {
        pol(
          "W-CONTAINER-EMPTY",
          e.id,
          `parallel '${e.id}' has no branches and would join immediately`,
        );
      }
    }
    if (n.type === "sequence" && n.steps.length === 0) {
      pol(
        "W-CONTAINER-EMPTY",
        e.id,
        `sequence '${e.id}' has no children and would run nothing`,
      );
    }
    if (
      n.type === "step" &&
      n.completion?.completionSignal !== undefined &&
      (n.completion.containsText !== undefined ||
        n.completion.fileCheck !== undefined)
    ) {
      pol(
        "W-STOP-CONDITION-SIGNAL-FIRST",
        e.id,
        `step '${e.id}' sets completionSignal alongside another stop form; the signal is tested first and may bypass the others when it matches`,
      );
    }

    const fc =
      n.type === "step"
        ? n.completion?.fileCheck
        : n.type === "repeat"
          ? n.stopCondition?.fileCheck
          : undefined;
    if (fc !== undefined && Array.isArray(fc.value)) {
      pol(
        "W-FILE-CHECK-VALUE-ARRAY",
        e.id,
        `'${e.id}' uses an ARRAY fileCheck.value, which the engine reads as "any of these candidates" (value.some(deepEqual)), not as "match this array"`,
      );
    }
    if (
      fc !== undefined &&
      (fc.path.includes("{{") ||
        fc.path.startsWith("/") ||
        fc.path.startsWith("~") ||
        fc.path.split("/").includes(".."))
    ) {
      pol(
        "W-FILE-CHECK-PATH-UNSAFE",
        e.id,
        `'${e.id}' fileCheck.path '${fc.path}' is templated, absolute, tilde-prefixed or escaping. A path the containment check reaches fails the run at LAUNCH; one that SKIPS it evaluates false forever with no error. Keep it a plain relative path.`,
      );
    }
  }

  // Measured, not theorized: a parallel is marked failed if ANY branch
  // aborted — under `all` AND `allSettled` alike — and the enclosing
  // container bubbles that and returns. So a repeat with
  // onMaxIterations="abort" inside a parallel makes every LATER sibling of
  // that parallel unreachable in exactly the exhaustion case a verify step
  // exists to catch. This defect shipped in a real drain recipe.
  for (const e of entries) {
    if (e.node.type !== "parallel") continue;
    const hasAbortingRepeat = entries.some(
      (x) =>
        x.node.type === "repeat" &&
        x.node.onMaxIterations === "abort" &&
        isDescendantOf(e.lineage, x.lineage),
    );
    const last = e.lineage[e.lineage.length - 1]!;
    const parent = e.lineage.slice(0, -1);
    const hasLaterSibling = entries.some(
      (x) =>
        x.lineage.length === e.lineage.length &&
        compareLineage(x.lineage.slice(0, -1), parent) === 0 &&
        x.lineage[x.lineage.length - 1]!.index > last.index,
    );
    if (hasAbortingRepeat && hasLaterSibling) {
      pol(
        "W-ABORT-BRANCH-STRANDS-DOWNSTREAM",
        e.id,
        `parallel '${e.id}' contains a repeat with onMaxIterations = "abort" and has later siblings; an aborted branch fails the parallel under every joinPolicy, so those siblings never run in the exhaustion case`,
      );
    }
  }

  return {
    diagnostics: d,
    errors: d.filter((x) => x.severity === "error"),
    warnings: d.filter((x) => x.severity === "warning"),
    stepCount,
    maxDepth: entries.reduce((m, e) => Math.max(m, e.lineage.length), 0),
  };
};
