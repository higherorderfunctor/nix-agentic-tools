import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

export const canonical = (value) =>
  JSON.stringify(value, (_key, item) =>
    item && typeof item === "object" && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]]),
        )
      : item,
  );
export const requestClaimParts = [
  "default",
  "destination",
  "disable",
  "trigger",
];
export const hash = (value) =>
  `sha256:${createHash("sha256").update(value).digest("hex")}`;
const ordered = (items) =>
  items.sort((a, b) =>
    canonical(a) < canonical(b) ? -1 : canonical(a) > canonical(b) ? 1 : 0,
  );
export class EvidenceError extends Error {
  constructor(code, detail, citation) {
    super(detail);
    this.code = code;
    this.citation = citation;
  }
}
const refuse = (code, detail, citation) => {
  throw new EvidenceError(code, detail, citation);
};
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const nonblank = (value) =>
  typeof value === "string" && value.trim().length > 0;
const digest = (value) =>
  typeof value === "string" && /^sha256:[a-f0-9]{64}$/.test(value);
export const escapeText = (value) => {
  if (typeof value !== "string") return "unavailable";
  return /[\r\n]/.test(value) ? JSON.stringify(value) : value;
};
export const schemaPrefix = (code) =>
  `invalid ${code === "REQUEST_FACT_INPUT" ? "requestCallers" : code === "FACT_INPUT" ? "regionRegistry.fields" : "verdict"} input at `;
function schema(code, path, reason) {
  refuse(code, `${schemaPrefix(code)}${path}: ${reason}`);
}
// The verdict and measured-row consumers share closed object/list validation.
function validate(value, shape, path = "", code = "VERDICT_INPUT") {
  if (typeof shape === "function") {
    if (shape(value, path, code) !== false) return;
  } else if (Array.isArray(shape)) {
    if (Array.isArray(value)) {
      for (const [i, item] of value.entries())
        validate(item, shape[0], `${path}/${i}`, code);
      return;
    }
  } else if (object(value)) {
    for (const key of Object.keys(value))
      if (!Object.hasOwn(shape, key))
        schema(code, `${path}/${key}`, "unknown field");
    for (const [key, specification] of Object.entries(shape)) {
      if (!Object.hasOwn(value, key))
        schema(code, `${path}/${key}`, "missing field");
      validate(value[key], specification, `${path}/${key}`, code);
    }
    return;
  }
  schema(code, path, "invalid type or value");
}
const string = (value) => typeof value === "string";
const version = (value, path) => {
  if (value !== 1) schema("VERDICT_INPUT", path, "unsupported schemaVersion");
};
const registryPath = "src/regions.ts";
const gatewayField = (value) => value === "llmBaseUrl";
const propertySite = (region) => ({
  anchor: {
    role: { keys: [region, "llmBaseUrl"], kind: "property" },
    symbol: "REGIONS",
  },
  path: registryPath,
});
const sourcePath = (v) =>
  string(v) &&
  v.startsWith("src/") &&
  !v.includes("\\") &&
  v.split("/").every((part) => part && part !== "." && part !== "..");
const ordinal = (v) => Number.isInteger(v) && v >= 0;
const steps = (v) =>
  Array.isArray(v) &&
  v.every(
    (s) =>
      Array.isArray(s) && s.length === 2 && nonblank(s[0]) && ordinal(s[1]),
  );
const callRole = { callee: nonblank, kind: (v) => v === "call", ordinal };
const requestSite = (role) => ({
  anchor: { role, symbol: steps },
  path: sourcePath,
});
const sourceSite = requestSite({ kind: (v) => v === "node", steps });
const isRequest = (selector) => selector?.fact?.kind === "requestCallers";
export const rootKey = (selector) =>
  canonical(
    selector?.fact?.where?.region !== undefined
      ? {
          kind: "regionRegistry.fields",
          where: { field: "llmBaseUrl", region: selector.fact.where.region },
        }
      : selector?.fact,
  );
