import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";
import {
  canonical,
  differences,
  EvidenceError,
  escapeText,
  factRows,
  hash,
  packet,
  resolver,
  schemaPrefix,
  verdicts,
} from "./packet.mjs";

const { values: args } = parseArgs({
  options: Object.fromEntries(
    ["facts", "out", "system", "tree", "typescript", "verdicts"].map((key) => [
      key,
      { type: "string" },
    ]),
  ),
});
const verdictFile = "packages/kimchi/surface-judgments.json";
const actions = {
  ANCHOR_AMBIGUOUS: `Make the structural citation unique without line offsets, then rejudge ${verdictFile}.`,
  ANCHOR_MISSING: `Inspect the source change; correct the citation only after reviewing its meaning, then rejudge ${verdictFile}.`,
  EVIDENCE_CHANGED: `Investigate every listed change, then update the claim, scope, rationale, verdict, recorded packet and evidenceHash as warranted in ${verdictFile}.`,
  FACT_INPUT: `Correct the regionRegistry producer or source pin, run nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate, then investigate and rejudge ${verdictFile}.`,
  RECORDED_HASH: `Inspect the recorded packet edit and current evidence, then deliberately update the reviewed record in ${verdictFile}.`,
  REMOVED_ROOT: `Inspect the removed evidence and remove this judgment by hand from ${verdictFile}.`,
  SOURCE_INPUT: `Correct the pinned source or structural resolver, regenerate facts if the source changed, then investigate and rejudge ${verdictFile}.`,
  UNCLASSIFIED_ROOT: `Review the candidate packet and add one scoped judgment or explicit unknown record to ${verdictFile}.`,
  VERDICT_INPUT: `Correct the named input in ${verdictFile}, inspect the emitted evidence, and rerun the check.`,
};
const failures = [],
  current = {},
  diff = {},
  display = {};
