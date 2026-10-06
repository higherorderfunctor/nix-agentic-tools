const { fs, nodes, code } = require("./ast.cjs");
const out = nodes
  .filter(
    (n) =>
      (n.type === "MethodDefinition" &&
        ((n.loc.start.line >= 15890 && n.loc.start.line <= 16600) ||
          (n.loc.start.line >= 17290 && n.loc.start.line <= 17710))) ||
      (n.type === "FunctionDeclaration" &&
        ["JRr", "Iki", "zOn", "HOn", "Bwe"].includes(n.id?.name)) ||
      (n.type === "VariableDeclarator" &&
        ["eIr", "Hji", "ECc", "Nji", "qji", "oRc"].includes(n.id?.name)),
  )
  .map((n) => ({
    name: n.key?.name || n.id?.name,
    type: n.type,
    line: n.loc.start.line,
    source: code(n),
  }));
fs.writeFileSync(
  process.cwd() + "/surfaces.json",
  JSON.stringify(out, null, 2),
);
console.log(
  out
    .filter((x) => !["constructor"].includes(x.name))
    .map((x) => ({ name: x.name, line: x.line, chars: x.source.length })),
);
