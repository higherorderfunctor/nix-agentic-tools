#!/usr/bin/env node
const assert = require("node:assert/strict");
const vm = require("node:vm");
// codex:A — executes the pinned depth resolver and Agent boundary in a VM.
// usage: NODE_PATH=<dir with acorn@8> node verify_depth.js <unpacked-dir>   (<unpacked-dir> from ../unpack.sh)
const {
  findFunction,
  findVars,
  parse,
  readChunks,
  selectSource: chooseSource,
  walk,
} = require("../bundle.cjs");

const unpacked = process.argv[2];
if (!unpacked) {
  console.error("usage: node verify_depth.js <unpacked-dir>");
  process.exit(2);
}
const chunks = readChunks(unpacked);
const selectSource = (...terms) => chooseSource(chunks, terms);

// Reuse the exact upstream H.int parsing implementation and its numeric helper.
const parserSource = selectSource("function d(", "digitsOnly");
const numberSource = selectSource("function ed(", "function Lgo(");
const parserHelpers = [
  findFunction(parserSource, "i"),
  findFunction(parserSource, "u"),
  findFunction(parserSource, "d"),
  findFunction(numberSource, "ed"),
  findFunction(numberSource, "Lgo"),
  findVars(numberSource, ["N", "E", "c"]),
].join("\n");
const parserContext = vm.createContext({});
vm.runInContext(parserHelpers, parserContext);
const parsedEnv = vm.runInContext("d({min:1,digitsOnly:true})", parserContext);

// Select the resolver by its env read, then inject only its two Bun modules.
// The cache, validation, fallback and precedence remain the pinned source.
const resolverSource = selectSource(
  "tengu_hazel_trellis",
  "maxSubagentSpawnDepthFromGrowthBook",
);
const resolverAst = parse(resolverSource);
const resolverNode = resolverAst.body.find(
  (item) =>
    item.type === "FunctionDeclaration" &&
    resolverSource
      .slice(item.start, item.end)
      .includes("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"),
);
if (!resolverNode) throw new Error("missing depth resolver");
let resolver = resolverSource.slice(resolverNode.start, resolverNode.end);
const calls = [];
walk(resolverNode, (node) => {
  if (
    node.type !== "CallExpression" ||
    node.callee.type !== "MemberExpression" ||
    node.callee.property.name !== "require"
  )
    return;
  const object = node.callee.object;
  if (
    object.type === "MetaProperty" &&
    object.meta.name === "import" &&
    object.property.name === "meta"
  ) {
    calls.push(node);
  }
});
if (calls.length !== 2)
  throw new Error(
    `expected two import.meta.require calls, found ${calls.length}`,
  );
for (const call of calls.toReversed()) {
  resolver =
    resolver.slice(0, call.start - resolverNode.start) +
    "globalThis.__growthBookModule" +
    resolver.slice(call.end - resolverNode.start);
}
const constants = findVars(resolverSource, ["n", "_"]);

function resolveDepth(rawEnv, featureValue, cachedValue) {
  const normalized =
    rawEnv === Symbol.for("absent") ? undefined : parsedEnv.parse(rawEnv);
  const state = {};
  const context = vm.createContext({
    a: { CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: normalized },
    So: () => state,
    __growthBookModule: {
      getCachedClientData: () => ({ tengu_hazel_trellis: cachedValue }),
      getFeatureValue_CACHED_MAY_BE_STALE: (_key, fallback) =>
        featureValue === undefined ? fallback : featureValue,
    },
  });
  vm.runInContext(
    `${constants};${findFunction(resolverSource, "u")};${resolver};`,
    context,
  );
  return {
    parsedEnv: normalized ?? null,
    cap: vm.runInContext(`${resolverNode.id.name}()`, context),
    growthBookState: state.maxSubagentSpawnDepthFromGrowthBook ?? null,
  };
}

// AST-select and execute the actual boundary expression used to withhold Agent.
const gateSource = selectSource("spawn_depth_cap", "declared_agent_withheld");
const gateAst = parse(gateSource);
const gates = [];
walk(gateAst, (node) => {
  if (
    node.type === "BinaryExpression" &&
    node.operator === ">=" &&
    node.left.type === "Identifier" &&
    node.left.name === "h" &&
    node.right.type === "CallExpression" &&
    node.right.callee.type === "Identifier" &&
    node.right.callee.name === resolverNode.id.name
  ) {
    gates.push(node);
  }
});
if (gates.length !== 1)
  throw new Error(`expected one depth boundary, found ${gates.length}`);
const gateExpr = gateSource.slice(gates[0].start, gates[0].end);
function blockedAt(depth, cap) {
  const context = vm.createContext({
    h: depth,
    [resolverNode.id.name]: () => cap,
  });
  return vm.runInContext(gateExpr, context);
}

const absent = Symbol.for("absent");
const results = {
  resolverCases: [
    ["env absent", absent, undefined],
    ["env 0 rejected by H.int min=1", "0", undefined],
    ["env 1", "1", undefined],
    ["env 2", "2", undefined],
    ["env negative rejected", "-2", undefined],
    ["env non-numeric rejected", "abc", undefined],
    ["growthbook 1", absent, 1],
    ["growthbook 2", absent, 2],
    ["growthbook 0 rejected", absent, 0],
    ["growthbook negative rejected", absent, -2],
    ["growthbook fractional rejected", absent, 1.5],
    ["cached value beats feature", absent, 2, 1],
    ["invalid cache falls back to feature", absent, 2, 0],
    ["env beats cached value", "2", 1, 1],
  ].map(([label, raw, feature, cached]) => ({
    label,
    ...resolveDepth(raw, feature, cached),
  })),
  gateCases: [1, 2, 3].map((cap) => ({
    cap,
    depths: [0, 1, 2, 3].map((depth) => ({
      depth,
      agentToolWithheld: blockedAt(depth, cap),
    })),
  })),
  gateExpression: gateExpr,
};
assert.deepEqual(
  results.resolverCases.map(({ cap }) => cap),
  [3, 3, 1, 2, 3, 3, 1, 2, 3, 3, 3, 1, 2, 2],
);
for (const { cap, depths } of results.gateCases)
  for (const { depth, agentToolWithheld } of depths)
    assert.equal(agentToolWithheld, depth >= cap);
process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
