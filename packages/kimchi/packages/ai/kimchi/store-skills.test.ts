// cspell:ignore earendil unstub
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { loadSkills } from "@earendil-works/pi-coding-agent";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resolveSkillPathsForDiscovery } from "./resolve-skill-roots.js";

describe("immutable bundled skills", () => {
  let root: string;
  let bundled: string;
  let readOnlyDir: string | undefined;
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "kimchi-store-test-"));
    bundled = join(root, "bundled");
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    if (readOnlyDir) chmodSync(readOnlyDir, 0o755);
    readOnlyDir = undefined;
    rmSync(root, { recursive: true, force: true });
  });
  function skill(base: string, name: string, resource?: string): string {
    const dir = join(base, name);
    mkdirSync(dir, { recursive: true });
    const requirement = resource ? `requires-resource: ${resource}\n` : "";
    writeFileSync(
      join(dir, "SKILL.md"),
      `---\nname: ${name}\ndescription: A test skill.\n${requirement}---\nSee reference.txt.\n`,
    );
    writeFileSync(join(dir, "reference.txt"), "Supporting content.");
    return dir;
  }
  function discover(extraPaths: string[] = []): string[] {
    return resolveSkillPathsForDiscovery(root, {
      homeDir: join(root, "home"),
      bundledDir: bundled,
      extraPaths,
    });
  }
  it("loads a read-only gated view in place without copying skills or adding an exit cleanup", () => {
    const agentDir = join(root, "agent");
    mkdirSync(agentDir);
    writeFileSync(
      join(agentDir, "settings.json"),
      JSON.stringify({ resources: { "skills.pptx": false } }),
    );
    vi.stubEnv("KIMCHI_CODING_AGENT_DIR", agentDir);
    const dir = skill(bundled, "bundled-example");
    skill(bundled, "gated", "skills.pptx");
    chmodSync(dir, 0o555);
    readOnlyDir = dir;
    // An ungated tree would never exercise the former temp-copy path.
    const listeners = process.listenerCount("exit");
    const paths = discover();
    expect(paths).toEqual([dir]);
    expect(process.listenerCount("exit")).toBe(listeners);
    const result = loadSkills({
      cwd: root,
      agentDir: join(root, "home"),
      skillPaths: paths,
      includeDefaults: false,
    });
    expect(result.diagnostics).toEqual([]);
    expect(result.skills.map((s) => s.name)).toEqual(["bundled-example"]);
    expect(
      readFileSync(
        join(dirname(result.skills[0].filePath), "reference.txt"),
        "utf8",
      ),
    ).toBe("Supporting content.");
  });
  it("honors a symlinked override beside a dangling link without losing unrelated bundled skills", () => {
    skill(bundled, "overridden");
    const kept = skill(bundled, "new-bundled");
    const custom = skill(join(root, "custom"), "overridden");
    const extra = join(root, "extra");
    mkdirSync(extra);
    symlinkSync(custom, join(extra, "overridden"), "dir");
    symlinkSync(join(root, "missing"), join(extra, "broken"), "dir");
    const paths = discover([extra]);
    expect(paths).toEqual([kept, extra]);
    const result = loadSkills({
      cwd: root,
      agentDir: join(root, "home"),
      skillPaths: paths,
      includeDefaults: false,
    });
    expect(result.skills.map((s) => s.name).sort()).toEqual([
      "new-bundled",
      "overridden",
    ]);
  });
  it("does not fall back to the bundled root when every skill was overridden", () => {
    skill(bundled, "overridden");
    const extra = join(root, "extra");
    skill(extra, "overridden");
    expect(discover([extra])).toEqual([extra]);
  });
});
