// Synthetic producer-boundary test; it does not run or emulate CodeQL.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "../../../../..");
const generator =
  process.argv[2] ||
  resolve(root, "packages/kimchi/extract/egress/generate.mjs");
const sources =
  process.argv[3] || resolve(root, "packages/kimchi/sources.json");
const { FACT_FIELDS, SCAN_FIELDS } = await import(
  pathToFileURL(resolve(generator, "../report.mjs"))
);
const read = (path) => JSON.parse(readFileSync(path, "utf8"));
const facts = {
  egressScan: {
    header: { scan: { fixture: true } },
    ...Object.fromEntries(Object.keys(SCAN_FIELDS).map((key) => [key, []])),
  },
  environment: { variables: {} },
  // Fails line-keyed joins and boundary omission: both columns survive unchanged.
  requestCallers: [5, 35].flatMap((column) => [
    {
      callSite: {
        file: "kimchi/src/requests.ts",
        line: 57,
        column,
        library: "fetch",
      },
      functionSite: { file: "kimchi/src/requests.ts", line: 54, column: 1 },
      kind: "enclosing",
      site: { file: "kimchi/src/requests.ts", line: 54, column: 1 },
      property: null,
      reason: null,
      distance: 0,
    },
    {
      callSite: {
        file: "kimchi/src/requests.ts",
        line: 57,
        column,
        library: "fetch",
      },
      functionSite: { file: "kimchi/src/requests.ts", line: 54, column: 1 },
      kind: "boundary",
      site: { file: "kimchi/src/requests.ts", line: 60, column: 1 },
      property: "fetchImpl",
      reason: "registration",
      distance: 1,
    },
  ]),
  network: {
    callSites: [
      9, 17, 24, 31, 40, 51, 57, 59, 64, 69, 70, 76, 85, 91, 97, 103, 105, 112,
      119, 126,
    ].map((line) => ({
      bundledModule: null,
      file: "src/requests.ts",
      library: "fetch",
      line,
      readBy: "kimchi",
      targets: [],
    })),
    unattributed: [],
  },
  ...Object.fromEntries(
    ["regionRegistry", "requestGuards", "resourceDefinitions"].map((name) => [
      name,
      read(resolve(import.meta.dirname, `expected/${name}.json`)),
    ]),
  ),
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
const report = generate();
assert.equal(report.requestCallers.length, 4);
for (const row of facts.requestCallers)
  assert.deepEqual(
    report.requestCallers.find(
      (actual) =>
        actual.kind === row.kind &&
        actual.callSite.column === row.callSite.column,
    ),
    row,
  );
assert.deepEqual(report.networkCallSites, facts.network.callSites);
assert.deepEqual(report.hosts, []);
assert.deepEqual(report.endpointVariables, []);
for (const key of Object.keys(SCAN_FIELDS))
  assert.deepEqual(report[key], facts.egressScan[key]);
assert.deepEqual(report.header.scan, facts.egressScan.header.scan);
assert.deepEqual(report.header.provenance, { ...FACT_FIELDS, ...SCAN_FIELDS });
assert.deepEqual(report.regionRegistry, facts.regionRegistry);
assert.deepEqual(report.resourceDefinitions, facts.resourceDefinitions);
for (const row of report.requestGuards) {
  const count = [9, 17, 24, 31, 40, 57, 119].includes(row.line) ? 1 : 0;
  assert.equal(row.guards.length, count);
  assert.equal(
    row.status,
    count
      ? "necessary local conditions at the listed call columns; not sufficient for execution"
      : "no modeled local guard",
  );
}
assert.equal(report.requestGuards[1].guards[0].conditionOutcome, false);
assert.equal(report.requestGuards[2].guards[0].outcome, "falsy");
facts.network.callSites.reverse();
facts.requestCallers.reverse();
facts.requestGuards.reverse();
assert.deepEqual(generate(), report);
// Fails attaching a guard to another bundled module sharing a line/library.
facts.network.callSites.push({
  ...facts.network.callSites.find(({ line }) => line === 9),
  bundledModule: "node_modules/unrelated/index.js",
});
assert.equal(
  generate().requestGuards.find(({ bundledModule }) => bundledModule !== null)
    .guards.length,
  0,
);
delete facts.requestCallers;
assert.throws(
  () => generate(),
  (error) => /lacks requestCallers/.test(String(error.stderr)),
);
console.log(
  "PASS: legacy fields preserved; four caller rows preserve columns and boundaries; seven guards joined; thirteen absent guards explicit; input order, bundle identity and missing caller fact checked",
);
