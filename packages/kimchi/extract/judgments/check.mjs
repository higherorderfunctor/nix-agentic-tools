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
  judgmentSelector,
  packet,
  requestClaimParts,
  requests,
  resolver,
  rootKey,
  schemaPrefix,
  spanId,
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
const actions = (request) => {
  const recorded = request ? "evidence summary" : "packet";
  const rows = request
    ? " Read current rows in current.json; read removed rows in the previous commit's packet artifact or use the recorded digest list and git history of the facts."
    : "";
  return {
    ANCHOR_AMBIGUOUS: `Make the structural citation unique without line offsets, then rejudge ${verdictFile}.`,
    ANCHOR_MISSING: `Inspect the source change; correct the citation only after reviewing its meaning, then rejudge ${verdictFile}.`,
    EVIDENCE_CHANGED: `Investigate every listed change, then update the claim, scope, rationale, verdict, recorded ${recorded} and evidenceHash as warranted in ${verdictFile}.${rows}`,
    FACT_INPUT: `Correct the regionRegistry producer or source pin, run nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate, then investigate and rejudge ${verdictFile}.`,
    RECORDED_HASH: `Inspect the recorded ${recorded} edit and current evidence, then deliberately update the reviewed record in ${verdictFile}.`,
    REMOVED_ROOT: `Inspect the removed evidence and remove this judgment by hand from ${verdictFile}.${rows}`,
    REQUEST_FACT_INPUT: `Correct the requestCallers producer or source pin, run nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate, then investigate and rejudge ${verdictFile}.`,
    REQUEST_LOCATION: `Align requestCallers with the pinned source using nix run .#checks.x86_64-linux.kimchi-extracted.passthru.regenerate, then inspect the candidate packets and rejudge ${verdictFile}.`,
    SOURCE_INPUT: `Correct the pinned source or structural resolver, regenerate facts if the source changed, then investigate and rejudge ${verdictFile}.`,
    UNCLASSIFIED_ROOT: `Review the candidate packet and add one scoped judgment or explicit unknown record to ${verdictFile}.`,
    VERDICT_INPUT: `Correct the verdict file at the named path in ${verdictFile} and rerun the check; a record's packet will be emitted once it is valid.`,
  };
};
const failures = [],
  current = {},
  diff = {},
  display = {},
  spans = {};
