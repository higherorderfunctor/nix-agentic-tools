import fs from "node:fs";
import { createRequire } from "node:module";

// The v3 engine's hook-trigger vocabulary is one frozen map in the KAS bundle:
// every canonical trigger maps to itself and every alias (v2 camelCase names,
// IDE names) maps to a canonical one. Located by CONTENT, never by the
// minified binding name, which changes between builds.
const require = createRequire(import.meta.url);
const ts = require(process.argv[3]);
const source = fs.readFileSync(process.argv[2], "utf8");
const file = ts.createSourceFile(
  "acp-server.js",
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);

function fail(message) {
  throw new Error(`kiro-extract: ${message}`);
}

if (file.parseDiagnostics.length)
  fail("the KAS engine bundle is not valid JavaScript");

const candidates = [];
function walk(node) {
  if (
    ts.isCallExpression(node) &&
    node.expression.getText(file) === "Object.freeze" &&
    node.arguments.length === 1 &&
    ts.isObjectLiteralExpression(node.arguments[0]) &&
    node.arguments[0].properties.some(
      (property) =>
        ts.isPropertyAssignment(property) &&
        property.name.getText(file) === "SessionStart",
    )
  ) {
    candidates.push(node.arguments[0]);
  }
  ts.forEachChild(node, walk);
}
walk(file);

if (candidates.length !== 1)
  fail(
    `hook trigger map is absent or ambiguous (${candidates.length} frozen ` +
      "objects carry a SessionStart key); re-derive the anchor against the bundle",
  );

const map = {};
for (const property of candidates[0].properties) {
  if (
    !ts.isPropertyAssignment(property) ||
    !(ts.isIdentifier(property.name) || ts.isStringLiteral(property.name)) ||
    !ts.isStringLiteral(property.initializer)
  )
    fail("hook trigger map contains a non-literal entry");
  map[property.name.text] = property.initializer.text;
}

const hookTriggers = [...new Set(Object.values(map))].sort();
const missing = ["PreToolUse", "SessionStart"].filter(
  (trigger) => !hookTriggers.includes(trigger),
);
if (
  missing.length ||
  hookTriggers.length < 8 ||
  hookTriggers.some((trigger) => map[trigger] !== trigger)
)
  fail(
    `hook trigger map shape changed: ${hookTriggers.length} canonical ` +
      `triggers, missing [${missing}], or a canonical trigger without its ` +
      "identity entry",
  );

process.stdout.write(
  JSON.stringify({
    hookTriggerAliases: Object.fromEntries(
      Object.entries(map).filter(([alias, trigger]) => alias !== trigger),
    ),
    hookTriggers,
  }),
);
