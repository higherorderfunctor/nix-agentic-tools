const root = `${process.env.KIRO_BUNDLES}/`; // directory ../bundles.py wrote
const fs = require("fs"),
  acorn = require("acorn"),
  walk = require("acorn-walk");
const src = fs.readFileSync(root + "tui.js", "utf8");
const ast = acorn.parse(src, {
  ecmaVersion: "latest",
  sourceType: "module",
  locations: true,
});
const terms = new Set([
  "_session/steer",
  "session/cancel",
  "moveToBackground",
  "defaultInterruptBehavior",
  "cancelStream",
  "forkSession",
  "agentSubtaskId",
  "steerSession",
  "cancelPrompt",
]);
const out = [],
  seen = new Set();
walk.fullAncestor(ast, (n, s, a) => {
  if (
    !(
      (n.type === "Literal" && terms.has(n.value)) ||
      (n.type === "MemberExpression" && terms.has(n.property?.name)) ||
      (n.type === "MethodDefinition" && terms.has(n.key?.name))
    )
  )
    return;
  const p = a
    .slice()
    .reverse()
    .find((x) =>
      [
        "MethodDefinition",
        "FunctionDeclaration",
        "Property",
        "VariableDeclarator",
      ].includes(x.type),
    );
  if (!p || seen.has(p.start)) return;
  seen.add(p.start);
  out.push({
    name: p.key?.name || p.key?.value || p.id?.name,
    line: p.loc.start.line,
    source: src.slice(p.start, p.end),
  });
});
fs.writeFileSync(process.cwd() + "/tui.json", JSON.stringify(out, null, 2));
console.log(
  out.map((x) => ({ name: x.name, line: x.line, chars: x.source.length })),
);
