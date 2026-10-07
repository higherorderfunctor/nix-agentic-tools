const { fs, nodes, code, named } = require("./ast.cjs");
const vm = require("vm"),
  assert = require("assert"),
  crypto = require("crypto");
const bundle = `${process.env.KIRO_BUNDLES}/kas.js`; // from ../bundles.py
assert.equal(
  crypto.createHash("sha256").update(fs.readFileSync(bundle)).digest("hex"),
  "3bc21b1f684cd3cc4aa0e10f198a5f97ea41398a63ed5db1858d4145fbe42828",
);
const report = [];
const log = (test, values) => report.push({ test, ...values });
const ctx = vm.createContext({
  console,
  process,
  Map,
  Set,
  WeakMap,
  AbortController,
  Date,
  Promise,
  setTimeout,
  clearTimeout,
});
const fn = (name) => {
  const n = named(name);
  assert(n, name);
  vm.runInContext(code(n), ctx);
  return ctx[name];
};
const method = (name, line) => {
  const n = nodes.find(
    (n) =>
      n.type === "MethodDefinition" &&
      n.key.name === name &&
      n.loc.start.line === line,
  );
  assert(n, name);
  return vm.runInContext("({" + code(n) + "})", ctx)[name];
};
Object.assign(ctx, {
  qp: () => ({
    models: [
      {
        id: "A",
        effortLevels: ["low", "medium", "high"],
        defaultEffortLevel: "low",
        effortSchemaPath: "a.effort",
      },
      {
        id: "B",
        effortLevels: ["low", "medium", "high", "max"],
        defaultEffortLevel: "medium",
        effortSchemaPath: "b.effort",
      },
    ],
  }),
  Yfe: new Set(["max"]),
  D1: "off",
  Xfe: "on",
});
fn("AUn");
fn("RUn");
log("effort-resolver", {
  registeredDefault: ctx.AUn("B", undefined, "default").effortLevel,
  inlineDefault: ctx.AUn("B", undefined, "belowMax").effortLevel,
  inlineUnsupported: ctx.AUn("B", "bogus", "belowMax").effortLevel,
  inlineLow: ctx.AUn("B", "low", "belowMax").effortLevel,
  autoIgnores: ctx.AUn("auto", "low").effortLevel === undefined,
});
assert.equal(ctx.AUn("B", "bogus", "belowMax").effortLevel, "high");
Object.assign(ctx, {
  eZ: (x) => ({ modelId: x }),
  Vl: () => "fixture-child",
  git: (x) => x,
  Qfe: (x) => x,
  xbt: (x) => x,
  XQi: async (x) => x,
  Qte: () => "FALLBACK",
  aTt: () => undefined,
  cEe: { id: "other" },
  eeo: () => ({
    needsFileTree: false,
    buildDefinition: async (x) => ({ input: x, type: "custom-agent" }),
    extractResult: () => ({ response: "RESULT", files: [] }),
  }),
  Zk: (t) => ({ agent: t.id }),
  RUn: ctx.RUn,
  AUn: ctx.AUn,
  v: { info() {}, debug() {}, warn() {} },
  An: () => false,
  CUe: { reportCountMetrics() {} },
  aOr: () => 1000,
  WLc: new Set(),
  Pr: { isSuccess: (x) => x === "Success" },
});
const workspace = {
  withToolPolicy: (p) => ({ ...workspace, policy: p }),
  withContext: (c) => ({ ...workspace, context: c }),
};
const launched = [];
ctx.y4e = (definition, opts) => {
  launched.push({ definition, opts });
  return {
    executionId: "fixture-child",
    activity: { idleMs: () => 0, bump() {} },
    invoke() {},
    waitForCompletion: async () => ({ status: "success" }),
  };
};
fn("cOi");
const dispatch = fn("mTt");
const parent = {
  workspace,
  model: { modelId: "A", effortLevel: "high", thinkingType: "on" },
  sessionServices: { shellTypeInfo: {}, promptTemplateContext: {} },
  getEventSink: () => ({
    registerSubAgentExecution() {},
    unregisterSubAgentExecution() {},
  }),
  getAgentContext: () => ({}),
  getAgentMode: () => "vibe",
  abortController: new AbortController(),
  subExecutionDepth: 2,
  steering: ["STEERING"],
  repositories: [],
  registerActiveChild() {},
  unregisterActiveChild() {},
};
async function main() {
  for (const [name, def, inline] of [
    [
      "registered",
      { id: "worker", prompt: "PROMPT", model: "B", effortLevel: "low" },
    ],
    [
      "inline",
      { id: "anonymous", prompt: "INLINE" },
      { resolvedModelId: "B", effort: "bogus" },
    ],
    ["inherit", { id: "worker", prompt: "PROMPT" }],
  ]) {
    const result = await dispatch({
      definition: def,
      caller: "test",
      agentName: def.id,
      prompt: "TASK",
      parentExecution: parent,
      registry: {},
      contextProviderRegistry: {},
      events: { forwardToParent: false },
      ...(inline ? { inline } : {}),
    });
    assert.equal(result.kind, "success");
    const c = launched.at(-1);
    log("dispatch-" + name, {
      result,
      model: c.opts.model,
      depth: c.opts.subExecutionDepth,
      sameWorkspace: c.definition.input.workspace === workspace,
      toolPolicy: c.opts.workspace.policy,
      context: c.opts.workspace.context,
      sharedSignal: c.opts.signal === parent.abortController.signal,
    });
  }
  assert.equal(launched[0].opts.model.modelId, "B");
  assert.equal(launched[0].opts.model.effortLevel, "low");
  assert.equal(launched[1].opts.model.effortLevel, "high");
  assert.strictEqual(launched[2].opts.model, parent.model);
  // Execute the real native-KAS constructor body against fixture services.
  ctx.dei = () => ({ promise: Promise.resolve(), resolve() {}, reject() {} });
  const construct = method("constructor", 12178);
  function child(signal) {
    const c = {
      abortController: new AbortController(),
      isCompleted: () => false,
    };
    construct.call(c, {
      signal,
      workspace: { withContext: () => ({}) },
      sessionServices: {},
      model: {},
      controller: {},
    });
    return c;
  }
  const root = new AbortController(),
    c = child(root.signal),
    g = child(c.abortController.signal);
  root.abort();
  assert(c.abortController.signal.aborted && g.abortController.signal.aborted);
  log("cancel-signal-tree", {
    childAborted: c.abortController.signal.aborted,
    grandchildAborted: g.abortController.signal.aborted,
  });
  ctx.lto = new WeakMap();
  ctx.uOr = 5;
  ctx.dto = {
    Sema: class {
      constructor(n) {
        this.capacity = n;
      }
    },
  };
  const sem = fn("hEe");
  const p1 = {},
    p2 = {};
  assert.strictEqual(sem(p1), sem(p1));
  assert.notStrictEqual(sem(p1), sem(p2));
  log("concurrency", {
    perExecutionCapacity: sem(p1).capacity,
    perExecutionNotGlobal: true,
  });
  fn("_k");
  ctx.Ito = 5;
  ctx.Dto = () => ({ kind: "missing" });
  ctx.e = { id: "invoke_sub_agent" };
  ctx.D3e = () => ({});
  ctx.qi = (x) => x.decision === "reject";
  ctx.Mc = () => "permission-denied";
  ctx.Ot = {
    of: (status, message) =>
      new Proxy(
        { status, message },
        {
          get(t, p) {
            if (p === "then") return undefined;
            return p in t
              ? t[p]
              : (...args) => {
                  if (p === "withOutput") t.output = args[0];
                  return new Proxy(t, this);
                };
          },
        },
      ),
  };
  const invoke = method("handle", 15961);
  for (const depth of [4, 5, 6]) {
    const receiver = {
      id: "invoke_sub_agent",
      config: {
        registry: { getWorkspaceRoot() {} },
        generateOperationId: (x) => x,
        acpToolApproval: async () => ({ decision: "reject" }),
      },
      origin: "fixture",
      tags: [],
      emitProgress() {},
      concludeToolUse: (r, n, m) => m,
    };
    const r = await invoke.call(receiver, {
      input: { name: "worker", prompt: "TASK" },
      state: {
        execution: {
          subExecutionDepth: depth,
          clearToolDispatch() {},
          registerToolDispatch() {},
        },
      },
      actionId: "test",
    });
    log("depth-" + depth, { status: r.status, message: r.message });
    assert.equal(r.status, depth < 5 ? "Rejected" : "Error");
  }
  ctx.sOr = "KIRO_SUBAGENT_DEADLINE_MS";
  ctx.oOr = 3600000;
  ctx.Lrc = 2147483647;
  fn("UU");
  fn("aOr");
  log("deadline-env", {
    default: ctx.aOr({}),
    zero: ctx.aOr({ KIRO_SUBAGENT_DEADLINE_MS: "0" }),
    valid: ctx.aOr({ KIRO_SUBAGENT_DEADLINE_MS: "123" }),
    invalid: ctx.aOr({ KIRO_SUBAGENT_DEADLINE_MS: "-1" }),
  });
  const timeout = await ctx.cOi(
    new Promise(() => {}),
    5,
    { idleMs: () => 10 },
    () => {},
  );
  assert(timeout.timedOut);
  log("idle-timeout", { timedOut: timeout.timedOut });
  ctx.v = { debug() {}, info() {} };
  ctx.va = (x) => x;
  ctx.iz = (kind, id) => id;
  ctx.tRe = /^NOTIFY/;
  ctx.gB = { randomUUID: () => "id" };
  const steer = method("handleSessionSteer", 17809);
  const buffer = [],
    updates = [];
  const result = await steer.call(
    {
      sessionState: () => ({
        steeringEpoch: 0,
        workspacePaths: [],
        steeringBuffer: { append: (...x) => buffer.push(x) },
      }),
      messageStore: { appendMessages: async () => {} },
      broadcastOutboundFor: () => ({ sessionUpdate: (x) => updates.push(x) }),
    },
    { sessionId: "session", message: "MIDRUN" },
  );
  assert(result.queued);
  log("steer-buffer", { result, buffer, updates });
  fs.writeFileSync(
    process.cwd() + "/replay-results.json",
    JSON.stringify(report, null, 2),
  );
  console.log(JSON.stringify(report, null, 2));
}
main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
