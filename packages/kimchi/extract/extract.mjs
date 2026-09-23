#!/usr/bin/env node

/** Extract Kimchi's settings and environment surfaces with TypeScript. */

import { readdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const EXTRACTOR_SCHEMA = 3;

function fail(message) {
  throw new Error(`kimchi-extract: ${message}`);
}

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined)
      fail(`invalid argument list near ${name ?? "<end>"}`);
    result[name.slice(2)] = value;
  }
  for (const name of [
    "annotations",
    "kimchi-source",
    "kimchi-source-url",
    "kimchi-version",
    "out",
    "pi-agent-core-package",
    "pi-ai-package",
    "pi-package",
    "pi-tui-package",
    "typescript",
  ]) {
    if (!result[name]) fail(`missing --${name}`);
  }
  return result;
}

async function filesUnder(root, accepted) {
  const found = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        if (!accepted.excludedDirectories.has(entry.name)) await visit(path);
      } else if (accepted.file(path)) {
        found.push(path);
      }
    }
  }
  await visit(root);
  return found.sort();
}

function sortObject(value) {
  return Object.fromEntries(
    Object.entries(value).sort(([left], [right]) => left.localeCompare(right)),
  );
}

function syntaxName(node, ts) {
  if (
    ts.isIdentifier(node) ||
    ts.isStringLiteralLike(node) ||
    ts.isNumericLiteral(node)
  )
    return node.text;
  if (
    ts.isComputedPropertyName(node) &&
    ts.isStringLiteralLike(node.expression)
  )
    return node.expression.text;
  return undefined;
}

// The initializer of the constant `identifier` names, resolved through the
// checker (so a same-named constant elsewhere can never stand in for it).
function constantInitializer(identifier, checker, ts) {
  let symbol = checker.getSymbolAtLocation(identifier);
  if (symbol && symbol.flags & ts.SymbolFlags.Alias)
    symbol = checker.getAliasedSymbol(symbol);
  const initializers = (symbol?.declarations ?? [])
    .filter(
      (declaration) =>
        ts.isVariableDeclaration(declaration) && declaration.initializer,
    )
    .map((declaration) => declaration.initializer);
  if (initializers.length !== 1)
    fail(
      `cannot resolve constant ${identifier.text} in ${identifier.getSourceFile().fileName} (${initializers.length} initialized declarations)`,
    );
  return initializers[0];
}

function literalValue(node, ts, checker, seen = new Set()) {
  if (ts.isStringLiteralLike(node) || ts.isNumericLiteral(node))
    return node.text;
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (node.kind === ts.SyntaxKind.NullKeyword) return null;
  if (ts.isPrefixUnaryExpression(node) && ts.isNumericLiteral(node.operand)) {
    const number = Number(node.operand.text);
    return node.operator === ts.SyntaxKind.MinusToken ? -number : number;
  }
  if (ts.isArrayLiteralExpression(node))
    return node.elements.map((element) =>
      literalValue(element, ts, checker, seen),
    );
  if (ts.isObjectLiteralExpression(node)) {
    const object = {};
    for (const property of node.properties) {
      if (
        !ts.isPropertyAssignment(property) &&
        !ts.isShorthandPropertyAssignment(property)
      ) {
        fail(`unsupported object member ${property.getText()}`);
      }
      const name = syntaxName(property.name, ts);
      if (name === undefined)
        fail(`unsupported computed object key ${property.name.getText()}`);
      object[name] = ts.isShorthandPropertyAssignment(property)
        ? literalValue(property.name, ts, checker, seen)
        : literalValue(property.initializer, ts, checker, seen);
    }
    return object;
  }
  if (ts.isIdentifier(node)) {
    if (seen.has(node.text))
      fail(`constant cycle while evaluating ${node.text}`);
    return literalValue(
      constantInitializer(node, checker, ts),
      ts,
      checker,
      new Set([...seen, node.text]),
    );
  }
  fail(`unsupported constant expression ${node.getText()}`);
}

// Every interface, type alias, function and variable declaration, by name,
// across the files that can matter: pi's, and the Kimchi modules reachable
// from src/entry.ts. A bare name is not an identity — Kimchi 1.1.30 ships two
// model-metadata.ts files with different schemas, one of them dead — so a
// lookup by name must match exactly one declaration or the extraction stops.
function declarationIndex(sourceFiles, ts) {
  const declarations = new Map();
  const add = (name, node) => {
    if (!declarations.has(name)) declarations.set(name, []);
    declarations.get(name).push(node);
  };
  for (const sourceFile of sourceFiles) {
    function visit(node) {
      if (
        (ts.isInterfaceDeclaration(node) ||
          ts.isTypeAliasDeclaration(node) ||
          ts.isFunctionDeclaration(node)) &&
        node.name
      ) {
        add(node.name.text, node);
      }
      if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name))
        add(node.name.text, node);
      ts.forEachChild(node, visit);
    }
    visit(sourceFile);
  }
  return declarations;
}

function requireDeclaration(declarations, name, predicate = () => true) {
  const found = (declarations.get(name) ?? []).filter(predicate);
  if (found.length !== 1) {
    const where = found.map((declaration) => {
      const sourceFile = declaration.getSourceFile();
      const { line } = sourceFile.getLineAndCharacterOfPosition(
        declaration.getStart(),
      );
      return `${sourceFile.fileName}:${line + 1}`;
    });
    fail(
      found.length === 0
        ? `TypeScript declaration ${name} was not found in the expected form`
        : `TypeScript declaration ${name} is declared ${found.length} times (${where.join(", ")}); the extraction cannot tell which one Kimchi uses`,
    );
  }
  return found[0];
}

// The declaration `name` refers to at the top level of `sourceFile`: its own
// declaration or the one it imports, never a same-named one elsewhere.
function declarationInScope(sourceFile, name, predicate, checker, ts) {
  let symbol = checker
    .getSymbolsInScope(
      sourceFile,
      ts.SymbolFlags.Value | ts.SymbolFlags.Type | ts.SymbolFlags.Alias,
    )
    .find((candidate) => candidate.name === name);
  if (symbol && symbol.flags & ts.SymbolFlags.Alias)
    symbol = checker.getAliasedSymbol(symbol);
  const found = (symbol?.declarations ?? []).filter(predicate);
  if (found.length !== 1)
    fail(
      `${sourceFile.fileName} does not reach exactly one ${name} in the expected form (found ${found.length})`,
    );
  return found[0];
}

function docsFor(symbol, checker, ts) {
  const text = ts
    .displayPartsToString(symbol?.getDocumentationComment(checker) ?? [])
    .trim();
  return text || undefined;
}

function descriptorForType(type, node, checker, ts, options = {}) {
  const typeFlags =
    ts.TypeFormatFlags.NoTruncation | ts.TypeFormatFlags.InTypeAlias;
  const typeExpression = checker.typeToString(type, node, typeFlags);
  const descriptor = { typeExpression };
  const members = type.isUnion() ? type.types : [type];
  const material = members.filter(
    (member) =>
      !(
        member.flags &
        (ts.TypeFlags.Undefined | ts.TypeFlags.Null | ts.TypeFlags.Never)
      ),
  );
  const literals = material.filter(
    (member) =>
      member.isStringLiteral?.() ||
      member.isNumberLiteral?.() ||
      member.flags & ts.TypeFlags.BooleanLiteral,
  );
  if (typeExpression === "boolean") {
    descriptor.type = "boolean";
  } else if (literals.length === material.length && literals.length > 0) {
    descriptor.type = "enum";
    descriptor.enum = literals.map((member) => {
      if (member.isStringLiteral?.() || member.isNumberLiteral?.())
        return member.value;
      return checker.typeToString(member, node) === "true";
    });
  } else if (
    material.length === 1 &&
    material[0].flags & ts.TypeFlags.StringLike
  ) {
    descriptor.type = "string";
  } else if (
    material.length === 1 &&
    material[0].flags & ts.TypeFlags.NumberLike
  ) {
    descriptor.type = "number";
  } else if (
    material.length === 1 &&
    material[0].flags & ts.TypeFlags.BooleanLike
  ) {
    descriptor.type = "boolean";
  } else if (material.length === 1 && checker.isArrayType(material[0])) {
    descriptor.type = "array";
    if (options.deep) {
      const arguments_ = checker.getTypeArguments(material[0]);
      if (arguments_[0])
        descriptor.items = descriptorForType(
          arguments_[0],
          node,
          checker,
          ts,
          options,
        );
    }
  } else if (material.length === 1 && material[0].flags & ts.TypeFlags.Object) {
    descriptor.type = "object";
    if (options.deep) {
      const properties = {};
      for (const property of checker.getPropertiesOfType(material[0])) {
        const declaration =
          property.valueDeclaration ?? property.declarations?.[0] ?? node;
        const propertyType = checker.getTypeOfSymbolAtLocation(
          property,
          declaration,
        );
        const child = descriptorForType(
          propertyType,
          declaration,
          checker,
          ts,
          options,
        );
        if (property.flags & ts.SymbolFlags.Optional) child.optional = true;
        const description = docsFor(property, checker, ts);
        if (description) child.description = description;
        properties[property.name] = child;
      }
      if (Object.keys(properties).length > 0)
        descriptor.properties = sortObject(properties);
      const index = checker
        .getIndexInfosOfType(material[0])
        .find(
          (info) =>
            info.keyType.flags &
            (ts.TypeFlags.StringLike | ts.TypeFlags.TemplateLiteral),
        );
      if (index)
        descriptor.additionalProperties = descriptorForType(
          index.type,
          node,
          checker,
          ts,
          options,
        );
    }
  } else if (material.length > 1) {
    descriptor.type = "union";
    if (literals.length > 0) {
      descriptor.enum = literals.map(
        (member) =>
          member.value ?? checker.typeToString(member, node) === "true",
      );
    }
  } else {
    descriptor.type = "named";
  }
  return descriptor;
}

