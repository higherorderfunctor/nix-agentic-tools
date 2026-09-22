#!/usr/bin/env node

/** Extract Kimchi's settings, CLI, and environment surfaces with TypeScript. */

import { readdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const EXTRACTOR_SCHEMA = 2;

// pi derives this name from mutable host branding at module evaluation time, so
// importing config.js cannot answer for the Kimchi host without running its
// entire bootstrap. The AST still proves ENV_SESSION_DIR is used as an actual
// process.env key; this map records pi's published/default spelling.
const DYNAMIC_ENVIRONMENT_NAMES = {
  ENV_SESSION_DIR: "PI_CODING_AGENT_SESSION_DIR",
};

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
    "kimchi-version",
    "out",
    "pi-package",
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

function literalValue(node, ts, declarations, seen = new Set()) {
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
      literalValue(element, ts, declarations, seen),
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
        ? literalValue(property.name, ts, declarations, seen)
        : literalValue(property.initializer, ts, declarations, seen);
    }
    return object;
  }
  if (ts.isIdentifier(node)) {
    if (seen.has(node.text))
      fail(`constant cycle while evaluating ${node.text}`);
    const declaration = declarations.get(node.text);
    if (!declaration?.initializer) fail(`cannot resolve constant ${node.text}`);
    return literalValue(
      declaration.initializer,
      ts,
      declarations,
      new Set([...seen, node.text]),
    );
  }
  fail(`unsupported constant expression ${node.getText()}`);
}

function declarationIndex(sourceFiles, ts) {
  const declarations = new Map();
  for (const sourceFile of sourceFiles) {
    function visit(node) {
      if (
        (ts.isInterfaceDeclaration(node) ||
          ts.isTypeAliasDeclaration(node) ||
          ts.isFunctionDeclaration(node)) &&
        node.name
      ) {
        const previous = declarations.get(node.name.text);
        if (!previous) declarations.set(node.name.text, node);
      }
      if (ts.isVariableDeclaration(node) && ts.isIdentifier(node.name)) {
        const previous = declarations.get(node.name.text);
        if (!previous || (!previous.initializer && node.initializer))
          declarations.set(node.name.text, node);
      }
      ts.forEachChild(node, visit);
    }
    visit(sourceFile);
  }
  return declarations;
}

