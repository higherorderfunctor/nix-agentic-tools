#!/usr/bin/env node
// census.mjs — emit the `settings` block of overlays/claude-code-extracted.json
// by driving the claude-code binary's OWN settings-schema builder, its OWN
// zod -> JSON-Schema converter and its OWN @internal filter.
//
//   node census.mjs <unpacked-root> [--out FILE] [--legacy] [--diagnostics]
//
// Nothing in the OUTPUT contains a chunk filename, a minified identifier, a
// byte offset or a module count. macOS and Linux builds of one version do not
// agree on any of those, so everything is located by CONTENT — see locate.mjs
// and the anchor justification in the accompanying report.

import fs from "node:fs";
import { registerHooks } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import * as L from "./locate.mjs";

// LC_ALL=C ordering — byte order, which is what `sort` hands the drift check.
const cmpC = (a, b) =>
  Buffer.compare(Buffer.from(a, "utf8"), Buffer.from(b, "utf8"));
const sortC = (xs) => [...xs].sort(cmpC);
const sortObj = (o) =>
  Object.fromEntries(sortC(Object.keys(o)).map((k) => [k, o[k]]));

// ---------------------------------------------------------------------------
// Topology 1: post-code-split (>= 2.1.245). The settings module is its own ESM
// chunk with no top-level side effects, so it can simply be imported.
// ---------------------------------------------------------------------------
let hooksRegistered = false;

async function loadSplit(root, info) {
  const url = pathToFileURL(info.settingsPath).href;
  const shim =
    ";export{" +
    [
      `${info.symbols.build} as __c_build`,
      `${info.symbols.convert} as __c_convert`,
      `${info.symbols.filter} as __c_filter`,
      ...info.thunks.map((t, i) => `${t} as __c_init${i}`),
    ].join(",") +
    "};";

  if (hooksRegistered)
    throw new Error("census: one process can drive one unpack root");
  hooksRegistered = true;
  registerHooks({
    // The unpacked chunks still carry bun's virtual-filesystem specifiers.
    resolve(spec, ctx, next) {
      if (L.isBunfs(spec)) {
        return {
          url: pathToFileURL(L.bunfsToPath(root, spec)).href,
          shortCircuit: true,
        };
      }
      return next(spec, ctx);
    },
    // Re-export the three located symbols under stable names, so nothing
    // downstream has to know a minified export alias. `convert` is an IMPORT
    // binding in this module; ESM lets an import be re-exported by local name,
    // which is how the re-export chain gets resolved without naming a chunk.
    load(u, ctx, next) {
      if (u === url)
        return {
          format: "module",
          source: info.src + shim,
          shortCircuit: true,
        };
      return next(u, ctx);
    },
  });

  const mod = await import(url);
  // The bundle is lazily initialized: every module body sits behind a memoised
  // thunk and the only thing that normally calls them is the CLI entry point,
  // which would start Claude Code. Calling THIS module's own thunks instead
  // initializes precisely the transitive closure the settings schema needs.
  const initErrors = [];
  let ran = 0,
    total = 0;
  for (const k of Object.keys(mod)) {
    if (!k.startsWith("__c_init")) continue;
    total++;
    try {
      mod[k]();
      ran++;
    } catch (e) {
      initErrors.push(String(e && e.message).slice(0, 120));
    }
  }
  return { mod, ran, total, initErrors, topology: "split" };
}

// ---------------------------------------------------------------------------
// Topology 2: pre-code-split (<= 2.1.241). One CJS blob whose last statement
// launches the CLI. mono.mjs strips that statement and stubs out every network
// and process-spawn primitive before evaluating.
// ---------------------------------------------------------------------------
// DELIBERATELY UNSUPPORTED. A monolith loader was written and measured working
// against 2.1.241, then dropped rather than shipped: it has to evaluate ~28MB of
// CLI code with the trailing bootstrap statement stripped, and the only thing
// standing between that and actually launching the CLI is a require-guard
// handing back inert stubs for net/tls/http. That is a lot of standing hazard to
// carry for a topology upstream already left behind.
//
// If upstream re-monoliths, this SHOULD fail the build loudly rather than
// quietly resurrecting that evaluator -- a held-back package with a legible
// reason is the outcome we want. Recovering it means restoring the loader from
// this commit's history, not loosening anything here.
function loadMono(root, info, scratch) {
  void root;
  void info;
  void scratch;
  throw new Error(
    "claude-census: this binary is a pre-code-split monolith (no chunk-*.js modules). " +
      "The monolith loader was deliberately not shipped -- see the comment above " +
      "loadMono in this file. Upstream code-split between 2.1.241 and 2.1.245; if it " +
      "has gone back to a monolith, restore the loader rather than working around this.",
  );
}

