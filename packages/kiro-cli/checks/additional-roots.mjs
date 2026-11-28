// Proves the session-roots patch on the pinned bundle. It patches a copy, then
// runs the real vendor functions the patch touches (workspace paths, the MCP
// roots entry and reader, the default permission rules), cut out by AST and run
// beside stubs. No session starts; vendor text is parsed, never printed.
// Usage: `node additional-roots.mjs <acp-server.js> <typescript> [<src>]`.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import vm from "node:vm";

const [pinned, typescript, src = path.join(import.meta.dirname, "../src")] =
  process.argv.slice(2);
const ts = createRequire(import.meta.url)(typescript);
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "roots-")));
const at = (...parts) => path.join(tmp, ...parts);
const write = (file, value) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(
    file,
    typeof value === "string" ? value : JSON.stringify(value),
  );
};
const read = (file) => fs.readFileSync(file, "utf8");
const stockSource = read(pinned);
const patchedFile = at("patched/acp-server.js");
write(patchedFile, stockSource);
fs.copyFileSync(
  path.join(src, "additional-roots.mjs"),
  at("patched/additional-roots.mjs"),
);
execFileSync(process.execPath, [
  path.join(src, "patch-session-roots.mjs"),
  patchedFile,
  typescript,
]);
execFileSync(process.execPath, ["--check", patchedFile]);
const patchedSource = read(patchedFile);
const roots = await import(pathToFileURL(at("patched/additional-roots.mjs")));

// The one node of `source` that `pick` accepts, as text.
const trees = new Map();
const find = (source, pick) => {
  if (!trees.has(source))
    trees.set(
      source,
      ts.createSourceFile(
        "x.js",
        source,
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.JS,
      ),
    );
  const found = [];
  (function walk(node) {
    if (pick(node)) found.push(node.getText());
    ts.forEachChild(node, walk);
  })(trees.get(source));
  assert.equal(found.length, 1, "one vendor anchor");
  return found[0];
};
const fn = (source, name) =>
  find(source, (n) => ts.isFunctionDeclaration(n) && n.name?.text === name);
const method = (source, name, arity) =>
  find(
    source,
    (n) =>
      ts.isMethodDeclaration(n) &&
      n.name.getText() === name &&
      n.parameters.length === arity,
  );
const assigned = (pattern) =>
  find(
    stockSource,
    (n) =>
      ts.isBinaryExpression(n) &&
      n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      pattern.test(n.getText()),
  ).replace(/^\w+=/, "");
const run = (code, extra = {}) =>
  vm.runInNewContext(code, {
    __nixRoots: roots,
    Qm: path,
    uH: path,
    kn: class extends Error {},
    ...extra,
  });
