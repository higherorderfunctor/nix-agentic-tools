// cspell:ignore unstub
import { execFile } from "node:child_process";
import {
  chmod,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  realpath,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { expect, it, vi } from "vitest";
import { prepareWorkflowPackage } from "../src/host/workflow-package.ts";
import {
  resolveWorkflowPackageManager,
  runWorkflowPackageManager,
} from "../src/host/workflow-package-manager.ts";

it("closes production preparation and verification over the store, ignoring user configuration", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "nix-workflow-toolchain-"));
  const requests: string[] = [];
  const registry = createServer((request, response) => {
    requests.push(request.url ?? "");
    response.writeHead(404);
    response.end("unshipped package");
  });
  await new Promise<void>((resolve) =>
    registry.listen(0, "127.0.0.1", resolve),
  );
  try {
    const wrongBin = path.join(root, "wrong-bin");
    await mkdir(wrongBin);
    for (const name of ["corepack", "node", "npm", "pnpm"]) {
      const file = path.join(wrongBin, name);
      await writeFile(
        file,
        "#!@shell@\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nexit 99\n",
      );
      await chmod(file, 0o755);
    }
    const address = registry.address();
    if (!address || typeof address === "string")
      throw new Error("no registry port");
    const mirror = `http://127.0.0.1:${address.port}`;
    // Production must impose offline/config isolation itself, including outside CI.
    for (const [key, value] of Object.entries({
      CI: undefined,
      CODE_REVIEW_BIN: "caller-variable-preserved",
      NPM_CONFIG_OFFLINE: "false",
      Npm_Config_fetch_retries: "0",
      "Npm_Config_node-mirror:release": `${mirror}/`,
      Npm_Config_use_node_version: "22.19.0",
      PATH: wrongBin,
      npm_config_offline: "false",
      npm_config_registry: mirror,
      npm_config_store_dir: path.join(root, "empty-store"),
      pNpM_HOME: path.join(root, "unwanted-pnpm-home"),
      pNpM_cOnFiG_use_node_version: "22.19.0",
    })) {
      vi.stubEnv(key, value);
    }
    for (const variable of [
      "HOME",
      "PNPM_HOME",
      "XDG_CACHE_HOME",
      "XDG_CONFIG_HOME",
      "XDG_DATA_HOME",
      "XDG_STATE_HOME",
    ]) {
      const location = path.join(root, variable);
      await mkdir(location);
      vi.stubEnv(variable, location);
    }
    const hostileConfig = `use-node-version=22.19.0\nnode-mirror:release=${mirror}/\nmanage-package-manager-versions=true\noffline=false\nregistry=${mirror}/\nupdate-notifier=true\n`;
    await writeFile(path.join(process.env.HOME!, ".npmrc"), hostileConfig);
    await mkdir(path.join(process.env.XDG_CONFIG_HOME!, "pnpm"));
    await writeFile(
      path.join(process.env.XDG_CONFIG_HOME!, "pnpm/rc"),
      hostileConfig,
    );
    const manager = await resolveWorkflowPackageManager();
    const directory = path.join(root, "workflows");
    await mkdir(directory);
    await writeFile(path.join(directory, "package.json"), "{}");
    // Both the workspace and its rc must be ignored by every launcher caller.
    const workspaceConfig =
      "packages: []\nuseNodeVersion: 22.19.0\nfetchRetries: 0\n";
    await writeFile(path.join(root, "pnpm-workspace.yaml"), workspaceConfig);
    await writeFile(path.join(root, ".npmrc"), hostileConfig);
    const launch = (args: readonly string[], cwd = directory) =>
      runWorkflowPackageManager(manager, [...args], {
        cwd,
        timeoutMs: 10_000,
        timeoutError: () => new Error(`pnpm ${args.join(" ")} timed out`),
        outputLimit: 65536,
      });
    // Read effective config from pnpm: hostile home, XDG, ancestor and env
    // settings must not restore network access, install hooks or a Node switch.
    const config = await launch(["config", "list", "--json"]);
    expect(config.code, JSON.stringify(config)).toBe(0);
    expect(JSON.parse(config.stdout)).toMatchObject({
      "ignore-scripts": true,
      "manage-package-manager-versions": false,
      offline: true,
      "update-notifier": false,
      "use-node-version": process.versions.node,
      userconfig: "/dev/null",
    });
    const hook = 'throw new Error("project hook must not run")';
    const install = ["--dir", directory, "install", "--ignore-scripts"];
    for (const [name, content, args, cwd] of [
      // Detect interpreting a child --dir as a pnpm option in the cwd path.
      [".pnpmfile.cjs", hook, ["exec", "node", "--dir", root], directory],
      // Install must check the directory selected by the leading --dir, not cwd.
      ["pnpm-workspace.yaml", workspaceConfig, install, root],
    ] as const) {
      const file = path.join(directory, name);
      await writeFile(file, content);
      try {
        const result = await launch(args, cwd);
        expect(result.code, JSON.stringify(args)).toBe(1);
        expect(result.stderr).toContain(
          `forbids project configuration file ${name}: ${directory}`,
        );
      } finally {
        await rm(file);
      }
    }
    // pnpm --version ignores --dir and reads the working directory, so the
    // launcher must run pnpm in the directory it checked: the probe's project
    // cwd keeps its hook, which must not run.
    const neutral = await mkdtemp(path.join(root, "neutral-"));
    const hookMarker = path.join(neutral, "probe-hook-ran");
    const probeHook = path.join(directory, ".pnpmfile.cjs");
    await writeFile(
      probeHook,
      `require("node:fs").writeFileSync(${JSON.stringify(hookMarker)}, "ran")`,
    );
    try {
      const probe = await launch(["--version", "--dir", neutral], directory);
      expect(probe.code, JSON.stringify(probe)).toBe(0);
      await expect(readFile(hookMarker, "utf8")).rejects.toMatchObject({
        code: "ENOENT",
      });
    } finally {
      await rm(probeHook);
    }
    const prepared = await prepareWorkflowPackage({ directory });
    expect(prepared.installed).toBe(true);
    expect(prepared.verifyCommand).toContain("@pnpm@");
    const readManifest = async (file: string) =>
      JSON.parse(await readFile(file, "utf8"));
    const installedManifest = (name: string) =>
      readManifest(path.join(directory, "node_modules", name, "package.json"));
    const manifest = await readManifest(prepared.manifestPath);
    // Pin the closure members, not merely the number of file: references.
    const frameworkName = "@kimchi-dev/kimchi-workflows";
    const toolchain = {
      piCodingAgent: "@earendil-works/pi-coding-agent",
      piTui: "@earendil-works/pi-tui",
      typebox: "typebox",
      typesNode: "@types/node",
      typescript: "typescript",
      vitest: "vitest",
    };
    expect(Object.keys(manifest.devDependencies).sort()).toEqual(
      [frameworkName, ...Object.values(toolchain)].sort(),
    );
    for (const name of Object.values(toolchain))
      expect(manifest.devDependencies[name]).toMatch(
        /^file:\/nix\/store\/.*\.tgz$/,
      );
    // A stale distribution stamp must not select a different package manager.
    expect(manifest.packageManager).toBe("pnpm@@pnpmVersion@");
    const framework = await installedManifest(frameworkName);
    // Compare the published stamp with what pnpm actually installed.
    const versions = Object.fromEntries(
      await Promise.all(
        Object.entries(toolchain).map(async ([key, name]) => {
          const { version } = await installedManifest(name);
          return [key, version];
        }),
      ),
    );
    expect(framework.kimchiWorkflows.toolchain).toEqual(versions);
    // Bundling a private copy of host-provided peers splits runtime identity.
    for (const name of [
      toolchain.piCodingAgent,
      toolchain.piTui,
      toolchain.typebox,
    ]) {
      expect(framework.dependencies).not.toHaveProperty(name);
      expect(framework.peerDependencies[name]).toBe("*");
    }
    await writeFile(
      path.join(directory, "entry.ts"),
      `
import { createStep, createWorkflow } from "@kimchi-dev/kimchi-workflows"
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent"
import { Type } from "typebox"
export type Host = ExtensionAPI
// These declarations exist only in Kimchi's patched PI, not its registry tarball.
export function report(ctx: ExtensionContext) { ctx.ui.showError("workflow failure") }
export function model(pi: ExtensionAPI) { return pi.setModel({} as never, { persist: false }) }
export function compact(ctx: ExtensionContext) { ctx.compact({ force: true }) }
export const schema = Type.String()
export default createWorkflow({ name: "offline" })
  .then(createStep({ name: "local", output: schema, run: () => "offline" })).commit()
`,
    );
    await writeFile(
      path.join(directory, "entry.test.ts"),
      `
import { expect, it } from "vitest"
import workflow, { schema } from "./entry.ts"
it("loads the store-backed authoring API", () => {
  expect(workflow).toBeDefined()
  expect(schema.type).toBe("string")
  expect(process.env.CODE_REVIEW_BIN).toBe("caller-variable-preserved")
})
`,
    );
    // Execute exactly the printed command after filling in its two placeholders.
    const command = prepared.verifyCommand
      .replace("<workflow.ts>", "entry.ts")
      .replace("<workflow.test.ts>", "entry.test.ts");
    const runPrinted = () =>
      promisify(execFile)("@shell@", ["-c", command], {
        cwd: directory,
        timeout: 60_000,
        maxBuffer: 65536,
      });
    const verify = async () => {
      const result = await runPrinted();
      expect(result.stdout).toContain(
        "TypeScript passed; focused test passed (1 test)",
      );
    };
    // The exact printed run must refuse an rc added after preparation that
    // would redirect pnpm to another lockfile root.
    await writeFile(
      path.join(directory, ".npmrc"),
      `lockfile-dir=${path.join(root, "foreign")}\n`,
    );
    try {
      await expect(runPrinted()).rejects.toMatchObject({
        code: 1,
        stderr: expect.stringContaining(
          `forbids project configuration file .npmrc: ${directory}`,
        ),
      });
    } finally {
      await rm(path.join(directory, ".npmrc"));
    }
    await verify();
    // Compare every physical imported file with the reachable store graph. This
    // catches the read-only-inode precondition for Darwin's unconditional bin chmod.
    const storeInodes = new Set<string>();
    const seen = new Set<string>();
    const scanStore = async (file: string): Promise<void> => {
      const resolved = await realpath(file);
      if (seen.has(resolved)) return;
      seen.add(resolved);
      const info = await stat(resolved);
      if (info.isDirectory()) {
        for (const name of await readdir(resolved))
          await scanStore(path.join(resolved, name));
      } else if (info.isFile()) storeInodes.add(`${info.dev}:${info.ino}`);
    };
    await scanStore("@workflowPackage@");
    let importedFiles = 0;
    const scanProject = async (file: string): Promise<void> => {
      for (const entry of await readdir(file, { withFileTypes: true })) {
        const child = path.join(file, entry.name);
        if (entry.isDirectory()) await scanProject(child);
        else if (entry.isFile()) {
          const info = await stat(child);
          expect(storeInodes.has(`${info.dev}:${info.ino}`), child).toBe(false);
          importedFiles++;
        } else if (entry.isSymbolicLink()) {
          expect(await realpath(child), child).not.toMatch(/^\/nix\/store\//);
        }
      }
    };
    await scanProject(path.join(directory, "node_modules"));
    expect(importedFiles).toBeGreaterThan(100);
    // A second preparation with no changes must not reinstall the package.
    expect((await prepareWorkflowPackage({ directory })).installed).toBe(false);
    // Exec must ignore the ancestor workspace, just as install and run did.
    const executed = await launch(["exec", "node", "--version"]);
    expect(executed.code, JSON.stringify(executed)).toBe(0);
    expect(executed.stdout.trim()).toBe(process.version);
    // Inspect the child's environment, not only the package manager's config.
    const environment = await launch(
      [
        "--dir",
        directory,
        "exec",
        "node",
        "-e",
        "console.log(JSON.stringify({ caller: process.env.CODE_REVIEW_BIN, mixed: Object.keys(process.env).filter(key => /^(Npm_Config_|pNpM_)/.test(key)) }))",
      ],
      root,
    );
    expect(environment.code, JSON.stringify(environment)).toBe(0);
    expect(JSON.parse(environment.stdout)).toEqual({
      caller: "caller-variable-preserved",
      mixed: [],
    });
    // A real install first proves the graph. A foreign layout then forces pnpm's
    // noninteractive purge path, retaining the authored workflow beside it.
    await writeFile(
      path.join(directory, "node_modules/.modules.yaml"),
      "layoutVersion: 0\npackageManager: pnpm@12.0.0\nstoreDir: /incompatible-store\nvirtualStoreDir: .pnpm\n",
    );
    await writeFile(
      prepared.manifestPath,
      JSON.stringify({ ...manifest, packageManager: "pnpm@12.0.0" }),
    );
    expect((await prepareWorkflowPackage({ directory })).installed).toBe(true);
    expect(
      await readFile(
        path.join(directory, "node_modules/.modules.yaml"),
        "utf8",
      ),
    ).not.toContain("layoutVersion: 0");
    await verify();
    for (const [name, manifest, diagnostic] of [
      [
        "extra",
        { dependencies: { "unshipped-workflow-dependency": "*" } },
        "dependencies package unshipped-workflow-dependency",
      ],
      [
        "local",
        {
          devDependencies: {
            "unshipped-local-dependency": "file:/tmp/outside-closure",
          },
        },
        "devDependencies package unshipped-local-dependency",
      ],
      [
        "override",
        { pnpm: { overrides: { typebox: "9.9.9" } } },
        "overrides: typebox",
      ],
      [
        "resolutions",
        { resolutions: { typebox: "9.9.9" } },
        "resolutions: typebox",
      ],
      [
        "runtime",
        { pnpm: { executionEnv: { nodeVersion: "22.19.0" } } },
        "executionEnv: executionEnv",
      ],
    ] as const) {
      const directory = path.join(root, name);
      await mkdir(directory);
      await writeFile(
        path.join(directory, "package.json"),
        JSON.stringify(manifest),
      );
      await expect(prepareWorkflowPackage({ directory })).rejects.toThrow(
        `closed Kimchi workflow toolchain forbids ${diagnostic}`,
      );
    }
    // The mock records attempted network access, even if pnpm recovers from it.
    expect(requests).toEqual([]);
  } finally {
    vi.unstubAllEnvs();
    await new Promise<void>((resolve, reject) =>
      registry.close((error) => (error ? reject(error) : resolve())),
    );
    await rm(root, { recursive: true, force: true });
  }
}, 180_000);
