// Prove the extensions.pr-watch resource gate in a Kimchi source tree.
// Called by pr-watch-resource.nix with the tree root as argv[2]. The real
// resource registry, store, filter and pr-watch session policy run here;
// only org policy (a network fetch), ACP host detection and the
// definitions' constant and discovery imports are stubbed. cli.ts and the
// ACP server are too large to load, so their wiring is checked as source.
import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, normalize } from "node:path";
import { SourceTextModule, SyntheticModule } from "node:vm";

const root = process.argv[2];
const resource = "extensions.pr-watch";
let acpHost = false;
const scratch = mkdtempSync(join(tmpdir(), "kimchi-pr-watch-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
let scenarios = 0;

const realModules = new Set([
  "src/config/json",
  "src/extensions/pr-watch/resource",
  "src/extensions/pr-watch/session-policy",
  "src/resources/definitions",
  "src/resources/filter",
  "src/resources/store",
  "src/resources/types",
]);
const stubs = {
  "src/extensions/claude-code-skills/definition": {
    CLAUDE_CODE_SKILLS_RESOURCE_ID: "skills.stub-claude-code",
  },
  "src/extensions/ferment-v2/constants": {
    FERMENT_V2_RESOURCE_ID: "extensions.stub-ferment-v2",
  },
  "src/extensions/mcp/gateway": {
    KIMCHI_MCP_GATEWAY_RESOURCE_ID: "plugins.stub-mcp-gateway",
  },
  "src/extensions/memory/config": {
    MEMORY_RESOURCE_ID: "extensions.stub-memory",
  },
  "src/extensions/pi-package-lookup/index": {
    PI_PACKAGE_LOOKUP_RESOURCE_ID: "extensions.stub-pi-package-lookup",
  },
  "src/extensions/pii-redaction/resource": {
    PII_REDACTION_RESOURCE_ID: "extensions.stub-pii-redaction",
  },
  "src/extensions/side-chat/resource": {
    SIDE_CHAT_PILL_RESOURCE_ID: "extensions.stub-side-chat-pill",
  },
  "src/extensions/work-attribution/resource": {
    COST_PER_PR_RESOURCE_ID: "extensions.stub-cost-per-pr",
  },
  "src/modes/acp/state": { isAcpSessionHost: () => acpHost },
  "src/org-policy": { getOrgPolicy: () => undefined },
  "src/resources/bash-hook-discovery": { discoverBashHookResources: () => [] },
  "src/resources/claude-code-hook-resources": {
    discoverClaudeCodeHookResourceDefinitions: () => [],
  },
  "src/resources/kimchi-hook-resources": {
    discoverKimchiHookResourceDefinitions: () => [],
  },
  "src/resources/package-resources": { discoverPackageResources: () => [] },
};

const modules = new Map();
function synthetic(values) {
  return new SyntheticModule(Object.keys(values), function () {
    for (const [key, value] of Object.entries(values))
      this.setExport(key, value);
  });
}
async function link(specifier, referrer) {
  if (specifier.startsWith("node:"))
    return synthetic({ ...(await import(specifier)) });
  const id = normalize(
    join(dirname(referrer.identifier), specifier.replace(/\.js$/, "")),
  );
  if (!modules.has(id)) {
    assert.ok(realModules.has(id) || stubs[id], `unexpected import: ${id}`);
    modules.set(
      id,
      stubs[id]
        ? synthetic(stubs[id])
        : new SourceTextModule(
            stripTypeScriptTypes(readFileSync(join(root, `${id}.ts`), "utf8")),
            { identifier: id },
          ),
    );
  }
  return modules.get(id);
}
async function load(id) {
  const module = await link(`./${id}.js`, { identifier: "." });
  await module.link(link);
  await module.evaluate();
  return module.namespace;
}
function withResources({ env, settings }, run) {
  const agentDir = join(scratch, String(scenarios++));
  mkdirSync(agentDir);
  writeFileSync(
    join(agentDir, "settings.json"),
    JSON.stringify({ resources: settings ?? {} }),
  );
  process.env.KIMCHI_CODING_AGENT_DIR = agentDir;
  if (env === undefined) delete process.env.KIMCHI_ENABLE_RESOURCES;
  else process.env.KIMCHI_ENABLE_RESOURCES = env;
  run();
}

const { enabledExtensionFactories } = await load("src/resources/filter");
const factory = (id) => ({ id, factory: id });
const enabledIds = (ids) => enabledExtensionFactories(ids.map(factory));
const managed = [resource, "extensions.remote-run", "extensions.teleport"];

// Fails on a missing definition (unknown ids default on) or defaultEnabled true.
withResources({}, () =>
  assert.deepEqual(enabledIds(managed), [
    "extensions.remote-run",
    "extensions.teleport",
  ]),
);
// Fails when the resource cannot be enabled through either delivery path:
// Home Manager writes settings.json, devenv sets KIMCHI_ENABLE_RESOURCES.
for (const delivery of [{ env: resource }, { settings: { [resource]: true } }])
  withResources(delivery, () =>
    assert.deepEqual(enabledIds([resource]), [resource]),
  );

const policy = await load("src/extensions/pr-watch/session-policy");
// Fails when the extension's own gate ignores the resource, which would leave
// ACP sessions (and any caller outside cli.ts's list) watching PRs.
for (const host of [false, true]) {
  acpHost = host;
  policy.setPRMonitoringPermitted(true);
  withResources({}, () => {
    assert.equal(policy.isPRWatchResourceEnabled(), false);
    assert.equal(policy.isPRMonitoringPermitted(), false);
  });
  withResources({ env: resource }, () => {
    assert.equal(policy.isPRMonitoringPermitted(), true);
    policy.setPRMonitoringPermitted(false);
    assert.equal(policy.isPRMonitoringPermitted(), !host);
  });
}

// Fails when cli.ts still lists the extension outside enabledExtensionFactories.
const cli = readFileSync(join(root, "src/cli.ts"), "utf8");
assert.match(cli, /\{ id: PR_WATCH_RESOURCE_ID, factory: prWatchExtension \}/);
assert.equal(cli.match(/\bprWatchExtension\b/g).length, 2);
// Fails when an ACP site trusts the client's opt-in without the resource.
// initialize's setPRMonitoringPermitted is covered by isPRMonitoringPermitted.
const server = readFileSync(join(root, "src/modes/acp/server.ts"), "utf8");
assert.match(
  server,
  /\[PR_MONITORING_CAPABILITY\]: isPRWatchResourceEnabled\(\),/,
);
const optIns = server
  .match(/^.*getClientOptedIntoPRMonitoring\(.*$/gm)
  .filter((line) => !line.includes("setPRMonitoringPermitted("));
assert.ok(optIns.length > 0, "no ACP opt-in sites found; reassess the check");
for (const line of optIns)
  assert.match(
    line,
    /isPRWatchResourceEnabled\(\) && getClientOptedIntoPRMonitoring\(/,
  );

console.log(
  "PASS: pr-watch stays off by default and every entry point honours its resource",
);
