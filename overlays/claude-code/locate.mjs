// locate.mjs — content-only location of the claude-code settings-schema machinery.
//
// Every anchor below is a STRING or STRUCTURAL pattern. Nothing here names a
// chunk file, a minified identifier, a byte offset or a module count. Minified
// identifiers are only ever CAPTURED (via backreferences), never written down.
//
// ANCHOR JUSTIFICATION — could upstream change this without a user-visible
// behavior change?
//
//  1. "JSON Schema reference for Claude Code settings"
//     The description of the `$schema` key of settings.json. `$schema` is a key
//     users type and editors act on; its description ships in the public schema.
//     Reword-able in principle, so it is one of THREE required anchors and has
//     an independent cross-check (anchor 2 locates the same function).
//
//  2. `unrepresentable:"any"`
//     A documented PUBLIC option of zod's `toJSONSchema`. Changing it changes
//     how unrepresentable types render in the schema users consume — i.e. it is
//     a user-visible behavior change, which is exactly the property we want.
//
//  3. `/^@internal`
//     The marker regex behind the public/internal split. Any change here moves
//     keys between the published and unpublished sets — the most user-visible
//     change this whole extractor exists to track.
//
//  4. The composite emitter statement (EMITTER_RE)
//     `f ? build(f) : buildGated()`, then `convert(s,{unrepresentable:"any"})`,
//     then `filter(j,!1)`. Structural, not lexical: it pins the three symbols
//     to each other in one match, so a rename cannot silently re-point one of
//     them. It IS coupled to minifier output shape (`let` vs `var`, statement
//     fusion), which is why each of the three has an independent fallback and
//     the two answers are asserted equal.
//
//  5. `.filter((x) => REG[x].buildGate())` and `{ buildGate: … }`
//     `buildGate` / `shape` / `permissionModes` are object PROPERTY names, which
//     bun's minifier does not rename. Each registry entry contributes settings
//     keys and permission modes, so removing one removes user-visible keys.
//
//  6. The lazy-thunk memoizer
//     The one anchor NOT tied to upstream behavior. Unavoidable — the module
//     graph is lazily initialized and the only other way to run the
//     initializers is to import the CLI entry point, which starts Claude Code.
//     It is confirmed structurally: the candidate must be the callee this
//     module wraps its own thunks with AND must be the export whose defining
//     module matches a memoizer body.
//
//     TWO mechanisms are recognised, because this stopped being bundler
//     runtime at 2.1.248. Through 2.1.245 it was bun's `__esm` ESM lowering,
//     `(a,b)=>()=>(a&&(b=a(a=0)),b)`, and the note here read "it is bundler
//     runtime … it changes when Bun changes its ESM lowering". Upstream then
//     replaced it with their OWN ~800-byte helper module exporting a
//     resettable lazy registry. So this anchor now tracks APPLICATION code
//     that merely looks like bundler plumbing — which means it can move for
//     product reasons, not just on a Bun upgrade. See MEMO_LAZY_METHOD_RE.

import fs from "node:fs";
import path from "node:path";

// ---------------------------------------------------------------------------
// Content anchors. Each one is a literal that upstream cannot change without a
// user-visible behavior change (see the justification table in the report).
// ---------------------------------------------------------------------------
export const ANCHORS = {
  // The description string attached to the `$schema` key of settings.json.
  // Users type `$schema` in settings.json; this is its documented description.
  schemaKeyDescription: "JSON Schema reference for Claude Code settings",
  // The zod v4 `toJSONSchema` option object used at the settings emit site.
  // "unrepresentable" is a documented public zod option name.
  unrepresentableAny: 'unrepresentable:"any"',
  // Source text of the marker regex that drives the @internal key filter.
  // "@internal" is the marker upstream writes into descriptions of keys it
  // does not publish; the leading `^` is part of the predicate.
  internalMarkerRegex: "/^@internal",
  // The bun ESM-lowering helper module carries this React sentinel.
  reactMemoSentinel: 'Symbol.for("react.memo_cache_sentinel")',
};

