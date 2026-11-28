// Synthetic producer-boundary test; it does not run or emulate CodeQL.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "../../../../..");
const generator =
  process.argv[2] ||
  resolve(root, "packages/kimchi/extract/egress/generate.mjs");
const sources =
  process.argv[3] || resolve(root, "packages/kimchi/sources.json");
const read = (path) => JSON.parse(readFileSync(path, "utf8"));
const fixture = (name) =>
  read(resolve(import.meta.dirname, `expected/${name}.json`));
const regionRegistry = fixture("regionRegistry");
const requestGuards = fixture("requestGuards");
const resourceDefinitions = fixture("resourceDefinitions");

// Use independent scanner keys and sentinels so a dropped or blanked section fails.
const scan = {
  commands: { cliSubcommands: ["search"] },
  dependencies: { kimchiDirect: { fixture: "1.0.0" } },
  goCallSites: [
    { callee: "http.Get", category: "http", file: "main.go", target: "url" },
  ],
  goHosts: [{ files: ["main.go"], value: "api.example" }],
  spawnCallSites: [
    { callee: "spawn", category: "spawn", file: "cli.ts", target: "git" },
  ],
  urlPathLiterals: [{ files: ["cli.ts"], value: "/v1/search" }],
};
const scanHeader = { fixture: true };
const callSite = (line, overrides = {}) => ({
  bundledModule: null,
  file: "src/requests.ts",
  library: "fetch",
  line,
  readBy: "kimchi",
  targets: [],
  ...overrides,
});
const absent = "no modeled local guard";
const necessary =
  "necessary local conditions at the listed call columns; not sufficient for execution";
const guardAt = (line) =>
  requestGuards.find(({ callSite }) => callSite.line === line);
// Pin all joined rows, including the polarity of the two early-return guards.
// Each negative row isolates one ignored component of the join identity.
const guardRows = [
  ["negated return", callSite(9), [guardAt(9)], necessary],
  [
    "different bundle",
    callSite(9, { bundledModule: "node_modules/unrelated/index.js" }),
    [],
    absent,
  ],
  ["different library", callSite(9, { library: "undici" }), [], absent],
  ["positive return", callSite(16), [guardAt(16)], necessary],
  ["sibling call with a different line", callSite(51), [], absent],
  ["different file", callSite(9, { file: "src/unrelated.ts" }), [], absent],
];
const callSites = guardRows.map(([, site]) => site);
const facts = {
  egressScan: { ...scan, header: { scan: scanHeader } },
  environment: { variables: {} },
  network: { callSites, unattributed: [] },
  regionRegistry,
  requestGuards,
  resourceDefinitions,
};
const dir = mkdtempSync(resolve(tmpdir(), "kimchi-request-evidence-"));
const input = resolve(dir, "facts.json");
const output = resolve(dir, "report.json");
function generate() {
  writeFileSync(input, JSON.stringify(facts));
  execFileSync(process.execPath, [
    generator,
    "--facts",
    input,
    "--sources",
    sources,
    "--out",
    output,
  ]);
  return read(output);
}
try {
  const report = generate();
  // The additive report must not erase scanner or extractor facts or invent
  // endpoints when no network row has a target.
  assert.deepEqual(report.networkCallSites, callSites);
  assert.deepEqual(report.hosts, []);
  assert.deepEqual(report.endpointVariables, []);
  for (const [key, expected] of Object.entries(scan)) {
    assert.deepEqual(report[key], expected, key);
  }
  assert.deepEqual(report.header.scan, scanHeader);
  assert.deepEqual(report.regionRegistry, regionRegistry);
  assert.deepEqual(report.resourceDefinitions, resourceDefinitions);

  assert.equal(
    report.requestGuards.length,
    guardRows.length,
    "preserve every network identity",
  );
  for (const [
    index,
    [name, { targets: _targets, ...site }, guards, status],
  ] of guardRows.entries()) {
    assert.deepEqual(
      report.requestGuards[index],
      { ...site, guards, status },
      name,
    );
  }
  // Move and reverse the non-tied rows, preserving the two bundles' tie order.
  // Without call-site sorting the published report would now be different.
  const [first, second, ...otherSites] = callSites;
  facts.network.callSites = [...otherSites.reverse(), first, second];
  assert.deepEqual(generate(), report);
} finally {
  rmSync(dir, { force: true, recursive: true });
}
console.log(
  "PASS: scanner and extractor facts preserved; guard polarity, absence, order and identity checked",
);
