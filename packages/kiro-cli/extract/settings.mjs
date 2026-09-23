import fs from "node:fs";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);
const ts = require(process.argv[3]);
const source = fs.readFileSync(process.argv[2], "utf8");
const file = ts.createSourceFile(
  "tui.js",
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);

function fail(message) {
  throw new Error(`kiro-extract: ${message}`);
}

if (file.parseDiagnostics.length)
  fail("the TUI bundle is not valid JavaScript");

const registryCandidates = [];
const setCandidates = [];
const warningFunctions = [];
const warning = "[cli-settings] failed to read workspace cli.json:";

function walk(node) {
  if (
    ts.isBinaryExpression(node) &&
    node.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
    ts.isIdentifier(node.left)
  ) {
    if (
      ts.isObjectLiteralExpression(node.right) &&
      node.right.properties.some(
        (property) =>
          ts.isPropertyAssignment(property) &&
          ts.isStringLiteral(property.initializer) &&
          property.initializer.text === "chat.defaultModel",
      )
    ) {
      registryCandidates.push(node);
    }
    if (
      ts.isNewExpression(node.right) &&
      ts.isIdentifier(node.right.expression) &&
      node.right.expression.text === "Set" &&
      node.right.arguments?.length === 1 &&
      ts.isArrayLiteralExpression(node.right.arguments[0]) &&
      node.right.arguments[0].elements.some(
        (member) =>
          ts.isStringLiteral(member) &&
          member.text === "chat.enableTangentMode",
      )
    ) {
      setCandidates.push(node);
    }
  }
  if (ts.isStringLiteral(node) && node.text === warning) {
    let parent = node.parent;
    while (parent && !ts.isFunctionDeclaration(parent)) parent = parent.parent;
    if (parent) warningFunctions.push(parent);
  }
  ts.forEachChild(node, walk);
}
walk(file);

const noWorkspaceMerge =
  setCandidates.length === 0 && warningFunctions.length === 0;
if (
  registryCandidates.length !== 1 ||
  (!noWorkspaceMerge &&
    (setCandidates.length !== 1 || warningFunctions.length !== 1))
) {
  fail(
    `settings anchors are ambiguous or absent (registry ${registryCandidates.length}, ` +
      `allowlist ${setCandidates.length}, merge ${warningFunctions.length})`,
  );
}

const registry = registryCandidates[0];
const registryName = registry.left.text;
const propertyNames = new Set();
for (const property of registry.right.properties) {
  if (
    !ts.isPropertyAssignment(property) ||
    !(ts.isIdentifier(property.name) || ts.isStringLiteral(property.name)) ||
    !ts.isStringLiteral(property.initializer) ||
    !/^[a-z][A-Za-z0-9]*(?:\.[A-Za-z0-9]+)+$/.test(property.initializer.text)
  ) {
    fail("settings registry contains a non-literal property");
  }
  const name = property.name.text;
  if (propertyNames.has(name)) fail(`settings registry repeats ${name}`);
  propertyNames.add(name);
}
if (!propertyNames.has("CHAT_DEFAULT_MODEL"))
  fail("settings registry lost CHAT_DEFAULT_MODEL");

if (noWorkspaceMerge) {
  const settingKeys = vm.runInNewContext(
    `Object.values(${registry.right.getText(file)})`,
    Object.create(null),
    { timeout: 1000, contextCodeGeneration: { strings: false, wasm: false } },
  );
  if (!Array.isArray(settingKeys) || settingKeys.length < 40)
    fail("evaluated settings registry has an unrecognizable shape");
  process.stdout.write(
    JSON.stringify({
      settingKeys: [...new Set(settingKeys)].sort(),
      workspaceOverridableSettings: [],
    }),
  );
  process.exit(0);
}

const allowlist = setCandidates[0];
const allowlistName = allowlist.left.text;

for (const member of allowlist.right.arguments[0].elements) {
  if (ts.isStringLiteral(member)) continue;
  if (
    ts.isPropertyAccessExpression(member) &&
    ts.isIdentifier(member.expression) &&
    member.expression.text === registryName &&
    propertyNames.has(member.name.text)
  ) {
    continue;
  }
  fail("workspace allowlist contains an unresolved or computed member");
}

// The set must be a single top-level binding with one initializer. Any write,
// alias, mutation, or shadowing changes what the merge observes; do not infer
// an allowlist from a mere syntactic Set literal in that case.
const setUses = [];
function findSetUses(node) {
  if (ts.isIdentifier(node) && node.text === allowlistName) setUses.push(node);
  ts.forEachChild(node, findSetUses);
}
findSetUses(file);
let declarations = 0;
let assignments = 0;
for (const use of setUses) {
  const parent = use.parent;
  if (ts.isVariableDeclaration(parent) && parent.name === use) {
    declarations += 1;
    if (parent.initializer || parent.parent.parent.parent !== file)
      fail("workspace allowlist binding is not a top-level declaration");
  } else if (parent === allowlist && allowlist.left === use) {
    assignments += 1;
  } else if (
    !(
      ts.isPropertyAccessExpression(parent) &&
      parent.expression === use &&
      parent.name.text === "has" &&
      ts.isCallExpression(parent.parent) &&
      parent.parent.expression === parent
    )
  ) {
    fail("workspace allowlist binding is mutated, shadowed, or escapes");
  }
}
if (declarations !== 1 || assignments !== 1)
  fail("workspace allowlist binding is ambiguous");

