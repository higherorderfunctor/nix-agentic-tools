#!/usr/bin/env node
// claude-extract-locate.mjs — fixture gate for structural anchors in
// packages/claude-code/extract/locate.mjs and the declaration slicer in
// packages/claude-code/extract/slice.mjs.
//
//   node claude-extract-locate.mjs <extract-dir> <fixture-dir> <typescript.js>
//
// The lazy-thunk memoizer is the one anchor the settings census needs that is
// NOT part of the settings schema, and it has now broken the update sweep
// twice: at 2.1.248 the settings chunk switched from bun's `__esm` lowering to
// Anthropic's lazy registry, and at 2.1.283 the registry's method body was
// rewritten under a locator that had pinned it as a literal. Neither change
// is visible in the released schema, so nothing but this gate exercises the
// locator on a shape it does not currently see in the pinned binary.
//
// The fixtures are SYNTHETIC defining modules — a few hundred bytes each,
// never an unpacked binary — carrying every memoizer shape that has shipped
// plus decoys that must NOT confirm. They are `.js.txt`, not `.js`: the shape
// under test IS the minifier's output, and biome rewrites it (it even turns
// `let` into `const`), so they sit outside every formatter's globs rather
// than behind an exclusion the local hook's baked config would not see.
// Each case drives `locateMemoizerLocal`
// exactly as `locate()` does: a settings-like source that imports the
// candidate and wraps thunks with it, plus a `readSpec` that serves the
// fixture as the defining module. When upstream ships a third shape, add it
// here in the same commit as the locator change.

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [extractDir, fixtureDir, typescriptPath] = process.argv.slice(2);
if (!extractDir || !fixtureDir || !typescriptPath) {
  console.error(
    "usage: claude-extract-locate.mjs <extract-dir> <fixture-dir> <typescript.js>",
  );
  process.exit(2);
}
const L = await import(pathToFileURL(path.join(extractDir, "locate.mjs")).href);
const { discoverAliases } = await import(
  pathToFileURL(path.join(extractDir, "census.mjs")).href
);
const { sliceModule } = await import(
  pathToFileURL(path.join(extractDir, "slice.mjs")).href
);