function descriptorForNode(node, checker, ts, deep = false) {
  return descriptorForType(checker.getTypeAtLocation(node), node, checker, ts, {
    deep,
  });
}

function membersOfTypeNode(node, checker, ts, deep = false) {
  const type = checker.getTypeAtLocation(node);
  const result = {};
  for (const property of checker.getPropertiesOfType(type)) {
    const declaration =
      property.valueDeclaration ?? property.declarations?.[0] ?? node;
    const descriptor = descriptorForType(
      checker.getTypeOfSymbolAtLocation(property, declaration),
      declaration,
      checker,
      ts,
      {
        deep,
      },
    );
    if (property.flags & ts.SymbolFlags.Optional) descriptor.optional = true;
    const description = docsFor(property, checker, ts);
    if (description) descriptor.description = description;
    result[property.name] = descriptor;
  }
  return sortObject(result);
}

function membersOfDeclaration(declaration, checker, ts, deep = false) {
  return membersOfTypeNode(declaration, checker, ts, deep);
}

// The JSON files config.ts reads, by the basename its readFileSync path ends
// in. Every parse must land in exactly one of these; config.ts reading any
// other file is a new surface and stops the extraction.
const CONFIG_TS_PARSE_TARGETS = {
  "config.json": "config",
  "settings.json": "harness",
};

// A path parameter of an exported config.ts function stands for a caller's
// override (tests, alternate homes). It never decides which file is read.
const CALLER_OVERRIDE = Symbol("caller override");

function unwrapExpression(expression, ts) {
  while (
    ts.isAsExpression(expression) ||
    ts.isNonNullExpression(expression) ||
    ts.isParenthesizedExpression(expression) ||
    ts.isSatisfiesExpression(expression)
  ) {
    expression = expression.expression;
  }
  return expression;
}

// Attribute each parsed object in config.ts to the file it was read from by
// following the parse argument back to readFileSync's path, then the path
// through constants, defaults, `??`/`||` fallbacks, and in-file call sites.
// Kimchi 1.1.30 parses harness/settings.json in config.ts
// (readAutoDefaultApplied), so "every JSON.parse here is config.json" no
// longer holds; an unattributable parse fails rather than being guessed.
function discoverConfigKeys(sourceFile, checker, ts) {
  const location = (node) => {
    const { line } = sourceFile.getLineAndCharacterOfPosition(node.getStart());
    return `config.ts:${line + 1}`;
  };
  const symbolOf = (node) => {
    let symbol = checker.getSymbolAtLocation(node);
    if (symbol && symbol.flags & ts.SymbolFlags.Alias)
      symbol = checker.getAliasedSymbol(symbol);
    return symbol;
  };
  const callSites = new Map();
  function indexCalls(node) {
    if (ts.isCallExpression(node)) {
      const symbol = symbolOf(node.expression);
      if (symbol) {
        if (!callSites.has(symbol)) callSites.set(symbol, []);
        callSites.get(symbol).push(node);
      }
    }
    ts.forEachChild(node, indexCalls);
  }
  indexCalls(sourceFile);

  const pathCache = new Map();
  function pathTargets(expression, seen = new Set()) {
    expression = unwrapExpression(expression, ts);
    if (ts.isStringLiteralLike(expression))
      return new Set([expression.text.split("/").pop()]);
    if (
      ts.isBinaryExpression(expression) &&
      [ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.BarBarToken].includes(
        expression.operatorToken.kind,
      )
    ) {
      return new Set([
        ...pathTargets(expression.left, seen),
        ...pathTargets(expression.right, seen),
      ]);
    }
    if (
      ts.isCallExpression(expression) &&
      ["join", "resolve"].includes(
        ts.isPropertyAccessExpression(expression.expression)
          ? expression.expression.name.text
          : expression.expression.getText(),
      ) &&
      expression.arguments.length > 0
    ) {
      return pathTargets(expression.arguments.at(-1), seen);
    }
    if (ts.isPropertyAccessExpression(expression)) {
      const root = pathTargets(expression.expression, seen);
      return root.size === 1 && root.has(CALLER_OVERRIDE) ? root : new Set();
    }
    if (!ts.isIdentifier(expression)) return new Set();
    const symbol = symbolOf(expression);
    if (!symbol || seen.has(symbol)) return new Set();
    if (pathCache.has(symbol)) return pathCache.get(symbol);
    const nextSeen = new Set([...seen, symbol]);
    const targets = new Set();
    for (const declaration of symbol.declarations ?? []) {
      if (ts.isVariableDeclaration(declaration) && declaration.initializer) {
        for (const target of pathTargets(declaration.initializer, nextSeen))
          targets.add(target);
      } else if (ts.isParameter(declaration)) {
        const owner = declaration.parent;
        if (declaration.initializer) {
          for (const target of pathTargets(declaration.initializer, nextSeen))
            targets.add(target);
        }
        if (!ts.isFunctionDeclaration(owner) || !owner.name) continue;
        if (ts.getCombinedModifierFlags(owner) & ts.ModifierFlags.Export)
          targets.add(CALLER_OVERRIDE);
        const index = owner.parameters.indexOf(declaration);
        for (const call of callSites.get(symbolOf(owner.name)) ?? []) {
          const argument = call.arguments[index];
          if (!argument) continue;
          for (const target of pathTargets(argument, nextSeen))
            targets.add(target);
        }
      }
    }
    if (seen.size === 0) pathCache.set(symbol, targets);
    return targets;
  }
  function surfaceOfPath(pathExpression, node) {
    const files = [...pathTargets(pathExpression)].filter(
      (target) => target !== CALLER_OVERRIDE,
    );
    const surface =
      files.length === 1 ? CONFIG_TS_PARSE_TARGETS[files[0]] : undefined;
    if (!surface) {
      fail(
        `cannot attribute the JSON read at ${location(node)} (${node.getText()}) to config.json or harness/settings.json; it resolves to ${JSON.stringify(files.sort())}`,
      );
    }
    return surface;
  }
  // JSON.parse's argument is the file text: readFileSync(path, ...) directly
  // or through a local bound to it.
  function readPath(expression, seen = new Set()) {
    expression = unwrapExpression(expression, ts);
    if (
      ts.isCallExpression(expression) &&
      expression.expression.getText() === "readFileSync" &&
      expression.arguments[0]
    ) {
      return expression.arguments[0];
    }
    if (!ts.isIdentifier(expression)) return undefined;
    const symbol = symbolOf(expression);
    if (!symbol || seen.has(symbol)) return undefined;
    for (const declaration of symbol.declarations ?? []) {
      if (ts.isVariableDeclaration(declaration) && declaration.initializer)
        return readPath(declaration.initializer, new Set([...seen, symbol]));
    }
    return undefined;
  }
  function boundSymbol(call) {
    const parent = call.parent;
    if (
      ts.isVariableDeclaration(parent) &&
      parent.initializer === call &&
      ts.isIdentifier(parent.name)
    )
      return symbolOf(parent.name);
    if (
      ts.isBinaryExpression(parent) &&
      parent.right === call &&
      parent.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      ts.isIdentifier(parent.left)
    )
      return symbolOf(parent.left);
    fail(
      `the JSON read at ${location(call)} is not bound to a local, so its keys cannot be counted`,
    );
  }

  const parsedSymbols = new Map();
  function identify(node) {
    if (ts.isCallExpression(node)) {
      const called = node.expression;
      let pathExpression;
      if (
        ts.isPropertyAccessExpression(called) &&
        called.expression.getText() === "JSON" &&
        called.name.text === "parse"
      ) {
        pathExpression = readPath(node.arguments[0]);
        if (!pathExpression)
          fail(
            `cannot follow the JSON.parse argument at ${location(node)} back to a readFileSync path`,
          );
      } else if (
        ts.isIdentifier(called) &&
        called.text === "readConfigObject"
      ) {
        pathExpression = node.arguments[0];
      }
      if (pathExpression) {
        const surface = surfaceOfPath(pathExpression, node);
        parsedSymbols.set(boundSymbol(node), surface);
      }
      if (ts.isIdentifier(called) && called.text === "updateConfigFile") {
        const surface = surfaceOfPath(node.arguments[0], node);
        const callback = node.arguments.find(
          (argument) =>
            ts.isArrowFunction(argument) || ts.isFunctionExpression(argument),
        );
        const parameter = callback?.parameters[0]?.name;
        if (parameter && ts.isIdentifier(parameter))
          parsedSymbols.set(symbolOf(parameter), surface);
      }
    }
    ts.forEachChild(node, identify);
  }
  identify(sourceFile);
  const found = { config: new Set(), harness: new Set() };
  function visit(node) {
    let name;
    if (
      ts.isPropertyAccessExpression(node) &&
      ts.isIdentifier(node.expression)
    ) {
      name = node.name.text;
    } else if (
      ts.isElementAccessExpression(node) &&
      ts.isIdentifier(node.expression) &&
      ts.isStringLiteralLike(node.argumentExpression)
    ) {
      name = node.argumentExpression.text;
    }
    const surface = name && parsedSymbols.get(symbolOf(node.expression));
    if (surface) found[surface].add(name);
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return found;
}

function discoverProjectConfigKeys(configSource, annotations, checker, ts) {
  const loadConfig = declarationInScope(
    configSource,
    "loadConfig",
    ts.isFunctionDeclaration,
    checker,
    ts,
  );
  let merge;
  function locate(node) {
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.name.text === "extras" &&
      node.initializer &&
      ts.isObjectLiteralExpression(node.initializer)
    ) {
      merge = node.initializer;
    }
    ts.forEachChild(node, locate);
  }
  locate(loadConfig);
  if (!merge) fail("loadConfig no longer has an object-literal extras merge");

  const canonical = new Set();
  for (const property of merge.properties) {
    if (!ts.isPropertyAssignment(property))
      fail("loadConfig extras merge contains an unsupported member");
    const name = syntaxName(property.name, ts);
    let readsProject = false;
    function inspect(node) {
      if (
        ts.isPropertyAccessExpression(node) &&
        ts.isIdentifier(node.expression) &&
        node.expression.text === "projectExtras"
      ) {
        readsProject = true;
      }
      ts.forEachChild(node, inspect);
    }
    inspect(property.initializer);
    if (readsProject) canonical.add(name);
  }

  const result = new Set(canonical);
  for (const [name, annotation] of Object.entries(annotations)) {
    if (annotation.aliasFor && canonical.has(annotation.aliasFor))
      result.add(name);
  }
  return result;
}

