// cspell:ignore earendil
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
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { resolveSkillPathsForDiscovery } from "./resolve-skill-roots.js";

describe("immutable bundled skills", () => {
  let root: string;
  let bundled: string;
  const readOnlyDirs: string[] = [];
  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), "kimchi-store-test-"));
    bundled = join(root, "bundled");
  });
  afterEach(() => {
    for (const path of readOnlyDirs.splice(0)) chmodSync(path, 0o755);
    rmSync(root, { recursive: true, force: true });
  });
  function skill(base: string, name: string): string {
    const dir = join(base, name);
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, "SKILL.md"),
      `---\nname: ${name}\ndescription: A test skill.\n---\nSee reference.txt.\n`,
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
  it("loads read-only source directories directly without an exit cleanup", () => {
    const dir = skill(bundled, "bundled-example");
    chmodSync(dir, 0o555);
    readOnlyDirs.push(dir);
    const listeners = process.listenerCount("exit");
    const paths = discover();
    expect(paths).toEqual([dir]);
    expect(discover()).toEqual(paths);
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
  it("honors symlinked overrides while retaining new bundled skills", () => {
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
    expect(result.diagnostics.filter((d) => d.type === "collision")).toEqual(
      [],
    );
    expect(result.skills.map((s) => s.name).sort()).toEqual([
      "new-bundled",
      "overridden",
    ]);
  });
  it("contributes nothing when every bundled skill is overridden", () => {
    skill(bundled, "overridden");
    const extra = join(root, "extra");
    skill(extra, "overridden");
    expect(discover([extra])).toEqual([extra]);
  });
});