function requireDeclaration(declarations, name, predicate = () => true) {
  const declaration = declarations.get(name);
  if (!declaration || !predicate(declaration))
    fail(`TypeScript declaration ${name} was not found in the expected form`);
  return declaration;
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

function discoverConfigKeys(sourceFile, checker, ts) {
  const parsedSymbols = new Set();
  const updateParameters = new Set();
  function identify(node) {
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer &&
      ts.isCallExpression(node.initializer)
    ) {
      const called = node.initializer.expression;
      if (
        (ts.isPropertyAccessExpression(called) &&
          called.expression.getText() === "JSON" &&
          called.name.text === "parse") ||
        (ts.isIdentifier(called) && called.text === "readConfigObject")
      ) {
        const symbol = checker.getSymbolAtLocation(node.name);
        if (symbol) parsedSymbols.add(symbol);
      }
    }
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "updateConfigFile"
    ) {
      const callback = node.arguments.find(
        (argument) =>
          ts.isArrowFunction(argument) || ts.isFunctionExpression(argument),
      );
      const parameter = callback?.parameters[0]?.name;
      if (parameter && ts.isIdentifier(parameter)) {
        const symbol = checker.getSymbolAtLocation(parameter);
        if (symbol) updateParameters.add(symbol);
      }
    }
    ts.forEachChild(node, identify);
  }
  identify(sourceFile);
  const found = new Set();
  function visit(node) {
    if (
      ts.isPropertyAccessExpression(node) &&
      ts.isIdentifier(node.expression)
    ) {
      const symbol = checker.getSymbolAtLocation(node.expression);
      if (symbol && (parsedSymbols.has(symbol) || updateParameters.has(symbol)))
        found.add(node.name.text);
    }
    if (
      ts.isElementAccessExpression(node) &&
      ts.isIdentifier(node.expression) &&
      ts.isStringLiteralLike(node.argumentExpression)
    ) {
      const symbol = checker.getSymbolAtLocation(node.expression);
      if (symbol && (parsedSymbols.has(symbol) || updateParameters.has(symbol)))
        found.add(node.argumentExpression.text);
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return found;
}

function discoverProjectConfigKeys(declarations, annotations, ts) {
  const loadConfig = requireDeclaration(
    declarations,
    "loadConfig",
    ts.isFunctionDeclaration,
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

function extractConfig(sourceFile, declarations, annotations, checker, ts) {
  const readExtras = requireDeclaration(
    declarations,
    "readConfigExtras",
    ts.isFunctionDeclaration,
  );
  if (!readExtras.type)
    fail("readConfigExtras no longer has an explicit return type");
  const extras = membersOfTypeNode(readExtras.type, checker, ts, true);
  const interfaceMembers = (name) => {
    const declaration = requireDeclaration(
      declarations,
      name,
      ts.isInterfaceDeclaration,
    );
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

  const discovered = discoverConfigKeys(sourceFile, checker, ts);
  let apiKeyStringGuard = false;
  function inspectGuard(node) {
    if (
      ts.isBinaryExpression(node) &&
      node.operatorToken.kind === ts.SyntaxKind.EqualsEqualsEqualsToken &&
      ts.isTypeOfExpression(node.left) &&
      ts.isPropertyAccessExpression(node.left.expression) &&
      node.left.expression.name.text === "apiKey" &&
      ts.isStringLiteralLike(node.right) &&
      node.right.text === "string"
    ) {
      apiKeyStringGuard = true;
    }
    ts.forEachChild(node, inspectGuard);
  }
  inspectGuard(sourceFile);
  if (!apiKeyStringGuard)
    fail(
      "config.json validation shape changed: apiKey is no longer guarded as a string",
    );
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
  const projectKeys = discoverProjectConfigKeys(declarations, annotations, ts);
  for (const [name, annotation] of Object.entries(annotations)) {
    if (!keys[name])
      fail(`no compiler-derived type for config.json key ${name}`);
    keys[name] = {
      ...keys[name],
      ...annotation,
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

function typeBoxDescriptor(initializer, declarations, ts) {
  function convert(node) {
    if (ts.isIdentifier(node)) {
      const declaration = declarations.get(node.text);
      if (!declaration?.initializer)
        fail(`cannot resolve TypeBox schema ${node.text}`);
      return convert(declaration.initializer);
    }
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
      const value = literalValue(node.arguments[0], ts, declarations);
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

function extractDefaultProjectTrust(sourceFile, declarations, ts) {
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
  const fallback = literalValue(expression.whenFalse, ts, declarations);
  if (typeof fallback !== "string")
    fail("pi getDefaultProjectTrust fallback is no longer a string literal");
  return fallback;
}

function extractHarness(declarations, settingsManagerSource, checker, ts) {
  const settings = requireDeclaration(
    declarations,
    "Settings",
    ts.isInterfaceDeclaration,
  );
  const baseKeys = membersOfDeclaration(settings, checker, ts);
  const defaultProjectTrust = extractDefaultProjectTrust(
    settingsManagerSource,
    declarations,
    ts,
  );
  if (!baseKeys.defaultProjectTrust?.enum?.includes(defaultProjectTrust))
    fail("pi default project trust is outside DefaultProjectTrust");
  baseKeys.defaultProjectTrust.default = defaultProjectTrust;
  const definitions = {};
  for (const name of [
    "BranchSummarySettings",
    "CompactionSettings",
    "ImageSettings",
    "MarkdownSettings",
    "ProviderRetrySettings",
    "RetrySettings",
    "TerminalSettings",
    "ThinkingBudgetsSettings",
    "WarningSettings",
  ]) {
    definitions[name] = membersOfDeclaration(
      requireDeclaration(declarations, name, ts.isInterfaceDeclaration),
      checker,
      ts,
    );
  }

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
        declarations,
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
  if (additions.modelRoles.properties.orchestrator?.type !== "string") {
    fail(
      "harness/settings.json Kimchi additions validation shape changed: modelRoles.orchestrator is no longer a string",
    );
  }
  additions.statusLine.properties.command = descriptorForType(
    checker.getStringType(),
    statusLine,
    checker,
    ts,
  );
  const overlap = Object.keys(additions).filter((name) => baseKeys[name]);
  if (overlap.length)
    fail(
      `Kimchi harness additions now overlap pi Settings: ${JSON.stringify(overlap.sort())}`,
    );
  const keys = {};
  for (const [name, descriptor] of Object.entries(baseKeys))
    keys[name] = { source: "pi", ...descriptor };
  for (const [name, descriptor] of Object.entries(additions))
    keys[name] = { source: "kimchi", ...descriptor };
  return {
    definitions: sortObject(definitions),
    keys: sortObject(keys),
    projectTier: { gatedByProjectTrust: true, supported: true },
  };
}

function staticTemplateText(node, ts) {
  if (ts.isNoSubstitutionTemplateLiteral(node) || ts.isStringLiteralLike(node))
    return node.text;
  if (!ts.isTemplateExpression(node)) return undefined;
  let result = node.head.text;
  for (const span of node.templateSpans) {
    result += `\${${span.expression.getText()}}`;
    result += span.literal.text;
  }
  return result;
}

function extractKimchiFlags(declarations, ts) {
  const helpFlags = requireDeclaration(
    declarations,
    "KIMCHI_FLAGS",
    ts.isVariableDeclaration,
  );
  const mapCall = helpFlags.initializer;
  const entriesCall =
    ts.isCallExpression(mapCall) &&
    ts.isPropertyAccessExpression(mapCall.expression)
      ? mapCall.expression.expression
      : undefined;
  const entriesAccess = ts.isCallExpression(entriesCall)
    ? entriesCall.expression
    : undefined;
  if (
    !ts.isCallExpression(mapCall) ||
    !ts.isPropertyAccessExpression(mapCall.expression) ||
    mapCall.expression.name.text !== "map" ||
    !ts.isCallExpression(entriesCall) ||
    !ts.isPropertyAccessExpression(entriesAccess) ||
    !ts.isIdentifier(entriesAccess.expression) ||
    entriesAccess.expression.text !== "Object" ||
    entriesAccess.name.text !== "entries" ||
    !ts.isIdentifier(entriesCall.arguments[0]) ||
    entriesCall.arguments[0].text !== "CLI_OPTIONS"
  ) {
    fail(
      "KIMCHI_FLAGS is no longer CLI help derived from CLI_OPTIONS; determine whether it became a feature gate",
    );
  }
  const declaration = requireDeclaration(
    declarations,
    "CLI_OPTIONS",
    ts.isVariableDeclaration,
  );
  if (
    !declaration.initializer ||
    !ts.isObjectLiteralExpression(declaration.initializer)
  )
    fail("CLI_OPTIONS is no longer an object literal");
  const raw = literalValue(declaration.initializer, ts, declarations);
  const flags = {};
  for (const [name, option] of Object.entries(raw)) {
    const valueName = option.placeholder?.slice(1, -1) ?? null;
    flags[`--${name}`] = {
      help: option.description,
      multiple: option.multiple === true,
      names: [`--${name}`, ...(option.short ? [`-${option.short}`] : [])],
      optionalValue: option.optional === true,
      origin: ["kimchi"],
      scope: "launcher-global",
      valueName,
    };
  }
  if (Object.keys(flags).length < 20)
    fail(
      `Kimchi CLI option census collapsed to ${Object.keys(flags).length} entries`,
    );
  return flags;
}

function equalityFlagNames(sourceFile, ts, identifier) {
  const names = new Set();
  function visit(node) {
    if (
      ts.isBinaryExpression(node) &&
      [
        ts.SyntaxKind.EqualsEqualsEqualsToken,
        ts.SyntaxKind.EqualsEqualsToken,
      ].includes(node.operatorToken.kind)
    ) {
      for (const [left, right] of [
        [node.left, node.right],
        [node.right, node.left],
      ]) {
        if (
          ts.isIdentifier(left) &&
          left.text === identifier &&
          ts.isStringLiteralLike(right) &&
          right.text.startsWith("-")
        ) {
          names.add(right.text);
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return names;
}

function helpRows(sourceFile, ts) {
  let helpText;
  function visit(node) {
    if (
      !helpText &&
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      node.expression.name.text === "log" &&
      node.arguments[0]
    ) {
      const text = staticTemplateText(node.arguments[0], ts);
      if (text?.includes("Options:")) helpText = text;
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  if (!helpText) fail("cannot locate pi's static CLI help template");
  const lines = helpText.split("\n");
  const start = lines.findIndex(
    (line) =>
      line.trim() === '${chalk.bold("Options:")}' || line.trim() === "Options:",
  );
  const end = lines.findIndex(
    (line, index) =>
      index > start &&
      line.includes("Extensions can register additional flags"),
  );
  if (start < 0 || end < 0) fail("cannot delimit pi's CLI help option rows");
  const rows = [];
  for (const line of lines.slice(start + 1, end)) {
    const trimmed = line.trimStart();
    if (!trimmed.startsWith("-")) {
      if (rows.length && trimmed) rows.at(-1).help += ` ${trimmed}`;
      continue;
    }
    let boundary = -1;
    for (let index = 0; index < trimmed.length - 1; index += 1) {
      if (trimmed[index] === " " && trimmed[index + 1] === " ") {
        boundary = index;
        break;
      }
    }
    if (boundary < 0) continue;
    const syntax = trimmed.slice(0, boundary).trim();
    const help = trimmed.slice(boundary).trim();
    const tokens = syntax.split(" ").filter(Boolean);
    const names = tokens
      .filter((token) => token.startsWith("-"))
      .map((token) => token.replaceAll(",", ""));
    const valueToken = tokens.find(
      (token) => token.startsWith("<") || token.startsWith("["),
    );
    rows.push({ help, names, valueName: valueToken?.slice(1, -1) ?? null });
  }
  return rows;
}

function extractPiFlags(sourceFile, ts) {
  const parsed = equalityFlagNames(sourceFile, ts, "arg");
  const rows = helpRows(sourceFile, ts);
  const documented = new Set(rows.flatMap((row) => row.names));
  const parserOnly = [...parsed].filter((name) => !documented.has(name)).sort();
  const helpOnly = [...documented].filter((name) => !parsed.has(name)).sort();
  if (parserOnly.length || helpOnly.length) {
    fail(
      `pi CLI parser/help census changed; parser-only=${JSON.stringify(parserOnly)}, help-only=${JSON.stringify(helpOnly)}`,
    );
  }
  const repeated = new Set([
    "--append-system-prompt",
    "--extension",
    "--prompt-template",
    "--skill",
    "--theme",
  ]);
  const flags = {};
  for (const row of rows) {
    flags[row.names[0]] = {
      help: row.help,
      multiple: repeated.has(row.names[0]),
      names: row.names,
      optionalValue: row.names[0] === "--list-models",
      origin: ["pi"],
      scope: "launcher-global",
      valueName: row.valueName,
    };
  }
  if (Object.keys(flags).length < 30)
    fail(
      `pi CLI option census collapsed to ${Object.keys(flags).length} entries`,
    );
  return flags;
}

function mergeFlags(kimchi, pi) {
  const merged = structuredClone(kimchi);
  for (const [name, flag] of Object.entries(pi)) {
    if (merged[name]) merged[name].origin.push("pi");
    else merged[name] = flag;
  }
  return Object.keys(merged)
    .sort()
    .map((name) => merged[name]);
}

function commandDefinitions(declaration, ts, declarations) {
  if (
    !declaration.initializer ||
    !ts.isArrayLiteralExpression(declaration.initializer)
  )
    fail("COMMANDS is no longer an array literal");
  return declaration.initializer.elements.map((element) => {
    if (!ts.isObjectLiteralExpression(element))
      fail("COMMANDS contains a non-object entry");
    const fields = Object.fromEntries(
      element.properties
        .filter(ts.isPropertyAssignment)
        .map((property) => [
          syntaxName(property.name, ts),
          property.initializer,
        ]),
    );
    if (!fields.name || !fields.summary)
      fail("COMMANDS entry has no name or summary");
    return {
      name: literalValue(fields.name, ts, declarations),
      summary: literalValue(fields.summary, ts, declarations),
    };
  });
}

function commandNames(sourceFile, ts) {
  const names = new Set(["auth", "config"]);
  function visit(node) {
    if (ts.isBinaryExpression(node)) {
      for (const side of [node.left, node.right]) {
        if (
          ts.isStringLiteralLike(side) &&
          [
            "install",
            "remove",
            "uninstall",
            "update",
            "list",
            "config",
          ].includes(side.text)
        ) {
          names.add(side.text);
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return names;
}

function subcommandFlags(sourceFile, ts) {
  const names = new Set();
  const declaredNames = new Set();
  function add(node) {
    if (!ts.isStringLiteralLike(node)) return;
    let name = node.text;
    if (!name.startsWith("-") || name === "--" || name.includes(" ")) return;
    if (name.endsWith("=")) name = name.slice(0, -1);
    names.add(name);
  }
  function isArgumentExpression(node) {
    return (
      (ts.isIdentifier(node) && ["arg", "args"].includes(node.text)) ||
      (ts.isElementAccessExpression(node) &&
        ts.isIdentifier(node.expression) &&
        node.expression.text === "args")
    );
  }
  function visit(node) {
    if (ts.isBinaryExpression(node)) {
      if (isArgumentExpression(node.left)) add(node.right);
      if (isArgumentExpression(node.right)) add(node.left);
    }
    if (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression)
    ) {
      const receiver = node.expression.expression;
      if (
        (node.expression.name.text === "includes" &&
          ts.isIdentifier(receiver) &&
          receiver.text === "args") ||
        (["startsWith", "endsWith"].includes(node.expression.name.text) &&
          isArgumentExpression(receiver))
      ) {
        add(node.arguments[0]);
      }
    }
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.name.text.includes("FLAG") &&
      node.initializer
    ) {
      const array = ts.isArrayLiteralExpression(node.initializer)
        ? node.initializer
        : ts.isNewExpression(node.initializer) &&
            ts.isIdentifier(node.initializer.expression) &&
            node.initializer.expression.text === "Set"
          ? node.initializer.arguments?.[0]
          : undefined;
      if (array && ts.isArrayLiteralExpression(array)) {
        for (const element of array.elements) {
          if (ts.isStringLiteralLike(element) && element.text.startsWith("-"))
            declaredNames.add(element.text);
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  const result = declaredNames.size ? declaredNames : names;
  return [...result]
    .sort()
    .map((name) => ({ names: [name], scope: "subcommand" }));
}

function extractCommands(
  declarations,
  packageManagerSource,
  commandSources,
  ts,
) {
  const kimchi = commandDefinitions(
    requireDeclaration(declarations, "COMMANDS", ts.isVariableDeclaration),
    ts,
    declarations,
  );
  if (kimchi.length < 10)
    fail(`Kimchi command census collapsed to ${kimchi.length} entries`);
  const pi = commandNames(packageManagerSource, ts);
  const expectedPi = [
    "auth",
    "config",
    "install",
    "list",
    "remove",
    "uninstall",
    "update",
  ];
  if (JSON.stringify([...pi].sort()) !== JSON.stringify(expectedPi))
    fail(`pi command census changed: ${JSON.stringify([...pi].sort())}`);
  const commands = {
    kimchi: {
      implementations: [{ origin: "pi", reachable: true }],
      path: ["kimchi"],
    },
  };
  for (const command of kimchi) {
    const record = {
      help: command.summary,
      implementations: [{ origin: "kimchi", reachable: true }],
      path: ["kimchi", command.name],
    };
    const sourceFile = commandSources.get(command.name);
    if (!sourceFile)
      fail(
        `cannot locate the implementation source for kimchi ${command.name}`,
      );
    const flags = subcommandFlags(sourceFile, ts);
    if (flags.length) record.flags = flags;
    commands[`kimchi ${command.name}`] = record;
  }
  for (const name of [...pi].sort()) {
    const key = `kimchi ${name}`;
    const implementation = {
      origin: "pi",
      reachable: !kimchi.some((command) => command.name === name),
    };
    if (!implementation.reachable)
      implementation.reason =
        "Kimchi's top-level dispatcher handles this command first";
    commands[key] ??= { implementations: [], path: ["kimchi", name] };
    commands[key].implementations.push(implementation);
  }
  return sortObject(commands);
}

function extractCli(
  declarations,
  piArgsSource,
  packageManagerSource,
  commandSources,
  ts,
) {
  return {
    commands: extractCommands(
      declarations,
      packageManagerSource,
      commandSources,
      ts,
    ),
    globalFlags: mergeFlags(
      extractKimchiFlags(declarations, ts),
      extractPiFlags(piArgsSource, ts),
    ),
  };
}

function stringConstant(
  expression,
  checker,
  ts,
  declarations,
  seen = new Set(),
) {
  if (ts.isStringLiteralLike(expression)) return expression.text;
  if (ts.isTemplateExpression(expression)) {
    let value = expression.head.text;
    for (const span of expression.templateSpans) {
      const part = stringConstant(
        span.expression,
        checker,
        ts,
        declarations,
        seen,
      );
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
      checker,
      ts,
      declarations,
      seen,
    )?.toUpperCase();
  }
  if (!ts.isIdentifier(expression)) return undefined;
  let symbol = checker.getSymbolAtLocation(expression);
  if (symbol) {
    if (symbol.flags & ts.SymbolFlags.Alias)
      symbol = checker.getAliasedSymbol(symbol);
    if (seen.has(symbol)) return undefined;
    seen.add(symbol);
    for (const declaration of symbol.declarations ?? []) {
      if (ts.isVariableDeclaration(declaration) && declaration.initializer) {
        const value = stringConstant(
          declaration.initializer,
          checker,
          ts,
          declarations,
          seen,
        );
        if (value !== undefined) return value;
      }
    }
  }
  const declaration = declarations.get(expression.text);
  if (declaration?.initializer)
    return stringConstant(
      declaration.initializer,
      checker,
      ts,
      declarations,
      seen,
    );
  return undefined;
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

function environmentReads(sourceFile, checker, ts, declarations) {
  const found = new Set();
  const environmentSymbols = new Set();
  function containsProcessEnvironment(node) {
    let foundEnvironment = false;
    function inspect(child) {
      if (
        ts.isPropertyAccessExpression(child) &&
        ts.isIdentifier(child.expression) &&
        child.expression.text === "process" &&
        child.name.text === "env"
      ) {
        foundEnvironment = true;
      }
      if (!foundEnvironment) ts.forEachChild(child, inspect);
    }
    inspect(node);
    return foundEnvironment;
  }
  function identifyAliases(node) {
    if (
      (ts.isVariableDeclaration(node) || ts.isParameter(node)) &&
      ts.isIdentifier(node.name) &&
      node.initializer &&
      containsProcessEnvironment(node.initializer)
    ) {
      const symbol = checker.getSymbolAtLocation(node.name);
      if (symbol) environmentSymbols.add(symbol);
    }
    ts.forEachChild(node, identifyAliases);
  }
  identifyAliases(sourceFile);
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
  function visit(node) {
    let name;
    if (
      ts.isCallExpression(node) &&
      ts.isIdentifier(node.expression) &&
      node.expression.text === "getProviderEnvValue" &&
      node.arguments[0]
    ) {
      name = stringConstant(node.arguments[0], checker, ts, declarations);
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
      name = stringConstant(node.argumentExpression, checker, ts, declarations);
      if (!name && ts.isIdentifier(node.argumentExpression))
        name = DYNAMIC_ENVIRONMENT_NAMES[node.argumentExpression.text];
    }
    if (
      name &&
      (name.startsWith("KIMCHI_") || name.startsWith("PI_")) &&
      !isWriteOnly(node, ts)
    )
      found.add(name);
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  return found;
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
  checker,
  ts,
  declarations,
) {
  const reads = { kimchi: new Set(), pi: new Set() };
  for (const sourceFile of kimchiSourceFiles) {
    for (const name of environmentReads(sourceFile, checker, ts, declarations))
      reads.kimchi.add(name);
  }
  for (const sourceFile of piSourceFiles) {
    for (const name of environmentReads(sourceFile, checker, ts, declarations))
      reads.pi.add(name);
  }
  for (const path of patchPaths) {
    const sourceFile = ts.createSourceFile(
      path,
      patchAddedSource(await readFile(path, "utf8")),
      ts.ScriptTarget.Latest,
      true,
    );
    for (const name of environmentReads(sourceFile, checker, ts, declarations))
      reads.pi.add(name);
  }
  const discovered = new Set([...reads.kimchi, ...reads.pi]);
  const expected = new Set(Object.keys(annotations));
  const unknown = [...discovered].filter((name) => !expected.has(name)).sort();
  const missing = [...expected].filter((name) => !discovered.has(name)).sort();
  if (unknown.length || missing.length)
    fail(
      `environment census changed; new=${JSON.stringify(unknown)}, missing=${JSON.stringify(missing)}`,
    );
  const variables = {};
  for (const [name, annotation] of Object.entries(annotations)) {
    variables[name] = {
      consumerOverridable: annotation.consumerOverridable ?? true,
      readBy: Object.entries(reads)
        .filter(([, names]) => names.has(name))
        .map(([runtime]) => runtime)
        .sort(),
      ...annotation,
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
  const program = ts.createProgram({
    rootNames: [...kimchiPaths, ...piPaths],
    options: {
      allowJs: true,
      allowSyntheticDefaultImports: true,
      checkJs: false,
      module: ts.ModuleKind.NodeNext,
      moduleResolution: ts.ModuleResolutionKind.NodeNext,
      noEmit: true,
      skipLibCheck: true,
      target: ts.ScriptTarget.ESNext,
    },
  });
  const checker = program.getTypeChecker();
  const sourceFiles = program
    .getSourceFiles()
    .filter(
      (sourceFile) =>
        kimchiPaths.includes(sourceFile.fileName) ||
        piPaths.includes(sourceFile.fileName),
    );
  const declarations = declarationIndex(sourceFiles, ts);
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
  if (
    kimchiPackage.dependencies?.["@earendil-works/pi-coding-agent"] !==
    piVersion
  ) {
    fail(
      `Kimchi pins pi ${JSON.stringify(kimchiPackage.dependencies?.["@earendil-works/pi-coding-agent"])}, but the supplied pi source is ${JSON.stringify(piVersion)}`,
    );
  }

  const result = {
    cli: extractCli(
      declarations,
      requireSource(join(piRoot, "dist/cli/args.js")),
      requireSource(join(piRoot, "dist/package-manager-cli.js")),
      new Map(
        [
          "claude",
          "codex",
          "config",
          "cursor",
          "gsd2",
          "login",
          "mcp",
          "openclaw",
          "opencode",
          "resources",
          "setup",
          "setup-tools",
          "update",
          "version",
        ].map((name) => [
          name,
          requireSource(join(kimchiRoot, `src/commands/${name}.ts`)),
        ]),
      ),
      ts,
    ),
    config: extractConfig(
      requireSource(join(kimchiRoot, "src/config.ts")),
      declarations,
      annotations.config,
      checker,
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
      checker,
      ts,
      declarations,
    ),
    harness: extractHarness(
      declarations,
      requireSource(join(piRoot, "dist/core/settings-manager.js")),
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
