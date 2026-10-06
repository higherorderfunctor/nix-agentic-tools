const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const assert = require("node:assert/strict");
const ts = require(process.env.TYPESCRIPT_JS);
const root = process.env.KIMCHI_SRC;
function nodes(rel, wanted) {
  const abs = path.join(root, rel),
    txt = fs.readFileSync(abs, "utf8"),
    sf = ts.createSourceFile(
      abs,
      txt,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TS,
    ),
    out = {};
  function v(n) {
    const name =
      ts.isFunctionDeclaration(n) ||
      ts.isMethodDeclaration(n) ||
      ts.isVariableDeclaration(n)
        ? n.name?.getText(sf)
        : undefined;
    if (name && wanted.includes(name)) out[name] = n.getText(sf);
    ts.forEachChild(n, v);
  }
  v(sf);
  return out;
}
function load(code, names, additions = "") {
  const js = ts.transpileModule(
    `${additions}\n${code}\n${names.map((n) => `exports.${n}=${n};`).join("\n")}`,
    {
      compilerOptions: {
        target: ts.ScriptTarget.ES2022,
        module: ts.ModuleKind.CommonJS,
      },
    },
  ).outputText;
  const box = { exports: {} };
  vm.runInNewContext(js, box);
  return box.exports;
}
const inv = nodes("src/extensions/agents/resolution/invocation-config.ts", [
  "resolveAgentInvocationConfig",
]);
const resolved = load(inv.resolveAgentInvocationConfig, [
  "resolveAgentInvocationConfig",
]).resolveAgentInvocationConfig;
const persona = {
  name: "P",
  description: "",
  extensions: true,
  skills: true,
  systemPrompt: "",
  promptMode: "replace",
  thinking: "low",
  maxTurns: 5,
  tokenBudget: 8000,
  maxDuration: 90,
  runInBackground: true,
};
const modelCases = [
  {
    name: "caller model is explicit",
    actual: resolved(persona, { model: "provider/child" }),
    want: { modelInput: "provider/child", modelFromParams: true },
  },
  {
    name: "no caller model is left for runner fallback",
    actual: resolved(persona, {}),
    want: { modelInput: undefined, modelFromParams: false },
  },
  {
    name: "persona policy fixes max turns despite larger caller request",
    actual: resolved(persona, { max_turns: 20 }),
    want: { maxTurns: 5 },
  },
  {
    name: "caller thinking overrides persona thinking",
    actual: resolved(persona, { thinking: "high" }),
    want: { thinking: "high" },
  },
  {
    name: "headless ignores persona background pin by default",
    actual: resolved(persona, {}, false),
    want: { runInBackground: false },
  },
  {
    name: "headless explicit opt-in backgrounds",
    actual: resolved(persona, { run_in_background: true }, false),
    want: { runInBackground: true },
  },
];
for (const c of modelCases)
  for (const [k, v] of Object.entries(c.want))
    assert.deepEqual(c.actual[k], v, `${c.name}.${k}`);
const runner = nodes("src/extensions/agents/manager/agent-runner.ts", [
  "isExcludedSubagentToolName",
  "getPromptToolNames",
]);
const excluded = [
  '"Agent"',
  '"resume_subagent"',
  '"get_subagent_result"',
  '"steer_subagent"',
  "...FERMENT_TOOL_NAMES",
].join(",");
const tools = load(
  `const FERMENT_TOOL_NAMES=['start_ferment_step','complete_ferment_step','list_ferments']; const EXCLUDED_TOOL_NAMES=[${excluded}]; ${runner.isExcludedSubagentToolName}\n${runner.getPromptToolNames}`,
  ["getPromptToolNames"],
);
const filtered = tools.getPromptToolNames([
  "read",
  "Agent",
  "resume_subagent",
  "get_subagent_result",
  "steer_subagent",
  "start_ferment_step",
  "list_ferments",
  "write",
]);
assert.deepEqual(Array.from(filtered), ["read", "write"]);
const manager = nodes("src/extensions/agents/manager/agent-manager.ts", [
  "abort",
]);
const cls = load(
  `class Harness { ${manager.abort} } exports.Harness=Harness;`,
  ["Harness"],
).Harness;
const queued = Object.create(cls.prototype);
queued.queue = [{ id: "q" }, { id: "other" }];
queued.agents = new Map([["q", { status: "queued" }]]);
assert.equal(queued.abort("q"), true);
assert.equal(queued.agents.get("q").status, "stopped");
assert.deepEqual(
  queued.queue.map((x) => x.id),
  ["other"],
);
const ctl = new AbortController(),
  running = Object.create(cls.prototype);
running.queue = [];
running.agents = new Map([["r", { status: "running", abortController: ctl }]]);
assert.equal(running.abort("r"), true);
assert.equal(ctl.signal.aborted, true);
assert.equal(running.agents.get("r").status, "stopped");
const active = Object.create(cls.prototype);
active.queue = [];
active.agents = new Map([["x", { status: "completed" }]]);
assert.equal(active.abort("x"), false);
console.log(
  JSON.stringify(
    {
      source: root,
      modelCases: modelCases.map(({ name, actual }) => ({
        name,
        result: {
          modelInput: actual.modelInput,
          modelFromParams: actual.modelFromParams,
          thinking: actual.thinking,
          maxTurns: actual.maxTurns,
          runInBackground: actual.runInBackground,
        },
      })),
      filteredChildTools: Array.from(filtered),
      abortCases: [
        "queued record removed from queue and stopped",
        "running record signal aborted and stopped",
        "completed record rejected",
      ],
      result: "all assertions passed",
    },
    null,
    2,
  ),
);
