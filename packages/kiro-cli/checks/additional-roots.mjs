// Execute actual packaged vendor policy, tools, workflow evaluator and admission
// methods, cutting only auth/server startup at a unique top-level AST boundary.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

const [server, typescript, dependencies] = process.argv.slice(2);
const ts = createRequire(import.meta.url)(typescript);
const source = await fs.readFile(server, "utf8");
const ast = ts.createSourceFile(
  server,
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);
assert.equal(ast.parseDiagnostics.length, 0);
const nodes = [];
function visit(n) {
  nodes.push(n);
  ts.forEachChild(n, visit);
}
visit(ast);
function unique(predicate) {
  const matches = nodes.filter(predicate);
  assert.equal(matches.length, 1, "unique vendor AST anchor");
  return matches[0];
}
const cut = unique(
  (n) =>
    ts.isVariableStatement(n) &&
    n.parent === ast &&
    n.declarationList.declarations.some((d) => d.name.getText(ast) === "mxl"),
);
const admitted = unique(
  (n) =>
    ts.isMethodDeclaration(n) && n.name.getText(ast) === "newSessionAdmitted",
);
assert.ok(ts.isVariableDeclaration(admitted.parent.parent));
const agentName = admitted.parent.parent.name.getText(ast);
const registryBuilder = unique(
  (n) =>
    ts.isPropertyAssignment(n) &&
    n.name.getText(ast) === "buildRegistryForRoots" &&
    ts.isArrowFunction(n.initializer) &&
    ts.isBlock(n.initializer.body),
);
const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "kiro-additional-roots-"));
const previousHome = process.env.KIRO_HOME;
try {
  await fs.symlink(dependencies, path.join(tmp, "node_modules"));
  for (const name of [
    "additional-roots.mjs",
    "prompt-files.mjs",
    "session-settings.mjs",
    "worktree-policy.mjs",
    "prompt-defaults",
  ])
    await fs.symlink(
      path.join(path.dirname(server), name),
      path.join(tmp, name),
    );
  await fs.writeFile(
    path.join(tmp, "vendor.mjs"),
    source.slice(0, cut.getStart(ast)) +
      `\nexport {fqe,h5,Xjc,mB,M$t,h0o,oPt,yce,ho,$qr,Uke,T9r,m9o,S8e,${agentName} as Agent};\nexport function workflowRegistry(roots, owner) { return (${registryBuilder.initializer.getText(ast)})(roots, owner); }\n`,
  );
  const vendor = await import(pathToFileURL(path.join(tmp, "vendor.mjs")));
  const {
    fqe,
    h5,
    Xjc,
    mB,
    M$t,
    h0o,
    oPt,
    yce,
    ho,
    $qr,
    Uke,
    Agent,
    m9o,
    S8e,
  } = vendor;
  const rootsApi = await import(
    pathToFileURL(path.join(tmp, "additional-roots.mjs"))
  );
  const home = path.join(tmp, "home"),
    global = path.join(tmp, "kiro"),
    a = path.join(tmp, "a"),
    b = path.join(tmp, "b");
  for (const dir of [
    home,
    path.join(global, "settings"),
    path.join(a, ".kiro/settings"),
    path.join(b, ".kiro/settings"),
    path.join(tmp, "protocol"),
    path.join(tmp, "global-root"),
  ])
    await fs.mkdir(dir, { recursive: true });
  process.env.KIRO_HOME = global;
  const globalFile = path.join(global, "settings/cli.json");
  const repoFile = (cwd) => path.join(cwd, ".kiro/settings/cli.json");
  const settings = (file, roots) =>
    fs.writeFile(file, JSON.stringify({ "chat.additionalDirectories": roots }));
  const resolve = (request) =>
    rootsApi.resolveRequest(home, request, Uke(request, false));
  await settings(globalFile, ["../../global-root"]);
  await settings(repoFile(a), [
    "../a-extra",
    "../global-root",
    "../a-extra/nested",
  ]);
  await settings(repoFile(b), ["../b-extra"]);
  await fs.symlink(path.join(tmp, "global-root"), path.join(tmp, "alias"));
  const protocol = path.join(tmp, "protocol") + "/";
  const [ra, rb] = await Promise.all([
    resolve({
      cwd: a,
      additionalDirectories: [protocol, path.join(tmp, "alias")],
    }),
    resolve({ cwd: b }),
  ]);
  assert.deepEqual(Uke(ra, false), [
    a,
    protocol,
    path.join(tmp, "alias"),
    path.join(tmp, "a-extra"),
    path.join(tmp, "a-extra/nested"),
  ]);
  assert.deepEqual(Uke(rb, false), [
    b,
    path.join(tmp, "global-root"),
    path.join(tmp, "b-extra"),
  ]);
  await assert.rejects(fs.stat(path.join(tmp, "a-extra")), { code: "ENOENT" });
  assert.equal(ra.cwd, a);
  for (const invalid of [null, "x", [""], [null], ["bad\0path"]]) {
    await settings(repoFile(a), invalid);
    await assert.rejects(resolve({ cwd: a }), /chat.additionalDirectories/);
  }
  await settings(repoFile(a), ["../a-extra"]);
  assert.throws(() => resolve({ cwd: a, additionalDirectories: ["relative"] }));

  // Execute actual public admission up to the persistence boundary. These host
  // callbacks capture its inputs; they do not duplicate the root carrier logic.
  const stop = new Error("captured persistence lookup");
  let observed, resident;
  const host = {
    homeDir: home,
    initPromise: Promise.resolve(),
    sessions: new Map(),
    kickoffModelRefresh() {},
    sessionState() {
      return resident;
    },
    resolveNewSessionPlacement() {
      return {};
    },
    resolveBackendUserAgentGate() {
      return Promise.resolve();
    },
    resolveExecutionContext() {
      return { kind: "local" };
    },
    extractCallerClientId() {},
    cloudStepOf() {},
    resolveSessionSource() {
      return "local";
    },
    outboundFor() {
      return {};
    },
    resolveSession(_policy, callback) {
      return callback(() => {});
    },
    resolveNewSession: Agent.prototype.resolveNewSession,
    persistence: {
      async loadSession(id, roots) {
        observed = roots;
        throw stop;
      },
    },
  };
  const request = { cwd: a, mcpServers: [] };
  for (const method of ["newSessionAdmitted", "loadSessionAdmitted"]) {
    await assert.rejects(
      Agent.prototype[method].call(host, { ...request, sessionId: "fixture" }),
      (error) => error === stop,
    );
    assert.deepEqual(observed, [
      a,
      path.join(tmp, "global-root"),
      path.join(tmp, "a-extra"),
    ]);
  }
  resident = {
    workspacePaths: [a, protocol],
    nixWorkspaceRoots: { version: 1, protocol: [a, protocol] },
  };
  await settings(repoFile(a), null);
  await assert.rejects(
    Agent.prototype.loadSessionAdmitted.call(host, {
      ...request,
      sessionId: "fixture",
    }),
    (error) => error === stop,
  );
  assert.deepEqual(observed, resident.workspacePaths);
  resident = undefined;
  host.resolveExecutionContext = () => ({ kind: "relayed" });
  host.newRemoteSession = async () => "remote";
  assert.equal(
    await Agent.prototype.newSessionAdmitted.call(host, request),
    "remote",
  );
  host.resolveExecutionContext = () => ({ kind: "local" });
  await assert.rejects(
    Agent.prototype.newSessionAdmitted.call(host, {
      ...request,
      _meta: { kiro: { isEmptyWorkspace: true } },
    }),
    (error) => error === stop,
  );
  assert.deepEqual(observed, []);

  await settings(repoFile(a), ["../a-extra"]);
  const specInputs = [];
  const specHost = {
    homeDir: home,
    sessions: new Map(),
    getOrCreateSpecSessionTracker: () => ({
      initialize: async () => {},
      getSessionId: () => "spec",
    }),
    persistence: {
      loadSession: async (_id, roots) => {
        specInputs.push(roots);
        return { metadata: {} };
      },
    },
    broadcastOutboundFor: () => ({}),
    buildSpecSessionKiroMeta: () => ({}),
    resolveSessionDisableAutoCompaction: () => false,
    sessionOpenGate: { run: (fn) => fn() },
    resolveSession: (_policy, fn) => fn(() => {}),
    hydrateSessionForLoad: async (_kind, request) => {
      specInputs.push(Uke(request, false));
      assert.deepEqual(rootsApi.requestAuthority(request).protocol, [a]);
      return {};
    },
    sessionFromLoadOutcome: () => {},
    startPolicyWorkAfterResponse: () => {},
  };
  assert.equal(
    (
      await Agent.prototype.getOrCreateSpecSession.call(
        specHost,
        "feature",
        [a],
        [],
      )
    ).sessionId,
    "spec",
  );
  assert.deepEqual(specInputs, [
    [a, path.join(tmp, "global-root"), path.join(tmp, "a-extra")],
    [a, path.join(tmp, "global-root"), path.join(tmp, "a-extra")],
  ]);
  specHost.sessions.set("spec", {});
  await settings(repoFile(a), null);
  assert.equal(
    (
      await Agent.prototype.getOrCreateSpecSession.call(
        specHost,
        "feature",
        [a],
        [],
      )
    ).sessionId,
    "spec",
  );

  // Worktree policy discovery is local to admission, never process cwd.
  const worktrees = await import(
    pathToFileURL(path.join(tmp, "worktree-policy.mjs"))
  );
  const git = (...args) =>
    execFileSync("git", args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    }).trim();
  const repoC = path.join(tmp, "policy-c"),
    repoD = path.join(tmp, "policy-d "),
    linked = path.join(tmp, "linked-c");
  for (const repo of [repoC, repoD]) {
    await fs.mkdir(repo);
    git("init", repo);
    await fs.mkdir(path.dirname(repoFile(repo)), { recursive: true });
    await fs.writeFile(
      repoFile(repo),
      JSON.stringify({ "chat.worktrees": { enable: true } }),
    );
  }
  git(
    "-C",
    repoC,
    "-c",
    "user.name=Fixture",
    "-c",
    "user.email=fixture@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "--allow-empty",
    "-m",
    "fixture",
  );
  git("-C", repoC, "worktree", "add", "-b", "linked", linked);
  const cwdBefore = process.cwd();
  assert.deepEqual(
    await Promise.all([repoC, linked, repoD].map(worktrees.discover)),
    [`${repoC}-worktrees`, `${repoC}-worktrees`, `${repoD}-worktrees`],
  );
  assert.equal(process.cwd(), cwdBefore);
  for (const suffix of ["\t", "\ninvalid"]) {
    const special = path.join(tmp, `policy-special${suffix}`);
    git("init", special);
    if (suffix === "\t")
      assert.equal(await worktrees.discover(special), `${special}-worktrees`);
    else
      await assert.rejects(
        worktrees.discover(special),
        /newlines are unsupported/,
      );
  }
  const originalPath = process.env.PATH;
  try {
    process.env.PATH = "";
    assert.equal(await worktrees.discover(linked), `${repoC}-worktrees`);
  } finally {
    process.env.PATH = originalPath;
  }
  await assert.rejects(fs.stat(`${repoC}-worktrees`), { code: "ENOENT" });
  // Only the automatically derived destination refuses symlinks. Explicit
  // additional-directory aliases keep their existing canonical semantics.
  const destination = `${repoC}-worktrees`;
  await fs.mkdir(path.dirname(repoFile(linked)), { recursive: true });
  await fs.writeFile(
    repoFile(linked),
    JSON.stringify({ "chat.worktrees": { enable: true } }),
  );
  for (const target of [repoC, a, path.join(tmp, "dangling-target")]) {
    await fs.symlink(target, destination);
    await assert.rejects(
      worktrees.discover(linked),
      /derived destination must not be a symlink/,
    );
    observed = undefined;
    await assert.rejects(
      Agent.prototype.newSessionAdmitted.call(host, {
        cwd: linked,
        mcpServers: [],
      }),
      /derived destination must not be a symlink/,
    );
    assert.equal(
      observed,
      undefined,
      "symlink admission refuses before persistence",
    );
    await fs.unlink(destination);
  }
  await fs.mkdir(destination);
  assert.equal(await worktrees.discover(linked), destination);
  const linkedRoots = Uke(await resolve({ cwd: linked }), false);
  await assert.rejects(
    rootsApi.validateWorkflowRoots(
      { sessionState: () => ({ workspacePaths: linkedRoots }) },
      "linked",
      [path.join(repoC, ".git")],
    ),
    /no longer authorized/,
  );
  await fs.rmdir(destination);
  assert.equal(await worktrees.discover(linked), destination);
  await assert.rejects(fs.lstat(destination), { code: "ENOENT" });

  assert.equal(await worktrees.discover(a), undefined);
  for (const invalid of [
    null,
    true,
    {},
    { enable: 1 },
    { enable: true, path: "x" },
  ])
    assert.throws(
      () =>
        worktrees.enabled([
          { path: "fixture", value: { "chat.worktrees": invalid } },
        ]),
      /chat.worktrees/,
    );
  assert.equal(
    worktrees.enabled([
      { value: { "chat.worktrees": { enable: true } } },
      { value: { "chat.worktrees": { enable: false } } },
    ]),
    false,
  );
  const bare = path.join(tmp, "bare.git"),
    separate = path.join(tmp, "separate");
  git("init", "--bare", bare);
  git("init", `--separate-git-dir=${path.join(tmp, "git-storage")}`, separate);
  await assert.rejects(worktrees.discover(bare), /chat.worktrees/);
  await assert.rejects(worktrees.discover(separate), /chat.worktrees/);
  const disguised = path.join(tmp, "disguised"),
    storage = path.join(tmp, "storage");
  await fs.mkdir(storage);
  git("init", `--separate-git-dir=${path.join(storage, ".git")}`, disguised);
  await assert.rejects(worktrees.discover(disguised), /chat.worktrees/);
  await fs.writeFile(
    repoFile(a),
    JSON.stringify({ "chat.worktrees": { enable: true } }),
  );
  assert.deepEqual(Uke(await resolve({ cwd: a }), false), [
    a,
    path.join(tmp, "global-root"),
  ]);
  await settings(repoFile(a), ["../a-extra"]);
  // Actual admission forwards both configured roots and the computed sibling.
  for (const method of ["newSessionAdmitted", "loadSessionAdmitted"]) {
    await assert.rejects(
      Agent.prototype[method].call(host, {
        cwd: repoC,
        sessionId: "policy",
        mcpServers: [],
      }),
      (error) => error === stop,
    );
    assert.deepEqual(observed, [
      repoC,
      path.join(tmp, "global-root"),
      `${repoC}-worktrees`,
    ]);
  }
  const policyRequest = await resolve({ cwd: repoC });
  const policySnapshot = await (
    await import(pathToFileURL(path.join(tmp, "prompt-files.mjs")))
  ).resolveSnapshot(home, repoC, worktrees.requestRoot(policyRequest));
  const policyMetadata = {
    workspacePaths: Uke(policyRequest, false),
    _meta: rootsApi.authorityMetadata(
      {},
      rootsApi.requestAuthority(policyRequest),
    ),
  };
  const policyOwner = {
    homeDir: home,
    sessionState: () => undefined,
    persistence: { loadSessionMetadata: async () => policyMetadata },
  };
  await fs.writeFile(
    repoFile(repoC),
    JSON.stringify({ "chat.worktrees": { enable: false } }),
  );
  assert.deepEqual(await rootsApi.ownerRoots(policyOwner, "policy"), [
    repoC,
    path.join(tmp, "global-root"),
  ]);
  assert.ok(
    policySnapshot.slots.worktreeGuidance.includes(`${repoC}-worktrees/<name>`),
  );
  await assert.rejects(
    rootsApi.validateWorkflowRoots(policyOwner, "policy", [
      `${repoC}-worktrees/future`,
    ]),
    /no longer authorized/,
  );

  // Detached workflow owner provenance: saved config roots are not protocol.
  await settings(repoFile(a), ["../a-extra"]);
  const owned = await resolve({ cwd: a });
  const metadata = {
    workspacePaths: Uke(owned, false),
    _meta: rootsApi.authorityMetadata(
      { kiro: { nixWorkspaceRoots: { version: 99 } } },
      rootsApi.requestAuthority(owned),
    ),
  };
  const owner = {
    homeDir: home,
    sessionState: () => undefined,
    persistence: { loadSessionMetadata: async () => metadata },
  };
  const registryStop = new Error("captured detached registry construction");
  owner.detachedAgentDefinitions = () => {
    throw registryStop;
  };
  const workflowRegistry = vendor.T9r({
    getLiveSessionRegistry: () => undefined,
    getLiveSessionModeId: () => undefined,
    buildRegistryForRoots: vendor.workflowRegistry.bind(owner),
  });
  const savedWorkflow = {
    parentSessionId: "parent",
    workspacePath: a,
    additionalDirectories: metadata.workspacePaths.slice(1),
  };
  await assert.rejects(
    workflowRegistry(savedWorkflow),
    (error) => error === registryStop,
  );
  await settings(repoFile(a), []);
  await assert.rejects(workflowRegistry(savedWorkflow), /no longer authorized/);
  const restored = await rootsApi.restoreRequest(owner, {
    sessionId: "parent",
    cwd: a,
    additionalDirectories: metadata.workspacePaths.slice(1),
  });
  assert.deepEqual(Uke(await resolve(restored), false), [
    a,
    path.join(tmp, "global-root"),
  ]);
  const childRequest = await rootsApi.workflowRequest(
    owner,
    { cwd: a },
    "parent",
    [a],
  );
  const childMetadata = {
    workspacePaths: [a],
    _meta: rootsApi.authorityMetadata(
      {},
      rootsApi.requestAuthority(childRequest),
    ),
  };
  assert.equal(childMetadata._meta.kiro.nixWorkspaceRoots.owner, "parent");
  const childOwner = {
    ...owner,
    persistence: {
      loadSessionMetadata: async (id) =>
        id === "child" ? childMetadata : metadata,
    },
  };
  assert.deepEqual(await rootsApi.ownerRoots(childOwner, "child"), [a]);
  await assert.rejects(
    rootsApi.validateWorkflowRoots(childOwner, "child", [
      path.join(tmp, "global-root"),
    ]),
    /no longer authorized/,
  );
  await assert.rejects(
    rootsApi.restoreRequest(childOwner, {
      sessionId: "child",
      cwd: a,
      additionalDirectories: [path.join(tmp, "global-root")],
    }),
    /no longer authorized/,
  );
  // An evicted owner must not strand its child or preserve revoked extra roots.
  const evictedOwner = {
    ...childOwner,
    persistence: {
      loadSessionMetadata: async (id) =>
        id === "child" ? childMetadata : undefined,
    },
  };
  assert.deepEqual(await rootsApi.ownerRoots(evictedOwner, "child"), [a]);
  assert.deepEqual(
    rootsApi.requestAuthority(
      await rootsApi.restoreRequest(evictedOwner, {
        sessionId: "child",
        cwd: a,
      }),
    ),
    rootsApi.requestAuthority(childRequest),
  );
  // The detached registry rebuild has the same fallback: cwd roots and prompt
  // snapshot resolve, while a saved extra root revoked by settings still fails.
  const evictedRegistry = vendor.T9r({
    getLiveSessionRegistry: () => undefined,
    getLiveSessionModeId: () => undefined,
    buildRegistryForRoots: vendor.workflowRegistry.bind(evictedOwner),
  });
  await assert.rejects(
    evictedRegistry({ parentSessionId: "parent", workspacePath: a }),
    (error) => error === registryStop,
  );
  await assert.rejects(
    evictedRegistry({
      parentSessionId: "parent",
      workspacePath: a,
      additionalDirectories: [path.join(tmp, "a-extra")],
    }),
    /no longer authorized/,
  );
  const childWithExtra = {
    ...evictedOwner,
    persistence: {
      loadSessionMetadata: async (id) =>
        id === "child"
          ? {
              workspacePaths: [a, path.join(tmp, "a-extra")],
              _meta: rootsApi.authorityMetadata(
                {},
                {
                  version: 1,
                  protocol: [a, path.join(tmp, "a-extra")],
                  owner: "parent",
                },
              ),
            }
          : undefined,
    },
  };
  await assert.rejects(
    rootsApi.ownerRoots(childWithExtra, "child"),
    /no longer authorized/,
  );
  await settings(repoFile(a), ["../a-extra"]);
  assert.deepEqual(await rootsApi.ownerRoots(childWithExtra, "child"), [
    a,
    path.join(tmp, "a-extra"),
  ]);
  await settings(repoFile(a), []);
  const cyclic = {
    ...owner,
    persistence: { loadSessionMetadata: async () => childMetadata },
  };
  await assert.rejects(
    rootsApi.ownerRoots(cyclic, "parent"),
    /cyclic persisted/,
  );
  const forgedMetadata = {
    ...metadata,
    _meta: {
      ...metadata._meta,
      kiro: {
        ...metadata._meta.kiro,
        serverSession: { ownerSessionId: "parent" },
      },
    },
  };
  assert.deepEqual(
    await rootsApi.ownerRoots(
      {
        ...owner,
        persistence: { loadSessionMetadata: async () => forgedMetadata },
      },
      "parent",
    ),
    [a, path.join(tmp, "global-root")],
  );
  const legacy = {
    ...owner,
    persistence: {
      loadSessionMetadata: async () => ({
        workspacePaths: [a, path.join(tmp, "a-extra")],
      }),
    },
  };
  await rootsApi.validateWorkflowRoots(legacy, "legacy", [
    a,
    path.join(tmp, "a-extra"),
  ]);
  assert.deepEqual(rootsApi.stripAuthority(metadata._meta), { kiro: {} });
  assert.throws(
    () =>
      rootsApi.storedAuthority({
        _meta: { kiro: { nixWorkspaceRoots: { version: 2, protocol: [] } } },
      }),
    /invalid persisted/,
  );

  // The actual MCP loader keeps each concurrent session's cwd, never its added
  // roots. Inert ports capture file declarations without starting MCP servers.
  const mcpHome = path.join(tmp, "mcp-home"),
    mcpCwd = path.join(tmp, "mcp-cwd"),
    mcpOther = path.join(tmp, "mcp-other"),
    mcpAdded = path.join(tmp, "mcp-added");
  for (const [root, name] of [
    [mcpHome, "global"],
    [mcpCwd, "cwd"],
    [mcpOther, "other"],
    [mcpAdded, "added"],
  ]) {
    const dir = path.join(root, ".kiro/settings");
    await fs.mkdir(dir, { recursive: true });
    await fs.writeFile(
      path.join(dir, "mcp.json"),
      JSON.stringify({ mcpServers: { [name]: { command: name } } }),
    );
  }
  const sessions = new Map();
  let fileConfigs, staged;
  const watched = [];
  const manager = Object.assign(Object.create(S8e.prototype), {
    homeDir: mcpHome,
    workspaceTrusted: true,
    globalEnvVars: {},
    pluginServers: {},
    configWatcher: { addWorkspacePaths: (roots) => watched.push(roots) },
    items: {
      openSession: (id, roots) => sessions.set(id, roots),
      closeSession: (id) => sessions.delete(id),
      roots: () => [...new Set([...sessions.values()].flat())],
      restate: (configs) => {
        fileConfigs = configs;
      },
      merged: () => [],
      stateWorkspace: (_port, configs) => {
        staged = configs;
      },
    },
  });
  manager.setWorkspacePaths([mcpCwd, mcpAdded], "one", {});
  manager.setWorkspacePaths([mcpOther, mcpAdded], "two", {});
  assert.deepEqual(Object.keys(fileConfigs.user.servers), ["global"]);
  assert.deepEqual([...fileConfigs.workspaces.keys()], [mcpCwd, mcpOther]);
  assert.deepEqual(Object.keys(fileConfigs.workspaces.get(mcpCwd).servers), [
    "cwd",
  ]);
  assert.deepEqual(Object.keys(fileConfigs.workspaces.get(mcpOther).servers), [
    "other",
  ]);
  assert.deepEqual(watched, [[mcpCwd], [mcpOther]]);
  manager.stateWorkspace([mcpCwd, mcpAdded], {});
  assert.deepEqual([...staged.keys()], [mcpCwd]);
  manager.removeSessionWorkspacePaths("one");
  assert.deepEqual([...fileConfigs.workspaces.keys()], [mcpOther]);

  // Default vendor reads flip from ask to allow only for a configured root.
  await settings(globalFile, []);
  await settings(repoFile(a), ["../a-extra"]);
  const readRequest = await rootsApi.resolveRequest(home, { cwd: a }, [a]);
  for (const [roots, target, expected] of [
    [[a], path.join(tmp, "a-extra/result.txt"), "ask"],
    [Uke(readRequest, false), path.join(tmp, "a-extra/result.txt"), "allow"],
    [Uke(readRequest, false), path.join(tmp, "unrelated/result.txt"), "ask"],
  ]) {
    const policy = new M$t({
      homeDir: home,
      workspaceRoots: roots,
      workspaceTrusted: true,
      agentPermissions: m9o([]),
    });
    const root = new yce(roots, home).resolveWorkspaceRoot(target);
    const decision = await policy.evaluateSingleResource(
      {
        capability: "fs_read",
        resource: root ? path.relative(root, target) : target,
      },
      { workspaceRoot: root },
    );
    assert.equal(decision.effect, expected);
    if (expected === "allow")
      assert.deepEqual(decision.matchedRule.match, ["./**"]);
    policy.dispose?.();
  }

  // Actual admission/write/fileCheck agreement; denied, no-grant, symlink and
  // common-git negatives are vendor-contract guards, not root-resolution tests.
  const results = [];
  await settings(globalFile, []);
  for (const kind of [
    "allowed",
    "denied",
    "no-grant",
    "symlink-escape",
    "common-git",
  ]) {
    const base = path.join(tmp, kind),
      fixtureHome = path.join(base, "home"),
      primary = path.join(base, "repo"),
      sibling = path.join(base, "repo-worktrees/review"),
      outside = path.join(base, "outside");
    for (const p of [
      fixtureHome,
      path.join(primary, ".kiro/settings"),
      sibling,
      outside,
    ])
      await fs.mkdir(p, { recursive: true });
    let commonGit;
    {
      const git = (...args) =>
        execFileSync("git", args, {
          encoding: "utf8",
          env: {
            ...process.env,
            GIT_CONFIG_GLOBAL: "/dev/null",
            GIT_CONFIG_NOSYSTEM: "1",
          },
          stdio: ["ignore", "pipe", "pipe"],
        }).trim();
      git("init", primary);
      git(
        "-C",
        primary,
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.invalid",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "-m",
        "fixture",
      );
      if (kind === "common-git")
        git("-C", primary, "worktree", "add", "-b", "review", sibling);
      commonGit = git(
        "-C",
        primary,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
      );
      assert.equal(commonGit, path.join(primary, ".git"));
    }
    const admissionCwd = kind === "common-git" ? sibling : primary;
    await fs.mkdir(path.dirname(repoFile(admissionCwd)), { recursive: true });
    await fs.writeFile(
      repoFile(admissionCwd),
      JSON.stringify({ "chat.worktrees": { enable: true } }),
    );
    const request = await rootsApi.resolveRequest(
      fixtureHome,
      { cwd: admissionCwd },
      [admissionCwd],
    );
    const roots = Uke(request, false);
    assert.deepEqual(roots, [admissionCwd, path.dirname(sibling)]);
    const cwd = roots[0],
      resolver = new yce(roots, fixtureHome),
      disk = new h5(cwd);
    const policyDir = $qr(path.dirname(sibling), fixtureHome);
    await fs.mkdir(policyDir, { recursive: true });
    const rules =
      kind === "no-grant"
        ? []
        : [
            {
              capability: "fs_write",
              effect: kind === "denied" ? "deny" : "allow",
              match: ["review/.agents/**"],
            },
          ];
    await fs.writeFile(
      path.join(policyDir, "permissions.json"),
      JSON.stringify({ rules }),
    );
    if (kind === "symlink-escape")
      await fs.symlink(outside, path.join(sibling, ".agents"));
    const policy = new M$t({
      homeDir: fixtureHome,
      workspaceRoots: roots,
      workspaceTrusted: true,
    });
    let prompts = 0;
    const approval = h0o({
      policySession: policy,
      shellTypeInfo: { shellType: "bash" },
      workspaceResolver: resolver,
      primaryCwd: cwd,
      consentDesk: new oPt(),
      prompt: async () => {
        prompts++;
        return { decision: "reject" };
      },
    });
    const decisions = [];
    const tool = new fqe({
      origin: "offline-fixture",
      acpToolApproval: async (req) => {
        const decision = await approval(req);
        decisions.push(decision);
        return decision;
      },
    });
    tool.emitProgress = () => {};
    tool.concludeToolUse = (_state, _tool, result) => result;
    tool.concludeToolRejection = (_state, _tool, rejection) => ({ rejection });
    let writes = 0;
    const workspace = {
      fs: disk,
      resolveRelativePath: (p) => resolver.resolveRelativePath(p),
      asRelativePath: (u) => resolver.asRelativePath(u),
      getHomeDir: () => fixtureHome,
      listWorkspaceFolders: () => ({
        folders: roots.map((p) => ({ uri: ho.file(p) })),
      }),
      getPolicyOverride: () => undefined,
      readFile: async ({ file }) => ({
        content: {
          text: (await disk.readTextFile({ path: file.uri.fsPath })).content,
        },
      }),
      writeFile: async ({ file, text }) => {
        writes++;
        await disk.writeTextFile({ path: file.uri.fsPath, content: text });
        return {
          original: undefined,
          modified: file.uri,
          write: Promise.resolve({ checkpointUri: file.uri }),
        };
      },
    };
    const controller = new AbortController(),
      execution = {
        abortController: controller,
        lifetime: controller.signal,
        executionId: kind,
        activity: { hold: () => () => {} },
        workspace,
        autonomyMode: "Autopilot",
      };
    const templateContext = {
      inputs: {
        worktree_path: kind === "common-git" ? commonGit : sibling,
      },
      artifacts: {},
      capturedOutputs: {},
      previousSiblingNodeId: null,
    };
    const spec = {
        path: "{{worktree_path}}/.agents/tasks/review.json",
        jsonPath: "verdict",
        value: "APPROVED",
      },
      target = mB(spec.path, templateContext);
    await tool.handle({
      actionId: kind,
      input: { path: target, text: JSON.stringify({ verdict: "APPROVED" }) },
      state: { execution },
      toolUse: { id: "fixture" },
    });
    let check;
    try {
      check = await Xjc(spec, {
        workspacePath: cwd,
        additionalDirectories: roots.slice(1),
        templateContext,
        fs: { readFile: (p) => fs.readFile(p, "utf8") },
      });
    } catch (error) {
      check = error.name;
    }
    assert.equal(policy.getLoadErrors().filter((e) => e.fatal).length, 0);
    assert.equal(writes, kind === "allowed" ? 1 : 0);
    if (kind === "allowed") assert.equal(check, true);
    else {
      assert.equal(decisions.at(-1).decision, "reject");
      await assert.rejects(fs.stat(target), { code: "ENOENT" });
    }
    if (["symlink-escape", "common-git"].includes(kind))
      assert.equal(check, "FileCheckPathOutsideWorkspaceError");
    if (kind === "no-grant") assert.equal(prompts, 1);
    results.push({ kind, writes, prompts, check });
    policy.dispose?.();
  }
  console.log(
    JSON.stringify({
      sourceSha256: createHash("sha256").update(source).digest("hex"),
      results,
    }),
  );
  console.log(
    "PASS: configured roots, actual new/load admission, detached provenance revocation and owner eviction, cwd-only MCP across sessions, default fs_read, write/fileCheck agreement, vendor-contract guards (denied/no-grant/symlink/common-git)",
  );
} finally {
  if (previousHome === undefined) delete process.env.KIRO_HOME;
  else process.env.KIRO_HOME = previousHome;
  await fs.rm(tmp, { recursive: true, force: true });
}
