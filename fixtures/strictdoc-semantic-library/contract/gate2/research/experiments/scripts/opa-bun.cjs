const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const root = path.resolve(__dirname, "..");
const { loadPolicy } = require(
  path.join(root, "opa-bun/node_modules/@open-policy-agent/opa-wasm"),
);

(async () => {
  const start = performance.now();
  const policy = await loadPolicy(
    fs.readFileSync(path.join(root, "opa-bun/policy.wasm")),
  );
  const loadMs = performance.now() - start;
  const input = JSON.parse(
    fs.readFileSync(path.join(root, "results/neutral-input.json")),
  );
  const expected = Object.fromEntries(
    input.queries.map((q) => [q.id, q.expected]),
  );
  const times = [];
  for (let i = 0; i < 20; i++) {
    const start = performance.now();
    assert.deepEqual(policy.evaluate(input)[0].result.answers, expected);
    times.push(performance.now() - start);
  }
  input.nodes.F2.closed = false;
  assert.equal(policy.evaluate(input)[0].result.answers.blocked_interior, true);
  input.nodes.F2.closed = true;
  assert.equal(
    policy.evaluate(input)[0].result.answers.blocked_interior,
    false,
  );
  const child = JSON.parse(
    fs.readFileSync(path.join(root, "results/child-input.json")),
  );
  const childExpected = Object.fromEntries(
    child.queries.map((q) => [q.id, q.expected]),
  );
  const childAnswers = policy.evaluate(child)[0].result.answers;
  assert.deepEqual(childAnswers, childExpected);
  child.nodes.F2.closed = false;
  assert.deepEqual(policy.evaluate(child)[0].result.answers, {
    ...childExpected,
    blocked_interior: true,
    external_blocked: true,
  });
  child.nodes.F2.closed = true;
  assert.deepEqual(policy.evaluate(child)[0].result.answers, childExpected);
  input.snapshot = { id: "protected-1", records: { I0: { closed: false } } };
  input.projection = { I0: { closed: false } };
  const unchanged = policy.evaluate(input)[0].result;
  assert.deepEqual(unchanged.protected_changes, []);
  assert.equal(unchanged.snapshot, "protected-1");
  input.projection = { I0: { closed: true } };
  const changed = policy.evaluate(input)[0].result;
  assert.deepEqual(changed.protected_changes, ["I0"]);
  assert.equal(changed.snapshot, unchanged.snapshot);
  const samples = [...times];
  times.sort((a, b) => a - b);
  console.log(
    JSON.stringify(
      {
        bun: Bun.version,
        evidence_version: 2,
        sdk: "1.10.0",
        status: "pass",
        loadMs,
        twentyRunMedianMs: (times[9] + times[10]) / 2,
        twentyRunSamplesMs: samples,
        selectedChildAnswers: childAnswers,
        sameSnapshotProtection: {
          snapshot: unchanged.snapshot,
          unchanged: unchanged.protected_changes,
          changed: changed.protected_changes,
        },
        controls: [
          "same Rego compiled to Wasm",
          "ten base truth rows",
          "boundary open and close",
          "ten explicitly Child-authored hierarchy truth rows",
          "Child hierarchy boundary open and close",
          "unchanged and changed protection under same nonempty snapshot",
        ],
        limitations:
          "warm in-process evaluation, full input each time; no Scribe integration, no incremental algorithm",
      },
      null,
      2,
    ),
  );
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
