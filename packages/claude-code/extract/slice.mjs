// slice.mjs — cut the top-level declarations reachable from named bindings
// out of one bundled ESM chunk, so census.mjs can evaluate the binary's own
// zod -> JSON-Schema converter and `@internal` filter WITHOUT evaluating the
// rest of their declaring chunk or that chunk's import closure. From 2.1.326
// both sit in chunks whose closure Node cannot load (Bun-only imports such as
// `ws`, the `import.meta.require` alias, embedded-asset loaders).
//
// Bindings are identified by the TypeScript checker's symbol, never by
// spelling: minified names are recycled, and a parameter `e` shadows a
// top-level `e`. A name the checker cannot resolve is a global and must exist
// on globalThis; anything else fails closed. A slice is only sound when its
// state equals its initializers, so a sliced variable that code outside the
// slice can read, write or export, a sliced variable without an initializer,
// a sliced function that code outside the slice does anything to but call or
// export, and any class declaration are all refused.
import path from "node:path";

function program(ts, fileName, src) {
  const options = {
    allowJs: true,
    checkJs: false,
    noLib: true,
    noResolve: true,
    types: [],
    target: ts.ScriptTarget.Latest,
    module: ts.ModuleKind.ESNext,
  };
  const sf = ts.createSourceFile(
    fileName,
    src,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.JS,
  );
  if (sf.parseDiagnostics.length)
    throw new Error(`census-slice: ${path.basename(fileName)} does not parse`);
  const host = {
    fileExists: (f) => f === fileName,
    getCanonicalFileName: (f) => f,
    getCurrentDirectory: () => path.dirname(fileName),
    getDefaultLibFileName: () => "lib.d.ts",
    getNewLine: () => "\n",
    getSourceFile: (f) => (f === fileName ? sf : undefined),
    readFile: (f) => (f === fileName ? src : undefined),
    useCaseSensitiveFileNames: () => true,
    writeFile: () => {},
  };
  const prog = ts.createProgram([fileName], options, host);
  return { sf, checker: prog.getTypeChecker() };
}

// The top-level unit that owns a declaration node, or null when the
// declaration is not a top-level one of this file.
function topLevelUnit(ts, sf, d) {
  let unit = null;
  for (let n = d; n && n !== sf; n = n.parent) {
    if (
      ts.isFunctionDeclaration(n) ||
      ts.isClassDeclaration(n) ||
      ts.isVariableDeclaration(n) ||
      ts.isImportDeclaration(n)
    )
      unit = n;
    if (n.parent === sf) {
      if (ts.isImportDeclaration(n))
        return { kind: "import", node: n, decl: d };
      if (ts.isFunctionDeclaration(n) || ts.isClassDeclaration(n))
        return { kind: "decl", node: n };
      if (ts.isVariableStatement(n) && unit && ts.isVariableDeclaration(unit))
        return { kind: "var", node: unit };
      return null;
    }
  }
  return null;
}

const within = (inner, outer) =>
  inner.getStart() >= outer.getStart() && inner.end <= outer.end;

