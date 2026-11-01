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
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const root = mkdtempSync(join(tmpdir(), "kimchi-package-warnings-"));
try {
  process.env.HOME = join(root, "home");
  const loaderUrl = pathToFileURL(resolve(process.argv[2]));
  const { DefaultResourceLoader } = await import(loaderUrl.href);
  const { CONFIG_DIR_NAME } = await import(new URL("../config.js", loaderUrl));
  const [user, project] = JSON.parse(readFileSync(process.argv[3], "utf8"));
  const cwd = join(root, "project");
  const agentDir = join(process.env.HOME, user.harnessDir);
  const projectDir = join(cwd, project.harnessDir);
  assert.equal(projectDir, join(cwd, CONFIG_DIR_NAME));
  for (const [delivery, base] of [
    [user, agentDir],
    [project, projectDir],
  ]) {
    const path = join(base, delivery.source);
    mkdirSync(dirname(path), { recursive: true });
    symlinkSync(delivery.extension, path, "dir");
    writeFileSync(
      join(base, "settings.json"),
      JSON.stringify({
        packages: [
          delivery.source,
          ...(delivery === user ? ["./packages/retained"] : []),
        ],
      }),
    );
  }
  const retained = join(agentDir, "packages/retained");
  mkdirSync(retained, { recursive: true });
  writeFileSync(
    join(retained, "package.json"),
    JSON.stringify({
      dependencies: { typebox: "*" },
      name: "retained-user-package",
      pi: { extensions: ["./index.js"] },
    }),
  );
  writeFileSync(join(retained, "index.js"), "export default () => {};\n");
  const userPath = join(agentDir, user.source, "index.js");
  const projectPath = join(projectDir, project.source, "index.js");
  const retainedPath = join(retained, "index.js");
  for (const trust of [true, false, undefined]) {
    const loader = new DefaultResourceLoader({
      agentDir,
      cwd,
      noContextFiles: true,
      noPromptTemplates: true,
      noSkills: true,
      noThemes: true,
    });
    const retainedWarning = {
      path: retainedPath,
      warning: "preloaded warning",
    };
    await loader.reload(
      trust === undefined
        ? undefined
        : {
            resolveProjectTrust: ({ extensionsResult }) => {
              assert.deepEqual(extensionsResult.errors, []);
              assert.ok(
                extensionsResult.extensions.some(
                  (ext) => ext.path === userPath,
                ),
              );
              assert.ok(
                extensionsResult.extensions.every(
                  (ext) => ext.path !== projectPath,
                ),
              );
              // Supply a non-package diagnostic from the surviving preloaded
              // extension; final loading must retain it.
              extensionsResult.warnings.push(retainedWarning);
              return trust;
            },
          },
    );
    const result = loader.getExtensions();
    assert.deepEqual(result.errors, []);
    const selectedPath = trust === false ? userPath : projectPath;
    assert.deepEqual(
      result.extensions.map((ext) => ext.path).sort(),
      [retainedPath, selectedPath].sort(),
    );
    assert.deepEqual(
      result.warnings
        .filter((entry) => entry.path.endsWith("/package.json"))
        .map((entry) => entry.path)
        .sort(),
      [
        join(retained, "package.json"),
        join(dirname(selectedPath), "package.json"),
      ].sort(),
      "only final packages may warn",
    );
    assert.deepEqual(
      result.warnings.filter((entry) => !entry.path.endsWith("/package.json")),
      trust === undefined ? [] : [retainedWarning],
      "surviving preloaded non-package warnings must remain",
    );
    console.log(
      `PASS: trust=${trust}: only final packages warn; retained warning preserved`,
    );
  }
} finally {
  rmSync(root, { force: true, recursive: true });
}
