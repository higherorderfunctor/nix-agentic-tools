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
import { expect, it } from "vitest";
import { distribution } from "../src/host/distribution.ts";
import {
  prepareWorkflowPackage,
  WorkflowPackagePreparationError,
} from "../src/host/workflow-package.ts";
import {
  resolveWorkflowPackageManager,
  runWorkflowPackageManager,
} from "../src/host/workflow-package-manager.ts";

it("closes production preparation and verification over the store, ignoring user configuration", async () => {
  const root = await mkdtemp(path.join(tmpdir(), "nix-workflow-toolchain-"));
  const saved = { ...process.env };
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
    process.env.PATH = wrongBin;
    // Production must impose offline/config isolation itself, including outside CI.
    delete process.env.CI;
    process.env.npm_config_offline = "false";
    process.env.NPM_CONFIG_OFFLINE = "false";
    process.env.Npm_Config_use_node_version = "22.19.0";
    process.env.Npm_Config_fetch_retries = "0";
    process.env.pNpM_cOnFiG_use_node_version = "22.19.0";
    process.env.pNpM_HOME = path.join(root, "unwanted-pnpm-home");
    process.env.CODE_REVIEW_BIN = "caller-variable-preserved";
    const address = registry.address();
    if (!address || typeof address === "string")
      throw new Error("no registry port");
    const mirror = `http://127.0.0.1:${address.port}`;
    process.env.npm_config_registry = mirror;
    process.env["Npm_Config_node-mirror:release"] = `${mirror}/`;
    process.env.npm_config_store_dir = path.join(root, "empty-store");
    for (const variable of [
      "HOME",
      "PNPM_HOME",
      "XDG_CACHE_HOME",
      "XDG_CONFIG_HOME",
      "XDG_DATA_HOME",
      "XDG_STATE_HOME",
    ]) {
      process.env[variable] = path.join(root, variable);
      await mkdir(process.env[variable]!);
    }
    const hostileConfig = `use-node-version=22.19.0\nnode-mirror:release=${mirror}/\nmanage-package-manager-versions=true\noffline=false\nregistry=${mirror}/\nupdate-notifier=true\n`;
    await writeFile(path.join(process.env.HOME!, ".npmrc"), hostileConfig);
    await mkdir(path.join(process.env.XDG_CONFIG_HOME!, "pnpm"));
    await writeFile(
      path.join(process.env.XDG_CONFIG_HOME!, "pnpm/rc"),
      hostileConfig,
    );
    const manager = await resolveWorkflowPackageManager();
    expect(manager).toEqual({ command: "@pnpm@", args: [] });
    expect(distribution.packageManager).toBe("pnpm@@pnpmVersion@");
    const directory = path.join(root, "workflows");
    await mkdir(directory);
    await writeFile(path.join(directory, "package.json"), "{}");
    // Both the workspace and its rc must be ignored by every launcher caller.
    const workspaceConfig =
      "packages: []\nuseNodeVersion: 22.19.0\nfetchRetries: 0\n";
    await writeFile(path.join(root, "pnpm-workspace.yaml"), workspaceConfig);
    await writeFile(path.join(root, ".npmrc"), hostileConfig);
    const config = await runWorkflowPackageManager(
      manager,
      ["config", "list", "--json"],
      {
        cwd: directory,
        timeoutMs: 10_000,
        timeoutError: () => new Error("production pnpm config timed out"),
        outputLimit: 65536,
      },
    );
    expect(config.code, JSON.stringify(config)).toBe(0);
    expect(JSON.parse(config.stdout)).toMatchObject({
      "ignore-scripts": true,
      "manage-package-manager-versions": false,
      offline: true,
      "update-notifier": false,
      userconfig: "/dev/null",
    });
    expect(JSON.parse(config.stdout)["use-node-version"]).toBe(
      process.versions.node,
    );
    console.log(`mixed-case Node selection ignored: ${process.versions.node}`);
    // Every entry hits the same launcher refusal. --dir overrides an unrelated
    // cwd; run/exec child arguments must not redirect the checked directory.
    const refuseConfig = async (name: string, content: string) => {
      const file = path.join(directory, name);
      await writeFile(file, content);
      try {
        for (const [args, cwd] of [
          [["--dir", directory, "install", "--ignore-scripts"], root],
          [["--dir", directory, "exec", "node", "--dir", root], root],
          [["exec", "node", "--dir", root], directory],
        ] as const) {
          const result = await runWorkflowPackageManager(manager, args, {
            cwd,
            timeoutMs: 10_000,
            timeoutError: () => new Error("config refusal timed out"),
            outputLimit: 65536,
          });
          expect(result.code).toBe(1);
          expect(result.stderr).toContain(
            `forbids project configuration file ${name}: ${directory}`,
          );
        }
        console.log(
          `launcher config refused for --dir install/exec and cwd exec: ${name}`,
        );
      } finally {
        await rm(file);
      }
    };
    await refuseConfig(
      ".pnpmfile.cjs",
      'throw new Error("project hook must not run")',
    );
    await refuseConfig("pnpm-workspace.yaml", workspaceConfig);
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
      const probe = await runWorkflowPackageManager(
        manager,
        ["--version", "--dir", neutral],
        {
          cwd: directory,
          timeoutMs: 10_000,
          timeoutError: () => new Error("version probe timed out"),
          outputLimit: 65536,
        },
      );
      expect(probe.code, JSON.stringify(probe)).toBe(0);
      await expect(readFile(hookMarker, "utf8")).rejects.toThrow();
      console.log("version probe ran pnpm in its --dir; cwd hook not loaded");
    } finally {
      await rm(probeHook);
    }
    const prepared = await prepareWorkflowPackage({ directory });
    expect(prepared.installed).toBe(true);
    expect(prepared.verifyCommand).toContain("@pnpm@");
    const manifest = JSON.parse(await readFile(prepared.manifestPath, "utf8"));
    expect(Object.keys(manifest.devDependencies)).toHaveLength(7);
    for (const spec of Object.values(manifest.devDependencies))
      expect(spec).toMatch(/^file:\/nix\/store\/.*\.tgz$/);
    expect(manifest.packageManager).toBe(distribution.packageManager);
    const framework = JSON.parse(
      await readFile(
        path.join(
          directory,
          "node_modules/@kimchi-dev/kimchi-workflows/package.json",
        ),
        "utf8",
      ),
    );
    expect(framework.kimchiWorkflows.toolchain).toEqual(distribution.toolchain);
    for (const name of [
      "@earendil-works/pi-coding-agent",
      "@earendil-works/pi-tui",
      "typebox",
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
    const verify = async () => {
      // Execute exactly the printed command after filling in its two placeholders.
      const command = prepared.verifyCommand
        .replace("<workflow.ts>", "entry.ts")
        .replace("<workflow.test.ts>", "entry.test.ts");
      const result = await promisify(execFile)("@shell@", ["-c", command], {
        cwd: directory,
        timeout: 60_000,
        maxBuffer: 65536,
      });
      expect(result.stdout).not.toContain("Fetching Node.js");
      expect(result.stdout).toContain(
        "TypeScript passed; focused test passed (1 test)",
      );
      console.log(`printed production verify: ${result.stdout.trim()}`);
    };
    // P7: a file added after preparation must be refused by the exact printed run.
    await writeFile(path.join(directory, ".npmrc"), hostileConfig);
    try {
      const command = prepared.verifyCommand
        .replace("<workflow.ts>", "entry.ts")
        .replace("<workflow.test.ts>", "entry.test.ts");
      await expect(
        promisify(execFile)("@shell@", ["-c", command], {
          cwd: directory,
          timeout: 10_000,
          maxBuffer: 65536,
        }),
      ).rejects.toMatchObject({
        code: 1,
        stderr: expect.stringContaining(
          `forbids project configuration file .npmrc: ${directory}`,
        ),
      });
      console.log("printed verify refused .npmrc added after preparation");
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
    console.log(
      `imported files sharing store inodes: 0 / ${importedFiles} (store inodes: ${storeInodes.size})`,
    );
    expect((await prepareWorkflowPackage({ directory })).installed).toBe(false);
    // The P5 root-manifest redirect must be refused before reading its override.
    const foreign = path.join(root, "foreign");
    const lockRoot = path.join(root, "lock-root");
    await mkdir(foreign);
    await mkdir(lockRoot);
    await writeFile(
      path.join(foreign, "package.json"),
      JSON.stringify({
        name: "typebox",
        version: "1.3.7",
        main: "index.js",
      }),
    );
    await writeFile(
      path.join(foreign, "index.js"),
      'export const proof="OUTSIDE_KIMCHI_CLOSURE"',
    );
    await writeFile(
      path.join(lockRoot, "package.json"),
      JSON.stringify({
        pnpm: { overrides: { typebox: `file:${foreign}` } },
      }),
    );
    await writeFile(prepared.manifestPath, JSON.stringify(manifest));
    await refuseConfig(".npmrc", `lockfile-dir=${lockRoot}\n${hostileConfig}`);
    await refuseConfig("pnpm-workspace.yaml", workspaceConfig);
    // Prove the injected global option is parsed by exec as well as install/run.
    const executed = await runWorkflowPackageManager(
      manager,
      ["exec", "node", "--version"],
      {
        cwd: directory,
        timeoutMs: 10_000,
        timeoutError: () => new Error("production pnpm exec timed out"),
        outputLimit: 65536,
      },
    );
    expect(executed.code, JSON.stringify(executed)).toBe(0);
    expect(executed.stdout.trim()).toBe(process.version);
    console.log(
      `ancestor workspace ignored by install, printed run and exec: ${executed.stdout.trim()}`,
    );
    const environment = await runWorkflowPackageManager(
      manager,
      [
        "--dir",
        directory,
        "exec",
        "node",
        "-e",
        "console.log(JSON.stringify({ caller: process.env.CODE_REVIEW_BIN, mixed: Object.keys(process.env).filter(key => /^(Npm_Config_|pNpM_)/.test(key)) }))",
      ],
      {
        cwd: root,
        timeoutMs: 10_000,
        timeoutError: () => new Error("environment probe timed out"),
        outputLimit: 65536,
      },
    );
    expect(environment.code, JSON.stringify(environment)).toBe(0);
    expect(JSON.parse(environment.stdout)).toEqual({
      caller: "caller-variable-preserved",
      mixed: [],
    });
    console.log(`filtered child environment: ${environment.stdout.trim()}`);
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
    expect(await readFile(path.join(directory, "entry.ts"), "utf8")).toContain(
      "ExtensionAPI",
    );
    await verify();
    for (const [name, manifest, diagnostic] of [
      [
        "extra",
        { dependencies: { "unshipped-workflow-dependency": "*" } },
        "unshipped-workflow-dependency",
      ],
      [
        "local",
        {
          devDependencies: {
            "unshipped-local-dependency": "file:/tmp/outside-closure",
          },
        },
        "unshipped-local-dependency",
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
        "executionEnv",
      ],
    ] as const) {
      const directory = path.join(root, name);
      await mkdir(directory);
      await writeFile(
        path.join(directory, "package.json"),
        JSON.stringify(manifest),
      );
      await expect(prepareWorkflowPackage({ directory })).rejects.toThrow(
        diagnostic,
      );
      console.log(`closed graph refused ${name}: ${diagnostic}`);
    }
    expect(requests).toEqual([]);
    console.log(`production registry requests: ${JSON.stringify(requests)}`);
  } finally {
    process.env = saved;
    await new Promise<void>((resolve, reject) =>
      registry.close((error) => (error ? reject(error) : resolve())),
    );
    await rm(root, { recursive: true, force: true });
  }
}, 180_000);