const BUNFS_PREFIX = "/$bunfs/root/";

export function isBunfs(spec) {
  return spec.startsWith(BUNFS_PREFIX);
}
export function bunfsToPath(root, spec) {
  return path.join(root, spec.slice(BUNFS_PREFIX.length));
}

// ---------------------------------------------------------------------------
// Locate the settings machinery by anchor, tolerating TWO module topologies.
//
// Through 2.1.245 upstream shipped all three anchors in ONE chunk. 2.1.248
// SPLIT them: the `$schema` description and the feature-gate registry stayed
// with the schema, while `unrepresentable:"any"` and `/^@internal` moved to a
// separate emitter chunk that imports the builder back. (Measured 2.1.250:
// chunk-a891q37t.js 152 K schema side, chunk-8v512hc9.js 60 K emitter side,
// alongside a 392 MB -> 224 MB binary and `// @bun @bytecode` headers — i.e.
// upstream turned on Bun bytecode compilation and re-chunked.)
//
// That is a BUNDLER change, not a behavior change, so it must not be fatal.
// What still has to hold is that each side is unambiguous: exactly one module
// carries the schema anchor and exactly one carries BOTH emitter anchors. The
// two may be the same file (monolith) or different files (split); anything
// else still fails closed, because an ambiguous match is the case where a
// silently wrong extraction becomes possible.
//
// The builder is deliberately NOT resolved here — it is cross-checked in
// `locate()` from both sides, and those two answers agreeing across the split
// is what proves the split was re-chunking rather than a reshape.
// ---------------------------------------------------------------------------
export function findSettingsModules(root) {
  const schemaAnchor = Buffer.from(ANCHORS.schemaKeyDescription, "utf8");
  const emitterAnchors = [
    ANCHORS.unrepresentableAny,
    ANCHORS.internalMarkerRegex,
  ].map((s) => Buffer.from(s, "utf8"));

  const schemaHits = [];
  const emitterHits = [];
  for (const name of fs.readdirSync(root)) {
    const p = path.join(root, name);
    let st;
    try {
      st = fs.statSync(p);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    // Native addons and images cannot be the settings module; skip by content,
    // not by name: only files whose bytes actually carry an anchor qualify.
    let buf;
    try {
      buf = fs.readFileSync(p);
    } catch {
      continue;
    }
    if (buf.indexOf(schemaAnchor) !== -1) schemaHits.push(p);
    if (emitterAnchors.every((b) => buf.indexOf(b) !== -1)) emitterHits.push(p);
  }

  const exactlyOne = (hits, what, carrying) => {
    if (hits.length !== 1)
      throw new Error(
        `${what}: expected exactly 1 file carrying ${carrying}, found ` +
          hits.length +
          (hits.length
            ? ` (${hits.map((h) => path.basename(h)).join(", ")})`
            : "") +
          " — upstream reshaped the settings schema or split it further",
      );
    return hits[0];
  };

  return {
    schemaPath: exactlyOne(
      schemaHits,
      "settings schema module",
      "the $schema-description anchor",
    ),
    emitterPath: exactlyOne(
      emitterHits,
      "settings emitter module",
      "both the unrepresentable and @internal anchors",
    ),
  };
}

// ---------------------------------------------------------------------------
// Static parsing of one module's ESM import list.
// ---------------------------------------------------------------------------
export function parseImports(src) {
  const map = new Map(); // local -> { exported, spec }
  const re = /import\{([^}]*)\}from"([^"]+)"/g;
  for (const m of src.matchAll(re)) {
    for (const part of m[1].split(",")) {
      const [a, b] = part.split(" as ");
      const exported = a.trim();
      const local = (b === undefined ? a : b).trim();
      if (local) map.set(local, { exported, spec: m[2] });
    }
  }
  return map;
}

