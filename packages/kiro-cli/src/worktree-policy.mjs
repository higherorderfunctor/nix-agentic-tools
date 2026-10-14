// Admission-only discovery; workflow steps own creation and user-owned policy.
import { execFile } from "node:child_process";
import { lstat, realpath, stat } from "node:fs/promises";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
  sep,
} from "node:path";
import { promisify } from "node:util";

const exec = promisify(execFile);
const policyKey = Symbol("resolved worktree policy");

function fail(message) {
  throw new Error(`chat.worktrees: ${message}`);
}

export function policy(layers) {
  let result;
  for (const { path, value } of layers) {
    const policy = value["chat.worktrees"];
    if (policy === undefined) continue;
    if (
      !policy ||
      typeof policy !== "object" ||
      Array.isArray(policy) ||
      Object.keys(policy).some(
        (key) => !["enable", "location"].includes(key),
      ) ||
      typeof policy.enable !== "boolean" ||
      (policy.location !== undefined &&
        (typeof policy.location !== "string" ||
          policy.location.length === 0 ||
          policy.location.includes("\0")))
    )
      fail(`${path}: expected { enable: boolean, location?: nonempty string }`);
    // Fixed variables only; discover resolves a relative rendering against {{primary}}.
    const [unknown] = [...(policy.location ?? "").matchAll(/\{\{([^{}]*)\}\}/g)]
      .map((match) => match[1])
      .filter((name) => name !== "primary" && name !== "repo");
    if (unknown !== undefined)
      fail(`${path}: unknown location variable {{${unknown}}}`);
    result = policy;
  }
  return result?.enable
    ? { location: result.location ?? "../{{repo}}-worktrees" }
    : undefined;
}

// Layouts without a derivable primary checkout admit no root; the policy still
// selects PR guidance, without a destination.
function noRoot(cwd, reason) {
  console.warn(`chat.worktrees: ${cwd}: ${reason}; no worktree root admitted`);
  return { root: undefined };
}

export async function discover(cwd, location) {
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
    return noRoot(
      cwd,
      `cannot discover repository: ${error.stderr?.trim().split("\n")[0] || error.message}`,
    );
  }
  const [common, bare, ...extra] = discovered.split("\n");
  if (extra.length)
    return noRoot(cwd, "repository paths containing newlines are unsupported");
  if (bare !== "false" || basename(common) !== ".git")
    return noRoot(cwd, "not a normal primary checkout or linked worktree");
  const commonPath = await realpath(common);
  const primary = dirname(commonPath);
  // Follow-up probes fail inside bare and dubious repositories; degrade, never abort.
  const probe = (...args) => git(...args).catch(() => undefined);
  const locations = (
    await probe(cwd, "--absolute-git-dir", "--show-toplevel")
  )?.split("\n");
  if (locations === undefined)
    return noRoot(cwd, "cannot locate the Git directory and checkout");
  if (locations.length !== 2)
    return noRoot(cwd, "repository paths containing newlines are unsupported");
  const [gitDir, topLevel] = await Promise.all(
    locations.map((path) => realpath(path)),
  );
  const primaryTop = await probe(primary, "--show-toplevel");
  if (
    !(await stat(join(primary, ".git"))).isDirectory() ||
    (gitDir === commonPath
      ? topLevel !== primary
      : dirname(gitDir) !== join(commonPath, "worktrees")) ||
    primaryTop === undefined ||
    (await realpath(primaryTop)) !== primary
  )
    return noRoot(
      cwd,
      "submodules, separate Git directories and bare repositories are unsupported",
    );
  const destination = resolve(
    primary,
    location.replace(/\{\{(primary|repo)\}\}/g, (_, name) =>
      name === "repo" ? basename(primary) : primary,
    ),
  );
  // A root at or above the checkout would make the checkout itself writable.
  const inside = relative(destination, primary);
  if (inside !== ".." && !inside.startsWith(`..${sep}`) && !isAbsolute(inside))
    fail(`location must not cover the primary checkout: ${destination}`);
  try {
    if ((await lstat(destination)).isSymbolicLink())
      fail(`derived destination must not be a symlink: ${destination}`);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  return { root: destination };
}

// One derivation for admission, the write grant and owner-less snapshots.
export async function admit(layers, cwd) {
  const enabled = policy(layers);
  return enabled ? discover(cwd, enabled.location) : undefined;
}

export function carry(request, worktree) {
  return { ...request, [policyKey]: worktree };
}

export function requestPolicy(request) {
  return request[policyKey];
}