// ---------------------------------------------------------------------------
// Flatten the emitted JSON Schema into the sidecar's dotted-path map.
//
//   properties           ->  a.b
//   additionalProperties ->  a.*        (user-keyed map values)
//   items                ->  a[]        (array elements)
//   anyOf                ->  a|0, a|1   (the one grammar extension — see report)
// ---------------------------------------------------------------------------
function nodeType(n) {
  if (typeof n.type === "string") return n.type;
  if (Array.isArray(n.type)) return n.type.join("|");
  if (n.enum) return "enum";
  if (n.const !== undefined) return "const";
  if (n.anyOf) return "anyOf";
  if (n.not !== undefined) return "never";
  return "any";
}

// For an object whose property NAMES are pinned to a fixed vocabulary
// (`z.record` over an enum key), report that vocabulary. This is the only
// place a `type:"object"` record carries an `enum`, and it is what makes the
// legacy `hookEvents` list derivable from the census.
function propertyNameEnum(n) {
  const pn = n.propertyNames;
  if (!pn || typeof pn !== "object") return null;
  if (Array.isArray(pn.enum)) return pn.enum;
  if (Array.isArray(pn.anyOf)) {
    const enums = pn.anyOf.filter((b) => Array.isArray(b.enum));
    // `z.never()` renders as `{not:{}}` and widens nothing; a bare
    // `{type:"string"}` branch WOULD, and makes the vocabulary open.
    const open = pn.anyOf.some(
      (b) => !Array.isArray(b.enum) && b.not === undefined,
    );
    if (enums.length === 1 && !open) return enums[0].enum;
  }
  return null;
}

function flatten(root) {
  const out = {};
  const raw = {}; // same enums in SOURCE order, for the legacy keys that need it
  const seen = new Set();
  const record = (p, n) => {
    const rec = { type: nodeType(n) };
    const e = Array.isArray(n.enum) ? n.enum : propertyNameEnum(n);
    if (e) {
      const vals = e.map(String);
      rec.enum = sortC(vals);
      raw[p] = vals;
    }
    out[p] = rec;
  };
  (function walk(n, p) {
    if (!n || typeof n !== "object" || seen.has(n)) return;
    seen.add(n);
    for (const [k, v] of Object.entries(n.properties || {})) {
      const q = p ? `${p}.${k}` : k;
      record(q, v);
      walk(v, q);
    }
    // A trailing `.*` means "user-keyed map", and both consumers read it that
    // way. zod's .passthrough()/.catchall(z.any()) lands here too but is NOT
    // that: it is an escape hatch hanging off a node that has its own named
    // children. Recording it silently opens the container -- a nested typo
    // under `permissions` stops being caught, and the option generator
    // degrades the whole record to freeform. So skip an unconstrained
    // catch-all whenever named siblings exist, and skip the root one outright
    // (its path would carry an empty first segment, outside the grammar the
    // sidecar documents). Not walking into it drops its descendants too.
    if (n.additionalProperties && typeof n.additionalProperties === "object") {
      const hasNamedSiblings = Object.keys(n.properties || {}).length > 0;
      const unconstrained = nodeType(n.additionalProperties) === "any";
      if (p !== "" && !(unconstrained && hasNamedSiblings)) {
        const q = `${p}.*`;
        record(q, n.additionalProperties);
        walk(n.additionalProperties, q);
      }
    }
    if (n.items && typeof n.items === "object") {
      const q = `${p}[]`;
      record(q, n.items);
      walk(n.items, q);
    }
    (n.anyOf || []).forEach((o, i) => {
      const q = `${p}|${i}`;
      record(q, o);
      walk(o, q);
    });
  })(root, "");
  return { paths: out, raw };
}