// `export{local as ALIAS,...}` — resolve minified export aliases statically.
export function parseExports(src) {
  const map = new Map(); // local -> alias
  const i = src.lastIndexOf("export{");
  if (i === -1) return map;
  const j = src.indexOf("}", i);
  for (const part of src.slice(i + "export{".length, j).split(",")) {
    const [a, b] = part.split(" as ");
    const local = a.trim();
    if (local) map.set(local, (b === undefined ? a : b).trim());
  }
  return map;
}

// ---------------------------------------------------------------------------
// Brace/paren matching good enough for minified bundles (skips string and
// template literals; regex literals are not scanned for braces because the
// spans we walk never start inside one).
// ---------------------------------------------------------------------------
function skipString(src, i) {
  const q = src[i];
  i++;
  while (i < src.length) {
    if (src[i] === "\\") {
      i += 2;
      continue;
    }
    if (src[i] === q) return i;
    i++;
  }
  return i;
}

export function matchBraces(src, openIdx) {
  let d = 0;
  for (let i = openIdx; i < src.length; i++) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") {
      i = skipString(src, i);
      continue;
    }
    if (c === "{") d++;
    else if (c === "}") {
      d--;
      if (d === 0) return i;
    }
  }
  return -1;
}

// Given the index of a `function NAME(` token, return {name,start,end}.
export function functionSpan(src, fnKeywordIdx) {
  const m = /^function\s+([A-Za-z0-9_$]+)\s*\(/.exec(
    src.slice(fnKeywordIdx, fnKeywordIdx + 80),
  );
  if (!m) return null;
  // balance the parameter list, then the body
  let i = fnKeywordIdx + m[0].length - 1;
  let d = 0;
  for (; i < src.length; i++) {
    const c = src[i];
    if (c === '"' || c === "'" || c === "`") {
      i = skipString(src, i);
      continue;
    }
    if (c === "(") d++;
    else if (c === ")") {
      d--;
      if (d === 0) break;
    }
  }
  const open = src.indexOf("{", i);
  const end = matchBraces(src, open);
  return { name: m[1], start: fnKeywordIdx, bodyStart: open, end };
}

// The innermost `function NAME(...)` whose body encloses `idx`.
export function enclosingFunction(src, idx) {
  let best = null;
  const re = /function\s+[A-Za-z0-9_$]+\s*\(/g;
  for (const m of src.matchAll(re)) {
    // The exec loop this replaces was `while (… && m.index < idx)`, so the
    // first match at or past `idx` ENDED the scan rather than skipping it.
    if (m.index >= idx) break;
    const span = functionSpan(src, m.index);
    if (!span || span.end < idx) continue;
    if (span.bodyStart < idx && idx < span.end) {
      if (!best || span.start > best.start) best = span;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// The three symbols we need, located by content within the settings module.
// ---------------------------------------------------------------------------

// PRIMARY: the composite public-schema emitter. One statement wires all three
// together, so one match cross-checks all three names against each other:
//
//   function A(f){ let s = f ? BUILD(f) : BUILD_GATED();
//                  let j = CONVERT(s, {unrepresentable:"any"});
//                  return FILTER(j, !1), STRINGIFY(j, null, 2) }
const EMITTER_RE = new RegExp(
  "function\\s+[A-Za-z0-9_$]+\\(([A-Za-z0-9_$]+)\\)\\{" +
    "(?:let|var|const)\\s+([A-Za-z0-9_$]+)=\\1\\?([A-Za-z0-9_$]+)\\(\\1\\):([A-Za-z0-9_$]+)\\(\\)," +
    '([A-Za-z0-9_$]+)=([A-Za-z0-9_$]+)\\(\\2,\\{unrepresentable:"any"\\}\\);' +
    "return\\s+([A-Za-z0-9_$]+)\\(\\5,",
);

export function locateEmitter(src) {
  const m = EMITTER_RE.exec(src);
  if (!m) return null;
  return { build: m[3], buildGated: m[4], convert: m[6], filter: m[7] };
}

// FALLBACK for the builder: the function whose body contains the description
// of the `$schema` settings key IS the settings-schema builder.
export function locateBuilderByDescription(src) {
  const i = src.indexOf(ANCHORS.schemaKeyDescription);
  if (i === -1) return null;
  const span = enclosingFunction(src, i);
  return span ? span.name : null;
}

// FALLBACK for the converter: the sole callee invoked with the
// `{unrepresentable:"any"}` option object.
export function locateConverterByOption(src) {
  const re =
    /([A-Za-z0-9_$]+)\(\s*[A-Za-z0-9_$]+\s*,\s*\{unrepresentable:"any"\}\s*\)/g;
  const names = new Set();
  for (const m of src.matchAll(re)) names.add(m[1]);
  return names.size === 1 ? [...names][0] : null;
}

// FALLBACK for the filter: find the var holding /^@internal…/, then the
// predicate that `.test`s it, then the self-recursive function that calls the
// predicate against `.description`.
export function locateFilterByMarker(src) {
  const mv = /([A-Za-z0-9_$]+)\s*=\s*\/\^@internal[^/]*\/[a-z]*/.exec(src);
  if (!mv) return null;
  const markerVar = mv[1];
  const mp = new RegExp(
    'function\\s+([A-Za-z0-9_$]+)\\(([A-Za-z0-9_$]+)\\)\\{return typeof \\2==="string"&&' +
      markerVar.replace(/\$/g, "\\$") +
      "\\.test\\(\\2\\)\\}",
  ).exec(src);
  if (!mp) return null;
  const pred = mp[1];
  const re = /function\s+[A-Za-z0-9_$]+\s*\(/g;
  const found = [];
  for (const m of src.matchAll(re)) {
    const span = functionSpan(src, m.index);
    if (!span || span.end < 0) continue;
    const body = src.slice(span.bodyStart, span.end);
    if (body.includes(pred + "(") && body.includes(span.name + "(")) {
      found.push({ name: span.name, size: span.end - span.bodyStart });
    }
  }
  if (!found.length) return null;
  // A minified bundle contains regex literals carrying unbalanced braces, so a
  // brace walk can over-run and report an OUTER function that merely encloses
  // the real one. The filter is the tightest function satisfying both
  // conditions, so take the smallest body.
  found.sort((a, b) => a.size - b.size);
  return found[0].name;
}

// ---------------------------------------------------------------------------
// The feature-gate registry. Every feature contributes extra settings keys and
// extra permission modes, so the full list is what makes the census a superset
// rather than a snapshot of one machine's runtime gates.
//
//   function G(){ return LIST.filter((x) => REG[x].buildGate()) }
//   LIST=["…","…"], REG={ "…":{ buildGate:… , shape:… } }
// ---------------------------------------------------------------------------
export function locateFeatureList(src) {
  const m =
    /function\s+[A-Za-z0-9_$]+\(\)\{return ([A-Za-z0-9_$]+)\.filter\(\(([A-Za-z0-9_$]+)\)=>([A-Za-z0-9_$]+)\[\2\]\.buildGate\(\)\)\}/.exec(
      src,
    );
  const listVar = m ? m[1] : null;
  if (listVar) {
    const lit = new RegExp(
      "(?:^|[^A-Za-z0-9_$.])" +
        listVar.replace(/\$/g, "\\$") +
        "=(\\[[^\\]]*\\])",
    ).exec(src);
    if (lit) {
      try {
        const arr = JSON.parse(lit[1]);
        if (
          Array.isArray(arr) &&
          arr.length &&
          arr.every((x) => typeof x === "string")
        )
          return arr;
      } catch {
        /* fall through */
      }
    }
  }
  // FALLBACK: the registry literal itself — `LIST=[…],REG={first:{buildGate:`
  const f =
    /([A-Za-z0-9_$]+)=(\["[^\]]*"\]),([A-Za-z0-9_$]+)=\{([A-Za-z0-9_$]+):\{buildGate:/.exec(
      src,
    );
  if (f) {
    try {
      const arr = JSON.parse(f[2]);
      if (arr[0] === f[4]) return arr;
    } catch {
      /* fall through */
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// The lazy-thunk memoizer. Used to enumerate this module's lazy-init thunks so
// we can initialise the graph WITHOUT importing the CLI entry point (which
// would run Claude Code).
//
// TWO shapes are recognised, because upstream replaced the mechanism at
// 2.1.248 and both must keep working:
//
//  BUN (<= 2.1.245) — bun's own `__esm` ESM lowering:
//      M=(a,b)=>()=>(a&&(b=a(a=0)),b)
//
//  LAZY REGISTRY (>= 2.1.248) — Anthropic's OWN helper module, ~800 bytes,
//  whose whole body is a resettable lazy registry:
//      class R{resetters=[];lazy(e){let t;return this.resetters.push(
//        ()=>{t=void 0}),()=>t??=e()}reset(){…}}
//      var S=new R;function h(e){return S.lazy(e)}export{h};
//
// Note what changed in KIND, not just in syntax: this anchor's justification
// in the header called it "the one anchor NOT tied to upstream behavior … it
// is bundler runtime". That is no longer true — the memoizer is now upstream
// application code with a `reset()` affordance. It is still confirmed
// structurally (backreferences only, no identifier is written down), and the
// two shapes are tried in order against the DEFINING module, so a match is
// never taken on the strength of the call site alone.
// ---------------------------------------------------------------------------
const MEMO_DECL_RE =
  /(?:var|let|const)\s+([A-Za-z0-9_$]+)=\(([A-Za-z0-9_$]+),([A-Za-z0-9_$]+)\)=>\(\)=>\(\2&&\(\3=\2\(\2=0\)\),\3\)/;

// The registry METHOD — proves the module really is a memoizer and not merely
// something that happens to export a one-argument function.
const MEMO_LAZY_METHOD_RE =
  /lazy\(([A-Za-z0-9_$]+)\)\{let ([A-Za-z0-9_$]+);return this\.resetters\.push\(\(\)=>\{\2=void 0\}\),\(\)=>\2\?\?=\1\(\)\}/;

// The exported wrapper that call sites actually use: `function h(e){return
// S.lazy(e)}`. Its NAME is what the importing module refers to.
const MEMO_LAZY_EXPORT_RE =
  /function\s+([A-Za-z0-9_$]+)\(([A-Za-z0-9_$]+)\)\{return\s+[A-Za-z0-9_$]+\.lazy\(\2\)\}/;

// Return the LOCAL name a defining module gives its memoizer, or null.
function memoDeclName(src) {
  const bun = MEMO_DECL_RE.exec(src);
  if (bun) return bun[1];
  if (!MEMO_LAZY_METHOD_RE.test(src)) return null;
  const wrapper = MEMO_LAZY_EXPORT_RE.exec(src);
  return wrapper ? wrapper[1] : null;
}

export function locateMemoizerLocal(settingsSrc, readSpec) {
  const imports = parseImports(settingsSrc);
  // The memoizer is whichever imported callee this module uses to wrap its own
  // lazy module initializers: `var X = M(() => { … })`. Pick candidates by that
  // usage, then CONFIRM each against the defining module's source.
  const candidates = [];
  for (const [local, info] of imports) {
    const n = (
      settingsSrc.match(
        new RegExp(
          "(?:var|let|const)\\s+[A-Za-z0-9_$]+=" +
            local.replace(/\$/g, "\\$") +
            "\\(\\(\\)=>",
          "g",
        ),
      ) || []
    ).length;
    // Ranked by call count, but a SINGLE site is enough to be a candidate:
    // the two-module layout leaves only one thunk in the emitter chunk, and a
    // `>= 3` floor silently rejected it. What actually rules out a false
    // positive is the structural confirmation against the DEFINING module
    // below, not how often the local is called here.
    if (n >= 1) candidates.push({ local, info, n });
  }
  candidates.sort((x, y) => y.n - x.n);
  for (const c of candidates) {
    const src2 = readSpec ? readSpec(c.info.spec) : null;
    if (!src2) continue;
    const declName = memoDeclName(src2);
    if (!declName) continue;
    if (parseExports(src2).get(declName) !== c.info.exported) continue;
    return {
      local: c.local,
      source: "import",
      spec: c.info.spec,
      thunkSites: c.n,
    };
  }
  // single-file topology: the memoizer is declared in the same file
  const inline = memoDeclName(settingsSrc);
  if (inline) return { local: inline, source: "inline" };
  return null;
}

export function locateInitThunks(src, memoLocal) {
  const re = new RegExp(
    "(?:var|let|const)\\s+([A-Za-z0-9_$]+)=" +
      memoLocal.replace(/\$/g, "\\$") +
      "\\(\\(\\)=>",
    "g",
  );
  const out = [];
  for (const m of src.matchAll(re)) out.push(m[1]);
  return out;
}

// ---------------------------------------------------------------------------
// One call that produces everything the census needs to drive the module.
// ---------------------------------------------------------------------------
export function locate(root) {
  const { emitterPath, schemaPath } = findSettingsModules(root);
  // census imports and instruments THIS module. In the split topology the
  // converter and filter are DEFINED here and the builder is in scope as an
  // import, so a single `export{… as __c_build}` shim still reaches all three
  // — which is why the emitter module, not the schema module, is the one the
  // census drives.
  const settingsPath = emitterPath;
  const split = emitterPath !== schemaPath;
  const src = fs.readFileSync(settingsPath, "utf8");
  const schemaSrc = split ? fs.readFileSync(schemaPath, "utf8") : src;
  const readSpec = (spec) => {
    const p = isBunfs(spec)
      ? bunfsToPath(root, spec)
      : path.resolve(path.dirname(settingsPath), spec);
    try {
      return fs.readFileSync(p, "utf8");
    } catch {
      return null;
    }
  };

  const emitter = locateEmitter(src);
  const builderAlt = locateBuilderByDescription(schemaSrc);
  const converterAlt = locateConverterByOption(src);
  const filterAlt = locateFilterByMarker(src);

  const build = emitter?.build ?? builderAlt;
  const convert = emitter?.convert ?? converterAlt;
  const filter = emitter?.filter ?? filterAlt;

  const disagreements = [];
  if (emitter && builderAlt && emitter.build !== builderAlt)
    disagreements.push(
      `builder: emitter says ${emitter.build}, $schema-description says ${builderAlt}`,
    );
  if (emitter && converterAlt && emitter.convert !== converterAlt)
    disagreements.push(
      `converter: emitter says ${emitter.convert}, option-site says ${converterAlt}`,
    );
  if (emitter && filterAlt && emitter.filter !== filterAlt)
    disagreements.push(
      `filter: emitter says ${emitter.filter}, @internal-marker says ${filterAlt}`,
    );
  if (disagreements.length)
    throw new Error(
      "independent anchors disagree — " + disagreements.join("; "),
    );

  if (!build) throw new Error("could not locate the settings-schema builder");
  if (!convert)
    throw new Error("could not locate the zod->JSON-Schema converter");
  if (!filter) throw new Error("could not locate the @internal filter");

  const features = locateFeatureList(schemaSrc);
  if (!features) throw new Error("could not locate the feature-gate registry");

  const memo = locateMemoizerLocal(src, readSpec);
  if (!memo) throw new Error("could not locate the bun __esm memoizer");
  const thunks = locateInitThunks(src, memo.local);

  return {
    settingsPath,
    schemaPath,
    layout: split ? "two-module" : "one-module",
    src,
    symbols: {
      build,
      convert,
      filter,
      buildGated: emitter?.buildGated ?? null,
    },
    via: {
      build: emitter ? "emitter-composite" : "schema-key-description",
      convert: emitter ? "emitter-composite" : "unrepresentable-option-site",
      filter: emitter ? "emitter-composite" : "internal-marker-chain",
    },
    alternates: { build: builderAlt, convert: converterAlt, filter: filterAlt },
    features,
    memo,
    thunks,
    imports: parseImports(src),
    exports: parseExports(src),
  };
}
