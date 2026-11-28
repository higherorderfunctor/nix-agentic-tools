import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";

// Local Git queries for the checkout and base used by `session-prompts.mjs`.
const exec = promisify(execFile);
const timeout = 10000;
let localEnvNames;

async function git(directory, ...args) {
  // Git can list these names without opening a repository or reading its config.
  localEnvNames ??= (
    await exec("git", ["rev-parse", "--local-env-vars"], {
      timeout,
    })
  ).stdout
    .trim()
    .split("\n");
  const env = { ...process.env };
  for (const name of [
    ...localEnvNames,
    "GIT_CEILING_DIRECTORIES",
    "GIT_NAMESPACE",
  ])
    delete env[name];
  const { stdout } = await exec("git", ["-C", directory, ...args], {
    env: { ...env, GIT_NO_LAZY_FETCH: "1", LC_ALL: "C" },
    timeout,
  });
  return stdout.replace(/\n$/, "");
}

const revParse = async (cwd, ...args) =>
  (await git(cwd, "rev-parse", ...args)).split("\n");

// Map a directory in a primary checkout or linked worktree to `{ primary, repo }`.
// Non-Git directories, bare repos, separate Git dirs and submodules have no result.
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

// A quiet lookup's exit status 1 means no value; other Git errors still fail.
function gitOptional(cwd, ...args) {
  return git(cwd, ...args).catch((error) => {
    if (error.code !== 1) throw error;
  });
}

// Resolve the session directory's base for the given mode, without fetching.
// Returns a local `{ oid }` or `{ reason }` for an unresolvable ref.
export async function worktreeBase(cwd, mode) {
  const head = await gitOptional(cwd, "symbolic-ref", "-q", "HEAD");
  const branch = head?.match(/^refs\/heads\/(.+)$/)?.[1];
  const config = (key) =>
    branch && gitOptional(cwd, "config", "--get", `branch.${branch}.${key}`);
  let ref = "HEAD";
  if (mode === "remote-default") {
    const configured = await config("remote");
    const remotes = (await git(cwd, "remote")).split("\n");
    if (configured && configured !== "." && !remotes.includes(configured))
      return { reason: "the configured branch remote does not exist" };
    const fallback = remotes.includes("origin")
      ? "origin"
      : remotes.length === 1 && remotes[0];
    const remote = configured && configured !== "." ? configured : fallback;
    if (!remote)
      return { reason: "no remote can be selected for remote-default" };
    ref = await gitOptional(
      cwd,
      "symbolic-ref",
      "-q",
      `refs/remotes/${remote}/HEAD`,
    );
    if (!ref) return { reason: "missing local symbolic remote HEAD" };
  } else if ((await config("merge")) !== undefined) ref = "@{upstream}";
  const oid = await gitOptional(
    cwd,
    "rev-parse",
    "-q",
    "--verify",
    `${ref}^{commit}`,
  );
  return oid
    ? { oid }
    : { reason: `${ref} does not resolve to a local commit` };
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