// ---------------------------------------------------------------------------
// Input aliases the emitted enum cannot show.
//
// `permissions.defaultMode` is declared `z.preprocess(fn, z.enum([...]))`:
// a user may type "manual" and the wrapper rewrites it to "default", so the
// emitted (output-side) enum omits a value the validator ACCEPTS. Rather than
// special-casing that key, walk the zod graph for EVERY transform sitting in
// front of an enum, read the alias out of the transform itself, and confirm it
// against the real validator before widening anything.
// ---------------------------------------------------------------------------
const UNWRAP = ["innerType", "element", "valueType", "schema"];

function collectTransforms(node, p, acc, depth, seen) {
  if (!node || depth > 40) return;
  const def = node._zod && node._zod.def;
  if (!def || seen.has(node)) return;
  seen.add(node);
  switch (def.type) {
    case "pipe": {
      const inDef = def.in && def.in._zod && def.in._zod.def;
      if (
        inDef &&
        inDef.type === "transform" &&
        typeof inDef.transform === "function"
      ) {
        acc.push({ path: p, fn: inDef.transform });
      }
      collectTransforms(def.in, p, acc, depth + 1, seen);
      collectTransforms(def.out, p, acc, depth + 1, seen);
      return;
    }
    case "object": {
      const shape = typeof def.shape === "function" ? def.shape() : def.shape;
      for (const [k, v] of Object.entries(shape || {})) {
        collectTransforms(v, p ? `${p}.${k}` : k, acc, depth + 1, seen);
      }
      return;
    }
    case "record":
    case "map":
      collectTransforms(def.valueType, `${p}.*`, acc, depth + 1, seen);
      return;
    case "array":
      collectTransforms(def.element, `${p}[]`, acc, depth + 1, seen);
      return;
    case "union":
      (def.options || []).forEach((o, i) => {
        collectTransforms(o, `${p}|${i}`, acc, depth + 1, seen);
      });
      return;
    case "lazy":
      try {
        collectTransforms(def.getter(), p, acc, depth + 1, seen);
      } catch {
        /* opaque */
      }
      return;
    default:
      for (const k of UNWRAP)
        if (def[k]) collectTransforms(def[k], p, acc, depth + 1, seen);
  }
}

const LITERALS_RE = /"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'/g;

function discoverAliases(schema, paths) {
  const acc = [];
  collectTransforms(schema, "", acc, 0, new Set());
  const found = [];
  for (const { path: p, fn } of acc) {
    const rec = paths[p];
    if (!rec || !rec.enum) continue;
    const members = new Set(rec.enum);
    let src;
    try {
      src = String(fn);
    } catch {
      continue;
    }
    const cands = new Set();
    // `matchAll` over `.exec` in a loop: it clones the regex internally, so the
    // module-level LITERALS_RE's own `lastIndex` is never advanced and no reset
    // is needed between transforms. An `exec` loop here DID need one, and
    // forgetting it would have made every alias after the first depend on the
    // length of the previous function's source.
    for (const m of src.matchAll(LITERALS_RE)) {
      cands.add(m[1] !== undefined ? m[1] : m[2]);
    }
    for (const c of cands) {
      if (members.has(c)) continue;
      let out;
      try {
        out = fn(c, { value: c, issues: [] });
      } catch {
        continue;
      }
      if (typeof out === "string" && members.has(out))
        found.push({ path: p, alias: c, becomes: out });
    }
  }
  return found;
}

