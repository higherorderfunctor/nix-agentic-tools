const { fs, nodes, code, named } = require("./ast.cjs");
const args = process.argv.slice(2),
  label = args.shift();
const out = [];
for (const spec of args) {
  let nn;
  if (spec.startsWith("line:")) {
    const line = +spec.slice(5);
    nn = nodes.filter(
      (n) =>
        ["MethodDefinition", "FunctionDeclaration"].includes(n.type) &&
        n.loc.start.line === line,
    );
  } else
    nn = nodes.filter(
      (n) =>
        (n.type === "FunctionDeclaration" && n.id?.name === spec) ||
        (n.type === "VariableDeclarator" && n.id?.name === spec) ||
        (n.type === "AssignmentExpression" && n.left?.name === spec),
    );
  for (const n of nn)
    out.push({
      name: n.key?.name || n.id?.name || n.left?.name,
      type: n.type,
      line: n.loc.start.line,
      source: code(n),
    });
}
fs.writeFileSync(
  process.cwd() + "/" + label + ".json",
  JSON.stringify(out, null, 2),
);
console.log(
  out.map((x) => ({
    name: x.name,
    type: x.type,
    line: x.line,
    chars: x.source.length,
  })),
);
