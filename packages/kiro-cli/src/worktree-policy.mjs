// Admission-only discovery; workflow steps own creation and user-owned policy.
import { execFile } from "node:child_process";
import { lstat, realpath, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
const rootKey = Symbol("resolved worktree policy root");

function fail(message) {
  throw new Error(`chat.worktrees: ${message}`);
}

export function enabled(layers) {
  let result = false;
  for (const { path, value } of layers) {
    const policy = value["chat.worktrees"];
    if (policy === undefined) continue;
    if (
      !policy ||
      typeof policy !== "object" ||
      Array.isArray(policy) ||
      Object.keys(policy).join() !== "enable" ||
      typeof policy.enable !== "boolean"
    )
      fail(`${path}: expected { enable: boolean }`);
    result = policy.enable;
  }
  return result;
}

export async function discover(cwd) {
  const env = { ...process.env, LC_ALL: "C" };
  for (const key of ["GIT_COMMON_DIR", "GIT_DIR", "GIT_WORK_TREE"])
    delete env[key];
  const git = async (directory, ...args) =>
    (
      await exec("git", ["-C", directory, "rev-parse", ...args], {
        env,
        timeout: 10000,
        maxBuffer: 1024 * 1024,
      })
    ).stdout.replace(/\n$/, "");
  let discovered;
  try {
    discovered = await git(
      cwd,
      "--path-format=absolute",
      "--git-common-dir",
      "--is-bare-repository",
    );
  } catch (error) {
    if (error.code === 128 && error.stderr?.includes("not a git repository"))
      return undefined;
    fail(`cannot discover repository: ${error.message}`);
  }
  const [common, bare, ...extra] = discovered.split("\n");
  if (extra.length)
    fail("repository paths containing newlines are unsupported");
  if (bare !== "false" || basename(common) !== ".git")
    fail("expected a normal primary checkout or linked worktree");
  const commonPath = await realpath(common);
  const primary = dirname(commonPath);
  const locations = (
    await git(cwd, "--absolute-git-dir", "--show-toplevel")
  ).split("\n");
  if (locations.length !== 2)
    fail("repository paths containing newlines are unsupported");
  const [gitDir, topLevel] = await Promise.all(
    locations.map((path) => realpath(path)),
  );
  if (
    !(await stat(join(primary, ".git"))).isDirectory() ||
    (gitDir === commonPath
      ? topLevel !== primary
      : dirname(gitDir) !== join(commonPath, "worktrees")) ||
    (await realpath(await git(primary, "--show-toplevel"))) !== primary
  )
    fail("separate Git directories and bare repositories are unsupported");
  const destination = `${primary}-worktrees`;
  try {
    if ((await lstat(destination)).isSymbolicLink())
      fail(`derived destination must not be a symlink: ${destination}`);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return destination;
}

export function carry(request, root) {
  return { ...request, [rootKey]: root };
}

export function requestRoot(request) {
  return request[rootKey];
}
