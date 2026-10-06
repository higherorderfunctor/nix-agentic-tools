#!/usr/bin/env node
const fs = require("node:fs");
const vm = require("node:vm");
// codex:A — executes the pinned depth resolver tw() and the `h >= tw()` Agent gate in a VM.
// usage: NODE_PATH=<dir with acorn@8> node verify_depth.js <unpacked-dir>   (<unpacked-dir> from ../unpack.sh)
const acorn = require("acorn");

const unpacked = process.argv[2];
if (!unpacked) {
  console.error("usage: node verify_depth.js <unpacked-dir>");
  process.exit(2);
}
const read = (name) => fs.readFileSync(`${unpacked}/${name}`, "utf8");
const parse = (source) =>
  acorn.parse(source, { ecmaVersion: "latest", sourceType: "module" });
function findFunction(source, name) {
  const ast = parse(source);
  const node = ast.body.find(
    (item) => item.type === "FunctionDeclaration" && item.id?.name === name,
  );
  if (!node) throw new Error(`missing function ${name}`);
  return source.slice(node.start, node.end);
}
function findVars(source, names) {
  const ast = parse(source);
  const wanted = new Set(names);
  const found = new Map();
  for (const statement of ast.body) {
    if (statement.type !== "VariableDeclaration") continue;
    for (const decl of statement.declarations) {
      if (decl.id.type === "Identifier" && wanted.has(decl.id.name)) {
        found.set(decl.id.name, source.slice(decl.start, decl.end));
      }
    }
  }
  for (const name of names)
    if (!found.has(name)) throw new Error(`missing variable ${name}`);
  return [...found.values()].join(";");
}
function walk(node, visit) {
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const [key, value] of Object.entries(node)) {
    if (key === "loc" || key === "start" || key === "end") continue;
    if (Array.isArray(value)) {
      for (const child of value) walk(child, visit);
    } else if (
      value &&
      typeof value === "object" &&
      typeof value.type === "string"
    )
      walk(value, visit);
  }
}

// Reuse the exact upstream H.int parsing implementation and its numeric helper.
const parserSource = read("chunk-gya34y41.js");
const numberSource = read("chunk-zrte1bjz.js");
const parserHelpers = [
  findFunction(parserSource, "i"),
  findFunction(parserSource, "u"),
  findFunction(parserSource, "d"),
  findFunction(numberSource, "m"),
  findFunction(numberSource, "Uc"),
  findVars(numberSource, ["N", "E", "c"]),
].join("\n");
const parserContext = vm.createContext({});
vm.runInContext(parserHelpers, parserContext);
const parsedEnv = vm.runInContext("d({min:1,digitsOnly:true})", parserContext);

// AST-select the real tw() function and replace only its Bun import.meta.require
// call with an injected GrowthBook module. Everything else is the pinned source.
const resolverSource = read("chunk-6v4f0vse.js");
const resolverAst = parse(resolverSource);
const resolverNode = resolverAst.body.find(
  (item) => item.type === "FunctionDeclaration" && item.id?.name === "tw",
);
if (!resolverNode) throw new Error("missing tw");
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
if (calls.length !== 1)
  throw new Error(`expected one import.meta.require, found ${calls.length}`);
const call = calls[0];
resolver =
  resolver.slice(0, call.start - resolverNode.start) +
  "globalThis.__growthBookModule" +
  resolver.slice(call.end - resolverNode.start);
const constants = findVars(resolverSource, ["n", "_"]);

function resolveDepth(rawEnv, featureValue) {
  const normalized =
    rawEnv === Symbol.for("absent") ? undefined : parsedEnv.parse(rawEnv);
  const state = {};
  const context = vm.createContext({
    a: { CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH: normalized },
    Oo: () => state,
    __growthBookModule: {
      getFeatureValue_CACHED_MAY_BE_STALE: (_key, fallback) =>
        featureValue === undefined ? fallback : featureValue,
    },
  });
  vm.runInContext(`${constants};${resolver};`, context);
  return {
    parsedEnv: normalized ?? null,
    cap: vm.runInContext("tw()", context),
    growthBookState: state.maxSubagentSpawnDepthFromGrowthBook ?? null,
  };
}

// AST-select and execute the actual boundary expression used to withhold Agent.
const gateSource = read("chunk-2dk1sr5c.js");
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
    node.right.callee.name === "tw"
  ) {
    gates.push(node);
  }
});
if (gates.length !== 1)
  throw new Error(`expected one h >= tw() gate, found ${gates.length}`);
const gateExpr = gateSource.slice(gates[0].start, gates[0].end);
function blockedAt(depth, cap) {
  const context = vm.createContext({ h: depth, tw: () => cap });
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
  ].map(([label, raw, feature]) => ({ label, ...resolveDepth(raw, feature) })),
  gateCases: [1, 2, 3].map((cap) => ({
    cap,
    depths: [0, 1, 2, 3].map((depth) => ({
      depth,
      agentToolWithheld: blockedAt(depth, cap),
    })),
  })),
  gateExpression: gateExpr,
};
process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
