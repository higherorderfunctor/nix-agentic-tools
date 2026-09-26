#!/usr/bin/env node
// claude-extract-locate.mjs — fixture gate for the memoizer anchor in
// packages/claude-code/extract/locate.mjs.
//
//   node claude-extract-locate.mjs <extract-dir> <fixture-dir>
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

import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [extractDir, fixtureDir] = process.argv.slice(2);
if (!extractDir || !fixtureDir) {
  console.error("usage: claude-extract-locate.mjs <extract-dir> <fixture-dir>");
  process.exit(2);
}
const L = await import(pathToFileURL(path.join(extractDir, "locate.mjs")).href);

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

// ── Every shape that has shipped confirms, with the right local and count ──
const shipped = [
  ["memo-bun.js.txt", "k", "M", 3],
  ["memo-registry-cell.js.txt", "f", "f", 2],
  ["memo-registry-built.js.txt", "f", "f", 4],
  // A `$` in the importing module's local name is a RegExp metacharacter
  // when interpolated; the locator must escape it rather than mis-scan.
  ["memo-registry-built.js.txt", "f", "$M", 2],
];
for (const [file, exported, local, n] of shipped) {
  const src = settingsUsing(`./${file}`, exported, local, n);
  const memo = L.locateMemoizerLocal(src, readSpec);
  check(
    `${file} as ${local}: confirmed from the defining module`,
    memo !== null &&
      memo.source === "import" &&
      memo.local === local &&
      memo.spec === `./${file}` &&
      memo.thunkSites === n &&
      memo.all.length === 1,
    memo,
  );
  if (memo)
    check(
      `${file} as ${local}: enumerates ${n} init thunks`,
      L.locateInitThunks(src, memo.local).length === n,
    );
}

// ── The registry method is recognised by contract, not by body text ──
for (const file of [
  "memo-registry-cell.js.txt",
  "memo-registry-built.js.txt",
]) {
  const m = L.locateLazyRegistryMethod(fixture(file));
  check(
    `${file}: lazy(e) owns cell t`,
    m !== null && m.param === "e" && m.cell === "t",
    m,
  );
}
check(
  "memo-bun.js: bun lowering is NOT mistaken for the registry",
  L.locateLazyRegistryMethod(fixture("memo-bun.js.txt")) === null,
);

// ── Decoys must not confirm, however the importing module uses them ──
for (const file of [
  "decoy-no-resetter.js.txt",
  "decoy-plain-call.js.txt",
  "decoy-two-registries.js.txt",
]) {
  const src = settingsUsing(`./${file}`, "f", "f", 3);
  check(
    `${file}: rejected despite 3 thunk-shaped call sites`,
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
    "bun + registry in one module: both families reported",
    memo !== null &&
      memo.all.length === 2 &&
      memo.all
        .map((m) => m.thunkSites)
        .sort()
        .join() === "2,3",
    memo,
  );
}

// ── Nothing imported and nothing inline: fail closed ──
check(
  "no memoizer anywhere: null, not a guess",
  L.locateMemoizerLocal("var A=1;", readSpec) === null,
);

if (failures) {
  console.error(`${failures} memoizer-locator case(s) failed`);
  process.exit(1);
}
console.log("all memoizer-locator cases passed");
