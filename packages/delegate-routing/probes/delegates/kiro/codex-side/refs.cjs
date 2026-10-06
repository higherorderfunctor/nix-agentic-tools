const { fs, nodes, code, walk, ast } = require("./ast.cjs");
const terms = new Set(process.argv.slice(2));
const out = [],
  seen = new Set();
walk.fullAncestor(ast, (n, s, a) => {
  if (
    !(
      (n.type === "Identifier" && terms.has(n.name)) ||
      (n.type === "Literal" && terms.has(n.value)) ||
      (n.type === "MemberExpression" && terms.has(n.property?.name)) ||
      (n.type === "MethodDefinition" && terms.has(n.key?.name)) ||
      (n.type === "Property" && terms.has(n.key?.name))
    )
  )
    return;
  const p = a
    .reverse()
    .find((x) =>
      [
        "MethodDefinition",
        "FunctionDeclaration",
        "Property",
        "VariableDeclarator",
        "AssignmentExpression",
      ].includes(x.type),
    );
  if (!p || seen.has(p.start)) return;
  seen.add(p.start);
  out.push({
    name: p.key?.name || p.key?.value || p.id?.name || p.left?.name,
    type: p.type,
    line: p.loc.start.line,
    source: code(p),
  });
});
fs.writeFileSync(process.cwd() + "/refs.json", JSON.stringify(out, null, 2));
console.log(
  out.map((x) => ({
    name: x.name,
    type: x.type,
    line: x.line,
    chars: x.source.length,
  })),
);
