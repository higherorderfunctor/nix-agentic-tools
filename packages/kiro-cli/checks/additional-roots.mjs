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
    "prompt-defaults",
  ])
    await fs.symlink(
      path.join(path.dirname(server), name),
      path.join(tmp, name),
    );
  await fs.writeFile(
    path.join(tmp, "vendor.mjs"),
    source.slice(0, cut.getStart(ast)) +
      `\nexport {fqe,h5,Xjc,mB,M$t,h0o,oPt,yce,ho,$qr,Uke,T9r,${agentName} as Agent};\nexport function workflowRegistry(roots, owner) { return (${registryBuilder.initializer.getText(ast)})(roots, owner); }\n`,
  );
  const vendor = await import(pathToFileURL(path.join(tmp, "vendor.mjs")));
  const { fqe, h5, Xjc, mB, M$t, h0o, oPt, yce, ho, $qr, Uke, Agent } = vendor;
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

  // Real vendor permission/admission/fs_write and identical absolute fileCheck.
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
    if (kind === "common-git") {
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
      git("-C", primary, "worktree", "add", "-b", "review", sibling);
      commonGit = git(
        "-C",
        sibling,
        "rev-parse",
        "--path-format=absolute",
        "--git-common-dir",
      );
      assert.equal(commonGit, path.join(primary, ".git"));
    }
    await settings(repoFile(primary), ["../repo-worktrees/review"]);
    const request = await rootsApi.resolveRequest(
      fixtureHome,
      { cwd: primary },
      [primary],
    );
    // A linked worktree's common Git directory is a separate resource. Declare
    // only the worktree for this case, leaving its primary checkout outside.
    const roots = kind === "common-git" ? [sibling] : Uke(request, false);
    const cwd = roots[0],
      resolver = new yce(roots, fixtureHome),
      disk = new h5(cwd);
    const policyDir = $qr(sibling, fixtureHome);
    await fs.mkdir(policyDir, { recursive: true });
    const rules =
      kind === "no-grant"
        ? []
        : [
            {
              capability: "fs_write",
              effect: kind === "denied" ? "deny" : "allow",
              match: [".agents/**"],
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
    "PASS: configured roots, actual new/load admission, detached provenance revocation, vendor policy/write/fileCheck (5 cases)",
  );
} finally {
  if (previousHome === undefined) delete process.env.KIRO_HOME;
  else process.env.KIRO_HOME = previousHome;
  await fs.rm(tmp, { recursive: true, force: true });
}
