// Relative permission rules apply in every admitted root; built-in modes and
// bundled profiles thereby get the vendor default fs_read ./** allow there.
import { isAbsolute, relative, resolve, sep } from "node:path";
import { settingsLayers } from "./session-settings.mjs";
import * as worktrees from "./worktree-policy.mjs";

const authority = Symbol("host workspace roots");
const metadataKey = "nixWorkspaceRoots";

function fail(message) {
  throw new Error(`chat.additionalDirectories: ${message}`);
}

export async function resolveRequest(
  homeDir,
  request,
  roots,
  workspaceTrusted,
) {
  // roots comes from the vendor validator, retaining protocol failures.
  const candidates = [...roots];
  const layers = await settingsLayers(homeDir, request.cwd);
  const worktree = await worktrees.admit(layers, request.cwd, workspaceTrusted);
  for (const { path, base, value } of layers) {
    const entries = value["chat.additionalDirectories"];
    if (entries === undefined) continue;
    if (!Array.isArray(entries)) fail(`${path}: expected an array of paths`);
    for (const entry of entries) {
      if (
        typeof entry !== "string" ||
        entry.length === 0 ||
        entry.includes("\0")
      )
        fail(`${path}: expected nonempty paths without NUL`);
      candidates.push(
        isAbsolute(entry) ? resolve(entry) : resolve(base, entry),
      );
    }
  }
  if (worktree?.root) candidates.push(worktree.root);
  const seen = new Set(),
    unique = [];
  for (const root of candidates) {
    const key = await worktrees.canonical(root);
    if (!seen.has(key)) {
      seen.add(key);
      unique.push(root);
    }
  }
  return worktrees.carry(
    {
      ...request,
      additionalDirectories: unique.slice(1),
      [authority]: Object.freeze({
        version: 1,
        protocol: Object.freeze([...roots]),
      }),
    },
    worktree,
  );
}

// Membership alone leaves writes prompting. Only the admitted policy root is
// writable; generic configured roots keep the vendor default.
export async function writableRoot(homeDir, roots, workspaceTrusted) {
  if (!roots.length) return undefined;
  const root = (
    await worktrees.admit(
      await settingsLayers(homeDir, roots[0]),
      roots[0],
      workspaceTrusted,
    )
  )?.root;
  if (!root) return undefined;
  const key = await worktrees.canonical(root);
  for (const candidate of roots)
    if ((await worktrees.canonical(candidate)) === key) return candidate;
}

export async function residentRequest(request, resident) {
  // A join must use the same identity as the already-constructed tools/policy.
  if (
    resident.workspacePaths.length &&
    (await worktrees.canonical(request.cwd)) !==
      (await worktrees.canonical(resident.workspacePaths[0]))
  )
    fail("resident session has a different working directory");
  return {
    ...request,
    additionalDirectories: resident.workspacePaths.slice(1),
    [authority]: resident.nixWorkspaceRoots,
  };
}

export function requestAuthority(request) {
  return request[authority];
}

function validate(value) {
  if (
    !value ||
    value.version !== 1 ||
    !["owner,protocol,version", "protocol,version"].includes(
      Object.keys(value).sort().join(),
    ) ||
    (value.owner !== undefined &&
      (typeof value.owner !== "string" || value.owner.length === 0)) ||
    !Array.isArray(value.protocol) ||
    value.protocol.some(
      (path) =>
        typeof path !== "string" || !isAbsolute(path) || path.includes("\0"),
    )
  )
    fail("invalid persisted host roots");
  return {
    version: 1,
    protocol: [...value.protocol],
    ...(value.owner === undefined ? {} : { owner: value.owner }),
  };
}

export function storedAuthority(metadata) {
  // Before this extension, every saved root was supplied by the protocol.
  return validate(
    metadata?._meta?.kiro?.[metadataKey] === undefined
      ? {
          version: 1,
          protocol: metadata.workspacePaths,
        }
      : metadata._meta.kiro[metadataKey],
  );
}

