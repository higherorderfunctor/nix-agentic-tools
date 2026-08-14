/**
 * Effect `Schema` for the Kiro workflow definition format.
 *
 * Unlike the Nix side, this schema is over the WIRE shape — it decodes a real
 * `.workflow.json`. Where the wire shape is loose, the looseness is recovered
 * with a discriminated union (`watch` splits on `handler`) or a filter, and
 * every such choice is annotated with what the engine actually does.
 *
 * Layering matches the Nix side deliberately, so the two stay comparable:
 *
 *   Schema (here)      what one node proves about itself
 *   analyze (here)     what only the whole tree proves + policy lints
 *   ./type-level.ts     the subset of the tree rules that fit at COMPILE time
 *
 * Ground truth is the shipped KAS bundle; the format is in no public doc.
 */
import { Schema } from "effect";
import {
  ENGINE,
  MAX_NESTING_DEPTH,
  MAX_REPEAT_ITERATIONS,
  MAX_STEP_NODES,
} from "./limits.js";

// ── Scalars ─────────────────────────────────────────────────────────────────

const NonEmptyString = Schema.String.pipe(
  Schema.filter((s) => s.length > 0 || "must not be empty"),
);

/**
 * `maxIterations`. The engine's `.int().positive().max(1000)` — 1000 is
 * inclusive-legal and the vendor's own `autoresearch` recipe sits exactly
 * there, so an exclusive bound would reject a shipped recipe.
 */
const MaxIterations = Schema.Int.pipe(
  Schema.positive(),
  Schema.lessThanOrEqualTo(MAX_REPEAT_ITERATIONS),
).annotations({ identifier: "MaxIterations" });

const PositiveNumber = Schema.Number.pipe(Schema.positive());

/**
 * `jsonPath` is NOT JSONPath: the engine does `split(".")` then a plain
 * property walk. `"$.drained"` therefore reads a property literally named
 * `$`, resolves undefined, and the loop never stops — silently, forever.
 *
 * Rejecting the JSONPath spellings is a POLICY choice (a property really
 * named `$` is legal JSON and the engine would read it), but it is the single
 * most expensive typo in this format.
 */
const JsonPath = NonEmptyString.pipe(
  Schema.filter(
    (s) =>
      (!s.startsWith("$") &&
        !s.includes("[") &&
        !s.includes("]") &&
        !s.includes("*") &&
        !s.split(".").some((seg) => seg === "")) ||
      `jsonPath ${JSON.stringify(s)} is not JSONPath — it is a '.'-separated property walk. Drop '$', brackets and wildcards.`,
  ),
).annotations({ identifier: "JsonPath" });

// ── Stop conditions ─────────────────────────────────────────────────────────

export const FileCheck = Schema.Struct({
  path: NonEmptyString,
  jsonPath: JsonPath,
  /** An ARRAY here means "any of these candidates" to the engine, not "match this array". */
  value: Schema.Unknown,
}).annotations({ identifier: "FileCheck" });

export const StopCondition = Schema.Struct({
  containsText: Schema.optional(NonEmptyString),
  fileCheck: Schema.optional(FileCheck),
  completionSignal: Schema.optional(
    Schema.Literal("success", "need_input", "error"),
  ),
})
  .pipe(
    Schema.filter(
      (c) =>
        c.containsText !== undefined ||
        c.fileCheck !== undefined ||
        c.completionSignal !== undefined ||
        "a stop condition requires at least one of containsText, fileCheck, completionSignal",
    ),
  )
  .annotations({ identifier: "StopCondition" });

// ── Nodes ───────────────────────────────────────────────────────────────────

export interface StepNode {
  readonly type: "step";
  readonly id: string;
  readonly agent: string;
  readonly prompt: string;
  readonly artifacts?: { readonly [k: string]: string };
  readonly captureOutput?: boolean;
  readonly completion?: Schema.Schema.Type<typeof StopCondition>;
  readonly modelId?: string;
  readonly effortLevel?: string;
  /** Removed legacy field. Declared so its presence is a loud parse error. */
  readonly input?: never;
}

export interface SequenceNode {
  readonly type: "sequence";
  readonly id: string;
  readonly steps: ReadonlyArray<WorkflowNode>;
}

export interface RepeatNode {
  readonly type: "repeat";
  readonly id: string;
  readonly steps: ReadonlyArray<WorkflowNode>;
  readonly maxIterations: number;
  readonly onMaxIterations: "abort" | "continue" | "pause";
  readonly stopCondition?: Schema.Schema.Type<typeof StopCondition>;
  readonly stopWhen?: string;
}

