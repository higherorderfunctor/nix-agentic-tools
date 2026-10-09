import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { WorkflowDefinition } from "@kimchi-dev/kimchi-workflows";
import {
  createTestRun,
  type StepOverrides,
} from "@kimchi-dev/kimchi-workflows/testing";
import { afterEach, describe, expect, it, vi } from "vitest";
import workflow, { fixtureProfile } from "./offline-entry.workflow.ts";
import { createReviewWorkflow } from "./workflow.ts";

// Deterministic subprocess fixtures validate more bookkeeping on correction turns.
vi.setConfig({ testTimeout: 20000 });
type Data = Record<string, any>;
const temporary: string[] = [];
afterEach(() => {
  for (const folder of temporary.splice(0))
    rmSync(folder, { recursive: true, force: true });
});
function fixture(profile = fixtureProfile) {
  const root = mkdtempSync(path.join(os.tmpdir(), "kimchi-review-offline-"));
  temporary.push(root);
  const checkout = path.join(root, "checkout");
  execFileSync("git", ["init", checkout], { stdio: "ignore" });
  const git = (...args: string[]) =>
    execFileSync(
      "git",
      [
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "-C",
        checkout,
        ...args,
      ],
      { encoding: "utf8" },
    ).trim();
  writeFileSync(
    path.join(checkout, "flag.ts"),
    "export const enabled = true;\n",
  );
  git("add", "flag.ts");
  git("commit", "-m", "fixture base");
  const base = git("rev-parse", "HEAD");
  writeFileSync(
    path.join(checkout, "flag.ts"),
    "export const enabled = false;\n",
  );
  git("add", "flag.ts");
  git("commit", "-m", "fixture head");
  const head = git("rev-parse", "HEAD");
  const diff = path.join(root, "prepared.diff");
  writeFileSync(diff, git("diff", base, head) + "\n");
  const bundle = path.join(root, "input.json"),
    profilePath = path.join(root, "profile.json");
  writeFileSync(
    bundle,
    JSON.stringify({
      schema_version: 1,
      target: { id: "fixture", base_sha: base, head_sha: head },
      checkout,
      diff,
      comments: [],
    }),
  );
  writeFileSync(profilePath, JSON.stringify(profile));
  return {
    arm: "kimchi-fixture",
    bundle,
    pass: 1,
    profile: profilePath,
    run_dir: path.join(root, "run"),
    root,
  };
}
function stubs(
  discovery: "once" | "always" | "none" = "once",
  steering?: string,
) {
  const calls: string[] = [],
    defenseInputs: Data[] = [],
    judgeInputs: Data[] = [];
  let discovered = false;
  let steeringWritten = false;
  const locus = { file: "flag.ts", side: "new", line: 1 };
  const candidate = (claim: string) => ({
    claim,
    locus,
    related_loci: [],
    citations: [],
  });
  const citation = {
    file: "flag.ts",
    line: 1,
    supports: "Pinned fixture flag is false",
  };
  const lens = {
    name: "flag behavior",
    ecosystem: "TypeScript",
    corpus: "generic maintainers",
    confidence: "low",
    basis: [],
    banks: [
      "correctness-security",
      "docs",
      "maintainability-reuse",
      "testing",
      "house",
    ],
    questions: ["Does the flag change preserve behavior?"],
  };
  const steps: Record<string, StepOverrides[string]> = {};
  for (const role of [
    "lens",
    "refine",
    "surface",
    "dedupe",
    "evidence",
    "defense",
    "judge",
    "finalize",
  ])
    steps[role] = ({ input }) => {
      const payload = input as Data,
        data = payload.input as Data,
        id = payload.task_id;
      calls.push(`${role}:${id}`);
      switch (role) {
        case "lens":
          return { task_id: id, lenses: [lens] };
        case "refine":
          return {
            task_id: id,
            lenses: [
              {
                ...lens,
                id: "flags",
                chunk_ids: data.chunks.map((chunk: Data) => chunk.id),
              },
            ],
            dropped: [],
          };
        case "surface":
          return {
            task_id: id,
            candidates: data.intake?.some((item: Data) => item.candidate)
              ? data.intake
                  .filter((item: Data) => item.candidate)
                  .map((item: Data) => ({
                    ...item.candidate,
                    intake_id: item.id,
                  }))
              : data.intake?.length
                ? []
                : [candidate("first claim"), candidate("challenge claim")],
          };
        case "dedupe":
          return {
            task_id: id,
            groups: data.candidates.map((entry: Data) => [entry.id]),
            dropped: [],
          };
        case "evidence": {
          const discoveries =
            discovery === "always"
              ? [candidate(`discovery ${id}`)]
              : discovery === "once" && !discovered
                ? [candidate("discovered claim")]
                : [];
          discovered = true;
          return {
            task_id: id,
            citations: [citation],
            verify_path: "Read pinned flag.ts line 1",
            needs_defense: data.claim === "challenge claim",
            narrative: "prosecutor-private",
            discoveries,
          };
        }
        case "defense":
          defenseInputs.push(data);
          return {
            task_id: id,
            citations: [citation],
            reason: "Independent check",
            discoveries: [],
          };
        case "judge":
          judgeInputs.push(data);
          return {
            task_id: id,
            disposition: "accepted",
            severity: "medium",
            reason: "Verified fixture claim",
            citations: [citation],
            verify_path: "Read pinned flag.ts line 1",
            discoveries: [],
          };
        case "finalize":
          if (steering && !steeringWritten) {
            writeFileSync(
              steering,
              JSON.stringify({
                steering: "Inspect flag change",
                claims: [candidate("steered claim")],
              }),
            );
            steeringWritten = true;
          }
          return {
            task_id: id,
            decisions: data.claims.map((claim: Data) => ({
              id: claim.id,
              disposition: claim.judgment.disposition,
              severity: claim.judgment.severity,
              reason: "Holistic fixture check",
            })),
            discoveries: [],
          };
      }
    };
  return { steps, calls, defenseInputs, judgeInputs };
}
function agents(definition: WorkflowDefinition): Data[] {
  return definition.nodes.flatMap((node: any) =>
    node.kind === "step"
      ? node.step.kind === "agent"
        ? [node.step]
        : []
      : node.kind === "branch"
        ? node.arms.flatMap((arm: any) => agents(arm.body))
        : node.kind === "parallel"
          ? node.arms.filter((step: any) => step.kind === "agent")
          : agents(node.body ?? node.workflow),
  );
}
describe("native Kimchi review adapter, offline", () => {
  it.each([1, 6])(
    "accepts concurrency boundary %i in factory",
    (concurrency) => {
      const profile = {
        ...fixtureProfile,
        limits: { ...fixtureProfile.limits, concurrency },
      };
      expect(createReviewWorkflow(profile).maxConcurrency).toBe(concurrency);
    },
  );
  it.each([0, 7, 1.5, true])(
    "rejects invalid concurrency %s in factory",
    (concurrency) => {
      const profile = {
        ...fixtureProfile,
        limits: { ...fixtureProfile.limits, concurrency },
      } as typeof fixtureProfile;
      expect(() => createReviewWorkflow(profile)).toThrow("limits.concurrency");
    },
  );
  it("drains horizontally with conditional defense and full discovery re-entry", async () => {
    const input = fixture(),
      doubles = stubs();
    const entry = path.join(input.root, "code-review.workflow.ts");
    writeFileSync(
      entry,
      `import { createReviewWorkflow } from ${JSON.stringify(fileURLToPath(new URL("./workflow.ts", import.meta.url)))}; export default createReviewWorkflow(${JSON.stringify(fixtureProfile)});`,
    );
    // The verifier aliases authoring/testing modules, but deliberately not /host.
    const hostPath = createRequire(import.meta.url).resolve(
      "@kimchi-dev/kimchi-workflows/host",
    );
    const { loadWorkflowFile } = (await import(
      pathToFileURL(hostPath).href
    )) as typeof import("@kimchi-dev/kimchi-workflows/host");
    const loaded = await loadWorkflowFile(
      process.env.CODE_REVIEW_STORE_ENTRY ?? entry,
    );
    const run = await createTestRun(loaded, { input, steps: doubles.steps });
    expect(run.status, run.error).toBe("completed");
    const report = JSON.parse(
      readFileSync(path.join(input.run_dir, "report.json"), "utf8"),
    );
    expect(report.status.complete).toBe(true);
    expect(report.accepted).toHaveLength(3);
    for (const [id, expectedRoles] of [
      ["w1-adjudicate-1", ["evidence", "judge"]],
      ["w1-adjudicate-2", ["evidence", "defense", "judge"]],
      ["w2-adjudicate-1", ["evidence", "judge"]],
    ] as const) {
      expect(
        doubles.calls
          .filter(
            (call) =>
              /^(evidence|defense|judge):/.test(call) &&
              call.endsWith(`:${id}`),
          )
          .map((call) => call.split(":")[0]),
      ).toEqual(expectedRoles);
    }
    expect(doubles.calls).toContain("lens:w2-lens-1");
    expect(doubles.calls).toContain("finalize:w2-finalize-1");
    expect(doubles.defenseInputs[0]).not.toHaveProperty("prosecution");
    expect(doubles.defenseInputs[0]).not.toHaveProperty("narrative");
    expect(doubles.judgeInputs[1]).toHaveProperty("prosecution");
    expect(doubles.judgeInputs[1]).toHaveProperty("challenge");
    expect(
      agents(workflow).every(
        (agent) =>
          agent.background === true && typeof agent.resumable === "function",
      ),
    ).toBe(true);
  });
  it("collects boundary steering without stopping and gives it the full review path", async () => {
    const input = fixture();
    const steering_file = path.join(input.root, "steering.json");
    const doubles = stubs("none", steering_file);
    const run = await createTestRun(workflow, {
      input: { ...input, steering_file },
      steps: doubles.steps,
    });
    expect(run.status, run.error).toBe("completed");
    const report = JSON.parse(
      readFileSync(path.join(input.run_dir, "report.json"), "utf8"),
    );
    expect(report.status.complete).toBe(true);
    expect(
      report.accepted.some((entry: Data) => entry.claim === "steered claim"),
    ).toBe(true);
    for (const role of [
      "lens",
      "refine",
      "surface",
      "dedupe",
      "evidence",
      "judge",
      "finalize",
    ]) {
      expect(doubles.calls.some((call) => call.startsWith(`${role}:w2-`))).toBe(
        true,
      );
    }
  });
  it("recovers an interrupted claim in a fresh native run without repeating receipted roles", async () => {
    const input = fixture(),
      first = stubs("none");
    const judge = first.steps.judge!;
    first.steps.judge = (args) => {
      if ((args.input as Data).task_id === "w1-adjudicate-2")
        throw new Error("fixture interruption");
      return judge(args);
    };
    const interrupted = await createTestRun(workflow, {
      input,
      steps: first.steps,
    });
    expect(interrupted.status).toBe("crashed");
    const recovery = stubs("none");
    const resumed = await createTestRun(workflow, {
      input,
      steps: recovery.steps,
    });
    expect(resumed.status, resumed.error).toBe("completed");
    expect(
      recovery.calls.filter((call) => /^(evidence|defense|judge):/.test(call)),
    ).toEqual(["judge:w1-adjudicate-2"]);
    const report = JSON.parse(
      readFileSync(path.join(input.run_dir, "report.json"), "utf8"),
    );
    expect(report.status.complete).toBe(true);
    expect(report.accepted).toHaveLength(2);
  });
  it("emits authorized role pins and native thinking without extra repair budgets", () => {
    const profile = JSON.parse(
      readFileSync(new URL("../profiles/kimchi.json", import.meta.url), "utf8"),
    );
    for (const agent of agents(createReviewWorkflow(profile))) {
      expect(agent.model).toBe(profile.roles[agent.name].model_id);
      expect(agent.thinking).toBe(profile.roles[agent.name].effort);
      expect(agent.maxOutputRepairs).toBe(0);
      expect(agent.maxDurationMs).toBeUndefined();
      expect(agent.maxTokens).toBeUndefined();
    }
  });
  it("allows two corrections across schema and relational rejections", async () => {
    const input = fixture();
    const doubles = stubs("none");
    const original = doubles.steps.lens as any;
    let attempt = 0;
    doubles.steps.lens = (args: any) => {
      attempt++;
      if (attempt === 1) return {};
      if (attempt === 2) return { ...original(args), task_id: "wrong" };
      return original(args);
    };
    const run = await createTestRun(workflow, { input, steps: doubles.steps });
    expect(run.status, run.error).toBe("completed");
    const report = JSON.parse(
      readFileSync(path.join(input.run_dir, "report.json"), "utf8"),
    );
    expect(
      report.submission_attempts["w1-lens-1"].lens.map((r: Data) => r.accepted),
    ).toEqual([false, false, true]);
    expect(report.native_controls.provider_effective_settings).toContain(
      "unknown",
    );
  });
  it("stops after three rejected submissions and recovery cannot reset the budget", async () => {
    const input = fixture();
    const doubles = stubs("none");
    let attempts = 0;
    doubles.steps.lens = () => {
      attempts++;
      return {};
    };
    const first = await createTestRun(workflow, {
      input,
      steps: doubles.steps,
    });
    expect(first.status).toBe("crashed");
    expect(attempts).toBe(3);
    const recovered = await createTestRun(workflow, {
      input,
      steps: doubles.steps,
    });
    expect(recovered.status).toBe("crashed");
    expect(attempts).toBe(3);
    const state = JSON.parse(
      readFileSync(path.join(input.run_dir, "state.json"), "utf8"),
    );
    expect(state.tasks["w1-lens-1"].submission_attempts.lens).toHaveLength(3);
    expect(state.tasks["w1-lens-1"].complete).toBe(false);
  });
  it("renders incomplete work at the wave cap", async () => {
    const profile = {
        ...fixtureProfile,
        limits: { ...fixtureProfile.limits, max_waves: 1 },
      },
      input = fixture(profile),
      doubles = stubs("always");
    const run = await createTestRun(createReviewWorkflow(profile), {
      input,
      steps: doubles.steps,
    });
    expect(run.status, run.error).toBe("completed");
    const report = JSON.parse(
      readFileSync(path.join(input.run_dir, "report.json"), "utf8"),
    );
    expect(report.status.complete).toBe(false);
    expect(report.pending_intake.length).toBeGreaterThan(0);
  });
});