function runtimeValidationKinds(node, ts, initialAliases = {}) {
  const aliases = new Map(
    Object.entries(initialAliases).map(([name, path]) => [name, path]),
  );
  function pathFor(expression) {
    expression = unwrapExpression(expression, ts);
    if (ts.isIdentifier(expression)) return aliases.get(expression.text);
    if (ts.isPropertyAccessExpression(expression)) {
      const parent = pathFor(expression.expression);
      if (parent) return [...parent, expression.name.text];
    }
    return undefined;
  }
  function collectAliases(current) {
    if (
      ts.isVariableDeclaration(current) &&
      ts.isIdentifier(current.name) &&
      current.initializer
    ) {
      const path = pathFor(current.initializer);
      if (path) aliases.set(current.name.text, path);
    }
    if (
      ts.isCallExpression(current) &&
      ts.isPropertyAccessExpression(current.expression) &&
      current.expression.name.text === "every"
    ) {
      const path = pathFor(current.expression.expression);
      const callback = current.arguments[0];
      const parameter =
        callback &&
        (ts.isArrowFunction(callback) || ts.isFunctionExpression(callback)) &&
        callback.parameters[0]?.name;
      if (path && parameter && ts.isIdentifier(parameter))
        aliases.set(parameter.text, [...path, "[]"]);
    }
    ts.forEachChild(current, collectAliases);
  }
  collectAliases(node);

  const found = new Map();
  function record(path, kind) {
    const key = path.join(".");
    if (!found.has(key)) found.set(key, new Set());
    found.get(key).add(kind);
  }
  function visit(current) {
    if (ts.isBinaryExpression(current)) {
      for (const [typed, literal] of [
        [current.left, current.right],
        [current.right, current.left],
      ]) {
        if (
          ts.isTypeOfExpression(typed) &&
          ts.isStringLiteralLike(literal) &&
          ["boolean", "number", "object", "string"].includes(literal.text)
        ) {
          const path = pathFor(typed.expression);
          if (path) record(path, literal.text);
        }
      }
    }
    if (
      ts.isCallExpression(current) &&
      ts.isPropertyAccessExpression(current.expression) &&
      ts.isIdentifier(current.expression.expression) &&
      current.expression.expression.text === "Array" &&
      current.expression.name.text === "isArray" &&
      current.arguments.length === 1
    ) {
      const path = pathFor(current.arguments[0]);
      if (path) record(path, "array");
    }
    ts.forEachChild(current, visit);
  }
  visit(node);
  return found;
}

function validateRuntimeDescriptor(
  name,
  descriptor,
  validationKinds,
  path = [name],
) {
  const key = path.join(".");
  if (
    ["array", "boolean", "number", "object", "string"].includes(descriptor.type)
  ) {
    if (!validationKinds.get(key)?.has(descriptor.type)) {
      fail(
        `config.json validation shape changed: ${key} is no longer guarded as a ${descriptor.type}`,
      );
    }
  }
  if (descriptor.type === "array" && descriptor.items) {
    validateRuntimeDescriptor(name, descriptor.items, validationKinds, [
      ...path,
      "[]",
    ]);
  }
  for (const [property, child] of Object.entries(descriptor.properties ?? {})) {
    if (child.type !== "enum" && child.type !== "union")
      validateRuntimeDescriptor(name, child, validationKinds, [
        ...path,
        property,
      ]);
  }
}

// config.json keys that have no runtime effect, derived rather than annotated.
// A key is inert when its loaded KimchiConfig member is tagged @deprecated
// upstream AND nothing reads it: neither the loaded member anywhere, nor the
// raw readConfigExtras member outside config.ts (whose own parse, merge and
// obsolete-key warning read it by design). A release that starts consuming the
// key clears the flag, and the key becomes an ordinary option.
function inertConfigKeys(
  configSource,
  kimchiSources,
  readExtras,
  kimchiConfig,
  checker,
  ts,
) {
  const memberNamed = (container, name) =>
    container.members.find(
      (member) => member.name && syntaxName(member.name, ts) === name,
    );
  const deprecated = new Map();
  for (const member of kimchiConfig.members) {
    const tag = ts
      .getJSDocTags(member)
      .find((candidate) => candidate.tagName.text === "deprecated");
    if (!tag || !member.name) continue;
    const text = ts.getTextOfJSDocComment(tag.comment)?.trim();
    if (!text)
      fail(
        `KimchiConfig.${member.name.getText()} is @deprecated without a reason`,
      );
    deprecated.set(syntaxName(member.name, ts), text);
  }
  const loaded = new Map();
  const raw = new Map();
  for (const name of deprecated.keys()) {
    loaded.set(memberNamed(kimchiConfig, name), name);
    const rawMember = memberNamed(readExtras.type, name);
    if (rawMember) raw.set(rawMember, name);
  }
  const consumed = new Map();
  for (const sourceFile of kimchiSources) {
    function record(symbol, node) {
      for (const declaration of symbol?.declarations ?? []) {
        const name =
          loaded.get(declaration) ??
          (sourceFile !== configSource ? raw.get(declaration) : undefined);
        if (name && !consumed.has(name)) {
          const { line } = sourceFile.getLineAndCharacterOfPosition(
            node.getStart(),
          );
          consumed.set(name, `${sourceFile.fileName}:${line + 1}`);
        }
      }
    }
    function visit(node) {
      if (
        (ts.isPropertyAccessExpression(node) ||
          ts.isElementAccessExpression(node)) &&
        !isWriteOnly(node, ts)
      ) {
        record(
          checker.getSymbolAtLocation(
            ts.isPropertyAccessExpression(node)
              ? node.name
              : node.argumentExpression,
          ),
          node,
        );
      }
      if (ts.isBindingElement(node) && ts.isObjectBindingPattern(node.parent)) {
        const property = syntaxName(node.propertyName ?? node.name, ts);
        if (property !== undefined) {
          record(
            checker.getTypeAtLocation(node.parent).getProperty?.(property),
            node,
          );
        }
      }
      ts.forEachChild(node, visit);
    }
    visit(sourceFile);
  }
  return new Map([...deprecated].filter(([name]) => !consumed.has(name)));
}

