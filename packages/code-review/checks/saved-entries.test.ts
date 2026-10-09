import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import { expect, it } from "vitest";

it("loads every deployed saved store entry without running its agents", async () => {
  const host = createRequire(import.meta.url).resolve(
    "@kimchi-dev/kimchi-workflows/host",
  );
  const { loadWorkflowFile } = await import(pathToFileURL(host).href);
  const entries = JSON.parse(process.env.CODE_REVIEW_SAVED_ENTRIES!);
  expect(entries).toHaveLength(3);
  for (const entry of entries) {
    expect(entry.startsWith("/nix/store/")).toBe(true);
    const workflow = await loadWorkflowFile(entry);
    expect(workflow.nodes.length).toBeGreaterThan(0);
  }
});
