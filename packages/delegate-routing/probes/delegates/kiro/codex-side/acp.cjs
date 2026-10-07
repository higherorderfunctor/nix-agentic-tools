const { fs, nodes, code } = require("./ast.cjs");
const out = nodes
  .filter(
    (n) =>
      n.type === "MethodDefinition" &&
      n.loc.start.line >= 17809 &&
      n.loc.start.line <= 17860,
  )
  .map((n) => ({ name: n.key?.name, line: n.loc.start.line, source: code(n) }));
fs.writeFileSync(process.cwd() + "/acp.json", JSON.stringify(out, null, 2));
console.log(
  out.map((x) => ({ name: x.name, line: x.line, chars: x.source.length })),
);
