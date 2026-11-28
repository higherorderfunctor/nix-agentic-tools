import { createHash } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";

// Extracts the three workflow prompts the Kiro engine ships as string literals
// (the orchestration steering and the `wf-workflow-creator` and `wf-planner`
// agent bodies). The bundle is parsed, never run.
// Usage: `node prompts.mjs <acp-server.js> <typescript> [--digest]`.
// Prints `{ <fact key>: { kind, start, end, text } }` as JSON; with `--digest`,
// `text` is replaced by `sha256` of its UTF-8 bytes. `start`/`end` are the
// UTF-8 byte span of the whole literal including its quotes (end exclusive),
// the convention the `lib/packaging.nix` wrapper and
// `checks/prompt-extract.mjs` rely on. A prompt that is missing, duplicated or
// not one static string fails the run naming its fact key.
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
  // from these through TypeScript's own write classification plus
  // `isAssignmentTarget` below for the cases it misses.
  if (typeof ts.isWriteAccess !== "function")
    fail("bundle", "the TypeScript build has no isWriteAccess");
  const occurrences = new Map();
  // isWriteAccess misses rest targets and shorthand defaults, so an identifier
  // is also a write when it is part of an assignment target: walk up through
  // the destructuring node kinds and answer true when the chain ends as the
  // left of an `=` (a nested default included) or the head of a for-in/of. A
  // spread or assignment in value position ends elsewhere, so it is a read or
  // an ordinary write.
  const keepsTarget = (parent, at) =>
    ts.isArrayLiteralExpression(parent) ||
    ts.isObjectLiteralExpression(parent) ||
    ts.isParenthesizedExpression(parent) ||
    ts.isSpreadElement(parent) ||
    ts.isSpreadAssignment(parent) ||
    (ts.isPropertyAssignment(parent) && parent.initializer === at) ||
    (ts.isShorthandPropertyAssignment(parent) && parent.name === at);
  const isAssignmentTarget = (node) => {
    for (let at = node; at.parent; at = at.parent) {
      const { parent } = at;
      if (
        (ts.isBinaryExpression(parent) &&
          parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
          parent.left === at) ||
        ((ts.isForInStatement(parent) || ts.isForOfStatement(parent)) &&
          parent.initializer === at)
      )
        return true;
      if (!keepsTarget(parent, at)) return false;
    }
    return false;
  };
  const symbolOf = (identifier) =>
    ts.isShorthandPropertyAssignment(identifier.parent) &&
    identifier.parent.name === identifier
      ? checker.getShorthandAssignmentValueSymbol(identifier.parent)
      : checker.getSymbolAtLocation(identifier);

  (function visit(node) {
    // A write inside `with` has no checker symbol, and a direct eval can write
    // any binding in scope, so neither could be seen.
    if (ts.isWithStatement(node)) fail("bundle", "the bundle uses with");
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "eval"
    )
      fail("bundle", "the bundle calls eval");
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
  // `name = value` assignment that is not part of a destructuring target.
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
      (id) =>
        ts.isWriteAccess(id) || isAssignmentTarget(id) || isInitializer(id),
    );
    if (writes.length !== 1) return undefined;
    const [id] = writes;
    const { parent } = id;
    if (isInitializer(id)) return parent.initializer;
    return ts.isBinaryExpression(parent) &&
      parent.left === id &&
      parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      !isAssignmentTarget(parent)
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
  const digestOnly = process.argv[4] === "--digest";
  const fact = (literal) => ({
    end: utf8Offset(literal.end),
    kind: ts.isStringLiteral(literal)
      ? "StringLiteral"
      : "NoSubstitutionTemplateLiteral",
    ...(digestOnly
      ? { sha256: createHash("sha256").update(literal.text).digest("hex") }
      : {}),
    start: utf8Offset(literal.getStart(file)),
    ...(digestOnly ? {} : { text: literal.text }),
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
