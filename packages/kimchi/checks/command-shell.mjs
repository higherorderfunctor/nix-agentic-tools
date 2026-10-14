// Execute the patched registration and both real execution branches offline.
// Only external collaborators are replaced; shell selection is observed where
// the actual tool hands its local operations to Pi or the process registry.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { join } from "node:path";
import { SourceTextModule, SyntheticModule } from "node:vm";

const root = process.argv[2];
const paths = {
  "./bash-background-tool.js":
    "src/extensions/bash-background/bash-background-tool.ts",
  entry: "src/extensions/bash-background/index.ts",
};
const modules = new Map();
const calls = [];
let shellPath;
let registered;
let sessionStart;
const registry = {
  displaySnapshot: () => ({}),
  spawn: (operations) => {
    calls.push(["background", operations.shellPath]);
    return "handle";
  },
};
const dependencies = {
  "../../settings-watcher.js": {
    getSettingsManager: () => ({ getShellPath: () => shellPath }),
  },
  "../bash-tool-guard.js": { bashToolDescription: () => "bash" },
  "../work-attribution/commits.js": {
    createWorkCommitTrackingOperations: (_ctx, _id, operations) => operations,
  },
  "./bash-display.js": { renderBashCall() {}, renderBashResult() {} },
  "./checkin.js": {
    awaitCheckin: async () => ({ state: "running", text: "" }),
  },
  "./commands-panel.js": { CommandsPanel: class {} },
  "./process-registry.js": { createProcessRegistry: () => registry },
  "./session-registry.js": {
    getSessionRegistry: () => registry,
    setSessionRegistry() {},
  },
  "./terminal-status.js": { throwIfTerminal() {} },
  "@earendil-works/pi-coding-agent": {
    createBashToolDefinition: (_cwd, options) => ({
      description: "bash",
      execute: async () => {
        calls.push(["short", options.operations.shellPath]);
        return { content: [] };
      },
    }),
    createLocalBashOperations: (options) => options,
  },
  typebox: {
    Type: Object.fromEntries(
      ["Number", "Object", "Optional", "String"].map((key) => [
        key,
        () => ({}),
      ]),
    ),
  },
};
function load(name) {
  if (!modules.has(name)) {
    const values = dependencies[name];
    assert.ok(paths[name] || values, `unexpected dependency: ${name}`);
    modules.set(
      name,
      paths[name]
        ? new SourceTextModule(
            stripTypeScriptTypes(readFileSync(join(root, paths[name]), "utf8")),
            { identifier: name },
          )
        : new SyntheticModule(Object.keys(values), function () {
            for (const [key, value] of Object.entries(values))
              this.setExport(key, value);
          }),
    );
  }
  return modules.get(name);
}
const entry = load("entry");
await entry.link(load);
await entry.evaluate();
entry.namespace.bashBackgroundExtension({
  on: (event, callback) => {
    if (event === "session_start") sessionStart = callback;
  },
  registerCommand() {},
  registerTool: (tool) => {
    registered = tool;
  },
});
for (const value of ["/configured/shell", undefined]) {
  shellPath = value;
  sessionStart({}, { cwd: "/project" });
  for (const timeout of [1, 30]) {
    await registered.execute(
      "call",
      { command: "true", timeout },
      undefined,
      undefined,
      {},
    );
  }
  assert.deepEqual(calls.splice(0), [
    ["short", value],
    ["background", value],
  ]);
}
console.log(
  "PASS: configured and absent shellPath reach short and background operations",
);
