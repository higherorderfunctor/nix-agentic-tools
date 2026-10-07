const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const vm = require("node:vm");
const {
  parse,
  readChunks,
  selectFunction: chooseFunction,
  walk,
} = require("../bundle.cjs");
const root = process.argv[2];
if (!root) throw new Error("usage: prompt-replay.cjs <unpacked-dir>");
const chunks = readChunks(root);
const selectFunction = (...terms) => chooseFunction(chunks, terms);
const carrier = selectFunction(
  "[bridge:carrier]",
  "CLAUDE_CODE_BRIDGE_PROMPT_SHA256",
);
const active = selectFunction(
  "CLAUDE_CODE_BRIDGE_PROMPT_SHA256",
  "isBridgeCarrierChild",
  "return a.",
);
const bytes = Buffer.from("APPFILE-9999");
const digest = crypto.createHash("sha256").update(bytes).digest("hex");
const carrierCases = [
  ["ordinary file", false, undefined, "APPFILE-9999"],
  ["carrier missing digest", true, undefined, undefined],
  ["carrier mismatched digest", true, "0".repeat(64), undefined],
  ["carrier matching digest", true, digest, "APPFILE-9999"],
  ["digest case insensitive", true, digest.toUpperCase(), "APPFILE-9999"],
].map(([label, isBridgeCarrierChild, hash, expected]) => {
  const env = { CLAUDE_CODE_BRIDGE_PROMPT_SHA256: hash };
  const context = vm.createContext({
    a: { ...env, unset: (key) => delete env[key] },
    tb: { isBridgeCarrierChild },
    hLo: crypto.createHash,
    t: () => {},
    bytes,
  });
  vm.runInContext(`${active.text};${carrier.text}`, context);
  const value = vm.runInContext(`${carrier.node.id.name}(bytes)`, context);
  assert.equal(value, expected, label);
  assert.equal(
    env.CLAUDE_CODE_BRIDGE_PROMPT_SHA256,
    undefined,
    "digest consumed",
  );
  return { label, result: value ?? null };
});
const child = selectFunction(
  "appendSubagentSystemPrompt",
  "SubagentStart hooks cancelled",
);
const candidates = [];
walk(child.node, (node) => {
  if (
    node.type !== "VariableDeclarator" ||
    node.init?.type !== "ConditionalExpression"
  )
    return;
  const expression = child.source.slice(node.init.start, node.init.end);
  if (
    expression.includes("appendSubagentSystemPrompt") &&
    expression.includes("isolatedContext")
  )
    candidates.push(expression);
});
assert.equal(candidates.length, 1, "expected one subagent append gate");
const appendCases = [
  ["ordinary child", false, false, true, "SUBAPP-1414"],
  ["isolated child", false, true, true, undefined],
  ["fork child", true, false, true, undefined],
  ["SDK gate disabled", false, false, false, undefined],
].map(([label, Z, isolatedContext, enabled, expected]) => {
  const context = vm.createContext({
    Z,
    O: { isolatedContext },
    Le: () => enabled,
    process: { env: {} },
    n: { options: { appendSubagentSystemPrompt: "SUBAPP-1414" } },
  });
  const value = vm.runInContext(candidates[0], context);
  assert.equal(value, expected, label);
  return { label, result: value ?? null };
});
// Title generation uses its fixed body, without the session append channel.
const title = selectFunction("generateSessionTitle failed:", "systemPrompt:");
const titleHelper = selectFunction(
  'querySource:"generate_session_title"',
  "hasAppendSystemPrompt:!1",
);
const titleAst = parse(title.source);
const titleConstant = titleAst.body
  .filter((node) => node.type === "VariableDeclaration")
  .flatMap((node) => node.declarations)
  .find(
    (node) =>
      node.init?.type === "TemplateLiteral" &&
      title.source
        .slice(node.start, node.end)
        .includes("You are naming a coding session"),
  );
assert.ok(titleConstant, "fixed session title body missing");
const titleContext = vm.createContext({
  _: 10,
  d: 2000,
  E: () => false,
  lt: () => ({}),
  i: () => {},
  t: () => {},
  ci: (blocks) => blocks,
  Ee: () => false,
  ol: () => ({}),
  uo: () => "title",
  LG: (value) => value,
  ft: (value) => value,
  b: () => ({
    safeParse: () => ({ success: true, data: { title: "Probe title" } }),
  }),
  SM: async (request) => {
    titleContext.request = request;
    return { message: { content: [] } };
  },
});
vm.runInContext(
  `var ${title.source.slice(titleConstant.start, titleConstant.end)};${titleHelper.text};${title.text}`,
  titleContext,
);
vm.runInContext(
  `${title.node.id.name}("APPINLINE-1313 name this session", undefined, undefined)`,
  titleContext,
)
  .then((result) => {
    assert.equal(result, "Probe title");
    assert.equal(titleContext.request.options.hasAppendSystemPrompt, false);
    assert.ok(
      titleContext.request.systemPrompt[0].startsWith(
        "You are naming a coding session",
      ),
    );
    assert.ok(!titleContext.request.systemPrompt[0].includes("APPINLINE-1313"));
    console.log(
      JSON.stringify(
        {
          carrier: `${carrier.file}:${carrier.node.id.name}`,
          carrierCases,
          child: `${child.file}:${child.node.id.name}`,
          appendExpression: candidates[0],
          appendCases,
          title: `${title.file}:${title.node.id.name}`,
          titleAppend: false,
        },
        null,
        2,
      ),
    );
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
