import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";

// Routes the KAS bundle's session roots through `additional-roots.mjs`, in
// place. Input: the bundle and the TypeScript library. `lib/kas.nix` runs it
// at build time when `chat.additionalDirectories` is configured. It finds the
// four places by AST, never by minified name, and refuses the build when a
// release has moved one: where a session's workspace paths are derived, where
// the MCP configuration reader takes a session's roots, where a workflow step
// is created or loaded with its saved roots, and where a cold session is loaded
// on demand from its saved roots.
const [path, typescript] = process.argv.slice(2);
const ts = createRequire(import.meta.url)(typescript);
const source = readFileSync(path, "utf8");
const file = ts.createSourceFile(
  path,
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);
if (file.parseDiagnostics.length)
  throw new Error("session-roots: invalid bundle JavaScript");
const nodes = [];
const collect = (node) => (nodes.push(node), ts.forEachChild(node, collect));
collect(file);

function only(predicate, what) {
  const found = nodes.filter(predicate);
  if (found.length !== 1)
    throw new Error(
      `session-roots: expected one ${what}, found ${found.length}`,
    );
  return found[0];
}
const text = (node) => node.getText(file);
const callee = (node, name) =>
  ts.isCallExpression(node) && text(node.expression) === name;
const edits = [];
const insert = (at, code) => edits.push({ start: at, end: at, code });
// Kiro registers each host function as `name: a(async (...) => {...}, "name")`.
const hostFunction = (name) =>
  only(
    (n) =>
      ts.isPropertyAssignment(n) &&
      text(n.name) === name &&
      callee(n.initializer, "a"),
    `${name} host function`,
  ).initializer.arguments[0];

// Kiro registers each function by name: `a(<function>, "resolveWorkspacePaths")`. Two functions share
// that name; the one wanted returns `[cwd, ...hostRoots]` from a request.
const registered = new Set(
  nodes
    .filter(
      (n) =>
        callee(n, "a") &&
        ts.isStringLiteral(n.arguments[1]) &&
        n.arguments[1].text === "resolveWorkspacePaths",
    )
    .map((n) => text(n.arguments[0])),
);
const returnsRoots = (n) => {
  const last = n.body?.statements.at(-1);
  const roots = ts.isReturnStatement(last) ? last.expression : undefined;
  return (
    roots &&
    ts.isArrayLiteralExpression(roots) &&
    roots.elements.length === 2 &&
    ts.isSpreadElement(roots.elements[1]) &&
    text(roots.elements[0]).endsWith(".cwd")
  );
};
const resolver = only(
  (n) =>
    ts.isFunctionDeclaration(n) &&
    registered.has(n.name?.text) &&
    returnsRoots(n),
  "workspace path function",
);
const roots = resolver.body.statements.at(-1).expression;
const [request] = resolver.parameters.map(text);
edits.push({
  start: roots.getStart(file),
  end: roots.end,
  code: ` __nixRoots.withConfiguredRoots(${request},${text(roots)})`,
});

const mcp = only(
  (n) =>
    ts.isMethodDeclaration(n) &&
    text(n.name) === "setWorkspacePaths" &&
    n.parameters.length === 3,
  "MCP setWorkspacePaths",
);
const [paths] = mcp.parameters.map(text);
insert(mcp.body.getStart(file) + 1, `${paths}=__nixRoots.mcpRoots(${paths});`);

// A step's saved roots go through its owner. `create` reads its run from the
// one parameter and `load` its cwd and options from the second and fifth; each
// must be an arrow function (so `this` is the host's) that reads the fields the
// helper replaces, or the release moved the shape and the build refuses.
const readsFields = (fn, param, names) => {
  const read = new Set();
  const visit = (n) => {
    if (ts.isPropertyAccessExpression(n) && text(n.expression) === param)
      read.add(text(n.name));
    if (
      ts.isVariableDeclaration(n) &&
      ts.isObjectBindingPattern(n.name) &&
      n.initializer &&
      text(n.initializer).replace(/\?\?\{\}$/, "") === param
    )
      for (const element of n.name.elements)
        read.add(text(element.propertyName ?? element.name));
    ts.forEachChild(n, visit);
  };
  visit(fn.body);
  return names.every((name) => read.has(name));
};
const stepFunction = (name, count, ...reads) => {
  const fn = hostFunction(name);
  const params = fn.parameters;
  if (
    !ts.isArrowFunction(fn) ||
    !ts.isBlock(fn.body) ||
    params.length !== count ||
    !params.every((p) => ts.isIdentifier(p.name)) ||
    !reads.every(([at, names]) => readsFields(fn, text(params[at]), names))
  )
    throw new Error(`session-roots: unexpected shape of ${name}`);
  return { body: fn.body, params: params.map(text) };
};
const stepPatch = (body, cwd, options) =>
  insert(
    body.getStart(file) + 1,
    `${options}=__nixRoots.stepOptions(${cwd},${options},this.host);`,
  );
const create = stepFunction("createWorkflowStepSession", 1, [
  0,
  ["additionalDirectories", "ownerSessionId", "workspacePath"],
]);
stepPatch(create.body, `${create.params[0]}.workspacePath`, create.params[0]);
const load = stepFunction("loadStepSession", 5, [
  4,
  ["additionalDirectories", "ownerSessionId"],
]);
stepPatch(load.body, load.params[1], load.params[4]);

// An on-demand load starts from the roots saved with the session.
const onDemand = only(
  (n) =>
    ts.isMethodDeclaration(n) &&
    text(n.name) === "loadSessionOnDemand" &&
    n.parameters.length === 2,
  "loadSessionOnDemand",
);
const saved = text(onDemand.parameters[1]);
insert(
  onDemand.body.getStart(file) + 1,
  `${saved}=__nixRoots.savedRoots(${saved});`,
);

// Static imports hoist, so the line sits below the bundle's shebang.
const top = source.startsWith("#!") ? source.indexOf("\n") + 1 : 0;
insert(top, 'import*as __nixRoots from"./additional-roots.mjs";\n');
let patched = source;
for (const { start, end, code } of edits.toSorted(
  (a, b) => b.start - a.start || b.end - a.end,
))
  patched = patched.slice(0, start) + code + patched.slice(end);
writeFileSync(path, patched);
