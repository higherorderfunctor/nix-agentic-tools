// Copy only the locked runtime graph. Kimchi's pi supplies the virtual packages
// inside its executable; a physical copy here would load a second pi.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

const output = path.resolve(process.argv[2]);
const virtual = new Set(JSON.parse(fs.readFileSync(process.argv[3], "utf8")));
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
const manifest = manifestAt(output);
assert(
  Array.isArray(manifest.pi?.extensions) && manifest.pi.extensions.length > 0,
);
for (const entry of manifest.pi.extensions) {
  const target = path.resolve(output, entry);
  assert(target.startsWith(output + path.sep) && fs.existsSync(target), entry);
}
for (const name of fs.readdirSync(path.join(output, "node_modules"), {
  recursive: true,
})) {
  const entry = path.join(output, "node_modules", name);
  if (fs.lstatSync(entry).isSymbolicLink())
    assert(fs.realpathSync(entry).startsWith(output + path.sep), entry);
}
