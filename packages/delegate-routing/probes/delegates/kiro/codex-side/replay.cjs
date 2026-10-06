const { fs, nodes, code, named } = require("./ast.cjs");
const vm = require("vm"),
  assert = require("assert"),
  crypto = require("crypto");
const bundle = `${process.env.KIRO_BUNDLES}/kas.js`; // from ../bundles.py
assert.equal(
  crypto.createHash("sha256").update(fs.readFileSync(bundle)).digest("hex"),
  "79a1a743ee7236a71bba9c6c68342deccfcffea4d61361eae0254288339b19c8",
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
  Df: () => ({
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
  Ipe: new Set(["max"]),
  hD: "off",
  Ppe: "on",
});
fn("zOn");
fn("HOn");
log("effort-resolver", {
  registeredDefault: ctx.zOn("B", undefined, "default").effortLevel,
  inlineDefault: ctx.zOn("B", undefined, "belowMax").effortLevel,
  inlineUnsupported: ctx.zOn("B", "bogus", "belowMax").effortLevel,
  inlineLow: ctx.zOn("B", "low", "belowMax").effortLevel,
  autoIgnores: ctx.zOn("auto", "low").effortLevel === undefined,
});
assert.equal(ctx.zOn("B", "bogus", "belowMax").effortLevel, "high");
Object.assign(ctx, {
  sX: (x) => ({ modelId: x }),
  Gl: () => "fixture-child",
  J_t: (x) => x,
  Brt: (x) => x,
  mGi: async (x) => x,
  Yee: () => "FALLBACK",
  Y_t: () => undefined,
  Iwe: { id: "other" },
  vGi: () => ({
    needsFileTree: false,
    buildDefinition: async (x) => ({ input: x, type: "custom-agent" }),
    extractResult: () => ({ response: "RESULT", files: [] }),
  }),
  $1: (t) => ({ agent: t.id }),
  HOn: ctx.HOn,
  zOn: ctx.zOn,
  w: { info() {}, debug() {}, warn() {} },
  Un: () => false,
  JRr: () => 1000,
  dCc: new Set(),
  Rr: { isSuccess: (x) => x === "Success" },
});
const workspace = {
  withToolPolicy: (p) => ({ ...workspace, policy: p }),
  withContext: (c) => ({ ...workspace, context: c }),
};
const launched = [];
ctx.e3e = (definition, opts) => {
  launched.push({ definition, opts });
  return {
    executionId: "fixture-child",
    activity: { idleMs: () => 0, bump() {} },
    invoke() {},
    waitForCompletion: async () => ({ status: "success" }),
  };
};
fn("Iki");
const dispatch = fn("sEt");
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
  ctx.Ljn = () => ({ promise: Promise.resolve(), resolve() {}, reject() {} });
  const construct = method("constructor", 12162);
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
  ctx.Nji = new WeakMap();
  ctx.eIr = 5;
  ctx.Mji = {
    Sema: class {
      constructor(n) {
        this.capacity = n;
      }
    },
  };
  const sem = fn("Lwe");
  const p1 = {},
    p2 = {};
  assert.strictEqual(sem(p1), sem(p1));
  assert.notStrictEqual(sem(p1), sem(p2));
  log("concurrency", {
    perExecutionCapacity: sem(p1).capacity,
    perExecutionNotGlobal: true,
  });
  fn("Gji");
  ctx.qji = 5;
  ctx.e = { id: "invoke_sub_agent" };
  ctx.I$e = () => ({});
  ctx.Bi = (x) => x.decision === "reject";
  ctx.Pc = () => "permission-denied";
  ctx.Mt = {
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
  const invoke = method("handle", 15930);
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
  ctx.ZRr = "KIRO_SUBAGENT_DEADLINE_MS";
  ctx.XRr = 3600000;
  ctx.Mja = 2147483647;
  fn("yU");
  fn("JRr");
  log("deadline-env", {
    default: ctx.JRr({}),
    zero: ctx.JRr({ KIRO_SUBAGENT_DEADLINE_MS: "0" }),
    valid: ctx.JRr({ KIRO_SUBAGENT_DEADLINE_MS: "123" }),
    invalid: ctx.JRr({ KIRO_SUBAGENT_DEADLINE_MS: "-1" }),
  });
  const timeout = await ctx.Iki(
    new Promise(() => {}),
    5,
    { idleMs: () => 10 },
    () => {},
  );
  assert(timeout.timedOut);
  log("idle-timeout", { timedOut: timeout.timedOut });
  ctx.w = { debug() {}, info() {} };
  ctx.Da = (x) => x;
  ctx.Iq = (kind, id) => id;
  ctx.oAe = /^NOTIFY/;
  ctx.G6 = { randomUUID: () => "id" };
  const steer = method("handleSessionSteer", 17817);
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
