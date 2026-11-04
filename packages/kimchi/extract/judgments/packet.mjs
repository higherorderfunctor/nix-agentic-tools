import { createHash } from "node:crypto";

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
  `invalid ${code === "FACT_INPUT" ? "regionRegistry.fields" : "verdict"} input at `;
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
function selector(value, path) {
  validate(
    value,
    {
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
export function verdicts(value) {
  validate(value, {
    judgments: (v) => Array.isArray(v),
    schemaVersion: version,
  });
  const ids = new Set(),
    roots = new Set();
  return value.judgments.map((judgment, i) => {
    const path = `/judgments/${i}`;
    try {
      validate(
        judgment,
        {
          claim: nonblank,
          evidenceHash: digest,
          id: (v) => string(v) && /^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/.test(v),
          ...(judgment?.verdict === "unknown"
            ? { missingEvidence: nonblank }
            : {}),
          packet: packetShape,
          rationale: nonblank,
          scope: nonblank,
          verdict: (v) => ["supported", "refuted", "unknown"].includes(v),
        },
        path,
      );
      for (const [array, items] of [
        ["rows", judgment.packet.rows],
        ["selector.sources", judgment.packet.selector.sources],
        ["spans", judgment.packet.spans],
      ])
        if (canonical(items) !== canonical(ordered([...items])))
          schema(
            "VERDICT_INPUT",
            `${path}/packet/${array.replace(".", "/")}`,
            `non-canonical ${array} array for judgment ${judgment.id}`,
          );
      const root = judgment.packet.selector.fact.where.region;
      if (ids.has(judgment.id))
        schema("VERDICT_INPUT", `${path}/id`, "duplicate judgment id");
      if (roots.has(root))
        schema(
          "VERDICT_INPUT",
          `${path}/packet/selector`,
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
export function resolver(bytes, ts, display) {
  const sourceError = (reason) =>
    refuse(
      "SOURCE_INPUT",
      `cannot resolve source evidence in src/regions.ts: ${reason}`,
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
    "src/regions.ts",
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
        node = match(
          [...node.properties].filter(
            (p) => ts.isPropertyAssignment(p) && name(p) === key,
          ),
          citation,
        );
        if (index === 0) node = node.initializer;
      }
    }
    const start = node.getStart(source, false),
      end = node.getEnd();
    display[canonical(citation)] ??= {
      start: coordinates(start),
      end: coordinates(end),
    };
    return {
      ...citation,
      sha256: hash(
        bytes.subarray(
          Buffer.byteLength(text.slice(0, start)),
          Buffer.byteLength(text.slice(0, end)),
        ),
      ),
    };
  };
}
export function packet(selector, rows, resolve) {
  const selected = rows.filter(
    (row) => row.region === selector.fact.where.region,
  );
  const normalized = selected.map(({ field, region, value }) => ({
    field,
    region,
    value,
    site: propertySite(region),
  }));
  const citations = new Map(
    [...normalized.map((row) => row.site), ...selector.sources].map(
      (citation) => [canonical(citation), citation],
    ),
  );
  const spans = [],
    errors = [];
  for (const citation of ordered([...citations.values()])) {
    try {
      spans.push(resolve(citation));
    } catch (error) {
      if (!(error instanceof EvidenceError)) throw error;
      errors.push(error);
    }
  }
  const result = {
    rows: ordered(normalized),
    schemaVersion: 1,
    selector: { ...selector, sources: ordered([...selector.sources]) },
    spans,
  };
  return errors.length
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
    : { packet: result, evidenceHash: hash(canonical(result)) };
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
    new Map(
      (packet?.spans ?? []).map((span) => {
        const { sha256, ...site } = span ?? {};
        return [canonical(site), { site, hash: sha256 }];
      }),
    );
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
