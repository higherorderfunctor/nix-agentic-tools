import { execFileSync } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type {
  RunContext,
  ThinkingLevel,
  WorkflowBuilder,
} from "@kimchi-dev/kimchi-workflows";
import {
  createAgentStep,
  createStep,
  createWorkflow,
} from "@kimchi-dev/kimchi-workflows";
import { Type } from "typebox";

export const roles = [
  "lens",
  "refine",
  "surface",
  "dedupe",
  "evidence",
  "defense",
  "judge",
  "finalize",
] as const;
type Role = (typeof roles)[number];
type Json = Record<string, unknown>;
interface Task {
  id: string;
  [key: string]: unknown;
}
interface Payload {
  task_id: string;
  proposal_id: string;
  prompt: string;
  input: unknown;
  cached_result?: Json;
}
export interface Profile {
  defense_policy?: "when-requested";
  roles: Record<Role, { model_id: string; effort: ThinkingLevel }>;
  limits: {
    concurrency: number;
    max_waves: number;
    max_duration_ms?: number;
    max_tokens?: number;
  };
}
interface Request {
  arm: string;
  bundle: string;
  pass: number;
  profile: string;
  run_dir: string;
  steering_file?: string;
}
const helper = fileURLToPath(new URL("../shared/review.py", import.meta.url));
const requestSchema = Type.Object({
  arm: Type.String(),
  bundle: Type.String(),
  pass: Type.Integer({ minimum: 1, maximum: 3 }),
  profile: Type.String(),
  run_dir: Type.String(),
  steering_file: Type.Optional(Type.String()),
});
const taskSchema = Type.Unsafe<Task>({ type: "object" });
const payloadSchema = Type.Unsafe<Payload>({
  type: "object",
  required: ["task_id", "prompt", "input"],
});
const objectSchema = Type.Unsafe<Json>({ type: "object" });

