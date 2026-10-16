// Build-time versions and packed project specs share the installed graph.
import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";

const [mode, target, supplied, host] = process.argv.slice(2);
const read = (directory) =>
  JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
const write = (directory, manifest) =>
  fs.writeFileSync(
    path.join(directory, "package.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
const names = {
  piCodingAgent: "@earendil-works/pi-coding-agent",
  piTui: "@earendil-works/pi-tui",
  typebox: "typebox",
  typesNode: "@types/node",
  typescript: "typescript",
  vitest: "vitest",
};

if (mode === "check-pnpm") {
  const manifest = JSON.parse(fs.readFileSync(target, "utf8"));
  const requested =
    manifest.kimchiWorkflows?.packageManager ?? manifest.packageManager;
  assert.equal(
    requested?.match(/^pnpm@(\d+)\./)?.[1],
    supplied.split(".")[0],
    `kimchi-workflows: upstream pnpm major differs from supplied pnpm ${supplied}: ${requested}`,
  );
} else if (mode === "stamp") {
  const directory = path.dirname(target);
  const manifest = read(directory);
  const hostManifest = read(host);
  const require = createRequire(
    path.join(
      supplied,
      "node_modules/@earendil-works/pi-coding-agent/package.json",
    ),
  );
  const semver = require("semver");
  const versions = {};
  for (const [key, name] of Object.entries(names)) {
    const root =
      key.startsWith("pi") || key === "typebox" ? supplied : directory;
    if (root === supplied) {
      const destination = path.join(directory, "node_modules", name);
      fs.unlinkSync(destination);
      fs.symlinkSync(path.join(supplied, "node_modules", name), destination);
    }
    const version = read(path.join(root, "node_modules", name)).version;
    const range =
      (key === "typebox" ? manifest.devDependencies?.[name] : undefined) ??
      manifest.peerDependencies?.[name] ??
      manifest.dependencies?.[name];
    assert(
      !range || semver.satisfies(version, range),
      `kimchi-workflows: incompatible supplied ${name}@${version}; framework expects ${range}`,
    );
    if (name in hostManifest.dependencies) {
      assert(
        semver.satisfies(version, hostManifest.dependencies[name]),
        `kimchi-workflows: Kimchi bundled ${name} differs from supplied ${version}`,
      );
    }
    versions[key] = version;
    const section =
      key.startsWith("pi") || key === "typebox"
        ? "devDependencies"
        : "dependencies";
    manifest[section][name] = version;
  }
  assert(
    semver.gte(versions.piCodingAgent, "0.85.1"),
    "kimchi-workflows: thinking API requires bundled PI >=0.85.1",
  );
  manifest.kimchiWorkflows.toolchain = versions;
  write(directory, manifest);
  console.log(
    `kimchi-workflows: supplied toolchain ${JSON.stringify(versions)}`,
  );
} else if (mode === "installed") {
  const manifest = read(target);
  const suppliedSpecs = JSON.parse(
    fs.readFileSync(path.join(supplied, "toolchain.json"), "utf8"),
  );
  for (const [key, name] of Object.entries(names)) {
    if (key.startsWith("pi") || key === "typebox") {
      const destination = path.join(target, "node_modules", name);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.symlinkSync(path.join(supplied, "node_modules", name), destination);
      // Physical verification needs PI; the harness still supplies virtual modules.
      manifest.dependencies[name] = suppliedSpecs[name];
    }
  }
  write(target, manifest);
  const specs = { [manifest.name]: `file:${target}/package.tgz` };
  for (const name of Object.values(names))
    specs[name] = manifest.dependencies[name];
  fs.writeFileSync(
    path.join(target, "toolchain.json"),
    JSON.stringify(specs, null, 2) + "\n",
  );
} else {
  throw new Error(`kimchi-workflows: unknown toolchain stamp mode ${mode}`);
}
