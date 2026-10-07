const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const ts = require(process.env.TYPESCRIPT_JS);
const source = process.env.KIMCHI_WORKFLOWS_SRC;
const extracted = [];
function extract(relative, names) {
  const filename = path.join(source, relative);
  const text = fs.readFileSync(filename, "utf8");
  const tree = ts.createSourceFile(
    filename,
    text,
    ts.ScriptTarget.Latest,
    true,
  );
  return names
    .map((name) => {
      const declaration = tree.statements.find(
        (n) =>
          (ts.isFunctionDeclaration(n) && n.name?.text === name) ||
          (ts.isVariableStatement(n) &&
            n.declarationList.declarations.some(
              (d) =>
                ts.isIdentifier(d.name) &&
                d.name.text === name &&
                d.initializer &&
                (ts.isArrowFunction(d.initializer) ||
                  ts.isFunctionExpression(d.initializer)),
            )),
      );
      assert(declaration, `missing ${name}`);
      const startLine =
        tree.getLineAndCharacterOfPosition(declaration.getStart(tree)).line + 1;
      let snippet = declaration.getText(tree).replace(/^export /, "");
      if (ts.isVariableStatement(declaration)) {
        const variable = declaration.declarationList.declarations.find(
          (d) => ts.isIdentifier(d.name) && d.name.text === name,
        );
        snippet = `const ${name} = ${variable.initializer.getText(tree)};`;
      }
      extracted.push({ relative, name, startLine, source: snippet });
      return ts.transpileModule(snippet, {
        compilerOptions: {
          target: ts.ScriptTarget.ES2022,
          module: ts.ModuleKind.None,
        },
      }).outputText;
    })
    .join("\n");
}
const captured = [];
const context = {
  process: {
    argv: [
      "kimchi",
      "--system-prompt",
      "BASE_PARENT",
      "--append-system-prompt",
      "EXTRA_PARENT",
      "--skill",
      "PARENT_SKILL",
      "-e",
      "EXT_A",
      "--extension=EXT_B",
    ],
  },
  SUBMIT_RESULT_TOOL: "workflow_submit_result",
  SIGKILL_GRACE_MS: 5000,
  // Network, process creation, file-writing and model lookup are boundary stubs. Prompt functions remain unchanged.
  sessionPath: () => "/fixture/workflow-node.jsonl",
  claimResumeFile: () => () => {},
  stepSessionName: () => "fixture-node",
  resolveModel: () => true,
  writeStepOutputToolSpec: () => "/fixture/tool-contract.json",
  stepOutputToolsStem: () => "fixture",
  STEP_OUTPUT_TOOLS_ENV: "KIMCHI_WORKFLOW_STEP_OUTPUT_TOOLS",
  setTimeout: () => ({
    unref() {
      return this;
    },
  }),
  clearTimeout: () => {},
  removeStepOutputToolSpec: () => {},
  runSubagent: async (_spawn, command, args, message, _signal, env) => {
    captured.push({ command, args, message, env });
    return { code: 0, turn: { text: "fixture response" } };
  },
};
vm.createContext(context);
vm.runInContext(
  extract("src/flow/create-agent-step.ts", ["createAgentStep"]) +
    extract("src/flow/questionnaire.ts", ["buildOutputProtocol"]) +
    extract("src/engine/step-runner.ts", ["freshPrompt"]) +
    extract("src/engine/scheduler.ts", ["createConcurrencyGate"]) +
    extract("src/host/pi-agent.ts", [
      "inheritedExtensionArgs",
      "backgroundSession",
    ]) +
    extract("src/host/subagent-process.ts", ["killOnAbort"]),
  context,
);
(async () => {
  const schema = {
    type: "object",
    properties: { answer: { type: "string" } },
    required: ["answer"],
  };
  const ctx = { get: () => "UPSTREAM_VALUE" };
  const make = (extra) =>
    context.createAgentStep({
      name: "named-node",
      prompt: ({ input, ctx }) => `NODE_TASK ${input} ${ctx.get("prior")}`,
      ...extra,
    });
  const acting = context.freshPrompt(make({}), "INPUT_VALUE", ctx);
  const reporting = context.freshPrompt(
    make({ output: schema }),
    "INPUT_VALUE",
    ctx,
  );
  assert.equal(acting, "NODE_TASK INPUT_VALUE UPSTREAM_VALUE");
  assert(reporting.startsWith(acting + "\n\nSubmit your result"));
  assert.equal(reporting.split("NODE_TASK").length - 1, 1);
  assert(!reporting.includes("BASE_PARENT"));
  const empty = context.freshPrompt(
    context.createAgentStep({ name: "empty-node", prompt: () => "" }),
    undefined,
    ctx,
  );
  assert.equal(empty, "");
  for (const outputSchema of [undefined, schema]) {
    const request = {
      workflowName: "fixture",
      runId: "run",
      path: "node",
      stepName: "named-node",
      attempt: 1,
      outputSchema,
    };
    const session = context.backgroundSession(
      {},
      request,
      (args) => ({ command: "fixture-harness", args }),
      () => {
        throw new Error("must not spawn");
      },
      "/fixture",
    );
    await session.sendAndAwaitEnd(outputSchema ? reporting : acting);
  }
  const modeledRequest = {
    workflowName: "fixture",
    runId: "run-model",
    path: "model-node",
    stepName: "model-node",
    attempt: 1,
    model: "provider/model-id",
  };
  const modeled = context.backgroundSession(
    {},
    modeledRequest,
    (args) => ({ command: "fixture-harness", args }),
    () => {
      throw new Error("must not spawn");
    },
    "/fixture",
  );
  await modeled.sendAndAwaitEnd("MODEL_PROMPT");
  assert.deepEqual(Array.from(captured[2].args.slice(-2)), [
    "--model",
    "provider/model-id",
  ]);
  const agentStep = context.createAgentStep({
    name: "option-node",
    model: "provider/model-id",
    maxDurationMs: 1234,
    maxTokens: 55,
    background: true,
    asks: false,
    retry: { maxRetry: 2, backoffMs: 3 },
    maxOutputRepairs: 4,
    optional: true,
    resumable: "conversation-key",
    prompt: () => "x",
  });
  assert.equal(agentStep.model, "provider/model-id");
  assert.equal(agentStep.maxDurationMs, 1234);
  assert.equal(agentStep.maxTokens, 55);
  assert.equal(agentStep.background, true);
  assert.equal(agentStep.resumable, "conversation-key");
  const gate = context.createConcurrencyGate(2);
  await gate.acquire();
  await gate.acquire();
  let thirdAcquired = false;
  const third = gate.acquire().then(() => {
    thirdAcquired = true;
  });
  await Promise.resolve();
  assert.equal(thirdAcquired, false);
  gate.release();
  await third;
  assert.equal(thirdAcquired, true);
  gate.release();
  gate.release();
  const killed = [];
  const abortController = new AbortController();
  const stopKillWatch = context.killOnAbort(
    { kill: (signal) => killed.push(signal) },
    abortController.signal,
  );
  abortController.abort();
  assert.deepEqual(Array.from(killed), ["SIGTERM"]);
  stopKillWatch();
  assert(
    !captured.some((c) =>
      c.args.some((arg) =>
        /system-prompt|skill|BASE_PARENT|EXTRA_PARENT/.test(arg),
      ),
    ),
  );
  assert(!captured[0].args.includes("-e"));
  assert.equal(captured[1].args.filter((arg) => arg === "-e").length, 2);
  const result = {
    status: "VERIFIED",
    mode: "AST extraction executing unchanged pinned functions; subprocess and filesystem boundaries mocked",
    source,
    cases: {
      acting,
      reporting,
      empty,
      modeledArgs: captured[2].args,
      agentStepOptions: {
        model: agentStep.model,
        maxDurationMs: agentStep.maxDurationMs,
        maxTokens: agentStep.maxTokens,
        background: agentStep.background,
        resumable: agentStep.resumable,
      },
      concurrencyGate: {
        limit: gate.limit,
        queuedAcquireBlockedUntilRelease: true,
      },
      abortSignalKillsChild: killed,
    },
    inheritedExtensionArgs: context.inheritedExtensionArgs(),
    captured,
  };
  fs.writeFileSync(
    path.join(process.cwd(), "output.json"),
    JSON.stringify(result, null, 2) + "\n",
  );
  fs.writeFileSync(
    path.join(process.cwd(), "extracted.json"),
    JSON.stringify(extracted, null, 2) + "\n",
  );
  console.log(JSON.stringify(result, null, 2));
})().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
