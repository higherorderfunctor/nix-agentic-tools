import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

// Adds the directories named by `chat.additionalDirectories` to a session's
// roots. `patch-session-roots.mjs` installs this module beside the KAS bundle
// and calls it where Kiro derives a session's workspace paths, where it starts
// a workflow step, where it loads a cold session, and where it hands roots to
// the MCP configuration reader.
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
// The configured identities of each array `withConfiguredRoots` returned, so the
// MCP seam learns which roots are configured from the derivation that made
// them, not from settings read again later.
const configuredOf = new WeakMap();
// Every configured identity this module has derived in this process. An array
// it did not derive (a vendor copy) is judged against this set, so a root the
// settings have since dropped stays withheld from the MCP reader.
const everConfigured = new Set();

// `[cwd, ...host roots]` followed by each configured root the list does not
// already hold; the first spelling of a root wins and host roots are untouched.
export function withConfiguredRoots(request, paths) {
  if (!derived.has(request)) {
    const configured = configuredRoots(paths[0]);
    const seen = new Set(paths.map(canonical));
    const added = [];
    for (const root of configured) {
      const key = canonical(root);
      if (!seen.has(key)) {
        seen.add(key);
        added.push(root);
      }
    }
    const roots = [...paths, ...added];
    const identities = configured.map(canonical);
    for (const key of identities) everConfigured.add(key);
    configuredOf.set(roots, new Set(identities));
    derived.set(request, roots);
  }
  return derived.get(request);
}

// A session's roots minus the configured ones, except its cwd, for the MCP
// reader: a configured root is not a place to take server definitions from.
// An array this module did not derive carries no provenance, so it fails
// closed: every root ever configured here, and every one configured now, is
// withheld.
export function mcpRoots(paths) {
  if (paths.length === 0) return paths;
  const configured =
    configuredOf.get(paths) ??
    new Set([...everConfigured, ...configuredRoots(paths[0]).map(canonical)]);
  return paths.filter(
    (root, at) => at === 0 || !configured.has(canonical(root)),
  );
}

// A workflow step's options with the roots its owner holds. The step's cwd must
// be one of them; its extra roots are kept only when the owner holds them. A
// step whose owner is absent or not loaded refuses, because its saved roots
// would otherwise stand in for the authority the owner has to give.
export function stepOptions(workspacePath, options, host) {
  const owner = options?.ownerSessionId;
  const ownerPaths =
    owner === undefined ? undefined : host.getSession(owner)?.workspacePaths;
  if (!ownerPaths) fail(`workflow owner ${owner} is not loaded`);
  const held = new Set(ownerPaths.map(canonical));
  if (typeof workspacePath !== "string" || !held.has(canonical(workspacePath)))
    fail(`workflow cwd ${workspacePath} is not held by owner ${owner}`);
  return {
    ...options,
    additionalDirectories: (options.additionalDirectories ?? []).filter(
      (root) => held.has(canonical(root)),
    ),
  };
}

// The roots an on-demand load may take from a session's saved record. Nothing
// vouches for them: a root the settings once added is saved as if a client had
// sent it, so only the cwd survives and the load derives the current
// configured roots afresh.
export const savedRoots = (paths) => paths.slice(0, 1);