const counts = { roots: 0, supported: 0, refuted: 0, unknown: 0 };
const unavailable = {
  id: "<verdict-file>",
  claim: "<unavailable: verdict input could not be read>",
};
function fail(
  judgment,
  code,
  detail,
  old = judgment.evidenceHash ?? "unavailable",
  fresh = "unavailable",
) {
  const id = typeof judgment.id === "string" ? judgment.id : unavailable.id;
  const claim =
    typeof judgment.claim === "string"
      ? judgment.claim
      : judgment.claim &&
          requestClaimParts.every(
            (key) => typeof judgment.claim[key] === "string",
          )
        ? canonical(judgment.claim)
        : unavailable.claim;
  failures.push({
    id,
    claim,
    code,
    detail,
    old,
    fresh,
    action: actions(
      judgmentSelector(judgment)?.fact?.kind === "requestCallers",
    )[code],
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
    if (error)
      fail(judgment ?? unavailable, error.code, error.message, "unavailable");
  const valid = records
    .filter((record) => !record.error)
    .map((record) => record.judgment);
  const invalidHashes = new Set();
  for (const judgment of valid) {
    const computed = hash(canonical(judgment.evidence ?? judgment.packet));
    if (computed !== judgment.evidenceHash) {
      invalidHashes.add(judgment.id);
      fail(
        judgment,
        "RECORDED_HASH",
        `recorded ${judgment.evidence ? "evidence summary" : "packet"} hashes to ${computed}, not its recorded evidenceHash ${judgment.evidenceHash}`,
        judgment.evidenceHash,
        computed,
      );
    }
  }
  let rows, resolve, requestEvidence;
  try {
    const facts = JSON.parse(await readFile(args.facts, "utf8"));
    rows = factRows(facts);
    const ts = (await import(pathToFileURL(args.typescript).href)).default;
    resolve = resolver(
      await readFile(join(args.tree, "src/regions.ts")),
      ts,
      display,
    );
    requestEvidence = await requests(facts, args.tree, ts, display);
  } catch (error) {
    if (!(error instanceof EvidenceError)) throw error;
    for (const judgment of valid.length ? valid : [unavailable]) {
      if (!invalidHashes.has(judgment.id))
        fail(judgment, error.code, error.message);
    }
    return;
  }
  const roots = new Map(
    [
      ...new Set(
        rows.filter((row) => row.value !== "").map((row) => row.region),
      ),
    ]
      .sort()
      .map((region) => {
        const selector = {
          fact: {
            kind: "regionRegistry.fields",
            where: { field: "llmBaseUrl", region },
          },
          sources: [],
        };
        return [rootKey(selector), { selector, rows }];
      }),
  );
  for (const [key, root] of requestEvidence.roots) roots.set(key, root);
  // A malformed record only suppresses coverage for its recoverable root.
  const recordedRoots = new Set(
    records.map(({ judgment }) => rootKey(judgmentSelector(judgment))),
  );
  const candidates = [...roots]
    .filter(([key]) => !recordedRoots.has(key))
    .map(([, { selector }]) => {
      const { region, request } = selector.fact.where,
        label = request ? `request:${canonical(request)}` : region;
      return {
        id: `<unclassified:${label}>`,
        claim: request
          ? `No four-part claim is recorded for request ${canonical(request)}.`
          : `No claim is recorded for hosted gateway ${region}.`,
        packet: { selector },
      };
    });
  for (const judgment of [...valid, ...candidates]) {
    const { id, evidenceHash: old = "absent" } = judgment;
    const recorded = judgment.evidenceHash
      ? (judgment.evidence ?? judgment.packet)
      : null;
    const selector = judgmentSelector(judgment),
      root = selector.fact.where.request
        ? canonical(selector.fact.where.request)
        : selector.fact.where.region,
      request = selector.fact.kind === "requestCallers",
      key = rootKey(selector);
    if (!roots.has(key)) {
      if (!invalidHashes.has(id))
        fail(
          judgment,
          "REMOVED_ROOT",
          `removed ${request ? "request root" : "root"} ${root}: ${request ? "no requestCallers occurrence remains" : "no nonempty llmBaseUrl declaration remains"}; removed rows=${canonical(recorded.rows)}`,
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
    const result = await packet(
      selector,
      roots.get(key).rows,
      request ? requestEvidence.resolve : resolve,
    );
    current[id] = result;
    for (const span of result.evidence?.spans ?? [])
      spans[spanId(span)] = span.sha256;
    diff[id] = {
      recorded: recorded ? old : null,
      current: result.evidenceHash ?? null,
      ...differences(
        recorded,
        result.evidence ?? result.packet ?? result.incomplete,
      ),
    };
    if (invalidHashes.has(id)) continue;
    if (!recorded)
      fail(
        judgment,
        "UNCLASSIFIED_ROOT",
        `unclassified ${request ? "request root" : "root"} ${root}: ${request ? "a requestCallers occurrence" : "a nonempty llmBaseUrl declaration"} has no judgment; added rows=${canonical((result.evidence ?? result.packet ?? result.incomplete).rows)}`,
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
        (f) => `FAIL kimchi-surface-judgments [${f.code}]
Judgment: ${escapeText(f.id)}
Claim: ${escapeText(f.claim)}
Changed: ${escapeText(f.detail)}
Evidence hash: old=${f.old}; new=${f.fresh}
Packets: nix build .#checks.${args.system}.kimchi-surface-judgments.passthru.packets --out-link /tmp/kimchi-judgment-packets
Inspect: /tmp/kimchi-judgment-packets/current.json; /tmp/kimchi-judgment-packets/diff.json; /tmp/kimchi-judgment-packets/display.json
Fix: ${f.action}
A red check means: ask a session to investigate and rejudge. CI does not update verdicts or hashes.
`,
      )
      .join("")
  : `ok: kimchi-surface-judgments: ${counts.roots} roots classified; ${counts.supported} supported, ${counts.refuted} refuted, ${counts.unknown} unknown; all evidence hashes match.\n`;
await mkdir(args.out, { recursive: true });
for (const [name, value] of Object.entries({
  current,
  diff,
  display,
  spans,
  status: {
    ok: !failures.length,
    counts,
    failures: failures.map((f) => f.code),
  },
}))
  await writeFile(join(args.out, `${name}.json`), `${canonical(value)}\n`);
await writeFile(join(args.out, "diagnostics.txt"), diagnostics);