export interface ParallelNode {
  readonly type: "parallel";
  readonly id: string;
  readonly branches: ReadonlyArray<WorkflowNode>;
  readonly joinPolicy: "all" | "allSettled" | "any";
}

export interface GithubPrWatchNode {
  readonly type: "watch";
  readonly id: string;
  readonly handler: "github-pr";
  readonly config: {
    readonly prRef?: string;
    readonly url?: string;
    readonly includeOwnActivity?: boolean;
    readonly ignoreAuthors?: ReadonlyArray<string>;
    readonly pollIntervalSec?: number;
    readonly commandTimeoutSec?: number;
  };
  readonly idleTimeoutSec?: number;
}

export interface CruxCrWatchNode {
  readonly type: "watch";
  readonly id: string;
  readonly handler: "crux-cr";
  readonly config: {
    readonly crRef?: string;
    readonly crId?: string;
    readonly pollIntervalSec?: number;
    readonly commandTimeoutSec?: number;
  };
  readonly idleTimeoutSec?: number;
}

export type WatchNode = GithubPrWatchNode | CruxCrWatchNode;

export type WorkflowNode =
  | StepNode
  | SequenceNode
  | RepeatNode
  | ParallelNode
  | WatchNode;

/**
 * `pollIntervalSec` below the registry minimum is a hard config error, not a
 * clamp. Shared by both handlers via the engine's passthrough base schema.
 */
const PollIntervalSec = Schema.Number.pipe(
  Schema.greaterThanOrEqualTo(ENGINE.watch.minPollIntervalSec),
);

const WatchBase = {
  pollIntervalSec: Schema.optional(PollIntervalSec),
  commandTimeoutSec: Schema.optional(PositiveNumber),
};

const GithubPrConfig = Schema.Struct({
  ...WatchBase,
  prRef: Schema.optional(NonEmptyString),
  url: Schema.optional(NonEmptyString),
  includeOwnActivity: Schema.optional(Schema.Boolean),
  ignoreAuthors: Schema.optional(Schema.Array(NonEmptyString)),
}).pipe(
  Schema.filter(
    (c) =>
      c.prRef !== undefined ||
      c.url !== undefined ||
      "github-pr requires one of prRef, url",
  ),
);

const CruxCrConfig = Schema.Struct({
  ...WatchBase,
  crRef: Schema.optional(NonEmptyString),
  crId: Schema.optional(Schema.String.pipe(Schema.pattern(/^CR-\d+$/))),
}).pipe(
  Schema.filter(
    (c) =>
      c.crRef !== undefined ||
      c.crId !== undefined ||
      "crux-cr requires one of crRef, crId",
  ),
);

const StepNodeSchema: Schema.Schema<StepNode> = Schema.Struct({
  type: Schema.Literal("step"),
  id: Schema.String,
  agent: NonEmptyString,
  /**
   * REQUIRED. The engine tests only `=== undefined`, so an empty string
   * passes both its schema and its validator — matched here rather than
   * tightened, since rejecting what the engine accepts is its own bug.
   */
  prompt: Schema.String,
  artifacts: Schema.optional(
    Schema.Record({ key: Schema.String, value: NonEmptyString }),
  ),
  captureOutput: Schema.optional(Schema.Boolean),
  completion: Schema.optional(StopCondition),
  /**
   * Deliberately NOT literal unions. The model catalog is fetched from the
   * control plane at runtime and the compiled-in default is EMPTY, and the
   * legal effort set is per-model and server-supplied. A literal union here
   * would reject ids and levels the server accepts.
   */
  modelId: Schema.optional(NonEmptyString),
  effortLevel: Schema.optional(NonEmptyString),
  /**
   * The step-level `input` field was removed and the engine now rejects it
   * loudly with a migration message. `optional(Never)` reproduces that: the
   * key is unrepresentable in the type AND fails at decode.
   */
  input: Schema.optional(Schema.Never),
}) as unknown as Schema.Schema<StepNode>;

const SequenceNodeSchema: Schema.Schema<SequenceNode> = Schema.Struct({
  type: Schema.Literal("sequence"),
  id: Schema.String,
  steps: Schema.Array(
    Schema.suspend((): Schema.Schema<WorkflowNode> => WorkflowNodeSchema),
  ),
}) as unknown as Schema.Schema<SequenceNode>;

