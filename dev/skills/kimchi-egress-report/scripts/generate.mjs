#!/usr/bin/env node

// regenerate.sh supplies lib.extracted facts; scan.mjs owns the retained fields.
import { readFile } from "node:fs/promises";
import {
  compare,
  FACT_FIELDS,
  fail as failWith,
  parseArgs,
  SCAN_FIELDS,
  writeReport,
} from "./report.mjs";

const fail = (message) => failWith("generate.mjs", message);
const readJson = async (path) => JSON.parse(await readFile(path, "utf8"));
const site = ({ file, line }) => `${file}:${line}`;
const originFile = (origin) => origin.replace(/:\d+$/, "");
const sortedUnique = (values) => [...new Set(values)].sort(compare);

function hosts(network) {
  const byHost = new Map();
  const entry = (host) => {
    if (!byHost.has(host)) byHost.set(host, { callSites: [], files: [] });
    return byHost.get(host);
  };
  for (const callSite of network.callSites)
    for (const { host, origin } of callSite.targets) {
      if (host === null) continue;
      entry(host).callSites.push(site(callSite));
      entry(host).files.push(originFile(origin));
    }
  for (const { file, host } of network.unattributed)
    if (host !== null) entry(host).files.push(file);
  return [...byHost.entries()]
    .sort(([left], [right]) => compare(left, right))
    .map(([value, { callSites, files }]) => ({
      callSites: sortedUnique(callSites),
      files: sortedUnique(files),
      value,
    }));
}

function endpointVariables(network, variables) {
  const byName = new Map();
  for (const callSite of network.callSites)
    for (const { kind, value } of callSite.targets) {
      if (kind !== "env") continue;
      if (!variables[value])
        fail(`${value} reaches ${site(callSite)} but has no environment fact`);
      if (!byName.has(value)) byName.set(value, []);
      byName.get(value).push(site(callSite));
    }
  return [...byName.entries()]
    .sort(([left], [right]) => compare(left, right))
    .map(([name, sites]) => ({
      callSites: sortedUnique(sites),
      consumerOverridable: variables[name].consumerOverridable,
      name,
      readBy: variables[name].readBy,
    }));
}

function callSites(network) {
  const key = (row) =>
    [row.file, String(row.line).padStart(8, "0"), row.library].join("|");
  const targetKey = ({ kind, value, origin }) => `${kind}|${value}|${origin}`;
  return network.callSites
    .map((row) => ({
      ...row,
      targets: [...row.targets].sort((left, right) =>
        compare(targetKey(left), targetKey(right)),
      ),
    }))
    .sort((left, right) => compare(key(left), key(right)));
}

async function main() {
  const args = parseArgs("generate.mjs", process.argv.slice(2), {
    facts: null,
    out: "packages/kimchi/egress-report.json",
    report: "packages/kimchi/egress-report.json",
    sources: "packages/kimchi/sources.json",
  });
  const { environment, network } = await readJson(args.facts);
  const scanned = await readJson(args.report);
  const missing = Object.keys(SCAN_FIELDS).filter((name) => !(name in scanned));
  if (missing.length > 0 || !scanned.header?.scan)
    fail(`${args.report} lacks scanned fields: ${missing.join(", ")}`);
  const sources = await readJson(args.sources);

  const report = {
    ...Object.fromEntries(
      Object.keys(SCAN_FIELDS).map((name) => [name, scanned[name]]),
    ),
    header: {
      facts: {
        kimchiSourceHash: sources.extraction.kimchiSource.hash,
        kimchiVersion: sources.version,
        piVersion: sources.extraction.piPackage.version,
      },
      provenance: { ...FACT_FIELDS, ...SCAN_FIELDS },
      scan: scanned.header.scan,
    },
    endpointVariables: endpointVariables(network, environment.variables),
    hosts: hosts(network),
    networkCallSites: callSites(network),
  };
  await writeReport(args.out, report);
  console.log(
    `generate.mjs: wrote ${args.out} (${report.hosts.length} hosts, ${report.networkCallSites.length} call sites)`,
  );
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
