const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const [normalizer, semver] = process.argv.slice(2);
const workspace = "packages/client";
const root = fs.mkdtempSync(path.join(os.tmpdir(), "bruno-lock-"));
const nestedPath = `${workspace}/node_modules/@example/parser`;
const original = {
  packages: {
    "node_modules/@example/client": { link: true, resolved: workspace },
    "node_modules/@example/parser": { version: "2.3.0" },
    [workspace]: { dependencies: { "@example/parser": "^2.0.0" } },
    [nestedPath]: { version: "1.0.0" },
    "packages/other/node_modules/@example/parser": { version: "1.0.0" },
  },
};
fs.mkdirSync(path.join(root, workspace), { recursive: true });
fs.writeFileSync(
  path.join(root, workspace, "package.json"),
  JSON.stringify({ dependencies: { "@example/parser": "^2.0.0" } }),
);
const filename = path.join(root, "package-lock.json");
const normalize = (lock) => {
  const before = `${JSON.stringify(lock, null, 2)}\n`;
  fs.writeFileSync(filename, before);
  execFileSync(process.execPath, [normalizer, semver], { cwd: root });
  return JSON.parse(fs.readFileSync(filename, "utf8"));
};

try {
  const repaired = structuredClone(original);
  delete repaired.packages[nestedPath];
  assert.deepEqual(normalize(original), repaired);
  assert.deepEqual(normalize(repaired), repaired);

  const valid = structuredClone(original);
  valid.packages[nestedPath].version = "2.1.0";
  assert.deepEqual(normalize(valid), valid);

  const missing = structuredClone(original);
  delete missing.packages["node_modules/@example/parser"];
  assert.deepEqual(normalize(missing), missing);

  const incompatible = structuredClone(original);
  incompatible.packages["node_modules/@example/parser"].version = "1.1.0";
  assert.deepEqual(normalize(incompatible), incompatible);

  const shadowed = structuredClone(original);
  shadowed.packages["packages/node_modules/@example/parser"] = {
    version: "1.2.0",
  };
  assert.deepEqual(normalize(shadowed), shadowed);

  const nearest = structuredClone(original);
  nearest.packages["packages/node_modules/@example/parser"] = {
    version: "2.2.0",
  };
  const nearestRepaired = structuredClone(nearest);
  delete nearestRepaired.packages[nestedPath];
  assert.deepEqual(normalize(nearest), nearestRepaired);

  const bytes = fs.readFileSync(filename, "utf8");
  execFileSync(process.execPath, [normalizer, semver], { cwd: root });
  assert.equal(fs.readFileSync(filename, "utf8"), bytes);
  console.log(
    "workspace lock fixtures passed (repair, valid, missing, incompatible, nearest ancestor, scoped package, idempotence)",
  );
} finally {
  fs.rmSync(root, { force: true, recursive: true });
}
