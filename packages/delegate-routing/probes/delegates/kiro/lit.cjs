// AST helper: node lit.cjs <file> <regex> [ctx=function|object|call|stmt] [maxChars=3000] [maxHits=20]
// Finds string literals / template quasis / identifiers / property keys matching regex, prints the innermost enclosing node of type ctx.
const fs = require("fs"),
  acorn = require("acorn"),
  walk = require("acorn-walk");
const [file, re, ctx = "function", maxc = "3000", maxh = "20"] =
  process.argv.slice(2);
const src = fs.readFileSync(file, "utf8");
const ast = acorn.parse(src, {
  ecmaVersion: "latest",
  sourceType: "module",
  locations: true,
});
const rx = new RegExp(re);
const types = {
  function: [
    "FunctionDeclaration",
    "FunctionExpression",
    "ArrowFunctionExpression",
    "MethodDefinition",
  ],
  object: ["ObjectExpression"],
  call: ["CallExpression"],
  stmt: ["ExpressionStatement", "VariableDeclaration", "ReturnStatement"],
  class: ["ClassDeclaration", "ClassExpression"],
}[ctx];
const seen = new Set();
let n = 0;
function hit(node, anc) {
  const p = [...anc]
    .reverse()
    .slice(1)
    .find((a) => types.includes(a.type));
  if (!p || seen.has(p.start)) return;
  seen.add(p.start);
  if (n++ >= +maxh) return;
  console.log(
    `=== L${p.loc.start.line} [${p.start}-${p.end}] len=${p.end - p.start} match=${JSON.stringify((node.value ?? node.name ?? node.cooked ?? "").toString().slice(0, 80))}`,
  );
  console.log(src.slice(p.start, Math.min(p.end, p.start + +maxc)));
}
walk.fullAncestor(ast, (node, st, anc) => {
  let v = null;
  if (node.type === "Literal" && typeof node.value === "string") v = node.value;
  else if (node.type === "TemplateElement") v = node.value.cooked;
  else if (node.type === "Identifier") v = node.name;
  if (v !== null && rx.test(v)) hit(node, anc);
});
console.error(`hits=${n}`);