const fixture = (name) => fs.readFileSync(path.join(fixtureDir, name), "utf8");
const readSpec = (spec) => {
  try {
    return fixture(spec.replace(/^\.\//, ""));
  } catch {
    return null;
  }
};

// A settings-like module: one import binding plus `n` lazy-init thunk sites
// wrapped with it, the way the real settings chunk wraps its module bodies.
const settingsUsing = (spec, exported, local, n) =>
  `import{${exported}${exported === local ? "" : ` as ${local}`}}from"${spec}";` +
  Array.from(
    { length: n },
    (_, i) => `var T${i}=${local}(()=>{return ${i}});`,
  ).join("");

let failures = 0;
const check = (name, ok, detail) => {
  if (ok) {
    console.log(`ok   ${name}`);
    return;
  }
  failures++;
  console.log(
    `FAIL ${name}${detail === undefined ? "" : ` — ${JSON.stringify(detail)}`}`,
  );
};

// Unexpected successes return no diagnostic; a throw only passes if the
// caller matches the diagnostic for the constraint it meant to exercise.
const failureMessage = (call) => {
  try {
    call();
    return "";
  } catch (error) {
    return error.message;
  }
};

// In the settings builder, a preprocess pipe holds the callback on its input.
{
  const change = (value) => (value === "old" ? "new" : value);
  const output = { type: "enum" };
  const pipe = (type) => ({ type: "pipe", in: { type, change }, out: output });
  const schema = {
    type: "object",
    shape: {
      mode: { type: "optional", innerType: pipe("transform") },
      decoy: pipe("string"),
      withoutEnum: pipe("transform"),
    },
  };
  const paths = { mode: { enum: ["new"] }, decoy: { enum: ["new"] } };
  const aliases = discoverAliases(schema, paths);
  check(
    "preprocess aliases: only a transform feeding an enum contributes a spelling",
    JSON.stringify(aliases) ===
      JSON.stringify([{ path: "mode", alias: "old", becomes: "new" }]),
    aliases,
  );
}

// ── The @internal marker identifies the filter by its calls, not substrings ──
// 2.1.302 named the predicate `ys`; `Object.keys(` in the smaller recursive
// decoy is not a call to it.
check(
  "internal marker: a member call ending in the predicate name is not a call",
  L.locateFilterByMarker(
    'var M=/^@internal/;function ys(e){return typeof e==="string"&&M.test(e)}' +
      "function gp(e,n){return Object.keys(n).every((r)=>gp(e,r))}" +
      "function F(e,n){if(ys(e.description))return;for(let c of e)F(c,n)}",
  ) === "F",
);

// ── The schema description identifies the direct builder or its wrapper ──
const schemaDescription = L.ANCHORS.schemaKeyDescription;
check(
  "schema description in direct builder: returns that builder",
  L.locateBuilderByDescription(
    `function B(){return {$schema:()=>z.describe(${JSON.stringify(schemaDescription)})}}`,
  ) === "B",
);
check(
  "schema description in descriptor factory: follows whole-schema wrapper",
  L.locateBuilderByDescription(
    `function F(e){return {$schema:()=>z.describe(${JSON.stringify(schemaDescription)})}}` +
      "function B(e,n={}){let s=F(e,n);return new S(s).whole()}",
  ) === "B",
);
const schemaAmbiguity = failureMessage(() =>
  L.locateBuilderByDescription(
    `function F(e){return {$schema:()=>z.describe(${JSON.stringify(schemaDescription)})}}` +
      "function B(e){let s=F(e);return new S(s).whole()}" +
      "function C(e){let s=F(e);return new S(s).whole()}",
  ),
);
check(
  "schema descriptor factory with two whole-schema wrappers: throws on ambiguity",
  schemaAmbiguity ===
    "$schema descriptor factory F has multiple whole-schema wrappers: B, C",
  schemaAmbiguity,
);

// ── Single-family cases cover the original registry cell and escaped aliases ──
const shipped = [
  [
    "memo-registry-cell.js.txt",
    "f",
    "f",
    2,
    "rejects the original registry cell",
  ],
  // A `$` in the importing module's local name is a RegExp metacharacter
  // when interpolated; the locator must escape it rather than mis-scan.
  [
    "memo-registry-built.js.txt",
    "f",
    "$M",
    2,
    "treats the local name as a regular expression",
  ],
];
for (const [file, exported, local, n, regression] of shipped) {
  const src = settingsUsing(`./${file}`, exported, local, n);
  const memo = L.locateMemoizerLocal(src, readSpec);
  check(
    `${file} as ${local}: ${regression}`,
    memo !== null && memo.all.length === 1 && memo.all[0].local === local,
    memo,
  );
}

// The census executes thunks by binding name, in discovery order; a count
// cannot detect a capture of the callee instead of the initialized binding.
const thunks = L.locateInitThunks(
  "var first=$M(()=>{});var decoy=M(()=>{});let second=$M(()=>{});",
  "$M",
);
check(
  "init thunks: captures the bindings in source order",
  thunks.join() === "first,second",
  thunks,
);

// ── Decoys must not confirm, however the importing module uses them ──
for (const [file, regression] of [
  ["decoy-eager-fill.js.txt", "accepts an eager cell fill"],
  ["decoy-no-resetter.js.txt", "accepts a cell without a resetter"],
  ["decoy-plain-call.js.txt", "guesses from call sites alone"],
  ["decoy-two-registries.js.txt", "chooses the first ambiguous registry"],
]) {
  const src = settingsUsing(`./${file}`, "f", "f", 3);
  check(
    `${file}: ${regression} despite defining-module confirmation`,
    L.locateMemoizerLocal(src, readSpec) === null,
  );
}

// An export-alias mismatch is a different module's memoizer, not this one's.
check(
  "memo-registry-built.js imported under a name it does not export: rejected",
  L.locateMemoizerLocal(
    settingsUsing("./memo-registry-built.js.txt", "g", "g", 2),
    readSpec,
  ) === null,
);

// ── Two live families in one module are both reported, never first-match ──
{
  const src =
    settingsUsing("./memo-bun.js.txt", "k", "M", 2) +
    settingsUsing("./memo-registry-built.js.txt", "f", "f", 3);
  const memo = L.locateMemoizerLocal(src, readSpec);
  check(
    "mixed Bun __esm lowering and registry: loses a memoizer family or alias",
    memo !== null &&
      memo.all.length === 2 &&
      memo.all
        .map(({ local }) => local)
        .sort()
        .join() === "M,f",
    memo,
  );
}

// ── Nothing imported and nothing inline: fail closed ──
check(
  "no memoizer anywhere: null, not a guess",
  L.locateMemoizerLocal("var A=1;", readSpec) === null,
);

const ts = (await import(pathToFileURL(typescriptPath).href)).default;

// ── resolveDefinition follows import/export aliases to the declaring chunk ──
// From 2.1.326 the emitter imports the converter from another chunk under a
// different minified name; only the export alias carries the name across.
const chain = fs.mkdtempSync(path.join(os.tmpdir(), "claude-resolve-"));
try {
  const write = (name, src) => fs.writeFileSync(path.join(chain, name), src);
  write("hop.js", 'import{X as q}from"/$bunfs/root/decl.js";export{q as Y};');
  write("decl.js", "function c(e){return e}export{c as X};");
  write("two.js", "function a(){}function b(){}export{a as Z,b as Z};");
  const start =
    'import{Y as k,Z as m}from"/$bunfs/root/hop.js";import{W as n}from"./rel.js";';
  const d = L.resolveDefinition(
    chain,
    path.join(chain, "start.js"),
    start,
    "k",
  );
  check(
    "resolveDefinition: two hops through export aliases reach the declaration",
    d.path === path.join(chain, "decl.js") && d.local === "c",
    { path: path.basename(d.path), local: d.local },
  );
  for (const [name, src, local, diagnostic] of [
    [
      "an alias no export carries",
      start,
      "m",
      "export Z of hop.js resolves to 0 locals",
    ],
    [
      "an alias two exports carry",
      'import{Z as m}from"/$bunfs/root/two.js";',
      "m",
      "export Z of two.js resolves to 2 locals",
    ],
    [
      "an import from outside the bundle",
      start,
      "n",
      "n is imported from ./rel.js, which is not a bundled chunk",
    ],
  ]) {
    const error = failureMessage(() =>
      L.resolveDefinition(chain, path.join(chain, "start.js"), src, local),
    );
    check(`resolveDefinition: refuses ${name}`, error === diagnostic, error);
  }
} finally {
  fs.rmSync(chain, { recursive: true, force: true });
}

// ── The slicer cuts by checker symbol and refuses state it cannot prove ──
// Each refusal names the shape a slice would otherwise evaluate wrongly: a
// slicer that matched names by spelling, or skipped the closure scan,
// passes the positive cases and fails these.
const slice = (src, roots) => sliceModule(ts, "/fixture/chunk.js", src, roots);
{
  const r = slice(
    'import{q as e}from"/$bunfs/root/big.js";var S=new Set(["a"]);' +
      "function f(e){return S.has(e)}export{f};",
    ["f"],
  );
  const cut =
    Object.keys(r.stats.imports).length === 0 && r.stats.declarations === 2;
  // Only a cut with no imports can be evaluated outside the unpacked graph.
  const m = cut
    ? await import(
        "data:text/javascript," + encodeURIComponent(`${r.source}export{f};`)
      )
    : null;
  check(
    "slice: a parameter does not drag in its top-level namesake",
    cut && m.f("a") === true && m.f("b") === false,
    r,
  );
}
{
  const r = slice(
    'import{a,b as c}from"/$bunfs/root/x.js";import{z}from"/$bunfs/root/y.js";' +
      "function f(v){return c(v)}function g(){return z()+a}export{f,g};",
    ["f"],
  );
  check(
    "slice: keeps the imported helper and drops the unrelated import",
    r.source.startsWith('import{b as c}from"/$bunfs/root/x.js";') &&
      !r.source.includes("y.js") &&
      !r.source.includes("function g"),
    r,
  );
}
for (const [name, src, roots, diagnostic] of [
  [
    "state mutated outside the slice",
    'var S=new Set(["a"]);function f(v){return S.has(v)}function o(){S.add("b")}export{f,o};',
    ["f"],
    "sliced variable S is referenced or exported outside the slice",
  ],
  [
    "exported state",
    'var S=new Set(["a"]);function f(v){return S.has(v)}export{f,S};',
    ["f"],
    "sliced variable S is referenced or exported outside the slice",
  ],
  [
    "lazily initialized state",
    'var S;var i=m(()=>{S=new Set(["a"])});function f(v){return S.has(v)}function m(x){return x}export{f};',
    ["f"],
    "sliced variable S has no initializer",
  ],
  [
    "a sliced class (its copy breaks instanceof)",
    "class C{}function f(v){return v instanceof C}export{f};",
    ["f"],
    "slice needs the class C",
  ],
  [
    "a sliced function reassigned elsewhere",
    "function h(v){return v}function f(v){return h(v)}function p(){h=()=>1}export{f};",
    ["f"],
    "sliced function h is used outside the slice other than by a call",
  ],
  [
    "a sliced function reassigned by destructuring",
    "function h(v){return v}function f(v){return h(v)}function p(o){[h]=o}export{f};",
    ["f"],
    "sliced function h is used outside the slice other than by a call",
  ],
  [
    "a sliced function patched through a property",
    "function h(v){return h.k+v}function f(v){return h(v)}var i=()=>{h.k=1};export{f};",
    ["f"],
    "sliced function h is used outside the slice other than by a call",
  ],
  [
    "a sliced function patched by Object.assign",
    "function h(v){return v}function f(v){return h(v)}function p(){Object.assign(h,{k:1})}export{f};",
    ["f"],
    "sliced function h is used outside the slice other than by a call",
  ],
  [
    "an unresolved identifier that is not a global",
    "function f(v){return notDeclaredAnywhere(v)}export{f};",
    ["f"],
    "unresolved identifier notDeclaredAnywhere is not a global",
  ],
  [
    "a default import",
    'import d from"ws";function f(v){return d(v)}export{f};',
    ["f"],
    "slice needs a non-named import from ws",
  ],
  [
    "a root that is not a top-level declaration",
    "function f(v){return v}export{f};",
    ["g"],
    "root binding g is not a top-level declaration",
  ],
]) {
  const error = failureMessage(() => slice(src, roots));
  check(
    `slice: refuses ${name}`,
    error === `census-slice: chunk.js: ${diagnostic}`,
    error,
  );
}

for (const [name, diagnostic] of [
  [
    "model-catalog-computed.js.txt",
    "model catalog entry: unsupported property form",
  ],
  [
    "model-catalog-spread.js.txt",
    "model catalog entry: unsupported property form",
  ],
  ["model-pins-computed.js.txt", "launch pin unpinOpus48LaunchEffort"],
  ["model-pins-multi-argument.js.txt", "launch pin unpinOpus48LaunchEffort"],
  ["model-pins-non-literal.js.txt", "launch pin unpinOpus48LaunchEffort"],
  ["model-pins-positive.js.txt", "launch pin unpinOpus48LaunchEffort"],
  ["model-retired-malformed.js.txt", 'retirement row "claude-opus-5"'],
]) {
  const error = failureMessage(() => L.locateModelSites(fixture(name), ts));
  check(
    `${name}: refuses unsupported structure with PROBE`,
    error.includes("PROBE failure:") && error.includes(diagnostic),
    error,
  );
}

// Drive the graph reader too: these refusals prevent a newly committed raw
// from blessing missing sites, ambiguity, a missing family or a malformed entry.
const graph = fs.mkdtempSync(path.join(os.tmpdir(), "claude-model-facts-"));
try {
  for (const name of ["model-catalog", "model-pins", "model-retired"])
    fs.writeFileSync(path.join(graph, `${name}.js`), fixture(`${name}.js.txt`));
  check(
    "graph: subtracts retired IDs and keeps both static pin guards but not the dynamic push",
    JSON.stringify(L.modelFacts(graph, ts)) ===
      JSON.stringify({
        launchEffortPins: [
          "unpinFable5LaunchEffort",
          "unpinOpus47LaunchEffort",
        ],
        models: ["claude-haiku-5", "claude-opus-5", "claude-sonnet-5"],
      }),
  );
  for (const [name, source, diagnostic] of [
    [
      "model-catalog",
      fixture("decoy-model-catalog.js.txt"),
      "LOCATION failure: catalog site: expected exactly 1 chunk, found 0",
    ],
    [
      "model-pins",
      fixture("decoy-model-pins.js.txt"),
      "LOCATION failure: pins site: expected exactly 1 chunk, found 0",
    ],
    [
      "model-retired",
      fixture("decoy-model-retired.js.txt"),
      "LOCATION failure: retired site: expected exactly 1 chunk, found 0",
    ],
    [
      "model-catalog",
      'var C=[{id:"claude-opus-5",family:"opus"}];',
      "no 'haiku' id",
    ],
    [
      "model-catalog",
      'var C=[{id:"claude-opus-5",family:"opus"},{id:"claude-stray"}];',
      "entry without literal id/family",
    ],
  ]) {
    const file = path.join(graph, `${name}.js`);
    fs.writeFileSync(file, source);
    const error = failureMessage(() => L.modelFacts(graph, ts));
    check(`graph: refuses ${diagnostic}`, error.includes(diagnostic), error);
    fs.writeFileSync(file, fixture(`${name}.js.txt`));
  }
  fs.writeFileSync(
    path.join(graph, "duplicate.js"),
    fixture("model-catalog.js.txt"),
  );
  const error = failureMessage(() => L.modelFacts(graph, ts));
  check(
    "graph: refuses ambiguous catalog location",
    error.includes("catalog site: expected exactly 1 chunk, found 2"),
    error,
  );
} finally {
  fs.rmSync(graph, { recursive: true, force: true });
}

// ── The slices may load only modules the settings-schema closure loaded ──
// A slice that imports any other chunk would evaluate code no init thunk
// prepared, so census.mjs refuses it by name. A census that dropped that
// comparison passes the first case and fails the second. Each case runs in
// its own node process: loadSplit registers process-wide loader hooks once.
{
  const tree = fs.mkdtempSync(path.join(os.tmpdir(), "claude-load-split-"));
  try {
    const write = (name, src) => fs.writeFileSync(path.join(tree, name), src);
    write("shared.js", "export function u(){return 1}");
    write("extra.js", "export function x(){return 2}");
    // The slice is served under its declaring chunk's URL; that chunk exists,
    // as it does in the unpacked tree, and must never itself be evaluated.
    write("decl.js", 'throw new Error("declaring chunk evaluated")');
    const schema =
      'import{u}from"/$bunfs/root/shared.js";function b(){return u()}';
    write("schema.js", schema);
    const loadSplit = (sliceImport) =>
      spawnSync(
        process.execPath,
        [
          "--input-type=module",
          "-e",
          `const{loadSplit}=await import(process.argv[1]);` +
            `await loadSplit(process.argv[2],JSON.parse(process.argv[3]));`,
          pathToFileURL(path.join(extractDir, "census.mjs")).href,
          tree,
          JSON.stringify({
            build: "b",
            schemaPath: path.join(tree, "schema.js"),
            slices: [
              {
                path: path.join(tree, "decl.js"),
                roles: { convert: "c", filter: "f" },
                source: `${sliceImport}function c(e){return e}function f(){}`,
              },
            ],
            src: schema,
            thunks: [],
          }),
        ],
        { encoding: "utf8" },
      );
    const inside = loadSplit('import{u}from"/$bunfs/root/shared.js";');
    check(
      "loadSplit: a slice importing a schema-closure module loads",
      inside.status === 0,
      inside.stderr,
    );
    const outside = loadSplit('import{x}from"/$bunfs/root/extra.js";');
    check(
      "loadSplit: refuses a slice that loads a module outside the schema closure",
      outside.status !== 0 &&
        outside.stderr.includes(
          "census: the slices load modules outside the settings-schema closure: extra.js",
        ),
      outside.stderr,
    );
  } finally {
    fs.rmSync(tree, { recursive: true, force: true });
  }
}

if (failures) {
  console.error(`${failures} locator case(s) failed`);
  process.exit(1);
}
console.log("all locator cases passed");