function extractConfig(
  sourceFile,
  discovered,
  declarations,
  annotations,
  kimchiSources,
  checker,
  analysisChecker,
  ts,
) {
  // Every name below is resolved as config.ts itself sees it: Kimchi 1.1.30
  // also declares a loadConfig in extensions/permissions/config.ts.
  const configDeclaration = (name, predicate) =>
    declarationInScope(sourceFile, name, predicate, checker, ts);
  const readExtras = configDeclaration(
    "readConfigExtras",
    ts.isFunctionDeclaration,
  );
  if (!readExtras.type)
    fail("readConfigExtras no longer has an explicit return type");
  const extras = membersOfTypeNode(readExtras.type, checker, ts, true);
  const interfaceMembers = (name) => {
    const declaration = configDeclaration(name, ts.isInterfaceDeclaration);
    return membersOfDeclaration(declaration, checker, ts, true);
  };
  const keys = { ...extras };
  keys.api_key = structuredClone(keys.apiKey);
  keys.device_id = structuredClone(keys.deviceId);
  // These objects are read behind presence/type guards rather than declared in
  // readConfigExtras, so absence is a valid state even though their nested
  // interfaces describe required fields once the object exists.
  keys.telemetry = {
    ...keys.telemetry,
    optional: true,
    type: "object",
    typeExpression: "TelemetryConfig",
    properties: interfaceMembers("TelemetryConfig"),
  };
  delete keys.telemetry.properties.apiKey;
  for (const property of Object.values(keys.telemetry.properties)) {
    // readTelemetryConfig independently validates each input member and fills
    // any absent value from an environment value or runtime default.
    property.optional = true;
  }
  keys.surveys = {
    ...keys.surveys,
    optional: true,
    type: "object",
    typeExpression: "Record<string, SurveyConfig>",
    additionalProperties: {
      type: "object",
      typeExpression: "SurveyConfig",
      properties: interfaceMembers("SurveyConfig"),
    },
  };
  const booleanType = checker.getBooleanType();
  keys.teleport = {
    ...keys.teleport,
    optional: true,
    type: "object",
    typeExpression: "{ compactHint?: { enabled?: boolean } }",
    properties: {
      compactHint: {
        optional: true,
        type: "object",
        typeExpression: "{ enabled?: boolean }",
        properties: {
          enabled: {
            ...descriptorForType(booleanType, sourceFile, checker, ts),
            optional: true,
          },
        },
      },
    },
  };
  keys.gitTokens = {
    ...keys.gitTokens,
    optional: true,
    type: "object",
    typeExpression: "Record<string, string>",
    additionalProperties: descriptorForType(
      checker.getStringType(),
      sourceFile,
      checker,
      ts,
    ),
  };

  const extrasValidation = runtimeValidationKinds(readExtras, ts, {
    parsed: [],
  });
  for (const [name, descriptor] of Object.entries(extras)) {
    if (["migrationState", "onboarding", "preferences"].includes(name))
      continue;
    validateRuntimeDescriptor(name, descriptor, extrasValidation);
  }
  for (const [alias, canonical] of [
    ["api_key", "apiKey"],
    ["device_id", "deviceId"],
  ]) {
    const kind = extras[canonical].type;
    if (!extrasValidation.get(alias)?.has(kind)) {
      fail(
        `config.json validation shape changed: ${alias} is no longer guarded as a ${kind}`,
      );
    }
  }
  for (const [name, functionName, root] of [
    ["onboarding", "parseOnboardingConfig", "value"],
    ["preferences", "parsePreferencesConfig", "value"],
    ["telemetry", "readTelemetryConfig", "parsed"],
  ]) {
    const parser = configDeclaration(functionName, ts.isFunctionDeclaration);
    const validation = runtimeValidationKinds(parser, ts, {
      [root]: name === "telemetry" ? [] : [name],
    });
    validateRuntimeDescriptor(name, keys[name], validation);
  }
  if (discovered.has("harness")) {
    fail(
      "config.json exposes a top-level 'harness' key; this collides with the reserved harness settings namespace",
    );
  }
  const expected = new Set(Object.keys(annotations));
  const unknown = [...discovered].filter((key) => !expected.has(key)).sort();
  const missing = [...expected].filter((key) => !discovered.has(key)).sort();
  if (unknown.length || missing.length)
    fail(
      `config.json key census changed; new=${JSON.stringify(unknown)}, missing=${JSON.stringify(missing)}`,
    );
  const projectKeys = discoverProjectConfigKeys(
    sourceFile,
    annotations,
    checker,
    ts,
  );
  const inert = inertConfigKeys(
    sourceFile,
    kimchiSources,
    readExtras,
    configDeclaration("KimchiConfig", ts.isInterfaceDeclaration),
    analysisChecker,
    ts,
  );
  for (const [name, annotation] of Object.entries(annotations)) {
    if (!keys[name])
      fail(`no compiler-derived type for config.json key ${name}`);
    const handKeys = Object.keys(annotation).filter(
      (key) => key !== "aliasFor",
    );
    if (handKeys.length)
      fail(
        `config.${name} annotations may name only an aliasFor; ${JSON.stringify(handKeys)} are derived from the sources`,
      );
    keys[name] = {
      ...keys[name],
      ...annotation,
      ...(inert.has(name) ? { deprecated: inert.get(name), inert: true } : {}),
      project: projectKeys.has(name),
    };
  }
  return {
    keys: sortObject(keys),
    projectTier: {
      gatedByProjectTrust: true,
      honoredKeys: [...projectKeys].sort(),
    },
  };
}

function typeBoxDescriptor(initializer, checker, ts) {
  function convert(node) {
    if (ts.isIdentifier(node))
      return convert(constantInitializer(node, checker, ts));
    if (
      !ts.isCallExpression(node) ||
      !ts.isPropertyAccessExpression(node.expression)
    ) {
      fail(`unsupported TypeBox schema expression ${node.getText()}`);
    }
    const method = node.expression.name.text;
    if (method === "Optional")
      return { ...convert(node.arguments[0]), optional: true };
    if (method === "String")
      return { type: "string", typeExpression: "string" };
    if (method === "Boolean")
      return { type: "boolean", typeExpression: "boolean" };
    if (method === "Literal") {
      const value = literalValue(node.arguments[0], ts, checker);
      return {
        enum: [value],
        type: "enum",
        typeExpression: JSON.stringify(value),
      };
    }
    if (method === "Union") {
      if (!ts.isArrayLiteralExpression(node.arguments[0]))
        fail("Type.Union argument is no longer an array literal");
      const values = node.arguments[0].elements.flatMap(
        (element) => convert(element).enum ?? [],
      );
      return {
        enum: values,
        type: "enum",
        typeExpression: values.map(JSON.stringify).join(" | "),
      };
    }
    if (method === "Object") {
      const object = node.arguments[0];
      if (!ts.isObjectLiteralExpression(object))
        fail("Type.Object argument is no longer an object literal");
      const properties = {};
      for (const property of object.properties) {
        if (!ts.isPropertyAssignment(property))
          fail("Type.Object has an unsupported member");
        const name = syntaxName(property.name, ts);
        properties[name] = convert(property.initializer);
      }
      return {
        properties: sortObject(properties),
        type: "object",
        typeExpression: "object",
      };
    }
    fail(`unsupported TypeBox method Type.${method}`);
  }
  return convert(initializer);
}

function extractDefaultProjectTrust(sourceFile, checker, ts) {
  let settingsManager;
  function findClass(node) {
    if (ts.isClassDeclaration(node) && node.name?.text === "SettingsManager") {
      settingsManager = node;
      return;
    }
    ts.forEachChild(node, findClass);
  }
  findClass(sourceFile);
  if (!settingsManager) fail("pi SettingsManager class was not found");
  const method = settingsManager.members.find(
    (member) =>
      ts.isMethodDeclaration(member) &&
      syntaxName(member.name, ts) === "getDefaultProjectTrust",
  );
  if (!method?.body)
    fail("pi getDefaultProjectTrust method was not found in the expected form");
  const returnStatement = method.body.statements.find(ts.isReturnStatement);
  const expression = returnStatement?.expression;
  if (!expression || !ts.isConditionalExpression(expression)) {
    fail("pi getDefaultProjectTrust no longer returns a conditional fallback");
  }
  const fallback = literalValue(expression.whenFalse, ts, checker);
  if (typeof fallback !== "string")
    fail("pi getDefaultProjectTrust fallback is no longer a string literal");
  return fallback;
}