export function stripAuthority(meta) {
  if (!meta?.kiro || !Object.hasOwn(meta.kiro, metadataKey)) return meta;
  const kiro = { ...meta.kiro };
  delete kiro[metadataKey];
  return { ...meta, kiro };
}

export function authorityMetadata(meta, value) {
  const clean = stripAuthority(meta);
  return { ...clean, kiro: { ...clean?.kiro, [metadataKey]: validate(value) } };
}

export async function ownerRoots(
  agent,
  owner,
  visited = new Set(),
  childRoots,
) {
  if (!owner) fail("workflow has no owning session");
  if (visited.has(owner)) fail("cyclic persisted workspace ownership");
  visited.add(owner);
  const resident = agent.sessionState(owner);
  if (resident) return resident.workspacePaths;
  const metadata = await agent.persistence.loadSessionMetadata(owner);
  if (!metadata) {
    if (!childRoots?.length) fail(`workflow owner ${owner} is unavailable`);
    // Vendor eviction may remove an owner first. Reauthorize its child from cwd;
    // saved configured roots must not become protocol authority after revocation.
    const request = await resolveRequest(
      agent.homeDir,
      { cwd: childRoots[0] },
      [childRoots[0]],
      agent.workspaceTrusted,
    );
    return [request.cwd, ...request.additionalDirectories];
  }
  const { owner: parent, protocol } = storedAuthority(metadata);
  if (parent) {
    await validateSubset(
      await ownerRoots(agent, parent, visited, protocol),
      protocol,
    );
    return protocol;
  }
  if (protocol.length === 0) return [];
  const request = await resolveRequest(
    agent.homeDir,
    { cwd: protocol[0] },
    protocol,
    agent.workspaceTrusted,
  );
  return [request.cwd, ...request.additionalDirectories];
}

async function validateSubset(allowedRoots, roots) {
  const allowed = await Promise.all(allowedRoots.map(worktrees.canonical));
  for (const root of roots) {
    const candidate = await worktrees.canonical(root);
    if (
      !allowed.some((base) => {
        const suffix = relative(base, candidate);
        return (
          suffix !== ".." &&
          !suffix.startsWith(`..${sep}`) &&
          !isAbsolute(suffix)
        );
      })
    )
      fail(`workflow root is no longer authorized by its owner: ${root}`);
  }
}

export async function validateWorkflowRoots(agent, owner, roots) {
  await validateSubset(await ownerRoots(agent, owner, new Set(), roots), roots);
}

// Only internal callers set this option. Saved effective roots are never fresh
// ACP host authority. Workflow children follow their owner at cold hydration.
export async function workflowRequest(agent, request, owner, roots) {
  await validateWorkflowRoots(agent, owner, roots);
  return {
    ...request,
    [authority]: { version: 1, protocol: [...roots], owner },
  };
}

export async function restoreRequest(agent, request) {
  const metadata = await agent.persistence.loadSessionMetadata(
    request.sessionId,
  );
  if (!metadata) fail(`saved session ${request.sessionId} is unavailable`);
  const saved = storedAuthority(metadata);
  if (saved.owner) {
    await validateSubset(await ownerRoots(agent, request.sessionId), [
      request.cwd,
      ...(request.additionalDirectories ?? []),
    ]);
    return { ...request, [authority]: saved };
  }
  const { protocol } = storedAuthority(metadata);
  if (protocol.length === 0)
    return {
      ...request,
      additionalDirectories: [],
      [authority]: { version: 1, protocol: [] },
    };
  return resolveRequest(
    agent.homeDir,
    { ...request, cwd: protocol[0], additionalDirectories: protocol.slice(1) },
    protocol,
    agent.workspaceTrusted,
  );
}

export function forkAuthority(request, metadata) {
  return request.cwd != null
    ? validate({
        version: 1,
        protocol: [request.cwd, ...(request.additionalDirectories ?? [])],
      })
    : storedAuthority(metadata);
}
