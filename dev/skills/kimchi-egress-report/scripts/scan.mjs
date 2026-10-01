#!/usr/bin/env node

import { execFile } from "node:child_process";
import { readdir, readFile, writeFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const SCANNER_VERSION = "1.0.0";
const execFileAsync = promisify(execFile);

function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function fail(message) {
  console.error(`scan.mjs: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (!argument.startsWith("--") || !argv[index + 1])
      fail(`invalid argument: ${argument}`);
    args[argument.slice(2)] = argv[++index];
  }
  for (const required of ["out", "pi", "sources", "tree", "typescript"]) {
    if (!args[required]) fail(`missing --${required} <path>`);
  }
  return args;
}

const EXCLUDED_DIRS = new Set([".git", "__mocks__", "dist", "node_modules"]);
const isTestFile = (path) => /\.(?:spec|test)\.[jt]sx?$/.test(path);

async function filesUnder(root, accept, excludedDirs = EXCLUDED_DIRS) {
  const files = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (!excludedDirs.has(entry.name)) await visit(path);
      } else if (accept(path)) {
        files.push(path);
      }
    }
  }
  await visit(root);
  return files.sort();
}

const HOST_RE = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$/i;
const HOST_DENY_RE =
  /\.(?:d\.ts|js|json|jsx|lock|md|png|svg|ts|tsx|yaml|yml)$/i;
const PATH_RE = /^\/[A-Za-z0-9][A-Za-z0-9/_.\-{}:+%]*$/;
const TLD_ALLOW = new Set([
  "ai",
  "app",
  "cloud",
  "cn",
  "co",
  "com",
  "dev",
  "edu",
  "eu",
  "gg",
  "gov",
  "info",
  "internal",
  "io",
  "me",
  "net",
  "org",
  "sh",
  "so",
  "tech",
  "to",
  "uk",
  "xyz",
]);

function looksLikeHost(value) {
  if (
    !value ||
    value.length > 253 ||
    !HOST_RE.test(value) ||
    HOST_DENY_RE.test(value)
  )
    return false;
  const labels = value.split(".");
  return /[a-z]/i.test(value) && TLD_ALLOW.has(labels.at(-1).toLowerCase());
}

function looksLikePath(value) {
  return value.length >= 2 && value.length <= 200 && PATH_RE.test(value);
}

function sourceLabel(path, root, prefix = "kimchi") {
  return `${prefix}/${relative(root, path)}`;
}

function addLiteral(value, file, literals) {
  if (/^(?:https?|wss?):\/\//i.test(value)) {
    try {
      const url = new URL(value);
      literals.hosts.push({ file, value: url.hostname });
      if (url.pathname !== "/")
        literals.paths.push({ file, value: url.pathname });
      return;
    } catch {
      // A scheme-like string that is not a URL can still be classified below.
    }
  }
  if (looksLikeHost(value)) literals.hosts.push({ file, value });
  else if (looksLikePath(value)) literals.paths.push({ file, value });
}

const NETWORK_CALL_NAMES = new Set([
  "axios",
  "axios.get",
  "axios.post",
  "fetch",
  "got",
  "http.get",
  "http.request",
  "https.get",
  "https.request",
  "undici.fetch",
  "undici.request",
]);
const NETWORK_TOOLS = new Set([
  "curl",
  "git",
  "nc",
  "rsync",
  "scp",
  "ssh",
  "wget",
]);
const SPAWN_CALL_NAMES = new Set([
  "child_process.exec",
  "child_process.execFile",
  "child_process.spawn",
  "exec",
  "execFile",
  "execFileSync",
  "execSync",
  "spawn",
  "spawnSync",
]);

function calleeText(expression, ts) {
  if (ts.isIdentifier(expression)) return expression.text;
  if (ts.isPropertyAccessExpression(expression)) {
    const base = calleeText(expression.expression, ts);
    return base ? `${base}.${expression.name.text}` : expression.name.text;
  }
  return expression.getText();
}

function scanTsFile(path, root, text, ts, sites, literals) {
  const scriptKind = path.endsWith(".tsx")
    ? ts.ScriptKind.TSX
    : path.endsWith(".jsx")
      ? ts.ScriptKind.JSX
      : path.endsWith(".ts")
        ? ts.ScriptKind.TS
        : ts.ScriptKind.JS;
  const source = ts.createSourceFile(
    path,
    text,
    ts.ScriptTarget.Latest,
    true,
    scriptKind,
  );
  const file = sourceLabel(path, root);

  function visit(node) {
    if (ts.isStringLiteralLike(node)) addLiteral(node.text, file, literals);
    if (ts.isNewExpression(node) || ts.isCallExpression(node)) {
      const callee = calleeText(node.expression, ts);
      const firstArgument = node.arguments?.[0];
      const target = firstArgument?.getText(source) ?? "<none>";
      const category =
        ts.isNewExpression(node) && callee === "EventSource"
          ? "eventsource"
          : ts.isNewExpression(node) && callee === "WebSocket"
            ? "websocket"
            : NETWORK_CALL_NAMES.has(callee)
              ? "http"
              : null;
      if (category) {
        sites.push({ callee, category, file, target });
      } else if (
        SPAWN_CALL_NAMES.has(callee) &&
        firstArgument &&
        ts.isStringLiteralLike(firstArgument)
      ) {
        const tool = firstArgument.text.trim().split(/\s+/, 1)[0];
        if (NETWORK_TOOLS.has(tool))
          sites.push({ callee, category: "spawn", file, target });
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
}

const GO_CALL_RE =
  /\b(http\.(?:Get|Head|NewRequestWithContext|NewRequest|Post)|websocket\.(?:DefaultDialer|Dial)|net\.Dial|exec\.Command)\s*\(([^)]*)\)/g;
const GO_STRING_RE = /"((?:[^"\\]|\\.)*)"/g;

function scanGoFile(path, root, text, sites, literals) {
  const file = sourceLabel(path, root);
  for (const match of text.matchAll(GO_STRING_RE))
    addLiteral(match[1], file, literals);
  for (const match of text.matchAll(GO_CALL_RE)) {
    const callee = match[1];
    const category = callee.startsWith("http.")
      ? "http"
      : callee.startsWith("websocket.")
        ? "websocket"
        : callee.startsWith("exec.")
          ? "spawn"
          : "net";
    const argumentsText = match[2].split(",").map((value) => value.trim());
    // NewRequestWithContext(ctx, method, url, body) carries the URL third.
    const targetIndex =
      callee === "http.NewRequestWithContext"
        ? 2
        : callee === "http.NewRequest" ||
            callee === "net.Dial" ||
            callee.startsWith("websocket.")
          ? 1
          : 0;
    sites.push({
      callee,
      category,
      file,
      target: argumentsText[targetIndex] ?? "<none>",
    });
  }
}

const JS_STRING_RE = /"((?:[^"\\]|\\.){1,200})"|'((?:[^'\\]|\\.){1,200})'/g;

function scanBundledJs(path, root, text, literals) {
  const file = sourceLabel(path, root, "pi");
  for (const match of text.matchAll(JS_STRING_RE))
    addLiteral(match[1] ?? match[2], file, literals);
}

function dedupeLiterals(entries) {
  const values = new Map();
  for (const { file, value } of entries) {
    if (!values.has(value)) values.set(value, new Set());
    values.get(value).add(file);
  }
  return [...values.entries()]
    .map(([value, files]) => ({ files: [...files].sort(compare), value }))
    .sort((left, right) => compare(left.value, right.value));
}

function dedupeSites(sites) {
  const keys = new Map();
  for (const site of sites) {
    const key = `${site.file}|${site.category}|${site.callee}|${site.target}`;
    if (!keys.has(key)) keys.set(key, site);
  }
  return [...keys.values()].sort((left, right) =>
    compare(
      `${left.file}|${left.category}|${left.callee}|${left.target}`,
      `${right.file}|${right.category}|${right.callee}|${right.target}`,
    ),
  );
}

function collectStringConstants(source, ts, constants) {
  function visit(node) {
    if (
      ts.isVariableDeclaration(node) &&
      ts.isIdentifier(node.name) &&
      node.initializer &&
      ts.isStringLiteralLike(node.initializer)
    ) {
      const oldValue = constants.get(node.name.text);
      constants.set(
        node.name.text,
        oldValue === undefined || oldValue === node.initializer.text
          ? node.initializer.text
          : null,
      );
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
}

function resolvedString(node, constants, ts) {
  if (node && ts.isStringLiteralLike(node)) return node.text;
  if (node && ts.isIdentifier(node)) return constants.get(node.text) ?? null;
  return null;
}

function objectPropertyStrings(source, propertyName, constants, ts) {
  const values = [];
  function visit(node) {
    if (
      ts.isPropertyAssignment(node) &&
      node.name.getText(source) === propertyName
    ) {
      const value = resolvedString(node.initializer, constants, ts);
      if (value) values.push(value);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return values;
}

function registerCommandStrings(source, constants, ts) {
  const values = [];
  function visit(node) {
    if (
      ts.isCallExpression(node) &&
      calleeText(node.expression, ts).endsWith("registerCommand")
    ) {
      const value = resolvedString(node.arguments[0], constants, ts);
      if (value) values.push(value);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return values;
}

function sortedUnique(values) {
  return [...new Set(values)].sort(compare);
}

function sortedObject(object) {
  return Object.fromEntries(
    Object.entries(object).sort(([left], [right]) => compare(left, right)),
  );
}

function formatReport(report) {
  const formatted = JSON.stringify(report, null, 2).replace(
    /^(\s*)"files": \[\n((?:\s+"(?:[^"\\]|\\.)*",?\n)+)\1\]/gm,
    (block, indent, entries) => {
      const values = entries
        .trim()
        .split("\n")
        .map((line) => line.trim().replace(/,$/, ""));
      const inline = `${indent}"files": [${values.join(", ")}]`;
      return inline.length + 1 <= 80 ? inline : block;
    },
  );
  return `${formatted}\n`;
}

async function narHash(path) {
  const { stdout } = await execFileAsync("nix", [
    "hash",
    "path",
    "--type",
    "sha256",
    "--sri",
    path,
  ]);
  return stdout.trim();
}

async function extractCommands(treeRoot, piRoot, files, ts) {
  const parsed = new Map();
  const constants = new Map();
  for (const path of files) {
    const source = ts.createSourceFile(
      path,
      await readFile(path, "utf8"),
      ts.ScriptTarget.Latest,
      true,
    );
    parsed.set(path, source);
    collectStringConstants(source, ts, constants);
  }

  const kimchiRegistered = [];
  for (const source of parsed.values())
    kimchiRegistered.push(...registerCommandStrings(source, constants, ts));

  const resourceSource = parsed.get(
    join(treeRoot, "src/resources/definitions.ts"),
  );
  const registrySource = parsed.get(join(treeRoot, "src/commands/registry.ts"));
  if (!resourceSource || !registrySource)
    fail("missing Kimchi command or resource definition source");

  const slashPath = join(piRoot, "dist/core/slash-commands.js");
  const slashSource = ts.createSourceFile(
    slashPath,
    await readFile(slashPath, "utf8"),
    ts.ScriptTarget.Latest,
    true,
  );
  return {
    cliSubcommands: sortedUnique(
      objectPropertyStrings(registrySource, "name", constants, ts),
    ),
    kimchiRegistered: sortedUnique(kimchiRegistered),
    piBuiltInSlash: sortedUnique(
      objectPropertyStrings(slashSource, "name", constants, ts),
    ),
    resourceIds: sortedUnique(
      objectPropertyStrings(resourceSource, "id", constants, ts),
    ),
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const tsModule = await import(pathToFileURL(args.typescript).href);
  const ts = tsModule.default ?? tsModule;
  const sources = JSON.parse(await readFile(args.sources, "utf8"));
  const kimchiPackage = JSON.parse(
    await readFile(join(args.tree, "package.json"), "utf8"),
  );
  const piPackage = JSON.parse(
    await readFile(join(args.pi, "package.json"), "utf8"),
  );
  const pinnedPiVersion = sources.extraction.piPackage.version;
  if ((await narHash(args.tree)) !== sources.extraction.kimchiSource.hash)
    fail("Kimchi tree hash does not match packages/kimchi/sources.json");
  if ((await narHash(args.pi)) !== sources.extraction.piPackage.hash)
    fail("pi tree hash does not match packages/kimchi/sources.json");
  if (piPackage.version !== pinnedPiVersion)
    fail("pi package version does not match packages/kimchi/sources.json");
  if (
    kimchiPackage.dependencies?.["@earendil-works/pi-coding-agent"] !==
    pinnedPiVersion
  )
    fail(
      "Kimchi's direct pi dependency does not match packages/kimchi/sources.json",
    );
  const literals = { hosts: [], paths: [] };
  const sites = [];

  const sourceFiles = await filesUnder(
    args.tree,
    (path) => /\.(?:cjs|js|jsx|mjs|ts|tsx)$/.test(path) && !isTestFile(path),
  );
  for (const path of sourceFiles) {
    scanTsFile(
      path,
      args.tree,
      await readFile(path, "utf8"),
      ts,
      sites,
      literals,
    );
  }
  const goFiles = await filesUnder(
    args.tree,
    (path) => path.endsWith(".go") && !path.endsWith("_test.go"),
  );
  for (const path of goFiles)
    scanGoFile(path, args.tree, await readFile(path, "utf8"), sites, literals);

  const piFiles = await filesUnder(
    join(args.pi, "dist"),
    (path) =>
      /\.(?:cjs|js|mjs)$/.test(path) &&
      !path.endsWith(".map") &&
      !isTestFile(path),
    new Set([".git", "node_modules"]),
  );
  for (const path of piFiles)
    scanBundledJs(path, args.pi, await readFile(path, "utf8"), literals);

  const commands = await extractCommands(args.tree, args.pi, sourceFiles, ts);
  const allCommands = sortedUnique(Object.values(commands).flat());
  const report = {
    commands,
    dependencies: {
      kimchiDirect: sortedObject(kimchiPackage.dependencies ?? {}),
      piPackages: sortedObject({
        "@earendil-works/pi-agent-core":
          sources.extraction.piAgentCorePackage.version,
        "@earendil-works/pi-ai": sources.extraction.piAiPackage.version,
        "@earendil-works/pi-coding-agent": sources.extraction.piPackage.version,
        "@earendil-works/pi-tui": sources.extraction.piTuiPackage.version,
      }),
    },
    header: {
      kimchiSourceHash: sources.extraction.kimchiSource.hash,
      kimchiVersion: sources.version,
      piVersion: piPackage.version,
      scannerVersion: SCANNER_VERSION,
    },
    hosts: dedupeLiterals(literals.hosts),
    networkCallSites: dedupeSites(sites),
    urlPathLiterals: dedupeLiterals(literals.paths),
  };

  if (!report.hosts.some(({ value }) => value === "llm.kimchi.dev")) {
    fail("sanity floor failed: llm.kimchi.dev is absent from hosts");
  }
  if (!allCommands.includes("teleport"))
    fail("sanity floor failed: teleport is absent from commands");

  await writeFile(args.out, formatReport(report));
  console.log(
    `scan.mjs: wrote ${args.out} (${report.hosts.length} hosts, ${report.urlPathLiterals.length} paths, ${report.networkCallSites.length} call sites, ${allCommands.length} commands)`,
  );
}

main().catch((error) => {
  if (!process.exitCode) {
    console.error(`scan.mjs: ${error.stack ?? error}`);
    process.exitCode = 1;
  }
});
