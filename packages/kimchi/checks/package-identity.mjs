// Exercise the installed PI class, including its callers, without a network or
// inference request. Pass a patched (or negative-control pristine) module path.
import assert from "node:assert/strict";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = mkdtempSync(join(tmpdir(), "kimchi-package-identity-"));
try {
  process.env.HOME = join(root, "home");
  const { DefaultPackageManager } = await import(
    pathToFileURL(resolve(process.argv[2])).href
  );
  const [userDelivery, projectDelivery] = JSON.parse(
    readFileSync(process.argv[3], "utf8"),
  );
  assert.equal(userDelivery.source, projectDelivery.source);
  const source = projectDelivery.source;
  const name = "@kimchi-dev/kimchi-workflows";
  let globalSettings = { packages: [source] };
  let projectSettings = { packages: [source] };
  let trusted = true;
  const pm = new DefaultPackageManager({
    agentDir: join(process.env.HOME, userDelivery.harnessDir),
    cwd: join(root, "project"),
    settingsManager: {
      getGlobalSettings: () => globalSettings,
      getProjectSettings: () => projectSettings,
      isProjectTrusted: () => trusted,
      setPackages: (packages) => {
        globalSettings = { packages };
      },
      setProjectPackages: (packages) => {
        projectSettings = { packages };
      },
    },
  });
  function local(scope, key, manifest) {
    const dir = join(pm.getBaseDirForScope(scope), dirname(source), key);
    mkdirSync(dir, { recursive: true });
    if (manifest !== undefined) {
      writeFileSync(
        join(dir, "package.json"),
        typeof manifest === "string" ? manifest : JSON.stringify(manifest),
      );
    }
    return { pkg: `${dirname(source)}/${key}`, scope };
  }
  assert.equal(
    pm.getBaseDirForScope("project"),
    join(pm.cwd, projectDelivery.harnessDir),
  );
  // Each module artifact is a directory of top-level links into its payload.
  // Link those exact artifacts at the paths declared by the modules.
  const payloads = [userDelivery.extension, projectDelivery.extension];
  const entries = ["user", "project"].map((scope, index) => {
    const path = join(pm.getBaseDirForScope(scope), source);
    mkdirSync(dirname(path), { recursive: true });
    symlinkSync(payloads[index], path, "dir");
    return { pkg: source, scope };
  });
  const [user, project] = entries;
  for (const order of [entries, [...entries].reverse()]) {
    assert.deepEqual(
      pm.dedupePackages(order),
      [project],
      "project package must win",
    );
  }
  for (const entry of entries) {
    assert.deepEqual(pm.dedupePackages([entry]), [entry]);
    assert.equal(pm.getPackageIdentity(entry.pkg, entry.scope), `npm:${name}`);
  }
  for (const spec of [`npm:${name}`, `npm:${name}@0.0.9`, `npm:${name}@^1`]) {
    assert.equal(pm.getPackageIdentity(spec), `npm:${name}`);
    const npmUser = { pkg: spec, scope: "user" };
    assert.deepEqual(pm.dedupePackages([npmUser, project]), [project]);
    assert.deepEqual(pm.dedupePackages([project, npmUser]), [project]);
  }
  const filtered = {
    pkg: { source: project.pkg, extensions: [] },
    scope: "project",
  };
  assert.deepEqual(pm.dedupePackages([user, filtered]), [filtered]);
  const delta = {
    pkg: { source: project.pkg, autoload: false },
    scope: "project",
  };
  assert.deepEqual(pm.dedupePackages([delta, user]), [delta, user]);
  assert.deepEqual(
    pm.findAutoloadDeltaBase(delta.pkg, "project", [delta, user]),
    {
      source: user.pkg,
      scope: "user",
    },
  );
  let packageSources;
  const resolvePackageSources = pm.resolvePackageSources.bind(pm);
  pm.resolvePackageSources = async (sources, ...args) => {
    packageSources = sources;
    return resolvePackageSources(sources, ...args);
  };
  // Count the FULL set: an auto-discovered copy must never bypass package
  // identity or Kimchi's source-based plugin toggle, even with distinct pins.
  const projectLink = join(pm.getBaseDirForScope("project"), project.pkg);
  for (const [label, target] of [
    ["same-target", payloads[0]],
    ["different-target", payloads[1]],
  ]) {
    rmSync(projectLink);
    symlinkSync(target, projectLink, "dir");
    const resolved = (await pm.resolve()).extensions;
    assert.deepEqual(packageSources, [project]);
    assert.equal(resolved.length, 1, `${label}: full resolved extension set`);
    assert.equal(resolved[0].metadata.origin, "package", label);
    assert.equal(resolved[0].metadata.scope, "project", label);
    assert.equal(resolved[0].metadata.source, project.pkg, label);
    assert.equal(resolved[0].path, join(projectLink, "index.js"), label);
    // A package exclusion must remove the only load path as well.
    projectSettings = { packages: [{ source, extensions: [] }] };
    assert.deepEqual(
      (await pm.resolve()).extensions.filter((entry) => entry.enabled),
      [],
      label,
    );
    projectSettings = { packages: [source] };
    console.log(
      `PASS: ${label}: one project extension with package source ${source}`,
    );
  }
  assert.equal(
    pm.listConfiguredPackages().length,
    2,
    "listing retains configured scopes",
  );

  const unnamed = [
    undefined,
    {},
    { name: "" },
    { name: null },
    { name: 1 },
    null,
    "{",
  ];
  for (const [index, manifest] of unnamed.entries()) {
    const pair = ["user", "project"].map((scope) =>
      local(scope, `unnamed-${index}`, manifest),
    );
    assert.deepEqual(pm.dedupePackages(pair), pair);
    for (const entry of pair) {
      assert.equal(
        pm.getPackageIdentity(entry.pkg, entry.scope),
        `local:${join(pm.getBaseDirForScope(entry.scope), entry.pkg)}`,
      );
    }
  }
  const unnamedPair = ["user", "project"].map((scope) => {
    const entry = local(scope, "unnamed-resources", {
      pi: { extensions: ["./index.js"] },
    });
    writeFileSync(
      join(pm.getBaseDirForScope(scope), entry.pkg, "index.js"),
      "export default () => {};\n",
    );
    return entry;
  });
  globalSettings = { packages: [unnamedPair[0].pkg] };
  projectSettings = { packages: [unnamedPair[1].pkg] };
  const unnamedResolved = (await pm.resolve()).extensions;
  assert.equal(unnamedResolved.length, 2, "both unnamed packages must load");
  assert.deepEqual(
    unnamedResolved.map((entry) => entry.metadata.scope).sort(),
    ["project", "user"],
  );
  assert.ok(
    unnamedResolved.every((entry) => entry.metadata.origin === "package"),
  );
  globalSettings = { packages: [source] };
  projectSettings = { packages: [source] };
  const bom = local("project", "bom", `\uFEFF${JSON.stringify({ name })}`);
  assert.equal(pm.getPackageIdentity(bom.pkg, bom.scope), `npm:${name}`);
  const different = local("project", "different", {
    name: "different-package",
  });
  assert.deepEqual(pm.dedupePackages([user, different]), [user, different]);
  for (const source of ["./missing", "./extension.js", "./unreadable"]) {
    const path = join(pm.cwd, source);
    if (source.endsWith(".js")) writeFileSync(path, "");
    if (source.endsWith("unreadable"))
      mkdirSync(join(path, "package.json"), { recursive: true });
    assert.equal(pm.getPackageIdentity(source), `local:${path}`);
  }
  assert.equal(pm.getPackageIdentity(payloads[0]), `npm:${name}`);
  assert.equal(
    pm.getPackageIdentity(relative(pm.cwd, payloads[0]), "temporary"),
    `npm:${name}`,
  );
  for (const source of [
    "git:https://github.com/example/repo.git@main",
    "git:git@github.com:example/repo.git@v1",
  ]) {
    assert.equal(pm.getPackageIdentity(source), "git:github.com/example/repo");
  }
  trusted = false;
  assert.throws(
    () => pm.getPackageIdentity(project.pkg, "project"),
    /Project is not trusted/,
  );
  trusted = true;

  // Targeted updates match by identity, but local directories never become
  // npm/git update jobs. No-source updates still enumerate configured entries.
  let updates;
  const updateConfiguredSources = pm.updateConfiguredSources.bind(pm);
  pm.updateConfiguredSources = async (sources) => {
    updates = sources;
  };
  await pm.update(payloads[0]);
  assert.deepEqual(
    updates,
    entries.map(({ pkg, scope }) => ({ source: pkg, scope })),
  );
  globalSettings = { packages: [`npm:${name}`] };
  await pm.update(payloads[0]);
  assert.deepEqual(updates, [
    { source: `npm:${name}`, scope: "user" },
    { source: project.pkg, scope: "project" },
  ]);
  await updateConfiguredSources([{ source: project.pkg, scope: "project" }]);
  pm.npmHasAvailableUpdate = async () => {
    assert.fail("shadowed npm package must not be checked");
  };
  assert.deepEqual(await pm.checkForAvailableUpdates(), []);

  // Install/remove persistence deliberately uses path matching, rather than
  // the loading identity. Removing one source cannot remove a same-name copy.
  globalSettings = { packages: [] };
  pm.addSourceToSettings(payloads[0]);
  pm.addSourceToSettings(payloads[1]);
  pm.addSourceToSettings(`npm:${name}`);
  assert.equal(globalSettings.packages.length, 3);
  assert.equal(pm.removeSourceFromSettings(payloads[0]), true);
  assert.equal(globalSettings.packages.length, 2);
  assert.equal(pm.removeSourceFromSettings(payloads[0]), false);
  console.log(
    "PASS: project wins for named local/npm packages; fallback, callers, delta and trust preserved",
  );
} finally {
  rmSync(root, { force: true, recursive: true });
}
