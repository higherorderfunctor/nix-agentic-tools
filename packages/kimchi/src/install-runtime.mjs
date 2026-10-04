// Copy only the locked runtime graph. Pi supplies these peers as virtual modules
// inside Kimchi's executable; shipping physical copies defeats that contract.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const output = path.resolve(process.argv[2]);
const virtual = new Set([
  "@earendil-works/pi-agent-core",
  "@earendil-works/pi-ai",
  "@earendil-works/pi-coding-agent",
  "@earendil-works/pi-tui",
  "typebox",
]);
const copied = new Map();
const manifestAt = (directory) =>
  JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));

function resolvePackage(directory, name, optional) {
  for (let parent = directory; ; parent = path.dirname(parent)) {
    const candidate = path.join(parent, "node_modules", name);
    if (fs.existsSync(candidate)) return fs.realpathSync(candidate);
    if (parent === path.dirname(parent)) break;
  }
  assert(
    optional,
    `Missing locked runtime dependency ${name} from ${directory}`,
  );
  return null;
}

function linkPackage(directory, name, target) {
  const link = path.join(directory, "node_modules", name);
  fs.mkdirSync(path.dirname(link), { recursive: true });
  fs.symlinkSync(path.relative(path.dirname(link), target), link);
}

function copyDependencies(source, destination, manifest) {
  const optional = manifest.optionalDependencies || {};
  const names = new Set([
    ...Object.keys(manifest.dependencies || {}),
    ...Object.keys(optional),
    ...Object.keys(manifest.peerDependencies || {}),
  ]);
  for (const name of [...names].sort()) {
    if (virtual.has(name)) continue;
    const dependency = resolvePackage(
      source,
      name,
      name in optional || manifest.peerDependenciesMeta?.[name]?.optional,
    );
    if (dependency) linkPackage(destination, name, copyPackage(dependency));
  }
}

function copyPackage(source) {
  if (copied.has(source)) return copied.get(source);
  const id = createHash("sha256")
    .update(path.relative(process.cwd(), source))
    .digest("hex")
    .slice(0, 20);
  const destination = path.join(output, "node_modules", ".runtime", id);
  copied.set(source, destination);
  fs.cpSync(source, destination, {
    recursive: true,
    filter: (entry) => entry !== path.join(source, "node_modules"),
  });
  copyDependencies(source, destination, manifestAt(source));
  return destination;
}

copyDependencies(process.cwd(), output, manifestAt(process.cwd()));
// The extension entry, distribution and manifest remain package-relative.
const manifest = manifestAt(output);
assert.deepEqual(manifest.pi.extensions, ["./src/host/extension.ts"]);
for (const name of virtual) {
  assert(!fs.existsSync(path.join(output, "node_modules", name)));
}