const merge = warningFunctions[0];
const statements = merge.body?.statements;
const globalStatement = statements?.[0];
const tryStatement = statements?.[1];
const returnStatement = statements?.[2];
const globalDecl = globalStatement?.declarationList?.declarations?.[0];
const workspaceDecl =
  tryStatement?.tryBlock?.statements?.[0]?.declarationList?.declarations?.[0];
const globalCall = globalDecl?.initializer;
const workspaceCall = workspaceDecl?.initializer;
const pathCall = workspaceCall?.arguments?.[0];
const catchCall = tryStatement?.catchClause?.block?.statements?.[0]?.expression;
if (
  statements?.length !== 3 ||
  !ts.isVariableStatement(globalStatement) ||
  globalStatement.declarationList.declarations.length !== 1 ||
  !ts.isIdentifier(globalDecl.name) ||
  !ts.isCallExpression(globalCall) ||
  !ts.isIdentifier(globalCall.expression) ||
  globalCall.arguments.length !== 0 ||
  !ts.isTryStatement(tryStatement) ||
  !ts.isVariableStatement(tryStatement.tryBlock.statements[0]) ||
  tryStatement.tryBlock.statements[0].declarationList.declarations.length !==
    1 ||
  !ts.isIdentifier(workspaceDecl.name) ||
  !ts.isCallExpression(workspaceCall) ||
  !ts.isIdentifier(workspaceCall.expression) ||
  workspaceCall.arguments.length !== 1 ||
  !ts.isCallExpression(pathCall) ||
  !ts.isIdentifier(pathCall.expression) ||
  pathCall.arguments.length !== 0 ||
  !ts.isCallExpression(catchCall) ||
  !ts.isPropertyAccessExpression(catchCall.expression) ||
  catchCall.expression.name.text !== "warn" ||
  !ts.isIdentifier(catchCall.expression.expression) ||
  !ts.isReturnStatement(returnStatement) ||
  !ts.isIdentifier(returnStatement.expression) ||
  returnStatement.expression.text !== globalDecl.name.text
)
  fail("workspace merge has an unsupported loader shape");

const hasCalls = [];
function checkMergeUses(node) {
  if (ts.isIdentifier(node) && node.text === allowlistName) {
    const access = node.parent;
    if (
      !ts.isPropertyAccessExpression(access) ||
      access.name.text !== "has" ||
      !ts.isCallExpression(access.parent) ||
      access.parent.expression !== access
    )
      fail("workspace merge no longer consults the extracted allowlist");
    hasCalls.push(access.parent);
  }
  ts.forEachChild(node, checkMergeUses);
}
checkMergeUses(merge);
if (hasCalls.length !== 1)
  fail("workspace merge no longer consults the extracted allowlist");

const expression =
  `(()=>{const ${registryName}=${registry.right.getText(file)};` +
  `return {registry:Object.values(${registryName}),` +
  `allowlist:Array.from(${allowlist.right.getText(file)})}})()`;
const values = vm.runInNewContext(expression, Object.create(null), {
  timeout: 1000,
  contextCodeGeneration: { strings: false, wasm: false },
});
if (
  !Array.isArray(values.registry) ||
  !Array.isArray(values.allowlist) ||
  values.registry.some((value) => typeof value !== "string") ||
  values.allowlist.some((value) => typeof value !== "string") ||
  values.registry.length < 40 ||
  values.allowlist.length < 10 ||
  !values.allowlist.includes("chat.defaultModel")
) {
  fail(
    "evaluated settings registry or workspace allowlist has an unrecognizable shape",
  );
}

// Execute only this small original merge helper, with inert load/read/logger
// dependencies. Opposing global/workspace sentinels prove every extracted key
// overrides and an unknown key does not; a negated or incidental .has fails.
const workspace = Object.fromEntries(
  [...values.allowlist, "kiro.extractor.unknown", "kiro.extractor.other"].map(
    (key) => [key, `workspace:${key}`],
  ),
);
const globalSettings = Object.fromEntries(
  Object.keys(workspace).map((key) => [key, `global:${key}`]),
);
const expectedMerged = Object.fromEntries(
  Object.keys(workspace).map((key) => [
    key,
    values.allowlist.includes(key) ? workspace[key] : globalSettings[key],
  ]),
);
const mergeExpression =
  `(()=>{const ${registryName}=${registry.right.getText(file)};` +
  `const ${allowlistName}=${allowlist.right.getText(file)};` +
  `const ${globalCall.expression.text}=()=>({...globalSettings});` +
  `const ${pathCall.expression.text}=()=>"fixture-path";` +
  `const ${workspaceCall.expression.text}=(path)=>{if(path!=="fixture-path")throw Error("path");return workspace};` +
  `const ${catchCall.expression.expression.text}={warn:()=>{throw Error("workspace read failed")}};` +
  `${merge.getText(file)};return ${merge.name.text}()})()`;
let merged;
try {
  merged = vm.runInNewContext(
    mergeExpression,
    { globalSettings, workspace },
    { timeout: 1000, contextCodeGeneration: { strings: false, wasm: false } },
  );
} catch {
  fail("workspace merge could not be evaluated with isolated settings");
}
for (const [key, expected] of Object.entries(expectedMerged)) {
  if (merged?.[key] !== expected)
    fail("workspace merge does not apply exactly the extracted allowlist");
}

process.stdout.write(
  JSON.stringify({
    settingKeys: [...new Set(values.registry)].sort(),
    workspaceOverridableSettings: [...new Set(values.allowlist)].sort(),
  }),
);
