import fs from "node:fs";
import { createRequire } from "node:module";

// Extracts the three workflow prompts the Kiro engine ships as string literals:
// the orchestration steering and the bodies of the `wf-workflow-creator` and
// `wf-planner` agents. Usage: `node prompts.mjs <acp-server.js> <typescript>`.
// Prints `{ <fact key>: { kind, start, end, text } }` as JSON, where `text` is
// the decoded literal and `start`/`end` are the UTF-8 byte span of the whole
// literal including its quotes (end exclusive), so a later unit can scope a
// find/replace to one prompt. The bundle is only parsed, never run. Every
// prompt is found by what it is (a heading, an id in the agent registration
// table), never by its minified binding name, and any prompt that is missing,
// duplicated or not a single static string fails the run naming its fact key.
const require = createRequire(import.meta.url);
const ts = require(process.argv[3]);
const source = fs.readFileSync(process.argv[2], "utf8");
const file = ts.createSourceFile(
  "acp-server.js",
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);

function fail(factKey, reason) {
  throw new Error(`kiro-extract: ${factKey}: ${reason}`);
}

try {
  if (file.parseDiagnostics.length)
    fail("bundle", "the KAS engine bundle is not valid JavaScript");

  // The checker tells apart bindings that share a spelling: a minified name is
  // reused by unrelated scopes, so only symbol identity may join a use to its
  // writes.
  const host = ts.createCompilerHost({});
  host.getSourceFile = (name) => (name === file.fileName ? file : undefined);
  const checker = ts
    .createProgram(
      [file.fileName],
      { allowJs: true, noLib: true, noResolve: true, types: [] },
      host,
    )
    .getTypeChecker();

  const isStaticString = (node) =>
    ts.isStringLiteralLike(node) && !ts.isTaggedTemplateExpression(node.parent);
  const heading = "# Workflow Orchestration\n";
  const headingLiterals = [];
  const registrationTables = [];
  // Every identifier occurrence, keyed by checker symbol. Writes are found
  // from these by TypeScript's own write classification, never by listing
  // syntax shapes.
  if (typeof ts.isWriteAccess !== "function")
    fail("bundle", "the TypeScript build has no isWriteAccess");
  const occurrences = new Map();
  // isWriteAccess misses a rest target (`[...x] = v`, `({...x} = v)`, even
  // nested), so a spread that wraps the identifier through literals alone is
  // treated as a write, which also fails closed for a plain read.
  const isSpreadWrapped = (node) => {
    for (let at = node; at.parent; at = at.parent) {
      if (ts.isSpreadElement(at.parent) || ts.isSpreadAssignment(at.parent))
        return true;
      if (
        ![
          ts.isArrayLiteralExpression,
          ts.isObjectLiteralExpression,
          ts.isParenthesizedExpression,
          ts.isPropertyAssignment,
        ].some((is) => is(at.parent))
      )
        return false;
    }
    return false;
  };
  const symbolOf = (identifier) =>
    ts.isShorthandPropertyAssignment(identifier.parent) &&
    identifier.parent.name === identifier
      ? checker.getShorthandAssignmentValueSymbol(identifier.parent)
      : checker.getSymbolAtLocation(identifier);

  // One walk collects everything the lookups need.
  (function visit(node) {
    if (
      (ts.isStringLiteralLike(node) || ts.isTemplateHead(node)) &&
      node.text.startsWith(heading)
    )
      headingLiterals.push(node);
    // A registration table is an array, declared or assigned to a binding,
    // whose every element is a two-element `[id, body]` row.
    if (
      ts.isArrayLiteralExpression(node) &&
      (ts.isVariableDeclaration(node.parent)
        ? node.parent.initializer === node
        : ts.isBinaryExpression(node.parent) &&
          node.parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
          node.parent.right === node) &&
      node.elements.length &&
      node.elements.every(
        (row) => ts.isArrayLiteralExpression(row) && row.elements.length === 2,
      )
    )
      registrationTables.push(node);
    const symbol = ts.isIdentifier(node) && symbolOf(node);
    if (symbol)
      occurrences.set(symbol, [...(occurrences.get(symbol) ?? []), node]);
    ts.forEachChild(node, visit);
  })(file);

  // The value a binding holds when it is static, else undefined. Static means
  // every declaration is a plain `var`/`let`/`const` of that name (not a
  // parameter, catch clause, function, pattern element or loop head) and the
  // whole file writes it exactly once, as a declaration initializer or a plain
  // `name = value` assignment that is not a destructuring default.
  function singleWrite(symbol) {
    const plain = (declaration) =>
      ts.isVariableDeclaration(declaration) &&
      ts.isIdentifier(declaration.name) &&
      ts.isVariableDeclarationList(declaration.parent) &&
      !ts.isForInStatement(declaration.parent.parent) &&
      !ts.isForOfStatement(declaration.parent.parent);
    if (!symbol?.declarations?.length || !symbol.declarations.every(plain))
      return undefined;
    const isInitializer = (id) =>
      ts.isVariableDeclaration(id.parent) &&
      id.parent.name === id &&
      id.parent.initializer;
    const writes = (occurrences.get(symbol) ?? []).filter(
      (id) => ts.isWriteAccess(id) || isSpreadWrapped(id) || isInitializer(id),
    );
    if (writes.length !== 1) return undefined;
    const [id] = writes;
    const { parent } = id;
    if (isInitializer(id)) return parent.initializer;
    return ts.isBinaryExpression(parent) &&
      parent.left === id &&
      parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      !ts.isArrayLiteralExpression(parent.parent) &&
      !ts.isPropertyAssignment(parent.parent) &&
      !ts.isSpreadElement(parent.parent)
      ? parent.right
      : undefined;
  }

  // The literal an expression is, directly or through static bindings. An
  // alias cycle is unresolved.
  function staticLiteral(expression, seen = new Set()) {
    if (isStaticString(expression)) return expression;
    if (!ts.isIdentifier(expression)) return undefined;
    const symbol = checker.getSymbolAtLocation(expression);
    const value = seen.has(symbol) ? undefined : singleWrite(symbol);
    return value && staticLiteral(value, seen.add(symbol));
  }

  // Byte offsets, because consumers patch UTF-8 and TypeScript counts UTF-16.
  const utf8Offset = (position) => Buffer.byteLength(source.slice(0, position));
  const fact = (literal) => ({
    end: utf8Offset(literal.end),
    kind: ts.isStringLiteral(literal)
      ? "StringLiteral"
      : "NoSubstitutionTemplateLiteral",
    start: utf8Offset(literal.getStart(file)),
    text: literal.text,
  });

  function agentBody(agentId, factKey) {
    const rows = registrationTables
      .flatMap((table) => [...table.elements])
      .filter((row) => staticLiteral(row.elements[0])?.text === agentId);
    if (rows.length !== 1)
      fail(factKey, `${rows.length} registration rows for ${agentId}`);
    const body = staticLiteral(rows[0].elements[1]);
    return body ?? fail(factKey, `${agentId} body is not one static string`);
  }

  const orchestrationKey = "workflow.orchestration";
  if (headingLiterals.length !== 1)
    fail(orchestrationKey, `${headingLiterals.length} headed literals`);
  if (!isStaticString(headingLiterals[0]))
    fail(orchestrationKey, "the headed literal is not one static string");

  process.stdout.write(
    JSON.stringify({
      "agents.workflow.creator": fact(
        agentBody("wf-workflow-creator", "agents.workflow.creator"),
      ),
      "agents.workflow.planner": fact(
        agentBody("wf-planner", "agents.workflow.planner"),
      ),
      [orchestrationKey]: fact(headingLiterals[0]),
    }),
  );
} catch (error) {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
}
