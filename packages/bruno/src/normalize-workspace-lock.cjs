const fs = require("node:fs");
const path = require("node:path");
const semver = require(process.argv[2]);

const filename = "package-lock.json";
const lock = JSON.parse(fs.readFileSync(filename, "utf8"));
const workspaces = new Set(
  Object.values(lock.packages)
    .filter((entry) => entry.link)
    .map((entry) => entry.resolved),
);
let changed = false;

for (const workspace of workspaces) {
  const manifest = JSON.parse(
    fs.readFileSync(`${workspace}/package.json`, "utf8"),
  );
  const dependencies = {
    ...manifest.devDependencies,
    ...manifest.dependencies,
    ...manifest.optionalDependencies,
  };
  for (const [name, range] of Object.entries(dependencies)) {
    const nestedPath = `${workspace}/node_modules/${name}`;
    const nested = lock.packages[nestedPath];
    if (
      !nested?.version ||
      !semver.validRange(range) ||
      semver.satisfies(nested.version, range)
    )
      continue;

    let parent = path.dirname(workspace);
    while (true) {
      const ancestor =
        lock.packages[path.posix.join(parent, "node_modules", name)];
      if (ancestor) {
        if (ancestor.version && semver.satisfies(ancestor.version, range)) {
          delete lock.packages[nestedPath];
          console.log(
            `Removed stale ${nestedPath} (${nested.version}); ancestor ${ancestor.version} satisfies ${range}`,
          );
          changed = true;
        }
        break;
      }
      if (parent === ".") break;
      parent = path.dirname(parent);
    }
  }
}

if (changed) fs.writeFileSync(filename, `${JSON.stringify(lock, null, 2)}\n`);
