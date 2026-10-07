// AST selection shared by the pinned-bundle probes. A missing or ambiguous match
// must fail; silently printing nothing is not evidence for a map row.
const fs = require("node:fs");
const acorn = require("acorn");
const parse = (source) =>
  acorn.parse(source, { ecmaVersion: "latest", sourceType: "module" });
function readChunks(root) {
  return fs
    .readdirSync(root)
    .filter((name) => name.startsWith("chunk-") && name.endsWith(".js"))
    .map((file) => ({
      file,
      source: fs.readFileSync(`${root}/${file}`, "utf8"),
    }));
}
function only(matches, label) {
  if (matches.length !== 1)
    throw new Error(`expected one ${label}, found ${matches.length}`);
  return matches[0];
}
function selectSource(chunks, terms) {
  return only(
    chunks.filter(({ source }) => terms.every((term) => source.includes(term))),
    `chunk for ${terms}`,
  ).source;
}
function selectFunction(chunks, terms) {
  const matches = [];
  for (const { file, source } of chunks) {
    if (!terms.every((term) => source.includes(term))) continue;
    for (const node of parse(source).body) {
      if (node.type !== "FunctionDeclaration") continue;
      const text = source.slice(node.start, node.end);
      if (terms.every((term) => text.includes(term)))
        matches.push({ file, source, node, text });
    }
  }
  return only(matches, `function for ${terms}`);
}
function findFunction(source, name) {
  const node = only(
    parse(source).body.filter(
      (item) => item.type === "FunctionDeclaration" && item.id?.name === name,
    ),
    `function ${name}`,
  );
  return source.slice(node.start, node.end);
}
function findVars(source, names) {
  const wanted = new Set(names),
    found = new Map();
  for (const statement of parse(source).body) {
    if (statement.type !== "VariableDeclaration") continue;
    for (const decl of statement.declarations)
      if (decl.id.type === "Identifier" && wanted.has(decl.id.name))
        found.set(decl.id.name, source.slice(decl.start, decl.end));
  }
  for (const name of names)
    if (!found.has(name)) throw new Error(`missing variable ${name}`);
  return [...found.values()].join(";");
}
function walk(node, visit) {
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const value of Object.values(node)) {
    if (Array.isArray(value)) for (const child of value) walk(child, visit);
    else if (value && typeof value === "object") walk(value, visit);
  }
}
module.exports = {
  findFunction,
  findVars,
  parse,
  readChunks,
  selectFunction,
  selectSource,
  walk,
};