// The interfaces a declaration's properties are typed with, transitively and
// by the checker's own resolution, keyed by the name walkType looks them up by.
// Resolving by name instead picked whichever same-named interface loaded first
// (pi 0.85.1 declares CompactionSettings twice, with different optionality).
function referencedInterfaces(root, checker, ts) {
  const found = new Map();
  const queue = [root];
  while (queue.length) {
    const declaration = queue.pop();
    for (const member of declaration.members) {
      if (!ts.isPropertySignature(member) || !member.type) continue;
      const type = checker.getNonNullableType(
        checker.getTypeFromTypeNode(member.type),
      );
      if (checker.isArrayType(type)) continue;
      const referenced = (type.aliasSymbol ? [] : [type.symbol])
        .flatMap((symbol) => symbol?.declarations ?? [])
        .filter(ts.isInterfaceDeclaration);
      for (const target of referenced) {
        const name = target.name.text;
        const previous = found.get(name);
        if (previous && previous !== target)
          fail(
            `two different interfaces named ${name} type ${root.name.text}'s settings (${previous.getSourceFile().fileName}, ${target.getSourceFile().fileName})`,
          );
        if (!previous) {
          found.set(name, target);
          queue.push(target);
        }
      }
    }
  }
  return found;
}

// Which scope pi reads each Settings key from. SettingsManager deep-merges the
// project file over the global one into `this.settings`; a key read through
// that merge honors a project harness settings.json. A key read only through
// `this.globalSettings` or `getGlobalSettings()` (project trust, the HTTP
// proxy) ignores it. A key the extractor sees no read of stops the extraction
// rather than defaulting either way.
function piSettingsScopes(names, piSources, ts) {
  const merged = new Set();
  const global = new Set();
  const isThisMember = (node, member) =>
    ts.isPropertyAccessExpression(node) &&
    node.expression.kind === ts.SyntaxKind.ThisKeyword &&
    node.name.text === member;
  for (const sourceFile of piSources) {
    function visit(node) {
      if (ts.isPropertyAccessExpression(node) && !isWriteOnly(node, ts)) {
        const object = unwrapExpression(node.expression, ts);
        const name = node.name.text;
        if (isThisMember(object, "settings")) merged.add(name);
        if (
          isThisMember(object, "globalSettings") ||
          (ts.isCallExpression(object) &&
            ts.isPropertyAccessExpression(object.expression) &&
            object.expression.name.text === "getGlobalSettings")
        )
          global.add(name);
      }
      ts.forEachChild(node, visit);
    }
    visit(sourceFile);
  }
  const unread = names.filter((name) => !merged.has(name) && !global.has(name));
  if (unread.length)
    fail(
      `pi reads Settings keys ${JSON.stringify(unread.sort())} in no way the extractor recognizes, so their scope is unknown`,
    );
  return new Map(names.map((name) => [name, merged.has(name)]));
}

function extractHarness(
  declarations,
  configSource,
  settingsManagerSource,
  settingsDeclarationSource,
  piSources,
  configTsHarnessReads,
  checker,
  ts,
) {
  // pi's Settings, as its own settings-manager declares it.
  const settings = checker
    .getSymbolAtLocation(settingsDeclarationSource)
    ?.exports?.get("Settings")
    ?.declarations?.find(ts.isInterfaceDeclaration);
  if (!settings)
    fail(
      `${settingsDeclarationSource.fileName} no longer exports a Settings interface`,
    );
  const baseKeys = membersOfDeclaration(settings, checker, ts);
  baseKeys.modelThinkingLevels = membersOfDeclaration(
    settings,
    checker,
    ts,
    true,
  ).modelThinkingLevels;
  const defaultProjectTrust = extractDefaultProjectTrust(
    settingsManagerSource,
    checker,
    ts,
  );
  if (!baseKeys.defaultProjectTrust?.enum?.includes(defaultProjectTrust))
    fail("pi default project trust is outside DefaultProjectTrust");
  baseKeys.defaultProjectTrust.default = defaultProjectTrust;
  const definitions = {};
  const referenced = referencedInterfaces(settings, checker, ts);
  for (const name of [...referenced.keys()].sort())
    definitions[name] = membersOfDeclaration(referenced.get(name), checker, ts);

  const ferment = requireDeclaration(
    declarations,
    "FermentV2Settings",
    ts.isInterfaceDeclaration,
  );
  const roles = requireDeclaration(
    declarations,
    "ModelRoles",
    ts.isInterfaceDeclaration,
  );
  const resourceSettings = requireDeclaration(
    declarations,
    "ResourceSettings",
    ts.isInterfaceDeclaration,
  );
  const terminalWarnings = requireDeclaration(
    declarations,
    "TerminalWarningSettings",
    ts.isInterfaceDeclaration,
  );
  const statusLine = requireDeclaration(
    declarations,
    "StatusLineConfig",
    ts.isTypeAliasDeclaration,
  );
  const metadataSchema = requireDeclaration(
    declarations,
    "ModelCustomMetadataSchema",
    ts.isVariableDeclaration,
  );
  const resourceMembers = membersOfDeclaration(
    resourceSettings,
    checker,
    ts,
    true,
  );
  const terminalMembers = membersOfDeclaration(
    terminalWarnings,
    checker,
    ts,
    true,
  );
  const additions = {
    // config.ts readAutoDefaultApplied: a one-shot marker, true once Kimchi
    // installed Auto as the saved default.
    autoDefaultApplied: descriptorForType(
      checker.getBooleanType(),
      ferment,
      checker,
      ts,
    ),
    fermentV2: {
      type: "object",
      typeExpression: "FermentV2Settings",
      properties: membersOfDeclaration(ferment, checker, ts, true),
    },
    hidePhaseChanges: descriptorForType(
      checker.getBooleanType(),
      ferment,
      checker,
      ts,
    ),
    lastTerminalWarnings: terminalMembers.lastTerminalWarnings,
    modelMetadata: {
      additionalProperties: typeBoxDescriptor(
        metadataSchema.initializer,
        checker,
        ts,
      ),
      type: "object",
      typeExpression: "Record<string, ModelCustomMetadata>",
    },
    modelRoles: {
      type: "object",
      typeExpression: "ModelRoles",
      properties: membersOfDeclaration(roles, checker, ts, true),
    },
    multiModel: descriptorForType(
      checker.getBooleanType(),
      ferment,
      checker,
      ts,
    ),
    resources: resourceMembers.resources,
    shellProfileApiKeyMigrationDismissed: descriptorForType(
      checker.getBooleanType(),
      ferment,
      checker,
      ts,
    ),
    statusLine: descriptorForNode(statusLine.type, checker, ts, true),
  };
  // Kimchi's harness settings readers accept an absent top-level key and
  // either return undefined or apply a fallback; none is required in the file.
  for (const descriptor of Object.values(additions)) descriptor.optional = true;
  // These declarations describe the normalized values after parser defaults.
  // Their persisted input objects accept every child independently.
  for (const name of ["fermentV2", "modelRoles"]) {
    for (const property of Object.values(additions[name].properties))
      property.optional = true;
  }
  additions.statusLine.properties.pinned.optional = true;
  if (additions.modelRoles.properties.orchestrator?.type !== "string") {
    fail(
      "harness/settings.json Kimchi additions validation shape changed: modelRoles.orchestrator is no longer a string",
    );
  }
  let autoDefaultMarker = false;
  function findAutoDefaultMarker(node) {
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsEqualsEqualsToken &&
      ts.isPropertyAccessExpression(node.left) &&
      node.left.name.text === "autoDefaultApplied" &&
      node.right.kind === ts.SyntaxKind.TrueKeyword
    ) {
      autoDefaultMarker = true;
    }
    ts.forEachChild(node, findAutoDefaultMarker);
  }
  findAutoDefaultMarker(
    declarationInScope(
      configSource,
      "readAutoDefaultApplied",
      ts.isFunctionDeclaration,
      checker,
      ts,
    ),
  );
  if (!autoDefaultMarker) {
    fail(
      "harness/settings.json Kimchi additions validation shape changed: readAutoDefaultApplied no longer reads autoDefaultApplied === true",
    );
  }
  additions.statusLine.properties.command = descriptorForType(
    checker.getStringType(),
    statusLine,
    checker,
    ts,
  );
  additions.statusLine.properties.command.optional = true;
  const overlap = Object.keys(additions).filter((name) => baseKeys[name]);
  if (overlap.length)
    fail(
      `Kimchi harness additions now overlap pi Settings: ${JSON.stringify(overlap.sort())}`,
    );
  const keys = {};
  const piProject = piSettingsScopes(Object.keys(baseKeys), piSources, ts);
  for (const [name, descriptor] of Object.entries(baseKeys))
    keys[name] = { source: "pi", ...descriptor, project: piProject.get(name) };
  for (const [name, descriptor] of Object.entries(baseKeys)) {
    if (descriptor.type === "named")
      fail(`pi harness setting ${name} has an unresolved named type`);
  }
  if (!baseKeys.modelThinkingLevels.additionalProperties)
    fail("pi modelThinkingLevels value type was not resolved");
  // Kimchi reads its additions itself, from the user harness file only
  // (config/settings.ts, config.ts readAutoDefaultApplied, the model-metadata
  // and terminal-warning readers all resolve ~/.config/kimchi/harness), never
  // through pi's project-merging SettingsManager, which does not type them.
  for (const [name, descriptor] of Object.entries(additions))
    keys[name] = { source: "kimchi", ...descriptor, project: false };
  const unknownHarnessReads = [...configTsHarnessReads]
    .filter((name) => !keys[name])
    .sort();
  if (unknownHarnessReads.length) {
    fail(
      `config.ts reads harness/settings.json keys that are neither pi Settings nor Kimchi additions: ${JSON.stringify(unknownHarnessReads)}`,
    );
  }
  return {
    definitions: sortObject(definitions),
    keys: sortObject(keys),
  };
}

