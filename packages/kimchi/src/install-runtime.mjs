// Materialize an installable, store-backed dependency graph for both the
// extension runtime and its project verification toolchain.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const output = path.resolve(process.argv[2]);
const configuration = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const virtual = new Set(configuration.virtualPackages || []);
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
  const dependencies = {};
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
    if (dependency) {
      const target = copyPackage(dependency);
      linkPackage(destination, name, target);
      dependencies[name] = `file:${archiveFor(target)}`;
    }
  }
  // Packed packages exclude node_modules; every edge resolves to another archive.
  manifest.dependencies = dependencies;
  delete manifest.optionalDependencies;
  delete manifest.peerDependencies;
  delete manifest.peerDependenciesMeta;
  delete manifest.devDependencies;
  fs.writeFileSync(
    path.join(destination, "package.json"),
    JSON.stringify(manifest, null, 2) + "\n",
  );
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
  // pnpm inputs are read-only; only the newly copied build output changes.
  fs.chmodSync(destination, 0o755);
  fs.chmodSync(path.join(destination, "package.json"), 0o644);
  copyDependencies(source, destination, manifestAt(source));
  return destination;
}

function archiveFor(directory) {
  return path.join(output, "tarballs", `${path.basename(directory)}.tgz`);
}

function tar(args) {
  const result = spawnSync(configuration.tarCommand, args, {
    encoding: "utf8",
  });
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
}

if (process.argv[4] === "pack") {
  // Run after fixup: native binaries and shebangs in the archives must be final.
  const directories = fs
    .readdirSync(path.join(output, "node_modules/.runtime"))
    .map((id) => path.join(output, "node_modules/.runtime", id));
  fs.mkdirSync(path.join(output, "tarballs"));
  if (!configuration.packages) directories.push(output);
  const patches = configuration.patchedSource
    ? manifestAt(configuration.patchedSource).pnpm.patchedDependencies
    : {};
  const staging = fs.mkdtempSync(path.join(tmpdir(), "kimchi-pack-"));
  try {
    for (const directory of directories) {
      const archive =
        directory === output
          ? path.join(output, "package.tgz")
          : archiveFor(directory);
      tar([
        "--sort=name",
        "--mtime=@1",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        "--exclude=./node_modules",
        ...(directory === output
          ? ["--exclude=./tarballs", "--exclude=./package.tgz"]
          : []),
        "--transform=s,^\\.,package,",
        "-czf",
        path.join(staging, "package.tgz"),
        "-C",
        directory,
        ".",
      ]);
      fs.copyFileSync(path.join(staging, "package.tgz"), archive);
      const { name, version } = manifestAt(directory);
      const patch = patches[`${name}@${version}`];
      if (!patch) continue;
      const unpacked = fs.mkdtempSync(
        path.join(tmpdir(), "kimchi-packed-patch-"),
      );
      try {
        tar(["-xzf", archive, "-C", unpacked]);
        assert.equal(
          manifestAt(path.join(unpacked, "package")).version,
          version,
        );
        // Check shipped archive bytes, not just the directory used to create them.
        // Match pnpm context whitespace while requiring every reverse hunk;
        // --check leaves archive bytes untouched and rejects pristine inputs.
        const result = spawnSync(
          configuration.gitCommand,
          ["apply", "--check", "--ignore-space-change", "--reverse"],
          {
            cwd: path.join(unpacked, "package"),
            encoding: "utf8",
            input: fs.readFileSync(
              path.join(configuration.patchedSource, patch),
            ),
          },
        );
        assert.equal(
          result.status,
          0,
          `kimchi-workflows: lost Kimchi patches for ${name}@${version}\n${result.stdout}\n${result.stderr}`,
        );
        console.log(
          `kimchi-workflows: verified all shipped patch hunks in packed ${name}@${version}`,
        );
      } finally {
        fs.rmSync(unpacked, { recursive: true, force: true });
      }
    }
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
  }
  console.log(
    `kimchi-workflows: packed ${directories.length} packages after fixup`,
  );
  process.exit(0);
}

if (configuration.packages) {
  const specs = {};
  for (const name of configuration.packages) {
    const source = resolvePackage(process.cwd(), name, false);
    const destination = copyPackage(source);
    linkPackage(output, name, destination);
    specs[name] = `file:${archiveFor(destination)}`;
  }
  fs.writeFileSync(path.join(output, "toolchain.json"), JSON.stringify(specs));
} else {
  copyDependencies(process.cwd(), output, manifestAt(process.cwd()));
}
const manifest = manifestAt(output);
assert(
  configuration.packages ||
    (Array.isArray(manifest.pi?.extensions) &&
      manifest.pi.extensions.length > 0),
);
for (const entry of manifest.pi?.extensions || []) {
  const target = path.resolve(output, entry);
  assert(target.startsWith(output + path.sep) && fs.existsSync(target), entry);
}
// Do not follow package links while walking: peer graphs can contain cycles.
function checkLinks(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const target = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) {
      assert(fs.realpathSync(target).startsWith(output + path.sep), target);
    } else if (entry.isDirectory()) {
      checkLinks(target);
    }
  }
}
checkLinks(path.join(output, "node_modules"));