function selector(value, path) {
  validate(
    value,
    isRequest(value)
      ? {
          fact: {
            kind: (v) => v === "requestCallers",
            where: { request: requestSite(callRole) },
          },
          sources: [sourceSite],
        }
      : {
          fact: {
            kind: (v) => v === "regionRegistry.fields",
            where: { field: gatewayField, region: nonblank },
          },
          sources: [
            {
              anchor: {
                role: { kind: (v) => v === "declaration" },
                symbol: nonblank,
              },
              path: (v) => v === registryPath,
            },
          ],
        },
    path,
  );
  const seen = new Set();
  value.sources.forEach((source, i) => {
    const key = canonical(source);
    if (seen.has(key))
      schema(
        "VERDICT_INPUT",
        `${path}/sources/${i}`,
        "duplicate source citation",
      );
    seen.add(key);
  });
}
const packetShape = {
  rows: Array.isArray,
  schemaVersion: version,
  selector,
  spans: Array.isArray,
};
export const judgmentSelector = (judgment) =>
  judgment?.selector ?? judgment?.packet?.selector;
export function verdicts(value) {
  validate(value, {
    judgments: (v) => Array.isArray(v),
    schemaVersion: version,
  });
  const ids = new Set(),
    roots = new Set();
  return value.judgments.map((judgment, i) => {
    const path = `/judgments/${i}`,
      request = isRequest(judgment?.selector);
    try {
      validate(
        judgment,
        {
          claim: request
            ? Object.fromEntries(
                requestClaimParts.map((key) => [key, nonblank]),
              )
            : nonblank,
          evidenceHash: digest,
          id: (v) => string(v) && /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(v),
          ...(judgment?.verdict === "unknown"
            ? { missingEvidence: nonblank }
            : {}),
          ...(request
            ? {
                evidence: {
                  rows: [digest],
                  spans: [{ ...sourceSite, sha256: digest }],
                  statement: digest,
                },
                selector,
              }
            : { packet: packetShape }),
          rationale: nonblank,
          scope: nonblank,
          verdict: (v) => ["supported", "refuted", "unknown"].includes(v),
        },
        path,
      );
      const evidence = request ? judgment.evidence : judgment.packet;
      for (const [array, items, field] of [
        ["rows", evidence.rows, request ? "evidence/rows" : "packet/rows"],
        [
          "selector.sources",
          judgmentSelector(judgment).sources,
          request ? "selector/sources" : "packet/selector/sources",
        ],
        ["spans", evidence.spans, request ? "evidence/spans" : "packet/spans"],
      ])
        if (canonical(items) !== canonical(ordered([...items])))
          schema(
            "VERDICT_INPUT",
            `${path}/${field}`,
            `non-canonical ${array} array for judgment ${judgment.id}`,
          );
      const root = rootKey(judgmentSelector(judgment));
      if (ids.has(judgment.id))
        schema("VERDICT_INPUT", `${path}/id`, "duplicate judgment id");
      if (roots.has(root))
        schema(
          "VERDICT_INPUT",
          `${path}/${request ? "selector" : "packet/selector"}`,
          "duplicate judgment root",
        );
      ids.add(judgment.id);
      roots.add(root);
      return { judgment };
    } catch (error) {
      if (!(error instanceof EvidenceError)) throw error;
      return { judgment, error };
    }
  });
}
export function factRows(value) {
  return value.regionRegistry.fields.filter((row, i) => {
    const path = `/regionRegistry/fields/${i}`;
    if (!gatewayField(row.field)) return false;
    validate(
      row,
      {
        field: gatewayField,
        file: (v) => v === registryPath,
        line: (v) => Number.isInteger(v) && v > 0,
        region: nonblank,
        value: string,
      },
      path,
      "FACT_INPUT",
    );
    return true;
  });
}
function syntax(bytes, ts, path, display) {
  const sourceError = (reason) =>
    refuse(
      "SOURCE_INPUT",
      `cannot resolve source evidence in ${path}: ${reason}`,
    );
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(
      bytes,
    );
  } catch (error) {
    if (!(error instanceof TypeError)) throw error;
    sourceError("invalid UTF-8");
  }
  const source = ts.createSourceFile(
    path,
    text,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const coordinates = (position) => {
    const p = source.getLineAndCharacterOfPosition(position);
    return { line: p.line + 1, column: p.character + 1 };
  };
  if (source.parseDiagnostics.length) {
    const d = source.parseDiagnostics[0],
      at = coordinates(d.start);
    sourceError(`TypeScript parse error ${d.code} at ${at.line}:${at.column}`);
  }
  const locate = (node, citation) => {
    display[canonical(citation)] ??= {
      start: coordinates(node.getStart(source, false)),
      end: coordinates(node.getEnd()),
    };
    return citation;
  };
  const slice = (node) =>
    bytes.subarray(
      Buffer.byteLength(text.slice(0, node.getStart(source, false))),
      Buffer.byteLength(text.slice(0, node.getEnd())),
    );
  return { coordinates, locate, slice, source, sourceError };
}
export function resolver(bytes, ts, display) {
  const { source, sourceError, coordinates, locate, slice } = syntax(
    bytes,
    ts,
    registryPath,
    display,
  );
  const exported = (node) =>
    node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword);
  const name = (node) =>
    node?.name && (ts.isIdentifier(node.name) || ts.isStringLiteral(node.name))
      ? node.name.text
      : null;
  const unwrap = (node) => {
    while (node && (ts.isAsExpression(node) || ts.isSatisfiesExpression(node)))
      node = node.expression;
    return node;
  };
  const registries = source.statements
    .filter(
      (s) =>
        ts.isVariableStatement(s) &&
        exported(s) &&
        s.declarationList.flags & ts.NodeFlags.Const,
    )
    .flatMap((s) => [...s.declarationList.declarations])
    .filter((d) => name(d) === "REGIONS");
  const match = (nodes, citation) => {
    if (nodes.length !== 1) {
      const count = nodes.length,
        anchor = canonical(citation);
      refuse(
        count ? "ANCHOR_AMBIGUOUS" : "ANCHOR_MISSING",
        `${count ? "ambiguous" : "missing"} anchor ${anchor}: expected one match, found ${count}${count ? `; candidates=${canonical(nodes.map((n) => coordinates(n.getStart(source, false))))}` : ""}`,
        citation,
      );
    }
    return nodes[0];
  };
  const shape = (citation) =>
    sourceError(`unsupported structural shape at ${canonical(citation)}`);
  // Inspect every direct region, including regions without a measured gateway row.
  if (registries.length === 1) {
    const registry = unwrap(registries[0].initializer);
    if (!registry || !ts.isObjectLiteralExpression(registry))
      shape(propertySite("*"));
    for (const entry of registry.properties) {
      if (
        !ts.isPropertyAssignment(entry) ||
        name(entry) === null ||
        !ts.isObjectLiteralExpression(entry.initializer)
      )
        shape(propertySite(name(entry) ?? "*"));
      for (const property of entry.initializer.properties)
        if (
          ts.isSpreadAssignment(property) ||
          (property.name && ts.isComputedPropertyName(property.name))
        )
          sourceError(
            `region ${JSON.stringify(name(entry))} contains unsupported ${property.name && ts.isComputedPropertyName(property.name) ? "computed property name" : ts.SyntaxKind[property.kind]}: spreads and computed property names are refused; use named members with identifier or string-literal names`,
          );
    }
  }
  return (citation) => {
    const { symbol, role } = citation.anchor;
    let node;
    if (role.kind === "declaration") {
      node = match(
        source.statements.filter(
          (s) =>
            ts.isFunctionDeclaration(s) && exported(s) && name(s) === symbol,
        ),
        citation,
      );
    } else {
      node = unwrap(match(registries, citation).initializer);
      for (const [index, key] of role.keys.entries()) {
        if (!node || !ts.isObjectLiteralExpression(node)) shape(citation);
        // A same-named accessor or method beside the assignment can override
        // it at runtime, so every same-named member counts toward uniqueness.
        const named = [...node.properties].filter((p) => name(p) === key);
        node = match(
          named.length > 1 ? named : named.filter(ts.isPropertyAssignment),
          citation,
        );
        if (index === 0) node = node.initializer;
      }
    }
    return { ...locate(node, citation), sha256: hash(slice(node)) };
  };
}
export async function requests(value, tree, ts, display) {
  const location = {
    column: (v) => Number.isInteger(v) && v > 0,
    file: (v) => string(v) && v.startsWith("kimchi/") && sourcePath(v.slice(7)),
    line: (v) => Number.isInteger(v) && v > 0,
  };
  const nullable = (v) => v === null || string(v);
  validate(
    value.requestCallers,
    [
      {
        callSite: {
          ...location,
          endColumn: location.column,
          endLine: location.line,
          library: nonblank,
        },
        distance: Number.isInteger,
        functionSite: location,
        kind: nonblank,
        property: nullable,
        reason: nullable,
        site: location,
      },
    ],
    "/requestCallers",
    "REQUEST_FACT_INPUT",
  );
  const files = new Map();
  const load = async (path, field, citation) => {
    if (files.has(path)) return files.get(path);
    const bytes = await readFile(join(tree, path)).catch((error) =>
      refuse(
        field ? "REQUEST_LOCATION" : "ANCHOR_MISSING",
        field
          ? `cannot adapt requestCallers location at ${field}: cannot read source ${path} (${error.code}); regenerate facts against the pinned source`
          : `missing anchor ${canonical(citation)}: cannot read source ${path} (${error.code})`,
        citation,
      ),
    );
    const parsed = syntax(bytes, ts, path, display);
    const { source, sourceError, coordinates, locate, slice } = parsed;
    const children = (n) =>
      n
        .getChildren(source)
        .filter((c) => c.kind !== ts.SyntaxKind.JSDocComment);
    const call = (n) => ts.isCallExpression(n) || ts.isNewExpression(n);
    const broad = (n) =>
      ts.isSourceFile(n) ||
      ts.isBlock(n) ||
      ts.isFunctionLike(n) ||
      ts.isClassLike(n);
    const spelling = (n) => {
      if (!n) return "";
      if (
        ts.isParenthesizedExpression(n) ||
        ts.isAsExpression(n) ||
        ts.isSatisfiesExpression(n) ||
        ts.isNonNullExpression(n)
      )
        return spelling(n.expression);
      if (call(n)) return `${spelling(n.expression)}()`;
      if (ts.isFunctionLike(n))
        return `function:${n.name ? spelling(n.name) : ""}`;
      if (ts.isClassLike(n)) return `class:${n.name ? spelling(n.name) : ""}`;
      const parts = children(n);
      return parts.length ? parts.map(spelling).join("") : n.getText(source);
    };
    const callee = (n) =>
      `${ts.isNewExpression(n) ? "new" : "call"}:${spelling(n.expression)}`;
    const named = (n) => {
      if (!(ts.isFunctionLike(n) && n.body) && !ts.isClassLike(n)) return null;
      if (ts.isConstructorDeclaration(n)) return "constructor:constructor";
      let binding = n.parent;
      while (
        binding &&
        (ts.isParenthesizedExpression(binding) ||
          ts.isAsExpression(binding) ||
          ts.isSatisfiesExpression(binding))
      )
        binding = binding.parent;
      const name =
        binding &&
        (ts.isVariableDeclaration(binding) || ts.isPropertyAssignment(binding))
          ? binding.name
          : n.name;
      if (!name) return null;
      const kind = ts.isClassLike(n)
        ? "class"
        : ts.isMethodDeclaration(n)
          ? "method"
          : ts.isGetAccessorDeclaration(n)
            ? "get"
            : ts.isSetAccessorDeclaration(n)
              ? "set"
              : "function";
      return `${kind}:${spelling(name)}`;
    };
    const nodes = [],
      owner = new Map(),
      symbols = new Map([[source, []]]),
      siblings = new Map();
    const visit = (n, parent) => {
      const name = named(n);
      if (name) {
        const key = canonical([symbols.get(parent), name]),
          index = siblings.get(key) ?? 0;
        siblings.set(key, index + 1);
        symbols.set(n, [...symbols.get(parent), [name, index]]);
        parent = n;
      }
      owner.set(n, parent);
      nodes.push(n);
      for (const child of children(n)) visit(child, parent);
    };
    visit(source, source);
    const address = (n, role) =>
      locate(n, { anchor: { role, symbol: symbols.get(owner.get(n)) }, path });
    const peers = (n, predicate) =>
      nodes.filter((p) => owner.get(p) === owner.get(n) && predicate(p));
    const callKey = (n, contextual) => {
      const literal = contextual && n.arguments?.find(ts.isStringLiteral);
      return callee(n) + (literal ? `:${JSON.stringify(literal.text)}` : "");
    };
    const callAddress = (n, contextual = false) =>
      address(n, {
        callee: callKey(n, contextual),
        kind: "call",
        ordinal: peers(
          n,
          (p) => call(p) && callKey(p, contextual) === callKey(n, contextual),
        ).indexOf(n),
      });
    const tokens = nodes.filter(
      (n) => !children(n).length && n.getWidth(source) > 0,
    );
    const starts = (n) => {
      const first = children(n)
        .flatMap((c) =>
          c.kind === ts.SyntaxKind.SyntaxList ? children(c) : [c],
        )
        .find(
          (c) =>
            c.kind !== ts.SyntaxKind.ExportKeyword &&
            c.kind !== ts.SyntaxKind.DefaultKeyword,
        );

      return [n.getStart(source, false), first?.getStart(source, false)].filter(
        (v) => v !== undefined,
      );
    };
    const functionStarts = new Map(
      nodes
        .filter(ts.isFunctionLike)
        .flatMap((n) => starts(n).map((p) => [p, n])),
    );
    const tokenKey = (n) => {
      const fn = functionStarts.get(n.getStart(source));
      if (!fn || named(fn)) return n.getText(source);
      const context = [];
      for (
        let child = fn, p = fn.parent;
        p && !broad(p);
        child = p, p = p.parent
      ) {
        if (p.name) context.push(spelling(p.name));
        if (call(p))
          return canonical([
            callAddress(p, true).anchor.role,
            p.arguments?.indexOf(child) ?? -1,
            ...context,
          ]);
      }
      return n.getText(source);
    };
    const at = (p, target, field) => {
      const matches = nodes.filter((n) => {
        const start = n.getStart(source, false),
          position = coordinates(start);
        if (target === "source token")
          return (
            tokens.includes(n) &&
            position.line === p.line &&
            position.column === p.column
          );
        if (target === "request call") {
          if (!call(n)) return false;
          // CodeQL ends are inclusive and 1-based; getEnd() is exclusive.
          const end = coordinates(n.getEnd() - 1);
          return (
            position.line === p.line &&
            position.column === p.column &&
            end.line === p.endLine &&
            end.column === p.endColumn
          );
        }
        if (!ts.isFunctionLike(n)) return false;
        return starts(n).some(
          (v) =>
            coordinates(v).line === p.line &&
            coordinates(v).column === p.column,
        );
      });
      if (matches.length !== 1)
        refuse(
          "REQUEST_LOCATION",
          `cannot adapt requestCallers location at ${field}: expected one ${target} at ${canonical(p)}, found ${matches.length}; regenerate facts against the pinned source`,
        );
      return matches[0];
    };
    const key = (n) => {
      if (n.name) return `name:${spelling(n.name)}`;
      if (call(n)) return callee(n);
      if (ts.isVariableStatement(n))
        return `bindings:${n.declarationList.declarations.map((d) => spelling(d.name)).join(",")}`;
      if (ts.isObjectLiteralExpression(n))
        for (const label of ["id", "name"]) {
          const fields = n.properties.filter(
            (p) =>
              p.name &&
              spelling(p.name) === label &&
              p.initializer &&
              (ts.isIdentifier(p.initializer) ||
                ts.isLiteralExpression(p.initializer)),
          );
          if (fields.length === 1)
            return `entry:${label}:${spelling(fields[0].initializer)}`;
        }
      return n.kind === ts.SyntaxKind.SyntaxList
        ? "list"
        : ts.isBlock(n)
          ? "block"
          : children(n).length
            ? "node"
            : "token";
    };
    const resolve = (citation) => {
      const { symbol, role } = citation.anchor;
      let matches = [...symbols]
        .filter(([, s]) => canonical(s) === canonical(symbol))
        .map(([n]) => n);
      if (role.kind === "node")
        for (const [name, index] of role.steps)
          matches = matches.flatMap((n) =>
            children(n)
              .filter((c) => key(c) === name)
              .slice(index, index + 1),
          );
      else
        matches = nodes
          .filter(
            (n) =>
              call(n) &&
              canonical(symbols.get(owner.get(n))) === canonical(symbol) &&
              callee(n) === role.callee,
          )
          .slice(role.ordinal, role.ordinal + 1);
      if (matches.length !== 1)
        refuse(
          "ANCHOR_MISSING",
          `missing anchor ${canonical(citation)}: expected one match, found 0`,
          citation,
        );
      let node = matches[0];
      if (role.kind === "statement") {
        while (node && !broad(node) && !ts.isStatement(node))
          node = node.parent;
        if (!node || broad(node))
          sourceError(
            `request call has no supported containing statement at ${canonical(citation)}`,
          );
      } else if (
        broad(node) ||
        (node.kind === ts.SyntaxKind.SyntaxList && broad(node.parent))
      )
        sourceError(
          `unsupported broad evidence node at ${canonical(citation)}`,
        );
      const bytes = slice(node);
      return {
        ...locate(node, citation),
        sha256: hash(bytes),
        ...(role.kind === "statement"
          ? { statement: bytes.toString("utf8") }
          : {}),
      };
    };
    const site = (n) => {
      let invocation = n.parent;
      while (invocation && !call(invocation) && !broad(invocation))
        invocation = invocation.parent;
      if (
        invocation &&
        call(invocation) &&
        n.getEnd() <= invocation.expression.getEnd()
      )
        return callAddress(invocation, true);
      return address(n, {
        key: tokenKey(n),
        kind: functionStarts.has(n.getStart(source))
          ? "function-start"
          : "token",
        ordinal: peers(
          n,
          (p) =>
            tokens.includes(p) &&
            functionStarts.has(p.getStart(source)) ===
              functionStarts.has(n.getStart(source)) &&
            tokenKey(p) === tokenKey(n),
        ).indexOf(n),
      });
    };
    const result = {
      at,
      callAddress,
      functionSite: (n) => address(owner.get(n), { kind: "owner" }),
      hasFunction: (n) => {
        for (let p = n.parent; p; p = p.parent)
          if (ts.isFunctionLike(p)) return true;
        return false;
      },
      resolve,
      site,
    };
    files.set(path, result);
    return result;
  };
  const roots = new Map();
  for (const [i, row] of value.requestCallers.entries()) {
    const path = `/requestCallers/${i}`,
      requestFile = await load(row.callSite.file.slice(7), `${path}/callSite`);
    const { endColumn, endLine, library, ...position } = row.callSite;
    const node = requestFile.at(
        { endColumn, endLine, ...position },
        "request call",
        `${path}/callSite`,
      ),
      request = requestFile.callAddress(node);
    const selector = {
        fact: { kind: "requestCallers", where: { request } },
        sources: [],
      },
      key = rootKey(selector);
    if (!roots.has(key)) roots.set(key, { rows: [], selector });
    const fn = await load(
        row.functionSite.file.slice(7),
        `${path}/functionSite`,
      ),
      use = await load(row.site.file.slice(7), `${path}/site`);
    const functionNode =
      canonical(row.functionSite) === canonical(position) &&
      !requestFile.hasFunction(node)
        ? node
        : fn.at(row.functionSite, "enclosing function", `${path}/functionSite`);
    roots.get(key).rows.push({
      distance: row.distance,
      functionSite: fn.functionSite(functionNode),
      kind: row.kind,
      library,
      property: row.property,
      reason: row.reason,
      site: use.site(use.at(row.site, "source token", `${path}/site`)),
    });
  }
  return {
    resolve: async (citation) =>
      (await load(citation.path, undefined, citation)).resolve(citation),
    roots,
  };
}
export async function packet(selector, rows, resolve) {
  const request = selector.fact.where.request;
  const selected = rows.filter(
    (row) => row.region === selector.fact.where.region,
  );
  const normalized = request
    ? rows
    : selected.map(({ field, region, value }) => ({
        field,
        region,
        value,
        site: propertySite(region),
      }));
  const citations = new Map(
    [
      ...(request
        ? [
            {
              ...request,
              anchor: {
                ...request.anchor,
                role: { ...request.anchor.role, kind: "statement" },
              },
            },
          ]
        : normalized.map((row) => row.site)),
      ...selector.sources,
    ].map((citation) => [canonical(citation), citation]),
  );
  const spans = [],
    errors = [];
  let statement;
  for (const citation of ordered([...citations.values()])) {
    try {
      const { statement: bytes, ...span } = await resolve(citation);
      if (bytes !== undefined) statement = bytes;
      spans.push(span);
    } catch (error) {
      if (!(error instanceof EvidenceError)) throw error;
      errors.push(error);
    }
  }
  const rowEntries = request
    ? normalized.map((row) => [hash(canonical(row)), row])
    : null;
  const evidence = request
    ? {
        rows: rowEntries.map(([digest]) => digest).sort(),
        spans: spans.filter((span) => span.anchor.role.kind !== "statement"),
        statement: spans.find((span) => span.anchor.role.kind === "statement")
          ?.sha256,
      }
    : null;
  const result = {
    rows: request ? Object.fromEntries(rowEntries) : ordered(normalized),
    schemaVersion: 1,
    selector: { ...selector, sources: ordered([...selector.sources]) },
    spans,
    ...(request ? { statement } : {}),
  };
  return {
    ...(request ? { evidence } : {}),
    ...(errors.length
      ? {
          incomplete: {
            ...result,
            errors: errors.map((e) => ({
              citation: e.citation,
              code: e.code,
              detail: e.message,
            })),
          },
        }
      : { packet: result, evidenceHash: hash(canonical(evidence ?? result)) }),
  };
}
export function differences(recorded, current) {
  const subtract = (left, right) => {
    const remaining = right.map(canonical);
    return left.filter((row) => {
      const at = remaining.indexOf(canonical(row));
      if (at < 0) return true;
      remaining.splice(at, 1);
      return false;
    });
  };
  const spanMap = (packet) =>
    new Map([
      ...(packet?.spans ?? []).map((span) => {
        const { sha256, ...site } = span ?? {};
        return [canonical(site), { site, hash: sha256 }];
      }),
      ...(packet?.statement
        ? [
            [
              "request statement",
              { site: "request statement", hash: packet.statement },
            ],
          ]
        : []),
    ]);
  const before = spanMap(recorded),
    after = spanMap(current);
  return {
    rows: {
      removed: subtract(recorded?.rows ?? [], current?.rows ?? []),
      added: subtract(current?.rows ?? [], recorded?.rows ?? []),
    },
    spans: [...new Set([...before.keys(), ...after.keys()])]
      .sort()
      .filter((key) => before.get(key)?.hash !== after.get(key)?.hash)
      .map((key) => ({
        site: (before.get(key) ?? after.get(key)).site,
        old: before.get(key)?.hash ?? null,
        new: after.get(key)?.hash ?? null,
      })),
  };
}
