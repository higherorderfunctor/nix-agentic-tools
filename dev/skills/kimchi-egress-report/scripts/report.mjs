// What packages/kimchi/egress-report.json holds, and who writes each field.
// scan.mjs writes the scanner's fields; generate.mjs writes the facts' fields
// and keeps the scanner's.

import { writeFile } from "node:fs/promises";

export const FACT_FIELDS = {
  endpointVariables:
    "network fact: env targets, each joined with its environment fact row",
  hosts: "network fact: target hosts and unattributed URL literals",
  networkCallSites: "network fact: call sites",
};

export const SCAN_FIELDS = {
  commands: "scan.mjs: TypeScript AST over the Kimchi and pi trees",
  dependencies: "scan.mjs: Kimchi package.json and sources.json",
  goCallSites: "scan.mjs: regex over tools/proxy-helper Go source",
  goHosts: "scan.mjs: regex over tools/proxy-helper Go source",
  spawnCallSites: "scan.mjs: TypeScript AST over Kimchi's tree",
  urlPathLiterals:
    "scan.mjs: TypeScript AST over Kimchi's tree, regex over pi's dist and Go",
};

export function compare(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

export function fail(script, message) {
  console.error(`${script}: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

// `options` maps each --name to its default; a null default is required.
export function parseArgs(script, argv, options) {
  const args = { ...options };
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (!argument.startsWith("--") || !argv[index + 1])
      fail(script, `invalid argument: ${argument}`);
    args[argument.slice(2)] = argv[++index];
  }
  for (const [name, value] of Object.entries(args))
    if (!(name in options)) fail(script, `unknown argument: --${name}`);
    else if (!value) fail(script, `missing --${name} <path>`);
  return args;
}

function sortedKeys(value) {
  if (Array.isArray(value)) return value.map(sortedKeys);
  if (value === null || typeof value !== "object") return value;
  return Object.fromEntries(
    Object.keys(value)
      .sort(compare)
      .map((key) => [key, sortedKeys(value[key])]),
  );
}

// treefmt (biome) owns the final layout; the check compares parsed JSON.
export async function writeReport(path, report) {
  await writeFile(path, `${JSON.stringify(sortedKeys(report), null, 2)}\n`);
}
