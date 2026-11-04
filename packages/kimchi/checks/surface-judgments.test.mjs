import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const flags = Object.fromEntries(
  process.argv
    .slice(2)
    .reduce(
      (pairs, arg, i, all) => (i % 2 ? pairs : [...pairs, [arg, all[i + 1]]]),
      [],
    ),
);
const scripts = flags["--scripts"] ?? resolve(here, "../extract/judgments");
const fixtures =
  flags["--fixtures"] ?? join(here, "fixtures/surface-judgments");
const read = (name) => JSON.parse(readFileSync(join(fixtures, name), "utf8"));
const verdicts = JSON.parse(
  readFileSync(
    flags["--verdicts"] ?? join(here, "../surface-judgments.json"),
    "utf8",
  ),
);
const baseline = Object.fromEntries(
  verdicts.judgments.map(({ id, packet, evidenceHash }) => [
    id,
    { packet, evidenceHash },
  ]),
);
const messages = read("expected/diagnostics.json");
for (const script of ["packet.mjs", "check.mjs"])
  assert.doesNotMatch(
    readFileSync(join(scripts, script), "utf8"),
    /child_process|node:(?:net|https?)|\bfetch\s*\(/,
    "packet scripts must not launch models or use the network",
  );
for (const test of read("cases.json")) {
  const temporary = mkdtempSync(join(tmpdir(), "kimchi-judgments-"));
  try {
    const files = {
      source: read("base/source.json"),
      facts: JSON.stringify(read("base/facts.json")),
      verdicts: JSON.stringify(verdicts),
    };
    if (test.hiddenRegion)
      files.source = `const HOSTED = { llmBaseUrl: "https://ap.example" };
const llmBaseUrl = "https://ap.example";
${files.source.replace("\tus: {", `\tap: { ${test.hiddenRegion} },\n\tus: {`)}`;
    for (const edit of test.edits ?? []) {
      assert.ok(
        files[edit.file].includes(edit.from),
        `${test.name}: fixture mutation must match`,
      );
      files[edit.file] = files[edit.file].replace(edit.from, edit.to);
    }
    if (test.reverseFacts) {
      const facts = JSON.parse(files.facts);
      facts.regionRegistry.fields.reverse();
      files.facts = JSON.stringify(facts);
    }
    if (test.unorderedArray) {
      const records = JSON.parse(files.verdicts);
      const judgment = records.judgments[0];
      const items = test.unorderedArray
        .split(".")
        .reduce((value, key) => value[key], judgment.packet);
      if (items.length === 1) {
        const extra = structuredClone(items[0]);
        if (test.unorderedArray === "rows") extra.value = "https://zz.example";
        else extra.anchor.symbol = "zzHelper";
        items.push(extra);
      }
      items.reverse();
      const { canonical, hash } = await import(
        join(resolve(scripts), "packet.mjs")
      );
      judgment.evidenceHash = hash(canonical(judgment.packet));
      files.verdicts = JSON.stringify(records);
    }
    mkdirSync(join(temporary, "src"));
    writeFileSync(
      join(temporary, "src/regions.ts"),
      test.invalidUtf8 ? Buffer.from([0xff]) : files.source,
    );
    for (const name of ["facts", "verdicts"])
      writeFileSync(join(temporary, `${name}.json`), files[name]);
    const run = (args) =>
      spawnSync(process.execPath, [join(scripts, "check.mjs"), ...args], {
        encoding: "utf8",
      });
    const out = join(temporary, "packets");
    const result = run([
      "--facts",
      join(temporary, "facts.json"),
      "--verdicts",
      join(temporary, "verdicts.json"),
      "--tree",
      temporary,
      "--typescript",
      flags["--typescript"],
      "--system",
      "x86_64-linux",
      "--out",
      out,
    ]);
    assert.equal(result.status, 0, `${test.name}: ${result.stderr}`);
    const artifacts = Object.fromEntries(
      ["current", "diff", "display", "status"].map((name) => [
        `${name}.json`,
        JSON.parse(readFileSync(join(out, `${name}.json`), "utf8")),
      ]),
    );
    assert.deepEqual(
      artifacts["status.json"].failures,
      test.codes,
      `${test.name}: rejects ${test.rejects}`,
    );
    if (test.incomplete)
      assert.ok(
        Object.values(artifacts["current.json"]).some(
          (result) => result.incomplete,
        ) &&
          Object.values(artifacts["current.json"]).every(
            (result) => !result.incomplete || !result.evidenceHash,
          ),
        `${test.name}: unresolved evidence cannot have a complete hash`,
      );
    if (test.unchanged)
      for (const [id, expected] of Object.entries(baseline))
        assert.deepEqual(
          artifacts["current.json"][id],
          expected,
          `${test.name}: rejects ${test.rejects}`,
        );
    for (const [pointer, expected] of Object.entries(test.expect ?? {}))
      assert.deepEqual(
        pointer.split("/").reduce((value, key) => value[key], artifacts),
        expected,
        test.name,
      );
    if (test.starts)
      assert.deepEqual(
        Object.values(artifacts["display.json"])
          .map((span) => span.start.line)
          .sort((a, b) => a - b),
        test.starts,
        test.name,
      );
    const diagnostics = readFileSync(join(out, "diagnostics.txt"), "utf8");
    if (messages[test.name])
      assert.equal(diagnostics, messages[test.name], test.name);
    for (const detail of test.details ?? [])
      assert.ok(
        diagnostics.includes(detail),
        `${test.name}: actionable detail ${detail}`,
      );
    for (const code of test.codes)
      assert.ok(
        diagnostics.includes(`[${code}]`),
        `${test.name}: readable failure code`,
      );
    const gate = spawnSync(
      flags["--jq"] ?? "jq",
      ["-e", ".ok", join(out, "status.json")],
      { encoding: "utf8" },
    );
    assert.equal(
      gate.status,
      test.codes.length ? 1 : 0,
      `${test.name}: mismatches must fail the shell gate predicate`,
    );
    assert.equal(
      readFileSync(join(temporary, "verdicts.json"), "utf8"),
      files.verdicts,
      `${test.name}: producer must never rewrite verdicts`,
    );
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}
console.log(
  `ok: ${read("cases.json").length} surface judgment fixtures; packets and gate preserve verdict bytes.`,
);