const RepeatNodeSchema: Schema.Schema<RepeatNode> = Schema.Struct({
  type: Schema.Literal("repeat"),
  id: Schema.String,
  steps: Schema.Array(
    Schema.suspend((): Schema.Schema<WorkflowNode> => WorkflowNodeSchema),
  ),
  maxIterations: MaxIterations,
  /** REQUIRED — the engine's Zod gives it no default. */
  onMaxIterations: Schema.Literal("abort", "continue", "pause"),
  stopCondition: Schema.optional(StopCondition),
  /** Free-form here; the grammar is enforced by `analyze`, as the engine does. */
  stopWhen: Schema.optional(NonEmptyString),
}).pipe(
  Schema.filter(
    (r) =>
      r.stopCondition === undefined ||
      r.stopWhen === undefined ||
      "a repeat must not define both stopCondition and stopWhen (defining NEITHER is legal)",
  ),
) as unknown as Schema.Schema<RepeatNode>;

const ParallelNodeSchema: Schema.Schema<ParallelNode> = Schema.Struct({
  type: Schema.Literal("parallel"),
  id: Schema.String,
  branches: Schema.Array(
    Schema.suspend((): Schema.Schema<WorkflowNode> => WorkflowNodeSchema),
  ),
  joinPolicy: Schema.Literal("all", "allSettled", "any"),
}) as unknown as Schema.Schema<ParallelNode>;

/**
 * The wire shape carries `handler: string` and `config: record(unknown)` as
 * two loose fields. Exactly two handlers ship, each with its own config
 * schema, so splitting into a union discriminated on `handler` recovers
 * per-handler field checking that the wire shape throws away.
 *
 * `config` is REQUIRED here though the engine's Zod marks it optional: both
 * shipped handlers refine "at least one of" over their config, so an absent
 * config fails the engine's separate `validateWatchConfigs` pass anyway.
 */
const WatchNodeSchema: Schema.Schema<WatchNode> = Schema.Union(
  Schema.Struct({
    type: Schema.Literal("watch"),
    id: Schema.String,
    handler: Schema.Literal("github-pr"),
    config: GithubPrConfig,
    idleTimeoutSec: Schema.optional(PositiveNumber),
  }),
  Schema.Struct({
    type: Schema.Literal("watch"),
    id: Schema.String,
    handler: Schema.Literal("crux-cr"),
    config: CruxCrConfig,
    idleTimeoutSec: Schema.optional(PositiveNumber),
  }),
) as unknown as Schema.Schema<WatchNode>;

export const WorkflowNodeSchema: Schema.Schema<WorkflowNode> = Schema.Union(
  StepNodeSchema,
  SequenceNodeSchema,
  RepeatNodeSchema,
  ParallelNodeSchema,
  WatchNodeSchema,
).annotations({ identifier: "WorkflowNode" });

// ── The workflow root ───────────────────────────────────────────────────────

export interface Workflow {
  readonly name: string;
  readonly description?: string;
  readonly inputs?: { readonly [k: string]: string };
  readonly steps: ReadonlyArray<WorkflowNode>;
  readonly modelId?: string;
  readonly effortLevel?: string;
}

export const WorkflowSchema: Schema.Schema<Workflow> = Schema.Struct({
  name: NonEmptyString,
  description: Schema.optional(NonEmptyString),
  /**
   * A DECLARATION map, name -> free-form type hint. The engine never merges
   * these in as defaults; they are only the allow-list for its
   * undeclared-reference warning. Values must be strings.
   */
  inputs: Schema.optional(
    Schema.Record({ key: Schema.String, value: Schema.String }),
  ),
  steps: Schema.Array(WorkflowNodeSchema),
  modelId: Schema.optional(NonEmptyString),
  effortLevel: Schema.optional(NonEmptyString),
  /**
   * `planRevision` is deliberately absent. The runner overwrites it with 0 at
   * creation, so an authored value is discarded — it is a runtime pairing
   * token between workflow-state.json and workflow-definition.json.
   *
   * The engine's Zod strips unknown keys rather than rejecting them, so a
   * definition carrying it still parses; it simply never round-trips.
   */
}).annotations({
  identifier: "Workflow",
}) as unknown as Schema.Schema<Workflow>;

export const decodeWorkflow = Schema.decodeUnknownEither(WorkflowSchema);

export { MAX_NESTING_DEPTH, MAX_REPEAT_ITERATIONS, MAX_STEP_NODES };
