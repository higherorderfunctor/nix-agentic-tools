import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

// Adds the directories named by `chat.additionalDirectories` to a session's
// roots. `patch-session-roots.mjs` installs this module beside the KAS bundle
// and calls it where Kiro derives a session's workspace paths, where it starts
// a workflow step, and where it hands roots to the MCP configuration reader.
// Settings are read from the global `cli.json` and from the one under the
// session's cwd; both lists add to the roots the host sent. A configured root
// is membership only: it grants no write and contributes no `mcp.json`.
const setting = "chat.additionalDirectories";
const fail = (message) => {
  throw new Error(`${setting}: ${message}`);
};

// The listed paths of one settings file, absolute: relative entries resolve
// from `base`. A missing file lists nothing; a malformed one refuses the session.
function layerRoots(path, base) {
  let file;
  try {
    file = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return [];
    fail(`${path}: ${error.message}`);
  }
  const entries = file?.[setting];
  if (entries === undefined) return [];
  if (!Array.isArray(entries)) fail(`${path}: expected an array of paths`);
  return entries.map((entry) => {
    if (typeof entry !== "string" || entry === "" || entry.includes("\0"))
      fail(`${path}: expected nonempty paths without NUL`);
    return resolve(base, entry);
  });
}

// Global entries first, so the user's roots keep their place ahead of a
// repository's. Relative global entries resolve beside the global file,
// repository entries from the session's cwd.
function configuredRoots(cwd) {
  const global = join(
    process.env.KIRO_HOME || join(homedir(), ".kiro"),
    "settings",
    "cli.json",
  );
  return [
    ...layerRoots(global, dirname(global)),
    ...layerRoots(join(cwd, ".kiro", "settings", "cli.json"), cwd),
  ];
}

// The real path of the deepest existing ancestor plus the missing tail, so a
// root that does not exist yet still compares equal to its other spellings.
function canonical(path) {
  const tail = [];
  for (let at = path; ; at = dirname(at)) {
    try {
      return join(realpathSync(at), ...tail.toReversed());
    } catch (error) {
      if (error.code !== "ENOENT" && error.code !== "ENOTDIR") throw error;
    }
    if (dirname(at) === at) return path;
    tail.push(basename(at));
  }
}

// One answer per request object, because Kiro derives the same session's paths
// several times and a settings edit between two calls must not split them.
const derived = new WeakMap();

// `[cwd, ...host roots]` followed by each configured root the list does not
// already hold; the first spelling of a root wins and host roots are untouched.
export function withConfiguredRoots(request, paths) {
  if (!derived.has(request)) {
    const seen = new Set(paths.map(canonical));
    const added = [];
    for (const root of configuredRoots(paths[0])) {
      const key = canonical(root);
      if (!seen.has(key)) {
        seen.add(key);
        added.push(root);
      }
    }
    derived.set(request, [...paths, ...added]);
  }
  return derived.get(request);
}

// A session's roots minus the configured ones, except its cwd, for the MCP
// reader: a configured root is not a place to take server definitions from.
export function mcpRoots(paths) {
  if (paths.length === 0) return paths;
  const configured = new Set(configuredRoots(paths[0]).map(canonical));
  return paths.filter(
    (root, at) => at === 0 || !configured.has(canonical(root)),
  );
}

// The extra roots a workflow step may start with: those its owning session
// holds. A step whose owner is named but not loaded refuses, because its saved
// roots would otherwise stand in for the authority the owner has to give.
export function stepRoots(extras, owner, ownerPaths) {
  if (!extras?.length || owner === undefined) return extras;
  if (!ownerPaths) fail(`workflow owner ${owner} is not loaded`);
  const held = new Set(ownerPaths.map(canonical));
  return extras.filter((root) => held.has(canonical(root)));
}
