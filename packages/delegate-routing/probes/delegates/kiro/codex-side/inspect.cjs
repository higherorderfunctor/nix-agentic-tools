const { fs, nodes, code, walk, ast } = require("./ast.cjs");
const terms = new Set(process.argv.slice(2));
const parents = new Map();
walk.fullAncestor(ast, (n, s, a) => parents.set(n, a.slice(0, -1)));
const hits = nodes.filter(
  (n) =>
    (n.type === "Literal" &&
      typeof n.value === "string" &&
      [...terms].some((t) => n.value.includes(t))) ||
    (n.type === "Identifier" && terms.has(n.name)),
);
const out = [],
  seen = new Set();
for (const h of hits) {
  const chain = parents.get(h) || [];
  const n =
    chain
      .slice()
      .reverse()
      .find((x) =>
        [
          "MethodDefinition",
          "FunctionDeclaration",
          "VariableDeclarator",
          "AssignmentExpression",
        ].includes(x.type),
      ) || h;
  if (seen.has(n.start)) continue;
  seen.add(n.start);
  out.push({
    line: n.loc.start.line,
    end: n.loc.end.line,
    type: n.type,
    name: n.key?.name || n.id?.name || n.left?.name,
    source: code(n),
  });
}
fs.writeFileSync(
  process.cwd() + "/ast-results.json",
  JSON.stringify(out, null, 2),
);
console.log(
  out.map((x) => ({
    line: x.line,
    end: x.end,
    type: x.type,
    name: x.name,
    chars: x.source.length,
  })),
);
