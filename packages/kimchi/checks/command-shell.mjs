// Execute the patched registration and the real execution path offline.
// Only external collaborators are replaced; shell selection is observed where
// the actual tool hands its local operations to the process registry.
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
  getEntry() {},
  onRunningCountChange() {},
  persistOutput: () => "/output.log",
  snapshotSince: () => ({}),
  snapshotTail: () => ({ text: "" }),
  spawn: (operations) => {
    calls.push(operations.shellPath);
    return "handle";
  },
};
const dependencies = {
  "../../cli-args.js": { resolveBashProcessLimitSeconds() {} },
  "../../components/status-line.js": { SHELLS_STATUS_KEY: "shells" },
  "../../settings-watcher.js": {
    getSettingsManager: () => ({ getShellPath: () => shellPath }),
  },
  "../agents/subagent-bash-clamp.js": { DEFAULT_BASH_TIMEOUT_SECONDS: 120 },
  "../bash-tool-guard.js": { bashToolDescription: () => "bash" },
  "../e2e-seam.js": { readE2eSeam() {} },
  "../work-attribution/commits.js": {
    createWorkCommitTrackingOperations: (_ctx, _id, operations) => operations,
  },
  "./bash-control-tool.js": { BASH_CONTROL_TOOL_NAME: "bash_control" },
  "./bash-display.js": { createBashRenderers: () => ({}) },
  "./commands-panel.js": { CommandsPanel: class {} },
  "./process-registry.js": {
    createProcessRegistry: () => registry,
    DEFAULT_BASH_PROCESS_LIMIT_SECONDS: 3600,
    elapsedSecondsSince: () => 0,
  },
  "./review-coordinator.js": {
    createReviewCoordinator: () => ({
      awaitInitialHandoff: async () => "running",
      handleSpawned() {},
    }),
  },
  "./session-policy.js": { bashSessionKindFromContext: () => "unattended" },
  "./session-registry.js": { getSessionState() {}, setSessionState() {} },
  "./status-text.js": {
    handoffGuidanceText: () => "",
    outputLogNoticeText: () => "",
    runningResultText: () => "",
    terminalResultText: () => "",
  },
  "./terminal-delivery.js": { createTerminalDelivery: () => ({}) },
  "./terminal-status.js": { appendStatus() {}, throwIfTerminal() {} },
  "@earendil-works/pi-coding-agent": {
    createBashToolDefinition: () => ({ description: "bash" }),
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
  // Keep the registered tool on its real background execution path.
  getActiveTools: () => [
    dependencies["./bash-control-tool.js"].BASH_CONTROL_TOOL_NAME,
  ],
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
  sessionStart(
    {},
    {
      cwd: "/project",
      sessionManager: { getSessionId: () => "session" },
      ui: { setStatus() {} },
    },
  );
  const result = await registered.execute(
    "call",
    { command: "true" },
    undefined,
    undefined,
    {},
  );
  assert.equal(result.details.handoff, true);
  assert.deepEqual(calls.splice(0), [value]);
}
console.log(
  "PASS: configured and absent shellPath reach the spawned operations",
);
