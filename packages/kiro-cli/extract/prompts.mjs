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
  // Every write to a binding, keyed by symbol. A write without a value (a
  // compound assignment, an update, a destructuring or iteration target) can
  // never resolve to a literal.
  const writesBySymbol = new Map();
  const symbolOf = (identifier) =>
    ts.isShorthandPropertyAssignment(identifier.parent) &&
    identifier.parent.name === identifier
      ? checker.getShorthandAssignmentValueSymbol(identifier.parent)
      : checker.getSymbolAtLocation(identifier);
  const addWrite = (target, value) => {
    const symbol = symbolOf(target);
    writesBySymbol.set(symbol, [...(writesBySymbol.get(symbol) ?? []), value]);
  };
  // Records every binding a pattern or assignment target writes to.
  function addTargetWrites(target) {
    if (ts.isIdentifier(target)) addWrite(target, undefined);
    else if (
      ts.isArrayBindingPattern(target) ||
      ts.isObjectBindingPattern(target) ||
      ts.isArrayLiteralExpression(target)
    )
      for (const element of target.elements)
        addTargetWrites(element.name ?? element);
    else if (ts.isObjectLiteralExpression(target))
      for (const property of target.properties)
        addTargetWrites(
          ts.isPropertyAssignment(property) ? property.initializer : property,
        );
    else if (ts.isShorthandPropertyAssignment(target))
      addTargetWrites(target.name);
    else if (
      ts.isSpreadElement(target) ||
      ts.isSpreadAssignment(target) ||
      ts.isParenthesizedExpression(target)
    )
      addTargetWrites(target.expression);
    else if (
      ts.isBinaryExpression(target) &&
      target.operatorToken.kind === ts.SyntaxKind.EqualsToken
    )
      addTargetWrites(target.left);
  }

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
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind >= ts.SyntaxKind.FirstAssignment &&
      node.operatorToken.kind <= ts.SyntaxKind.LastAssignment
    )
      if (
        ts.isIdentifier(node.left) &&
        node.operatorToken.kind === ts.SyntaxKind.EqualsToken
      )
        addWrite(node.left, node.right);
      else addTargetWrites(node.left);
    if (ts.isVariableDeclaration(node)) {
      if (ts.isIdentifier(node.name)) {
        if (node.initializer) addWrite(node.name, node.initializer);
        else if (
          ts.isForInStatement(node.parent.parent) ||
          ts.isForOfStatement(node.parent.parent)
        )
          addTargetWrites(node.name);
      } else addTargetWrites(node.name);
    }
    if (
      (ts.isForInStatement(node) || ts.isForOfStatement(node)) &&
      !ts.isVariableDeclarationList(node.initializer)
    )
      addTargetWrites(node.initializer);
    if (
      (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node)) &&
      [ts.SyntaxKind.PlusPlusToken, ts.SyntaxKind.MinusMinusToken].includes(
        node.operator,
      )
    )
      addTargetWrites(node.operand);
    ts.forEachChild(node, visit);
  })(file);

  // The literal an expression is, directly or through bindings that each have
  // exactly one write anywhere in the bundle (including inside lazy
  // initializer callbacks), else undefined. An alias cycle is unresolved.
  function staticLiteral(expression, seen = new Set()) {
    if (isStaticString(expression)) return expression;
    if (!ts.isIdentifier(expression)) return undefined;
    const symbol = checker.getSymbolAtLocation(expression);
    const writes = writesBySymbol.get(symbol) ?? [];
    if (!symbol || seen.has(symbol) || writes.length !== 1 || !writes[0])
      return undefined;
    return staticLiteral(writes[0], seen.add(symbol));
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
