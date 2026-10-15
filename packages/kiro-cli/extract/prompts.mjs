// Static AST extraction only: never import or execute the vendor bundle.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const ts = require(process.argv[3]);
const source = readFileSync(process.argv[2], "utf8");
const file = ts.createSourceFile(
  "kas.js",
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);
if (file.parseDiagnostics.length)
  throw new Error(
    ts.flattenDiagnosticMessageText(file.parseDiagnostics[0].messageText, "\n"),
  );

// These identify inspected entry points, not a classification of every string.
// All other literals remain searchable so a new prompt cannot evade inspection
// merely because its author did not give it a recognizable property name.
const anchors = {
  identity:
    "You operate in a terminal environment: there is no graphical editor",
  systemFeatures: "<key_kiro_features>",
  vibe: "- Execute the user goal using the provided tools.",
  workflowCreator: "name: wf-workflow-creator\n",
  workflowOrchestration: "# Workflow Orchestration\n",
};
const chunks = [];
const groups = {};
const templates = [];
const positions = new Set([0]);
function range(node) {
  const start = node.getStart(file),
    end = node.end;
  positions.add(start);
  positions.add(end);
  return { start, end };
}
function context(node) {
  let parent = node.parent;
  while (parent && !ts.isFunctionLike(parent) && !ts.isSourceFile(parent))
    parent = parent.parent;
  return parent && !ts.isSourceFile(parent) ? range(parent) : null;
}
function chunk(node, tagged = false) {
  const item = {
    ...range(node),
    kind: ts.SyntaxKind[node.kind],
    text: node.text,
  };
  if (tagged) item.tagged = true;
  const index = chunks.push(item) - 1;
  for (const [name, anchor] of Object.entries(anchors)) {
    if (node.text.includes(anchor)) {
      if (groups[name])
        throw new Error(`ambiguous prompt entry point: ${name}`);
      groups[name] = { chunk: index, callable: context(node) };
    }
  }
  return index;
}
function visit(node) {
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
    chunk(node, ts.isTaggedTemplateExpression(node.parent));
  } else if (ts.isTemplateExpression(node)) {
    const tagged = ts.isTaggedTemplateExpression(node.parent);
    templates.push({
      ...range(node),
      callable: context(node),
      parts: [
        { chunk: chunk(node.head, tagged) },
        ...node.templateSpans.flatMap((span) => [
          {
            ...range(span.expression),
            expression: span.expression.getText(file),
          },
          { chunk: chunk(span.literal, tagged) },
        ]),
      ],
    });
  }
  ts.forEachChild(node, visit);
}
visit(file);
// TypeScript offsets are UTF-16 code units; consumers splice UTF-8 bytes.
// Convert sorted boundaries in one pass, including non-BMP source characters.
const bytes = new Map();
let cursor = 0,
  offset = 0;
for (const position of [...positions].sort((a, b) => a - b)) {
  offset += Buffer.byteLength(source.slice(cursor, position));
  bytes.set(position, offset);
  cursor = position;
}
function byteRanges(value) {
  if (Array.isArray(value)) return value.map(byteRanges);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.entries(value).map(([key, item]) => [
      key,
      key === "start" || key === "end" ? bytes.get(item) : byteRanges(item),
    ]),
  );
}
const corpus = byteRanges({ chunks, groups, templates });
const digest = (value) => createHash("sha256").update(value).digest("hex");
console.log(
  JSON.stringify({
    ...corpus,
    sourceSha256: digest(source),
    summary: {
      promptCorpusSha256: digest(JSON.stringify(corpus)),
      promptGroups: Object.keys(groups).sort(),
      promptStaticChunks: chunks.length,
      promptTemplates: templates.length,
    },
  }),
);