// End-to-end confirmation: does the REAL validator accept the alias?
function confirmAlias(schema, p, alias) {
  if (/[|*[\]]/.test(p)) return null; // only plain dotted paths are constructible
  const segs = p.split(".");
  const doc = {};
  let cur = doc;
  for (let i = 0; i < segs.length - 1; i++) cur = cur[segs[i]] = {};
  cur[segs[segs.length - 1]] = alias;
  try {
    return schema.safeParse(doc).success;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
export async function census(
  root,
  scratch = path.dirname(new URL(import.meta.url).pathname),
) {
  const info = L.locate(root);
  const loaded =
    info.exports.size > 0
      ? await loadSplit(root, info)
      : loadMono(root, info, scratch);
  const { mod } = loaded;

  const build = () => mod.__c_build(info.features);

  const fullSchema = build();
  const fullJson = mod.__c_convert(fullSchema, { unrepresentable: "any" });
  mod.__c_filter(fullJson, true); // keep @internal keys, strip the marker prefix

  const pubJson = mod.__c_convert(build(), { unrepresentable: "any" });
  mod.__c_filter(pubJson, false); // the binary's OWN public-schema filter

  const fullTop = Object.keys(fullJson.properties || {});
  const pubTop = new Set(Object.keys(pubJson.properties || {}));

  const { paths, raw } = flatten(fullJson);

  const applied = [];
  for (const a of discoverAliases(fullSchema, paths)) {
    const ok = confirmAlias(fullSchema, a.path, a.alias);
    if (ok === false) continue; // the validator rejects it; do not widen the enum
    paths[a.path].enum = sortC([...new Set([...paths[a.path].enum, a.alias])]);
    applied.push({ ...a, confirmedByValidator: ok });
  }

  return {
    settings: {
      publicKeys: sortC(fullTop.filter((k) => pubTop.has(k))),
      internalKeys: sortC(fullTop.filter((k) => !pubTop.has(k))),
      paths: sortObj(paths),
    },
    rawEnums: raw,
    diagnostics: {
      topology: loaded.topology,
      settingsModule: path.basename(info.settingsPath),
      locatedVia: info.via,
      alternateAnchorsAgree:
        info.alternates.build === info.symbols.build &&
        info.alternates.convert === info.symbols.convert &&
        info.alternates.filter === info.symbols.filter,
      features: info.features,
      initThunksRun: `${loaded.ran}/${loaded.total}`,
      distinctInitErrors: [...new Set(loaded.initErrors)],
      aliasesApplied: applied,
      openHandles: (process._getActiveHandles
        ? process._getActiveHandles()
        : []
      )
        .map((h) => h.constructor && h.constructor.name)
        .filter((n) => n !== "WriteStream" && n !== "Socket"),
    },
  };
}

// ---------------------------------------------------------------------------
// The five legacy sidecar keys, so far as the census can honestly supply them.
// `rawEnums` carries SOURCE order, which `effortLevels` needs (the committed
// sidecar is low/medium/high/xhigh — a ladder, not a sort).
// ---------------------------------------------------------------------------
export function legacyFromCensus(settings, rawEnums) {
  const allTop = sortC([...settings.publicKeys, ...settings.internalKeys]);
  const paths = settings.paths;

  const effort = new Set();
  for (const [p, vals] of Object.entries(rawEnums)) {
    const last = p
      .split(".")
      .pop()
      .replace(/\[\]$/, "")
      .replace(/\|\d+$/, "");
    if (last === "effortLevel") effort.add(JSON.stringify(vals));
  }

  return {
    // NOT derivable from the settings schema — these are local-config keys.
    launchEffortPins: null,
    effortLevels: effort.size === 1 ? JSON.parse([...effort][0]) : null,
    effortLevelEnumsSeen: effort.size,
    hookEvents: paths.hooks && paths.hooks.enum ? paths.hooks.enum : null,
    // The legacy key is a hand-written triple that the old grep only VALIDATED;
    // the census can supply every boolean top-level key instead.
    settingsBooleanKeys: [
      "enableWorkflows",
      "ultracode",
      "workflowKeywordTriggerEnabled",
    ].filter((k) => paths[k] && paths[k].type === "boolean"),
    settingsBooleanKeysAll: allTop.filter(
      (k) => paths[k] && paths[k].type === "boolean",
    ),
    models: null, // a separate catalog module — see report
  };
}

// ---------------------------------------------------------------------------
if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  const root = process.argv[2];
  if (!root) {
    console.error(
      "usage: census.mjs <unpacked-root> [--out FILE] [--legacy] [--diagnostics]",
    );
    process.exit(2);
  }
  const outIdx = process.argv.indexOf("--out");
  const out = outIdx > -1 ? process.argv[outIdx + 1] : null;
  const r = await census(path.resolve(root));
  const doc = { settings: r.settings };
  if (process.argv.includes("--legacy"))
    doc.legacy = legacyFromCensus(r.settings, r.rawEnums);
  if (process.argv.includes("--diagnostics")) doc.diagnostics = r.diagnostics;
  const text = JSON.stringify(doc, null, 2) + "\n";
  if (out) {
    fs.writeFileSync(out, text);
    console.error(JSON.stringify(r.diagnostics));
    process.exit(0);
  }
  // Never process.exit() before the pipe has drained — a large document to a
  // pipe is truncated otherwise.
  process.stdout.write(text, () => process.exit(0));
}