// pi names two of its variables after the host application:
//   APP_NAME = piConfigName || "pi"   (piConfigName = pkg.piConfig?.name)
//   ENV_SESSION_DIR = `${APP_NAME.toUpperCase()}_CODING_AGENT_SESSION_DIR`
// pkg is the package.json under PI_PACKAGE_DIR, which Kimchi's entry.ts points
// at its own share/kimchi before pi loads, so the host is Kimchi's piConfig.name
// (the context's appName). Any other APP_NAME shape stops the extraction.
function hostAppName(declaration, context) {
  const { appName, checker, ts } = context;
  const initializer = unwrapExpression(declaration.initializer, ts);
  const brandingSource = (identifier) => {
    const initializer = checker
      .getSymbolAtLocation(identifier)
      ?.declarations?.find(ts.isVariableDeclaration)?.initializer;
    return (
      initializer &&
      ts.isPropertyAccessExpression(initializer) &&
      initializer.name.text === "name" &&
      ts.isPropertyAccessExpression(initializer.expression) &&
      initializer.expression.name.text === "piConfig"
    );
  };
  if (
    !ts.isBinaryExpression(initializer) ||
    initializer.operatorToken.kind !== ts.SyntaxKind.BarBarToken ||
    !ts.isIdentifier(initializer.left) ||
    !brandingSource(initializer.left) ||
    !ts.isStringLiteralLike(initializer.right)
  ) {
    fail(
      `pi APP_NAME in ${declaration.getSourceFile().fileName} is no longer piConfig.name || "<default>": ${initializer.getText()}`,
    );
  }
  return appName || initializer.right.text;
}

function stringConstant(expression, context, seen = new Set()) {
  const { checker, declarations, ts } = context;
  if (ts.isStringLiteralLike(expression)) return expression.text;
  if (ts.isTemplateExpression(expression)) {
    let value = expression.head.text;
    for (const span of expression.templateSpans) {
      const part = stringConstant(span.expression, context, seen);
      if (part === undefined) return undefined;
      value += part + span.literal.text;
    }
    return value;
  }
  if (
    ts.isCallExpression(expression) &&
    ts.isPropertyAccessExpression(expression.expression) &&
    expression.expression.name.text === "toUpperCase" &&
    expression.arguments.length === 0
  ) {
    return stringConstant(
      expression.expression.expression,
      context,
      seen,
    )?.toUpperCase();
  }
  if (!ts.isIdentifier(expression)) return undefined;
  const fromDeclaration = (declaration) =>
    declaration.name.getText() === "APP_NAME"
      ? hostAppName(declaration, context)
      : stringConstant(declaration.initializer, context, seen);
  let symbol = checker.getSymbolAtLocation(expression);
  if (symbol) {
    if (symbol.flags & ts.SymbolFlags.Alias)
      symbol = checker.getAliasedSymbol(symbol);
    if (seen.has(symbol)) return undefined;
    seen.add(symbol);
    for (const declaration of symbol.declarations ?? []) {
      if (ts.isVariableDeclaration(declaration) && declaration.initializer) {
        const value = fromDeclaration(declaration);
        if (value !== undefined) return value;
      }
    }
    // A parameter or a computed local is not a constant.
    const constantShaped = (symbol.declarations ?? []).every(
      (declaration) =>
        ts.isBindingElement(declaration) ||
        (ts.isVariableDeclaration(declaration) && !declaration.initializer),
    );
    if (!constantShaped) return undefined;
  }
  // No usable initializer: a patched source parsed outside the program, an
  // import that resolves to pi's .d.ts rather than its .js, or a destructured
  // re-import in a bundled chunk. Fall back to the constants of that name
  // everywhere, but only when they all agree.
  const values = new Set(
    (declarations.get(expression.text) ?? [])
      .filter(
        (declaration) =>
          ts.isVariableDeclaration(declaration) && declaration.initializer,
      )
      .map(fromDeclaration)
      .filter((value) => value !== undefined),
  );
  if (values.size > 1)
    fail(
      `constant ${expression.text} in ${expression.getSourceFile().fileName} is ambiguous: same-named constants evaluate to ${JSON.stringify([...values].sort())}`,
    );
  return [...values][0];
}

function isWriteOnly(node, ts) {
  const parent = node.parent;
  if (ts.isDeleteExpression(parent)) return true;
  if (
    ts.isBinaryExpression(parent) &&
    parent.left === node &&
    parent.operatorToken.kind === ts.SyntaxKind.EqualsToken
  )
    return true;
  return false;
}

function environmentReads(sourceFile, context) {
  const { checker, ts } = context;
  const found = new Set();
  const environmentSymbols = new Set();
  function isEnvironmentExpression(node) {
    if (
      ts.isPropertyAccessExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "process" &&
      node.name.text === "env"
    ) {
      return true;
    }
    if (ts.isIdentifier(node)) {
      const symbol = checker.getSymbolAtLocation(node);
      return symbol ? environmentSymbols.has(symbol) : false;
    }
    return false;
  }
  // An alias holds the environment object itself (`env = process.env`,
  // `env = options.env ?? process.env`), not a value read from it and not a
  // derived child environment (`{ ...process.env, X: ... }`): member reads on
  // those are not reads of this process's environment.
  function isEnvironmentValue(node) {
    node = unwrapExpression(node, ts);
    if (isEnvironmentExpression(node)) return true;
    return (
      ts.isBinaryExpression(node) &&
      [ts.SyntaxKind.QuestionQuestionToken, ts.SyntaxKind.BarBarToken].includes(
        node.operatorToken.kind,
      ) &&
      (isEnvironmentValue(node.left) || isEnvironmentValue(node.right))
    );
  }
  function identifyAliases(node) {
    if (
      (ts.isVariableDeclaration(node) || ts.isParameter(node)) &&
      ts.isIdentifier(node.name) &&
      node.initializer &&
      isEnvironmentValue(node.initializer)
    ) {
      const symbol = checker.getSymbolAtLocation(node.name);
      if (symbol) environmentSymbols.add(symbol);
    }
    ts.forEachChild(node, identifyAliases);
  }
  identifyAliases(sourceFile);
  function visit(node) {
    let name;
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "getProviderEnvValue" &&
      node.arguments[0]
    ) {
      name = stringConstant(node.arguments[0], context);
    }
    if (
      ts.isPropertyAccessExpression(node) &&
      isEnvironmentExpression(node.expression)
    ) {
      name = node.name.text;
    } else if (
      ts.isElementAccessExpression(node) &&
      isEnvironmentExpression(node.expression)
    ) {
      name = stringConstant(node.argumentExpression, context);
    }
    if (name && !isWriteOnly(node, ts)) found.add(name);
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return found;
}

