// Shared AST loader for the codex-side kiro scripts: parses $KIRO_BUNDLES/kas.js (from ../bundles.py).
// Needs acorn and acorn-walk on NODE_PATH.
const fs = require("fs"),
  acorn = require("acorn"),
  walk = require("acorn-walk");
if (!process.env.KIRO_BUNDLES) {
  console.error("set KIRO_BUNDLES to the directory ../bundles.py wrote");
  process.exit(2);
}
const src = fs.readFileSync(`${process.env.KIRO_BUNDLES}/kas.js`, "utf8");
const ast = acorn.parse(src, {
  ecmaVersion: "latest",
  sourceType: "module",
  locations: true,
});
const nodes = [];
walk.full(ast, (n) => nodes.push(n));
const code = (n) => src.slice(n.start, n.end);
function named(name, type = "FunctionDeclaration") {
  return nodes.find((n) => n.type === type && n.id?.name === name);
}
module.exports = { fs, walk, src, ast, nodes, code, named };
if (require.main === module) {
  for (const name of process.argv.slice(2)) {
    const n = named(name) ?? named(name, "VariableDeclarator");
    console.log(
      name,
      n
        ? JSON.stringify({ line: n.loc.start.line, source: code(n) })
        : "MISSING",
    );
  }
}
