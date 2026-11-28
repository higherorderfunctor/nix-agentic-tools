import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";

// Finds the primary checkout a working directory belongs to, so `{{primary}}`
// and `{{repo}}` in prompt text mean the same thing from the primary checkout
// and from any linked worktree. Input: a directory. Output: `{ primary, repo }`
// or undefined when the directory is not inside one ordinary repository:
// non-git directories, bare repositories, separate Git directories and
// submodules have no primary checkout to name. Callers: `session-prompts.mjs`.
const exec = promisify(execFile);

async function git(directory, ...args) {
  const env = { ...process.env, GIT_NO_LAZY_FETCH: "1", LC_ALL: "C" };
  for (const name of ["GIT_COMMON_DIR", "GIT_DIR", "GIT_WORK_TREE"])
    delete env[name];
  const { stdout } = await exec("git", ["-C", directory, ...args], {
    env,
    timeout: 10000,
  });
  return stdout.replace(/\n$/, "");
}

const revParse = async (cwd, ...args) =>
  (await git(cwd, "rev-parse", ...args)).split("\n");

export async function repoRoot(cwd) {
  try {
    const [common, bare, extra] = await revParse(
      cwd,
      "--path-format=absolute",
      "--git-common-dir",
      "--is-bare-repository",
    );
    if (extra !== undefined || bare !== "false" || basename(common) !== ".git")
      return undefined;
    const commonDir = await realpath(common);
    const primary = dirname(commonDir);
    const [gitDir, top, more] = await revParse(
      cwd,
      "--absolute-git-dir",
      "--show-toplevel",
    );
    const [primaryTop] = await revParse(primary, "--show-toplevel");
    const [realGit, realTop, realPrimaryTop] = await Promise.all(
      [gitDir, top, primaryTop].map((path) => realpath(path)),
    );
    const isPrimary = realGit === commonDir && realTop === primary;
    const isLinked = dirname(realGit) === join(commonDir, "worktrees");
    return more === undefined &&
      (isPrimary || isLinked) &&
      realPrimaryTop === primary
      ? { primary, repo: basename(primary) }
      : undefined;
  } catch {
    return undefined;
  }
}

function gitOptional(cwd, ...args) {
  return git(cwd, ...args).catch((error) => {
    if (error.code !== 1) throw error;
  });
}

// Resolve a local commit for the session prompt without guessing or fetching refs.
export async function worktreeBase(cwd, mode) {
  const head = await gitOptional(cwd, "symbolic-ref", "-q", "HEAD");
  const branch = head?.match(/^refs\/heads\/(.+)$/)?.[1];
  const config = (key) =>
    branch && gitOptional(cwd, "config", "--get", `branch.${branch}.${key}`);
  let ref = "HEAD";
  if (mode === "remote-default") {
    const configured = await config("remote");
    const remotes = (await git(cwd, "remote")).split("\n");
    const fallback = remotes.includes("origin")
      ? "origin"
      : remotes.length === 1 && remotes[0];
    const remote = configured && configured !== "." ? configured : fallback;
    if (!remote || !remotes.includes(remote))
      throw new Error("Kiro: no remote for remote-default");
    ref = await gitOptional(
      cwd,
      "symbolic-ref",
      "-q",
      `refs/remotes/${remote}/HEAD`,
    );
    if (!ref) throw new Error("Kiro: missing local symbolic remote HEAD");
  } else if ((await config("merge")) !== undefined) ref = "@{upstream}";
  const oid = await gitOptional(
    cwd,
    "rev-parse",
    "-q",
    "--verify",
    `${ref}^{commit}`,
  );
  if (!oid) throw new Error(`Kiro: ${ref} does not resolve to a local commit`);
  return oid;
}

// Mustache has no escape for `{{`, so each inserted `{` is printed by swapping
// the delimiters around it: `{{=<% %>=}}` then the brace then `<%={{ }}=%>`.
const literalBrace = "{{=<% %>=}}{<%={{ }}=%>";

// One pass over authored text: inserted values are never scanned again. With
// `templated`, values stay literal through Kiro's Mustache render of the text.
export const fillPlaceholders = (text, { primary, repo }, templated = false) =>
  text.replace(/\{\{(primary|repo)\}\}/g, (_, name) => {
    const value = name === "repo" ? repo : primary;
    return templated ? value.replaceAll("{", literalBrace) : value;
  });