const data = (code, extra) => JSON.parse(run(`JSON.stringify(${code})`, extra));
// Vendor arrays come from another realm; copy them out to compare by value.
const derive = (source) => {
  const name = /function (\w+)\(t,e\)\{if\(e\)return\[\];/.exec(stockSource)[1];
  const call = run(
    `${["e6n", "RWe"].map((n) => fn(stockSource, n)).join(";")};${fn(source, name)};${name}`,
  );
  return (...args) => [...call(...args)];
};
const [stock, patched] = [stockSource, patchedSource].map(derive);

process.env.KIRO_HOME = at("home");
const [repo, globalRoot, repoRoot, hostRoot] = [
  "repo",
  "global-root",
  "repo-root",
  "host-root",
].map((n) => (fs.mkdirSync(at(n)), at(n)));
fs.symlinkSync(repoRoot, at("link"));
const listed = (file, entries) =>
  write(file, { "chat.additionalDirectories": entries });
const request = (...hostRoots) => ({
  cwd: repo,
  additionalDirectories: hostRoots,
});
const repoSettings = at("repo/.kiro/settings/cli.json");
listed(at("home/settings/cli.json"), [globalRoot, "../global-extra"]);
listed(repoSettings, ["../repo-root", "../link", "../missing"]);

// Fresh: the client's roots, then global, then repository entries, one spelling per directory.
assert.deepEqual(patched(request(hostRoot, hostRoot), false), [
  repo,
  hostRoot,
  hostRoot,
  globalRoot,
  at("home/global-extra"),
  repoRoot,
  at("missing"),
]);
assert.deepEqual(
  stock(request(hostRoot), false),
  [repo, hostRoot],
  "unmanaged stock adds nothing",
);
assert.deepEqual(
  patched(request(repoRoot), false).slice(0, 2),
  [repo, repoRoot],
  "the client's spelling wins",
);
// Resident joins keep the first derivation; a cold load reads current settings.
const resident = request(hostRoot);
const first = patched(resident, false);
listed(repoSettings, []);
assert.deepEqual(patched(resident, false), first);
assert.equal(patched(request(hostRoot), false).length, 4);
// Denied: the client's roots keep Kiro's own check; configured entries must be nonempty strings in an array.
assert.throws(() => patched(request("relative"), false), /absolute/);
for (const bad of ["not-an-array", [""]]) {
  listed(repoSettings, bad);
  assert.throws(() => patched(request(), false), /chat\.additionalDirectories/);
}

// MCP: the entry offers the reader the cwd and the client's roots; the reader reads every root it is given.
listed(repoSettings, [repoRoot]);
for (const [root, name] of [
  [repoRoot, "configured"],
  [hostRoot, "host"],
  [repo, "cwd"],
])
  write(path.join(root, ".kiro/settings/mcp.json"), {
    mcpServers: { [name]: {} },
  });
const opened = [];
const vendor = run(
  `({${method(patchedSource, "setWorkspacePaths", 3)},${method(stockSource, "readWorkspaceFiles", 3)}})`,
  { Ncn: path, FHr: "mcp.json", $Hr: (v) => v ?? {} },
);
const self = {
  items: { openSession: (id, paths) => opened.push(paths) },
  configWatcher: { addWorkspacePaths() {} },
  readAndMergeFileConfigs: () => false,
  readParsedConfig: (file) =>
    fs.existsSync(file) ? JSON.parse(read(file)) : {},
  workspaceTrusted: true,
};
vendor.setWorkspacePaths.call(self, [repo, hostRoot, repoRoot], "s", {});
assert.deepEqual(opened, [[repo, hostRoot]]);
const servers = [
  ...vendor.readWorkspaceFiles.call(
    self,
    [repo, hostRoot, repoRoot],
    new Set(),
    [],
  ),
];
assert.deepEqual(
  servers.flatMap(([, entry]) => Object.keys(entry.servers)),
  ["cwd", "host", "configured"],
  "the vendor reader reads whatever it is given",
);

// Workflow steps keep only roots the owner holds; a named but absent owner refuses; both host functions call it.
assert.deepEqual(roots.stepRoots([hostRoot, repoRoot], "o", [repo, hostRoot]), [
  hostRoot,
]);
assert.throws(() => roots.stepRoots([hostRoot], "o", undefined), /not loaded/);
assert.deepEqual(roots.stepRoots([hostRoot], undefined, undefined), [hostRoot]);
for (const name of ["createWorkflowStepSession", "loadStepSession"])
  assert.match(
    find(
      patchedSource,
      (n) => ts.isPropertyAssignment(n) && n.name.getText() === name,
    ).slice(0, 200),
    /__nixRoots\.stepRoots/,
  );
assert.equal(
  patchedSource.match(/__nixRoots\.\w+/g).length,
  4,
  "four sites, no others",
);
assert.deepEqual(
  Object.keys(roots).sort(),
  ["mcpRoots", "stepRoots", "withConfiguredRoots"],
  "the module grants no permission",
);

// Writes: Kiro's default policy allows reading under the roots and allows no write, so membership still prompts.
const readRule = data(
  `(${assigned(/^\w+=\{capability:"fs_read",match:\["\.\/\*\*"\]/)})`,
);
const shell = data(assigned(/^\w+=\[\{capability:"shell",match:\["pwd"/));
const policy = data(
  `(${find(stockSource, (n) => ts.isVariableDeclaration(n) && /^\w+=\{rules:\[SBn,\.\.\.hGe,/.test(n.getText())).replace(/^\w+=/, "")})`,
  { SBn: readRule, hGe: shell },
);
assert.deepEqual(readRule, {
  capability: "fs_read",
  match: ["./**"],
  effect: "allow",
});
assert.deepEqual([...new Set(policy.rules.map((r) => r.capability))].sort(), [
  "fs_read",
  "shell",
  "web_fetch",
]);
fs.rmSync(tmp, { force: true, recursive: true });
console.log("PASS: additional roots");
