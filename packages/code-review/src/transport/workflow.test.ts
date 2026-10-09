import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createTestRun } from "@kimchi-dev/kimchi-workflows/testing";
import { afterEach, describe, expect, it } from "vitest";
import { createTransportWorkflow } from "./kimchi.ts";

const profile = {
  roles: { lens: { model_id: "fixture/transport", effort: "high" as const } },
};
const roots: string[] = [];
afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});
const helper = fileURLToPath(new URL("./local.py", import.meta.url));
function command(...args: string[]) {
  return JSON.parse(
    execFileSync("python3", [helper, ...args], { encoding: "utf8" }),
  );
}
function fixture() {
  const root = mkdtempSync(path.join(os.tmpdir(), "transport-offline-"));
  roots.push(root);
  const checkout = path.join(root, "source");
  execFileSync("git", ["init", "-q", checkout]);
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
  writeFileSync(path.join(checkout, "flag.txt"), "before\n");
  git("add", ".");
  git("commit", "-qm", "base");
  const base = git("rev-parse", "HEAD");
  writeFileSync(path.join(checkout, "flag.txt"), "after\n");
  git("add", ".");
  git("commit", "-qm", "head");
  const head = git("rev-parse", "HEAD");
  const refs = { base_sha: base, head_sha: head, start_sha: base };
  const target = {
    host: "gitlab.example.invalid",
    project_id: "12",
    mr_iid: "3",
  };
  const snapshot = path.join(root, "remote.json");
  const observed = {
    schema_version: 1,
    complete: true,
    observed_at: new Date().toISOString(),
    target: { ...target, ...refs },
    before_refs: refs,
    after_refs: refs,
    discussions: [] as any[],
  };
  writeFileSync(snapshot, JSON.stringify(observed));
  const request_file = path.join(root, "request.json");
  const request = {
    schema_version: 1,
    target,
    snapshot,
    checkout,
    output_dir: path.join(root, "frozen"),
    intake_output: path.join(root, "new-intake.json"),
  };
  writeFileSync(request_file, JSON.stringify(request));
  return { root, request_file, request, observed };
}
describe("standalone native transport, offline", () => {
  it("loads native entry and only completes after a real frozen receipt", async () => {
    const fixtureData = fixture();
    const hostPath = createRequire(import.meta.url).resolve(
      "@kimchi-dev/kimchi-workflows/host",
    );
    const { loadWorkflowFile } = (await import(
      pathToFileURL(hostPath).href
    )) as typeof import("@kimchi-dev/kimchi-workflows/host");
    const loaded = await loadWorkflowFile(
      fileURLToPath(new URL("./offline-entry.workflow.ts", import.meta.url)),
    );
    const run = await createTestRun(loaded, {
      input: { request_file: fixtureData.request_file },
      steps: {
        transport: async () => {
          writeFileSync(
            fixtureData.request.intake_output,
            JSON.stringify({
              claims: [
                {
                  claim: "Actionable supplied discussion",
                  locus: { file: "flag.txt", line: 1 },
                },
              ],
            }),
          );
          command(
            "freeze",
            "--snapshot",
            fixtureData.request.snapshot,
            "--checkout",
            fixtureData.request.checkout,
            "--output-dir",
            fixtureData.request.output_dir,
            "--intake",
            fixtureData.request.intake_output,
          );
          return "agent prose is not the receipt";
        },
      },
    });
    expect(run.status, run.error).toBe("completed");
    const again = await createTestRun(loaded, {
      input: { request_file: fixtureData.request_file },
      steps: { transport: async () => "verified resume" },
    });
    expect(again.status, again.error).toBe("completed");
  });
  it("rejects agent success without frozen artifacts", async () => {
    const data = fixture();
    const run = await createTestRun(createTransportWorkflow("pull", profile), {
      input: { request_file: data.request_file },
      steps: { transport: async () => "success" },
    });
    expect(run.status).toBe("crashed");
    expect(run.error).toContain("missing frozen receipt");
  });
  it("checks a selected push report and actual observed publication receipt", async () => {
    const data = fixture();
    const report_json = path.join(data.root, "report.json"),
      report_md = path.join(data.root, "report.md"),
      publication_dir = path.join(data.root, "publication");
    writeFileSync(
      report_json,
      JSON.stringify({
        schema_version: 1,
        status: { complete: true },
        target: {
          id: "gitlab:gitlab.example.invalid:12!3",
          base_sha: data.observed.target.base_sha,
          head_sha: data.observed.target.head_sha,
        },
        provenance: { input_digest: "a".repeat(64) },
      }),
    );
    writeFileSync(
      report_md,
      "# Selected bot report\nEvidence and check details stay exact.\n",
    );
    writeFileSync(
      data.request_file,
      JSON.stringify({
        schema_version: 1,
        target: data.request.target,
        snapshot: data.request.snapshot,
        observation_file: path.join(data.root, "fresh.json"),
        report_json,
        report_md,
        publication_dir,
        action: "create",
      }),
    );
    const workflow = createTransportWorkflow("push", profile);
    const run = await createTestRun(workflow, {
      input: { request_file: data.request_file },
      steps: {
        transport: async () => {
          command(
            "plan",
            "--snapshot",
            data.request.snapshot,
            "--report-json",
            report_json,
            "--report-md",
            report_md,
            "--publication-dir",
            publication_dir,
            "--action",
            "create",
          );
          const plan = JSON.parse(
            readFileSync(path.join(publication_dir, "plan.json"), "utf8"),
          );
          expect(plan.body).toContain(readFileSync(report_md, "utf8"));
          data.observed.discussions = [
            {
              id: "thread",
              notes: [
                {
                  id: "9",
                  body: plan.body,
                  updated_at: new Date().toISOString(),
                },
              ],
            },
          ];
          const fresh = path.join(data.root, "fresh.json");
          writeFileSync(fresh, JSON.stringify(data.observed));
          command(
            "observe",
            "--publication-dir",
            publication_dir,
            "--snapshot",
            fresh,
          );
          return "done";
        },
      },
    });
    expect(run.status, run.error).toBe("completed");
    writeFileSync(report_md, "Different selected report\n");
    let called = false;
    const refused = await createTestRun(workflow, {
      input: { request_file: data.request_file },
      steps: {
        transport: async () => {
          called = true;
          return "done";
        },
      },
    });
    expect(refused.status).toBe("crashed");
    expect(called).toBe(false);
    expect(refused.error).toContain("another request/report");
  });
});
