const fs = require("node:fs");
const path = require("node:path");
const ts = require(process.env.TYPESCRIPT_JS);
const root = process.env.KIMCHI_SRC;
const files = [
  "src/extensions/agents/index.ts",
  "src/extensions/agents/resume-tool.ts",
  "src/extensions/remote-run/dispatch-tool.ts",
  "src/extensions/ferment/tools/steps.ts",
];
const sources = new Map();
for (const rel of files) {
  const file = path.join(root, rel),
    text = fs.readFileSync(file, "utf8");
  sources.set(
    rel,
    ts.createSourceFile(
      file,
      text,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TS,
    ),
  );
}
function propName(n) {
  return n.name && (ts.isIdentifier(n.name) || ts.isStringLiteral(n.name))
    ? n.name.text
    : undefined;
}
function isOptional(p, sf) {
  return (
    !!p.questionToken ||
    (ts.isPropertyAssignment(p) &&
      ts.isCallExpression(p.initializer) &&
      p.initializer.expression.getText(sf) === "Type.Optional")
  );
}
function getProperties(schema, sf) {
  if (!schema) return [];
  let obj;
  if (
    ts.isCallExpression(schema) &&
    schema.expression.getText(sf) === "Type.Object"
  )
    obj = schema.arguments[0];
  else if (ts.isIdentifier(schema)) {
    for (const st of sf.statements) {
      if (ts.isVariableStatement(st))
        for (const d of st.declarationList.declarations)
          if (
            propName(d) === schema.text &&
            d.initializer &&
            ts.isCallExpression(d.initializer) &&
            d.initializer.expression.getText(sf) === "Type.Object"
          )
            obj = d.initializer.arguments[0];
    }
  }
  return obj && ts.isObjectLiteralExpression(obj)
    ? obj.properties.map((p) => ({
        name: propName(p),
        optional: isOptional(p, sf),
        line: sf.getLineAndCharacterOfPosition(p.getStart(sf)).line + 1,
      }))
    : [];
}
const tools = [];
for (const [rel, sf] of sources) {
  const visit = function visit(n) {
    if (
      ts.isCallExpression(n) &&
      n.expression.getText(sf) === "pi.registerTool"
    ) {
      let obj = n.arguments[0];
      if (
        obj &&
        ts.isCallExpression(obj) &&
        obj.expression.getText(sf) === "defineTool"
      )
        obj = obj.arguments[0];
      if (obj && ts.isObjectLiteralExpression(obj)) {
        const get = (k) =>
          obj.properties.find(
            (p) => ts.isPropertyAssignment(p) && propName(p) === k,
          )?.initializer;
        const name = get("name");
        const params = get("parameters");
        tools.push({
          file: rel,
          line: sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1,
          name: name?.getText(sf).replace(/^"|"$/g, ""),
          fields: getProperties(params, sf),
        });
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
}
console.log(JSON.stringify({ root, tools }, null, 2));