function request(ctx: RunContext): Request {
  return ctx.getInitData<Request>()!;
}
function command(ctx: RunContext, name: string, args: string[] = []): Json {
  const input = request(ctx);
  return JSON.parse(
    execFileSync(
      "@python@",
      [helper, name, "--run-dir", input.run_dir, "--arm", input.arm, ...args],
      {
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
      },
    ),
  );
}
function intake(ctx: RunContext): Json {
  const file = request(ctx).steering_file;
  return file && existsSync(file)
    ? command(ctx, "intake", ["--input", file])
    : { skipped: true };
}
function selectedTask(ctx: RunContext, frame: string): Task {
  const task = ctx.scope(frame)?.input as Task | undefined;
  if (!task?.id) throw new Error(`missing task in ${frame}`);
  return task;
}
function appendRole(
  builder: WorkflowBuilder,
  role: Role,
  frame: string,
  profile: Profile,
): WorkflowBuilder {
  // Python validates the complete contract, so native schema repairs must not
  // allocate a second budget before relational checks see the same proposal.
  const turn = createWorkflow({ name: `${role}-turn` })
    .then(
      createStep({
        name: `${role}-correction-payload`,
        output: payloadSchema,
        run: ({ ctx }) =>
          command(ctx, "payload", [
            "--task",
            selectedTask(ctx, frame).id,
            "--role",
            role,
          ]) as unknown as Payload,
      }),
    )
    .then(
      createAgentStep({
        name: role,
        input: payloadSchema,
        output: Type.Any(),
        background: true,
        model: profile.roles[role].model_id,
        thinking: profile.roles[role].effort,
        maxOutputRepairs: 0,
        maxDurationMs: profile.limits.max_duration_ms,
        maxTokens: profile.limits.max_tokens,
        resumable: ({ ctx }) =>
          createHash("sha256")
            .update(
              `${path.resolve(request(ctx).run_dir)}/${request(ctx).arm}/${selectedTask(ctx, frame).id}/${role}`,
            )
            .digest("hex"),
        prompt: ({ input }) =>
          `${input.prompt}\n\n${JSON.stringify(input.input)}`,
      }),
    )
    .then(
      createStep({
        name: `${role}-attempt`,
        input: Type.Any(),
        output: objectSchema,
        run: ({ input, ctx }) => {
          const directory = path.join(request(ctx).run_dir, "adapter-results");
          mkdirSync(directory, { recursive: true });
          const file = path.join(directory, `${role}-${randomUUID()}.json`);
          writeFileSync(file, JSON.stringify(input));
          return command(ctx, "submit", [
            "--task",
            selectedTask(ctx, frame).id,
            "--role",
            role,
            "--result",
            file,
            "--proposal-id",
            ctx.getStepResult<Payload>(`${role}-correction-payload`)!
              .proposal_id,
          ]);
        },
      }),
    )
    .commit();
  const fresh = createWorkflow({ name: `${role}-fresh` })
    .dountil(
      turn,
      (ctx) => {
        const receipt = ctx.getStepResult<Json>(`${role}-attempt`)!;
        return receipt.accepted === true || receipt.exhausted === true;
      },
      { name: `${role}-corrections`, maxIterations: 3 },
    )
    .then(
      createStep({
        name: `${role}-accepted`,
        input: objectSchema,
        output: objectSchema,
        run: ({ input }) => {
          if (input.accepted !== true)
            throw new Error(
              `${role}: submission budget exhausted: ${input.error}`,
            );
          return input;
        },
      }),
    )
    .commit();
  const cached = createWorkflow({ name: `${role}-cached` })
    .then(
      createStep({
        name: `${role}-reuse`,
        input: payloadSchema,
        output: objectSchema,
        run: ({ ctx, input }) => {
          const directory = path.join(request(ctx).run_dir, "adapter-results");
          mkdirSync(directory, { recursive: true });
          const file = path.join(directory, `${role}-${randomUUID()}.json`);
          writeFileSync(file, JSON.stringify(input.cached_result));
          return command(ctx, "submit", [
            "--task",
            selectedTask(ctx, frame).id,
            "--role",
            role,
            "--result",
            file,
            "--proposal-id",
            input.proposal_id,
          ]);
        },
      }),
    )
    .commit();
  return builder
    .then(
      createStep({
        name: `${role}-payload`,
        output: payloadSchema,
        run: ({ ctx }) => {
          const task = selectedTask(ctx, frame);
          const payload = command(ctx, "payload", [
            "--task",
            task.id,
            "--role",
            role,
          ]) as unknown as Payload;
          const prior = (task.results as Record<string, Json> | undefined)?.[
            role
          ];
          return prior === undefined
            ? payload
            : { ...payload, cached_result: prior };
        },
      }),
    )
    .branch(
      [
        [
          (ctx) =>
            ctx.getStepResult<Payload>(`${role}-payload`)!.cached_result ===
            undefined,
          fresh,
        ],
        [
          (ctx) =>
            ctx.getStepResult<Payload>(`${role}-payload`)!.cached_result !==
            undefined,
          cached,
        ],
      ],
      { name: `${role}-result` },
    )
    .map(
      (ctx) => {
        const results = ctx.getStepResult<Json>(`${role}-result`)!;
        return results[`${role}-fresh`] ?? results[`${role}-cached`];
      },
      { name: `${role}-receipt` },
    );
}

function stage(
  builder: WorkflowBuilder,
  role: Exclude<Role, "evidence" | "defense" | "judge">,
  profile: Profile,
): WorkflowBuilder {
  const frame = `${role}-fan`;
  const body = appendRole(
    createWorkflow({ name: `${role}-body` }),
    role,
    frame,
    profile,
  ).commit();
  return builder
    .then(
      createStep({
        name: `${role}-tasks`,
        output: Type.Array(taskSchema),
        run: ({ ctx }) =>
          command(ctx, "tasks", ["--stage", role]).tasks as Task[],
      }),
    )
    .foreach(body, (ctx) => ctx.getStepResult<Task[]>(`${role}-tasks`)!, {
      name: frame,
      concurrency: ["refine", "dedupe", "finalize"].includes(role)
        ? 1
        : profile.limits.concurrency,
    });
}

