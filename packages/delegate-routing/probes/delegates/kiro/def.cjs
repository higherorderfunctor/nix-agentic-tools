// AST helper: node def.cjs <file> <name>[,<name>...] [maxChars=6000] — prints FunctionDeclaration / VariableDeclarator / class / method named <name>.
const fs = require("fs"),
  acorn = require("acorn"),
  walk = require("acorn-walk");
const [file, names, maxc = "6000"] = process.argv.slice(2);
const want = new Set(names.split(","));
const src = fs.readFileSync(file, "utf8");
const ast = acorn.parse(src, {
  ecmaVersion: "latest",
  sourceType: "module",
  locations: true,
});
walk.full(ast, (n) => {
  let nm = null;
  if (
    (n.type === "FunctionDeclaration" || n.type === "ClassDeclaration") &&
    n.id
  )
    nm = n.id.name;
  else if (n.type === "VariableDeclarator" && n.id.type === "Identifier")
    nm = n.id.name;
  else if (n.type === "AssignmentExpression" && n.left.type === "Identifier")
    nm = n.left.name;
  else if (
    (n.type === "MethodDefinition" || n.type === "PropertyDefinition") &&
    n.key &&
    (n.key.name || n.key.value)
  )
    nm = n.key.name || n.key.value;
  if (nm && want.has(nm)) {
    console.log(
      `=== ${nm} ${n.type} L${n.loc.start.line} [${n.start}-${n.end}] len=${n.end - n.start}`,
    );
    console.log(src.slice(n.start, Math.min(n.end, n.start + +maxc)));
  }
});