export function sliceModule(ts, fileName, src, rootNames) {
  const base = path.basename(fileName);
  const fail = (msg) => {
    throw new Error(`census-slice: ${base}: ${msg}`);
  };
  const { sf, checker } = program(ts, fileName, src);

  // Roots: top-level bindings with these names.
  const tops = new Map();
  for (const st of sf.statements) {
    if ((ts.isFunctionDeclaration(st) || ts.isClassDeclaration(st)) && st.name)
      tops.set(st.name.text, { kind: "decl", node: st });
    else if (ts.isVariableStatement(st))
      for (const d of st.declarationList.declarations)
        if (ts.isIdentifier(d.name))
          tops.set(d.name.text, { kind: "var", node: d });
  }

  const units = new Set(); // sliced function/class/var declaration nodes
  const imports = new Map(); // spec -> Map(local -> imported)
  const globals = new Set();
  const queue = [];
  for (const name of rootNames) {
    const t = tops.get(name);
    if (!t) fail(`root binding ${name} is not a top-level declaration`);
    queue.push(t.node);
  }

  const isNameOnly = (id) => {
    const p = id.parent;
    return (
      (ts.isPropertyAccessExpression(p) && p.name === id) ||
      ((ts.isPropertyAssignment(p) ||
        ts.isMethodDeclaration(p) ||
        ts.isPropertyDeclaration(p) ||
        ts.isGetAccessor(p) ||
        ts.isSetAccessor(p)) &&
        p.name === id) ||
      (ts.isBindingElement(p) && p.propertyName === id) ||
      ts.isLabeledStatement(p) ||
      ts.isBreakOrContinueStatement(p)
    );
  };

  const symbolAt = (id) => {
    let sym = checker.getSymbolAtLocation(id);
    if (sym && ts.isShorthandPropertyAssignment(id.parent))
      sym = checker.getShorthandAssignmentValueSymbol(id.parent) ?? sym;
    return sym;
  };

  while (queue.length) {
    const node = queue.pop();
    if (units.has(node)) continue;
    // A slice holds a SECOND copy of each declaration, so `instanceof` would
    // tell instances the loaded chunk created from the slice's apart.
    if (ts.isClassDeclaration(node))
      fail(`slice needs the class ${node.name?.text ?? "(anonymous)"}`);
    units.add(node);
    (function walk(n) {
      if (ts.isIdentifier(n)) {
        if (isNameOnly(n)) return;
        const sym = symbolAt(n);
        if (!sym || !sym.declarations || !sym.declarations.length) {
          // Undeclared in this file: a global, matched by spelling.
          if (!(n.text in globalThis) && n.text !== "undefined")
            fail(`unresolved identifier ${n.text} is not a global`);
          globals.add(n.text);
          return;
        }
        for (const d of sym.declarations) {
          if (within(d, node)) continue; // local to this unit
          const u = topLevelUnit(ts, sf, d);
          if (!u)
            fail(
              `identifier ${n.text} resolves to a declaration that is neither local nor top-level`,
            );
          if (u.kind === "import") {
            const spec = u.node.moduleSpecifier.text;
            if (!ts.isImportSpecifier(u.decl))
              fail(`slice needs a non-named import from ${spec}`);
            const m = imports.get(spec) ?? new Map();
            m.set(u.decl.name.text, (u.decl.propertyName ?? u.decl.name).text);
            imports.set(spec, m);
          } else queue.push(u.node);
        }
        return;
      }
      ts.forEachChild(n, walk);
    })(node);
  }

  // Closure check: sliced VARIABLES are state. Every reference to one must sit
  // inside the slice, it must have an initializer and it must not be exported;
  // otherwise code we do not evaluate could have changed it. A sliced function
  // is state too (its properties, its prototype, the binding itself), so code
  // outside the slice may only call or export it.
  const sliced = [...units];
  const inSlice = (n) => sliced.some((u) => within(n, u));
  const stateNames = new Map(); // text -> declaration node
  for (const u of sliced) {
    if (ts.isVariableDeclaration(u)) {
      if (!ts.isIdentifier(u.name)) fail("sliced destructuring declaration");
      if (!u.initializer)
        fail(`sliced variable ${u.name.text} has no initializer`);
    }
    stateNames.set(u.name.text, u);
  }
  (function scan(n) {
    if (ts.isIdentifier(n) && stateNames.has(n.text) && !isNameOnly(n)) {
      const u = stateNames.get(n.text);
      if (n !== u.name && !inSlice(n)) {
        const sym = symbolAt(n);
        const p = n.parent;
        const exported = ts.isExportSpecifier(p);
        const hits =
          exported ||
          (sym?.declarations ?? []).some((d) => d === u || within(d, u));
        if (hits) {
          if (ts.isVariableDeclaration(u))
            fail(
              `sliced variable ${n.text} is referenced or exported outside the slice`,
            );
          if (!exported && !(ts.isCallExpression(p) && p.expression === n))
            fail(
              `sliced function ${n.text} is used outside the slice other than by a call`,
            );
        }
      }
      return;
    }
    ts.forEachChild(n, scan);
  })(sf);

  // Emit: needed imports, then the sliced declarations in SOURCE order.
  const out = [];
  for (const [spec, m] of [...imports].sort(([a], [b]) => (a < b ? -1 : 1))) {
    const parts = [...m]
      .sort(([a], [b]) => (a < b ? -1 : 1))
      .map(([local, imported]) =>
        local === imported ? local : `${imported} as ${local}`,
      );
    out.push(`import{${parts.join(",")}}from${JSON.stringify(spec)};`);
  }
  for (const u of sliced.sort((a, b) => a.getStart() - b.getStart()))
    out.push(
      ts.isVariableDeclaration(u) ? `var ${u.getText(sf)};` : u.getText(sf),
    );
  return {
    source: out.join("\n") + "\n",
    stats: {
      module: base,
      roots: rootNames,
      declarations: sliced.length,
      variables: sliced.filter((u) => ts.isVariableDeclaration(u)).length,
      bytes: out.join("\n").length,
      imports: Object.fromEntries(
        [...imports].map(([spec, m]) => [spec, [...m.keys()].sort()]),
      ),
      globals: [...globals].sort(),
    },
  };
}