/** Build once from a supplied immutable role profile; never discover or choose live models. */
export function createReviewWorkflow(profile: Profile) {
  const concurrency = profile.limits.concurrency;
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 6)
    throw new Error("limits.concurrency must be an integer from 1 through 6");
  for (const role of roles) {
    if (!profile.roles[role]?.model_id?.includes("/"))
      throw new Error(`configure provider/modelId for ${role}`);
  }
  for (const role of roles) {
    if (
      !["off", "minimal", "low", "medium", "high", "xhigh", "max"].includes(
        profile.roles[role].effort,
      )
    )
      throw new Error(`configure native thinking for ${role}`);
  }
  for (const [key, value] of Object.entries(profile.limits)) {
    if (!Number.isInteger(value) || value < 1)
      throw new Error(`positive integer required: ${key}`);
  }
  const defended = appendRole(
    createWorkflow({ name: "with-defense" }),
    "defense",
    "claims",
    profile,
  ).commit();
  const undefended = createWorkflow({ name: "without-defense" })
    .then(
      createStep({
        name: "skip-defense",
        output: objectSchema,
        run: () => ({ skipped: true }),
      }),
    )
    .commit();
  let claim = appendRole(
    createWorkflow({ name: "claim-review" }),
    "evidence",
    "claims",
    profile,
  );
  claim = claim.branch(
    [
      [
        (ctx) =>
          ctx.getStepResult<Json>("evidence-receipt")!.needs_defense === true,
        defended,
      ],
      [
        (ctx) =>
          ctx.getStepResult<Json>("evidence-receipt")!.needs_defense !== true,
        undefended,
      ],
    ],
    { name: "defense-choice" },
  );
  claim = appendRole(claim, "judge", "claims", profile);

  let wave = createWorkflow({
    name: "review-wave",
    maxConcurrency: profile.limits.concurrency,
  }).then(
    createStep({
      name: "steering-start",
      output: objectSchema,
      run: ({ ctx }) => intake(ctx),
    }),
  );
  for (const role of ["lens", "refine", "surface", "dedupe"] as const)
    wave = stage(wave, role, profile);
  wave = wave
    .then(
      createStep({
        name: "claim-tasks",
        output: Type.Array(taskSchema),
        run: ({ ctx }) =>
          command(ctx, "tasks", ["--stage", "adjudicate"]).tasks as Task[],
      }),
    )
    .foreach(
      claim.commit(),
      (ctx) => ctx.getStepResult<Task[]>("claim-tasks")!,
      { name: "claims", concurrency: profile.limits.concurrency },
    );
  wave = stage(wave, "finalize", profile)
    .then(
      createStep({
        name: "steering-end",
        output: objectSchema,
        run: ({ ctx }) => intake(ctx),
      }),
    )
    .then(
      createStep({
        name: "next-wave",
        output: Type.Object({ continue: Type.Boolean() }),
        run: ({ ctx }) => command(ctx, "next-wave") as { continue: boolean },
      }),
    );
  return createWorkflow({
    name: "code-review",
    input: requestSchema,
    maxConcurrency: profile.limits.concurrency,
  })
    .then(
      createStep({
        name: "prepare",
        output: objectSchema,
        run: ({ ctx }) => {
          const input = request(ctx);
          const supplied = JSON.parse(readFileSync(input.profile, "utf8"));
          if (JSON.stringify(supplied) !== JSON.stringify(profile))
            throw new Error("profile differs from materialized workflow");
          return command(ctx, "prepare", [
            "--input",
            input.bundle,
            "--runtime",
            "kimchi",
            "--pass",
            String(input.pass),
            "--profile",
            input.profile,
            "--max-waves",
            String(profile.limits.max_waves),
          ]);
        },
      }),
    )
    .dountil(
      wave.commit(),
      (_ctx, output) => !(output as { continue: boolean }).continue,
      { name: "waves", maxIterations: profile.limits.max_waves + 1 },
    )
    .then(
      createStep({
        name: "render",
        output: objectSchema,
        run: ({ ctx }) => command(ctx, "report"),
      }),
    )
    .commit();
}