// The program source files `sourceFile` imports: static imports and re-exports
// that execute (never `import type`), plus `import("…")` when `dynamic`.
function importedSourceFiles(sourceFile, program, ts, { dynamic, types }) {
  const specifiers = [];
  function visit(node) {
    if (
      (ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier &&
      ts.isStringLiteralLike(node.moduleSpecifier) &&
      (types ||
        !(ts.isImportDeclaration(node)
          ? node.importClause?.isTypeOnly
          : node.isTypeOnly))
    ) {
      specifiers.push(node.moduleSpecifier.text);
    }
    if (
      dynamic &&
      ts.isCallExpression(node) &&
      node.expression.kind === ts.SyntaxKind.ImportKeyword &&
      node.arguments[0] &&
      ts.isStringLiteralLike(node.arguments[0])
    ) {
      specifiers.push(node.arguments[0].text);
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return specifiers
    .map(
      (specifier) =>
        ts.resolveModuleName(
          specifier,
          sourceFile.fileName,
          program.getCompilerOptions(),
          ts.sys,
        ).resolvedModule?.resolvedFileName,
    )
    .map((fileName) => fileName && program.getSourceFile(fileName))
    .filter(Boolean);
}

// Every program source file reachable from `roots` through imports.
function moduleClosure(roots, program, ts, options) {
  const reached = new Set(roots);
  const queue = [...roots];
  while (queue.length) {
    for (const imported of importedSourceFiles(
      queue.pop(),
      program,
      ts,
      options,
    )) {
      if (!reached.has(imported)) {
        reached.add(imported);
        queue.push(imported);
      }
    }
  }
  return reached;
}

// Named reads of `parameter` inside `declaration`'s body. Any other use of the
// parameter (passing it on, spreading it) hides which names it reads.
function parameterEnvironmentReads(declaration, parameter, context) {
  const { checker, ts } = context;
  const symbol = checker.getSymbolAtLocation(parameter.name);
  const found = new Set();
  function visit(node) {
    if (
      ts.isIdentifier(node) &&
      node !== parameter.name &&
      checker.getSymbolAtLocation(node) === symbol
    ) {
      const parent = node.parent;
      let name;
      if (ts.isPropertyAccessExpression(parent) && parent.expression === node)
        name = parent.name.text;
      else if (
        ts.isElementAccessExpression(parent) &&
        parent.expression === node
      )
        name = stringConstant(parent.argumentExpression, context);
      if (name === undefined)
        fail(
          `${declaration.getSourceFile().fileName} uses the environment parameter ${parameter.name.getText()} as a whole (${parent.getText()}), so the names it reads cannot be listed`,
        );
      if (!isWriteOnly(parent, ts)) found.add(name);
    }
    ts.forEachChild(node, visit);
  }
  if (declaration.body) visit(declaration.body);
  return found;
}

// Environment names one top-level entry.ts statement reads: named member
// reads, plus what a callee reads from the environment object passed to it.
function statementEnvironmentReads(statement, context) {
  const { checker, ts } = context;
  const found = environmentReads(statement, context);
  function visit(node) {
    const isEnvironmentObject =
      ts.isPropertyAccessExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "process" &&
      node.name.text === "env";
    const parent = node.parent;
    if (
      isEnvironmentObject &&
      !(
        (ts.isPropertyAccessExpression(parent) ||
          ts.isElementAccessExpression(parent)) &&
        parent.expression === node
      )
    ) {
      let callee;
      if (ts.isCallExpression(parent) && parent.arguments.includes(node)) {
        let symbol = checker.getSymbolAtLocation(parent.expression);
        if (symbol && symbol.flags & ts.SymbolFlags.Alias)
          symbol = checker.getAliasedSymbol(symbol);
        callee = symbol?.declarations?.find(
          (declaration) =>
            ts.isFunctionDeclaration(declaration) && declaration.body,
        );
      }
      const parameter =
        callee?.parameters[parent.arguments.indexOf(node)] ?? undefined;
      if (!parameter || !ts.isIdentifier(parameter.name))
        fail(
          `src/entry.ts hands process.env to ${parent.getText()} before its last assignment, and the names that reads cannot be resolved`,
        );
      for (const name of parameterEnvironmentReads(callee, parameter, context))
        found.add(name);
    }
    ts.forEachChild(node, visit);
  }
  visit(statement);
  return found;
}

// Names a top-level statement assigns on every path through it.
function definiteEnvironmentWrites(statement, context) {
  const { ts } = context;
  if (
    ts.isExpressionStatement(statement) &&
    ts.isBinaryExpression(statement.expression) &&
    statement.expression.operatorToken.kind === ts.SyntaxKind.EqualsToken
  ) {
    const target = statement.expression.left;
    const isEnvironment = (node) =>
      ts.isPropertyAccessExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "process" &&
      node.name.text === "env";
    if (
      ts.isPropertyAccessExpression(target) &&
      isEnvironment(target.expression)
    )
      return new Set([target.name.text]);
    if (
      ts.isElementAccessExpression(target) &&
      isEnvironment(target.expression)
    ) {
      const name = stringConstant(target.argumentExpression, context);
      if (name === undefined)
        fail(
          `src/entry.ts assigns a computed environment name: ${statement.getText()}`,
        );
      return new Set([name]);
    }
    return new Set();
  }
  if (ts.isIfStatement(statement) && statement.elseStatement) {
    const then = definiteEnvironmentWrites(statement.thenStatement, context);
    const otherwise = definiteEnvironmentWrites(
      statement.elseStatement,
      context,
    );
    return new Set([...then].filter((name) => otherwise.has(name)));
  }
  if (ts.isBlock(statement)) {
    return new Set(
      statement.statements.flatMap((child) => [
        ...definiteEnvironmentWrites(child, context),
      ]),
    );
  }
  return new Set();
}

// Variables Kimchi's entry point assigns on every launch before anything
// reads them, so a value the caller sets is never read. entry.ts exists to set
// pi's environment before pi loads; its top-level statements run in order
// once the modules it statically imports have been evaluated. A variable
// counts as overwritten when a top-level statement assigns it on every path
// and no earlier statement (or a callee handed process.env) reads it. Anything
// that would make that order unknowable fails the extraction: a read of the
// same name anywhere in the statically imported modules, or an assignment
// after entry.ts first awaits or imports dynamically.
function launchOverwrites(entrySource, program, context) {
  const { ts } = context;
  const imported = moduleClosure([entrySource], program, ts, {
    dynamic: false,
    types: false,
  });
  imported.delete(entrySource);
  const importedReads = new Map();
  for (const sourceFile of imported) {
    for (const name of environmentReads(sourceFile, context)) {
      if (!importedReads.has(name))
        importedReads.set(name, sourceFile.fileName);
    }
  }
  const read = new Set();
  const overwritten = new Set();
  let suspended;
  for (const statement of entrySource.statements) {
    if (ts.isImportDeclaration(statement)) continue;
    for (const name of statementEnvironmentReads(statement, context))
      read.add(name);
    for (const name of definiteEnvironmentWrites(statement, context)) {
      if (read.has(name) || overwritten.has(name)) continue;
      if (suspended)
        fail(
          `src/entry.ts assigns ${name} after it suspends at ${suspended}, when dynamically imported code may already have read it`,
        );
      if (importedReads.has(name))
        fail(
          `src/entry.ts assigns ${name} before reading it, but ${importedReads.get(name)}, which it imports, reads it too; whether that read runs first is not decidable here`,
        );
      overwritten.add(name);
    }
    // Past an `await` or `import()`, modules loaded dynamically (by entry.ts
    // or by anything it called) may have run.
    function findSuspension(node) {
      if (
        !suspended &&
        (ts.isAwaitExpression(node) ||
          (ts.isCallExpression(node) &&
            node.expression.kind === ts.SyntaxKind.ImportKeyword))
      ) {
        const { line } = entrySource.getLineAndCharacterOfPosition(
          node.getStart(),
        );
        suspended = `src/entry.ts:${line + 1}`;
      }
      ts.forEachChild(node, findSuspension);
    }
    findSuspension(statement);
  }
  return overwritten;
}

function patchAddedSource(text) {
  return text
    .split("\n")
    .filter((line) => line.startsWith("+") && !line.startsWith("+++"))
    .map((line) => line.slice(1))
    .join("\n");
}

async function extractEnvironment(
  kimchiSourceFiles,
  piSourceFiles,
  patchPaths,
  annotations,
  ignored,
  overwritten,
  context,
) {
  const { ts } = context;
  const reads = { kimchi: new Set(), pi: new Set() };
  for (const sourceFile of kimchiSourceFiles) {
    for (const name of environmentReads(sourceFile, context))
      reads.kimchi.add(name);
  }
  for (const sourceFile of piSourceFiles) {
    for (const name of environmentReads(sourceFile, context))
      reads.pi.add(name);
  }
  for (const path of patchPaths) {
    const sourceFile = ts.createSourceFile(
      path,
      patchAddedSource(await readFile(path, "utf8")),
      ts.ScriptTarget.Latest,
      true,
    );
    for (const name of environmentReads(sourceFile, context))
      reads.pi.add(name);
  }
  // The census runs over every resolved read, not a KIMCHI_/PI_ subset: a
  // name is either published (annotations) or ignored with a reason, and
  // both lists must match what the sources actually read.
  const discovered = new Set([...reads.kimchi, ...reads.pi]);
  const expected = new Set(Object.keys(annotations));
  // Ignored names are grouped under one shared reason, but each is an exact
  // name: a prefix or pattern would reopen the blind spot the census closes.
  const ignoredList = Object.entries(ignored).flatMap(([group, entry]) => {
    if (!entry.reason || !Array.isArray(entry.names))
      fail(`environmentIgnored.${group} needs a reason and a names list`);
    return entry.names;
  });
  const ignoredNames = new Set(ignoredList);
  if (ignoredNames.size !== ignoredList.length)
    fail("environmentIgnored lists a name in more than one group");
  const unknown = [...discovered]
    .filter((name) => !expected.has(name) && !ignoredNames.has(name))
    .sort();
  const missing = [...expected].filter((name) => !discovered.has(name)).sort();
  const staleIgnored = [...ignoredNames]
    .filter((name) => !discovered.has(name))
    .sort();
  const both = [...expected].filter((name) => ignoredNames.has(name)).sort();
  if (unknown.length || missing.length || staleIgnored.length || both.length)
    fail(
      `environment census changed; new=${JSON.stringify(unknown)}, missing=${JSON.stringify(missing)}, staleIgnored=${JSON.stringify(staleIgnored)}, annotatedAndIgnored=${JSON.stringify(both)}`,
    );
  const variables = {};
  for (const [name, annotation] of Object.entries(annotations)) {
    const handKeys = Object.keys(annotation).filter(
      (key) => key !== "controls",
    );
    if (!annotation.controls || handKeys.length)
      fail(
        `environment.${name} must carry only a 'controls' description; ${JSON.stringify(handKeys)} are derived from the sources`,
      );
    const fixed = overwritten.has(name);
    variables[name] = {
      consumerOverridable: !fixed,
      readBy: Object.entries(reads)
        .filter(([, names]) => names.has(name))
        .map(([runtime]) => runtime)
        .sort(),
      ...annotation,
      ...(fixed
        ? {
            reason:
              "src/entry.ts assigns it on every launch before anything reads it",
          }
        : {}),
    };
  }
  return { variables: sortObject(variables) };
}

async function main() {
  const args = parseArguments(process.argv.slice(2));
  const tsModule = await import(pathToFileURL(resolve(args.typescript)).href);
  const ts = tsModule.default ?? tsModule;
  const annotations = JSON.parse(
    await readFile(resolve(args.annotations), "utf8"),
  );
  const kimchiRoot = resolve(args["kimchi-source"]);
  const piRoot = resolve(args["pi-package"]);
  const piTypePackages = {
    "@earendil-works/pi-agent-core": resolve(args["pi-agent-core-package"]),
    "@earendil-works/pi-ai": resolve(args["pi-ai-package"]),
    "@earendil-works/pi-tui": resolve(args["pi-tui-package"]),
  };
  const kimchiPaths = await filesUnder(join(kimchiRoot, "src"), {
    excludedDirectories: new Set(["__mocks__", "node_modules"]),
    file: (path) => path.endsWith(".ts") && !path.endsWith(".test.ts"),
  });
  const piPaths = await filesUnder(join(piRoot, "dist"), {
    excludedDirectories: new Set(),
    file: (path) =>
      (path.endsWith(".js") || path.endsWith(".d.ts")) &&
      !path.endsWith(".test.js"),
  });
  const patchPaths = await filesUnder(join(kimchiRoot, "patches"), {
    excludedDirectories: new Set(),
    file: (path) => path.endsWith(".patch"),
  });
  const compilerOptions = {
    allowJs: true,
    allowSyntheticDefaultImports: true,
    baseUrl: "/",
    checkJs: false,
    module: ts.ModuleKind.NodeNext,
    moduleResolution: ts.ModuleResolutionKind.NodeNext,
    noEmit: true,
    paths: Object.fromEntries(
      Object.entries(piTypePackages).map(([name, root]) => [
        name,
        [join(root, "dist/index.d.ts")],
      ]),
    ),
    skipLibCheck: true,
    target: ts.ScriptTarget.ESNext,
  };
  const rootNames = [...kimchiPaths, ...piPaths];
  const program = ts.createProgram({ rootNames, options: compilerOptions });
  const checker = program.getTypeChecker();
  // A second checker over the same parsed files, for analyses that type-check
  // arbitrary Kimchi code. The checker numbers types as it first meets them and
  // prints unions in that order, so running those queries through `checker`
  // would reorder the extracted enums. The syntax trees are shared, so nodes
  // and bound symbols compare across the two.
  const analysisHost = ts.createCompilerHost(compilerOptions);
  const parse = analysisHost.getSourceFile;
  analysisHost.getSourceFile = (fileName, ...rest) =>
    program.getSourceFile(fileName) ??
    parse.call(analysisHost, fileName, ...rest);
  const analysisProgram = ts.createProgram({
    host: analysisHost,
    options: compilerOptions,
    rootNames,
  });
  for (const fileName of rootNames) {
    if (
      analysisProgram.getSourceFile(fileName) !==
      program.getSourceFile(fileName)
    )
      fail(`the analysis program re-parsed ${fileName}`);
  }
  const analysisChecker = analysisProgram.getTypeChecker();
  const sourceFiles = program
    .getSourceFiles()
    .filter(
      (sourceFile) =>
        kimchiPaths.includes(sourceFile.fileName) ||
        piPaths.includes(sourceFile.fileName),
    );
  const liveKimchi = moduleClosure(
    [
      program.getSourceFile(join(kimchiRoot, "src/entry.ts")) ??
        fail("program did not load src/entry.ts"),
    ],
    program,
    ts,
    { dynamic: true, types: true },
  );
  const declarations = declarationIndex(
    sourceFiles.filter(
      (sourceFile) =>
        liveKimchi.has(sourceFile) || piPaths.includes(sourceFile.fileName),
    ),
    ts,
  );
  const byPath = new Map(
    sourceFiles.map((sourceFile) => [resolve(sourceFile.fileName), sourceFile]),
  );
  const requireSource = (path) =>
    byPath.get(resolve(path)) ?? fail(`program did not load ${path}`);
  const piPackage = JSON.parse(
    await readFile(join(piRoot, "package.json"), "utf8"),
  );
  const kimchiPackage = JSON.parse(
    await readFile(join(kimchiRoot, "package.json"), "utf8"),
  );
  const piVersion = piPackage.version;
  for (const [name, root] of Object.entries(piTypePackages)) {
    const dependencyPackage = JSON.parse(
      await readFile(join(root, "package.json"), "utf8"),
    );
    const requested = piPackage.dependencies?.[name];
    const expectedVersion = requested?.startsWith("^")
      ? requested.slice(1)
      : requested;
    if (!expectedVersion || dependencyPackage.version !== expectedVersion) {
      fail(
        `pi requests ${name} ${JSON.stringify(requested)}, but the supplied declaration package is ${JSON.stringify(dependencyPackage.version)}`,
      );
    }
  }
  const expectedKimchiSourceUrl = new URL(
    `https://github.com/getkimchi/kimchi/archive/refs/tags/v${args["kimchi-version"]}.tar.gz`,
  );
  let kimchiSourceUrl;
  try {
    kimchiSourceUrl = new URL(args["kimchi-source-url"]);
  } catch {
    fail("--kimchi-source-url is not a valid URL");
  }
  if (kimchiSourceUrl.href !== expectedKimchiSourceUrl.href) {
    fail(
      `Kimchi source URL ${JSON.stringify(kimchiSourceUrl.href)} does not match --kimchi-version ${JSON.stringify(args["kimchi-version"])}`,
    );
  }
  if (
    kimchiPackage.dependencies?.["@earendil-works/pi-coding-agent"] !==
    piVersion
  ) {
    fail(
      `Kimchi pins pi ${JSON.stringify(kimchiPackage.dependencies?.["@earendil-works/pi-coding-agent"])}, but the supplied pi source is ${JSON.stringify(piVersion)}`,
    );
  }

  const configSource = requireSource(join(kimchiRoot, "src/config.ts"));
  const configTsReads = discoverConfigKeys(configSource, checker, ts);
  const environmentContext = {
    appName: kimchiPackage.piConfig?.name,
    checker,
    declarations,
    ts,
  };
  const result = {
    config: extractConfig(
      configSource,
      configTsReads.config,
      declarations,
      annotations.config,
      sourceFiles.filter((sourceFile) =>
        kimchiPaths.includes(sourceFile.fileName),
      ),
      checker,
      analysisChecker,
      ts,
    ),
    environment: await extractEnvironment(
      sourceFiles.filter((sourceFile) =>
        sourceFile.fileName.startsWith(join(kimchiRoot, "src")),
      ),
      sourceFiles.filter(
        (sourceFile) =>
          sourceFile.fileName.startsWith(join(piRoot, "dist")) &&
          sourceFile.fileName.endsWith(".js"),
      ),
      patchPaths,
      annotations.environment,
      annotations.environmentIgnored ??
        fail("annotations lack environmentIgnored"),
      launchOverwrites(
        requireSource(join(kimchiRoot, "src/entry.ts")),
        program,
        environmentContext,
      ),
      environmentContext,
    ),
    harness: extractHarness(
      declarations,
      configSource,
      requireSource(join(piRoot, "dist/core/settings-manager.js")),
      requireSource(join(piRoot, "dist/core/settings-manager.d.ts")),
      sourceFiles.filter(
        (sourceFile) =>
          piPaths.includes(sourceFile.fileName) &&
          sourceFile.fileName.endsWith(".js"),
      ),
      configTsReads.harness,
      checker,
      ts,
    ),
    provenance: {
      extractorSchema: EXTRACTOR_SCHEMA,
      kimchiVersion: args["kimchi-version"],
      piVersion,
    },
  };
  const encoded = `${JSON.stringify(result, null, 2)}\n`;
  if (args.out === "-") process.stdout.write(encoded);
  else await writeFile(args.out, encoded);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exitCode = 1;
});