const counts = { roots: 0, supported: 0, refuted: 0, unknown: 0 };
const unavailable = {
  id: "<verdict-file>",
  claim: "<unavailable: verdict input could not be read>",
};
function fail(
  judgment,
  code,
  detail,
  old = judgment.evidenceHash,
  fresh = "unavailable",
) {
  const id = typeof judgment.id === "string" ? judgment.id : unavailable.id;
  const claim =
    typeof judgment.claim === "string" ? judgment.claim : unavailable.claim;
  failures.push({
    id,
    claim,
    code,
    detail,
    old,
    fresh,
  });
}
async function json(path) {
  const text = await readFile(path, "utf8");
  try {
    return JSON.parse(text);
  } catch (error) {
    if (!(error instanceof SyntaxError)) throw error;
    throw new EvidenceError(
      "VERDICT_INPUT",
      `${schemaPrefix("VERDICT_INPUT")}: invalid JSON`,
    );
  }
}
async function evaluate() {
  let records;
  try {
    records = verdicts(await json(args.verdicts));
  } catch (error) {
    if (!(error instanceof EvidenceError)) throw error;
    fail(unavailable, error.code, error.message);
    return;
  }
  for (const { judgment, error } of records)
    if (error) fail(judgment ?? unavailable, error.code, error.message);
  const valid = records
    .filter((record) => !record.error)
    .map((record) => record.judgment);
  const invalidHashes = new Set();
  for (const judgment of valid) {
    const computed = hash(canonical(judgment.packet));
    if (computed !== judgment.evidenceHash) {
      invalidHashes.add(judgment.id);
      fail(
        judgment,
        "RECORDED_HASH",
        `recorded packet hashes to ${computed}, not its recorded evidenceHash ${judgment.evidenceHash}`,
        judgment.evidenceHash,
        computed,
      );
    }
  }
  let rows, resolve;
  try {
    rows = factRows(JSON.parse(await readFile(args.facts, "utf8")));
    const ts = (await import(pathToFileURL(args.typescript).href)).default;
    resolve = resolver(
      await readFile(join(args.tree, "src/regions.ts")),
      ts,
      display,
    );
  } catch (error) {
    if (!(error instanceof EvidenceError)) throw error;
    for (const judgment of valid.length ? valid : [unavailable]) {
      if (!invalidHashes.has(judgment.id))
        fail(judgment, error.code, error.message);
    }
    return;
  }
  const roots = [
    ...new Set(rows.filter((row) => row.value !== "").map((row) => row.region)),
  ].sort();
  // A malformed record only suppresses coverage for its recoverable root.
  const recordedRoots = new Set(
    records.map(
      ({ judgment }) => judgment?.packet?.selector?.fact?.where?.region,
    ),
  );
  const candidates = roots
    .filter((root) => !recordedRoots.has(root))
    .map((region) => ({
      id: `<unclassified:${region}>`,
      claim: `No claim is recorded for hosted gateway ${region}.`,
      packet: {
        selector: {
          fact: {
            kind: "regionRegistry.fields",
            where: { field: "llmBaseUrl", region },
          },
          sources: [],
        },
      },
    }));
  for (const judgment of [...valid, ...candidates]) {
    const { id, evidenceHash: old = "absent" } = judgment;
    const recorded = judgment.evidenceHash ? judgment.packet : null;
    const selector = judgment.packet.selector,
      root = selector.fact.where.region;
    if (!roots.includes(root)) {
      if (!invalidHashes.has(id))
        fail(
          judgment,
          "REMOVED_ROOT",
          `removed root ${root}: no nonempty llmBaseUrl declaration remains; removed rows=${canonical(recorded.rows)}`,
          old,
          "absent",
        );
      diff[id] = {
        recorded: old,
        current: null,
        ...differences(recorded, null),
      };
      current[id] = { absent: true };
      continue;
    }
    if (recorded && !invalidHashes.has(id)) {
      counts.roots++;
      counts[judgment.verdict]++;
    }
    const result = packet(selector, rows, resolve);
    current[id] = result;
    diff[id] = {
      recorded: recorded ? old : null,
      current: result.evidenceHash ?? null,
      ...differences(recorded, result.packet ?? result.incomplete),
    };
    if (invalidHashes.has(id)) continue;
    if (!recorded)
      fail(
        judgment,
        "UNCLASSIFIED_ROOT",
        `unclassified root ${root}: a nonempty llmBaseUrl declaration has no judgment; added rows=${canonical((result.packet ?? result.incomplete).rows)}`,
        old,
        result.evidenceHash ?? "unresolved",
      );
    if (result.incomplete) {
      for (const error of result.incomplete.errors) {
        let detail = error.detail;
        if (error.code.startsWith("ANCHOR_")) {
          const citation = recorded?.spans.find(
            (span) =>
              canonical({ path: span?.path, anchor: span?.anchor }) ===
              canonical(error.citation),
          );
          detail += `; span old=${citation?.sha256 ?? "absent"}; new=unresolved`;
        }
        fail(judgment, error.code, detail, old, "unresolved");
      }
    } else if (recorded && result.evidenceHash !== old) {
      const changes = diff[id];
      fail(
        judgment,
        "EVIDENCE_CHANGED",
        `selected evidence changed: rows removed=${canonical(changes.rows.removed)}; rows added=${canonical(changes.rows.added)}; spans=${canonical(changes.spans)}`,
        old,
        result.evidenceHash,
      );
    }
  }
}
await evaluate();
const compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
failures.sort((a, b) => compare(a.id, b.id) || compare(a.code, b.code));
const diagnostics = failures.length
  ? failures
      .map(
        (f) => `FAIL kimchi-surface-judgments [${escapeText(f.code)}]
Judgment: ${escapeText(f.id)}
Claim: ${escapeText(f.claim)}
Changed: ${escapeText(f.detail)}
Evidence hash: old=${escapeText(f.old, "hash")}; new=${escapeText(f.fresh, "hash")}
Packets: nix build .#checks.${escapeText(args.system)}.kimchi-surface-judgments.passthru.packets --out-link /tmp/kimchi-judgment-packets
Inspect: /tmp/kimchi-judgment-packets/current.json; /tmp/kimchi-judgment-packets/diff.json; /tmp/kimchi-judgment-packets/display.json
Fix: ${escapeText(actions[f.code])}
A red check means: ask a session to investigate and rejudge. CI does not update verdicts or hashes.
`,
      )
      .join("")
  : `ok: kimchi-surface-judgments: ${escapeText(String(counts.roots))} roots classified; ${escapeText(String(counts.supported))} supported, ${escapeText(String(counts.refuted))} refuted, ${escapeText(String(counts.unknown))} unknown; all evidence hashes match.\n`;
await mkdir(args.out, { recursive: true });
for (const [name, value] of Object.entries({
  current,
  diff,
  display,
  status: {
    ok: !failures.length,
    counts,
    failures: failures.map((f) => f.code),
  },
}))
  await writeFile(join(args.out, `${name}.json`), `${canonical(value)}\n`);
await writeFile(join(args.out, "diagnostics.txt"), diagnostics);
