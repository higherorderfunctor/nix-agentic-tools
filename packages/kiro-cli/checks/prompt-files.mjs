// Isolated construction from the actual patched vendor AST. No KAS startup,
// authentication, transport send, or model service is evaluated by this test.
import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";
import vm from "node:vm";

const [server, typescript] = process.argv.slice(2);
const nixPrompts = await import(
  pathToFileURL(join(dirname(server), "prompt-files.mjs"))
);
const nixRoots = await import(
  pathToFileURL(join(dirname(server), "additional-roots.mjs"))
);
const ts = createRequire(import.meta.url)(typescript);
const source = await readFile(server, "utf8");
const ast = ts.createSourceFile(
  server,
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);
assert.equal(ast.parseDiagnostics.length, 0);
const nodes = [];
function walk(node) {
  nodes.push(node);
  ts.forEachChild(node, walk);
}
walk(ast);
function unique(predicate, name) {
  const result = nodes.filter(predicate);
  assert.equal(result.length, 1, `unique vendor AST ${name}`);
  return result[0];
}
const functionNode = (name) =>
  unique((n) => ts.isFunctionDeclaration(n) && n.name?.text === name, name);
const variableNode = (name) =>
  unique(
    (n) => ts.isVariableDeclaration(n) && n.name.getText(ast) === name,
    name,
  );
function valueNode(name) {
  const assignments = nodes.filter(
    (n) =>
      ts.isBinaryExpression(n) &&
      n.operatorToken.kind === ts.SyntaxKind.EqualsToken &&
      n.left.getText(ast) === name,
  );
  const declarations = nodes.filter(
    (n) =>
      ts.isVariableDeclaration(n) &&
      n.name.getText(ast) === name &&
      n.initializer,
  );
  assert.equal(
    assignments.length + declarations.length,
    1,
    `one vendor value ${name}`,
  );
  return assignments[0]?.right ?? declarations[0].initializer;
}
const silent = () => {};
class Message {
  constructor(type = "human") {
    this.type = type;
    this.role = type;
    this.content = "";
  }
  withText(text) {
    this.content += text;
    return this;
  }
  withTexts(texts) {
    for (const text of texts) this.withText(text);
    return this;
  }
  withForcedRole() {
    this.forcedRole = true;
    return this;
  }
  withUserAuthored() {
    return this;
  }
  withAgentContext() {
    return this;
  }
  withDocuments(documents) {
    this.documents = documents;
    return this;
  }
}
const context = vm.createContext(
  {
    Buffer,
    Date,
    Map,
    Set,
    console,
    nixPrompts,
    nixRoots,
    // Host and message-builder boundaries, not prompt constructors.
    E: (initialize) => initialize,
    Ife: () => "Fixture OS",
    QGn: () => ({ modelId: "fixture" }),
    S: { debug: silent, error: silent, info: silent, warn: silent },
    ajn: { platform: () => "fixture-platform" },
    ljn: { platform: () => "fixture-platform" },
    kje: Error,
    process: { platform: "linux" },
    qt: { fromHuman: () => new Message(), fromAI: () => new Message("ai") },
    _co: silent,
    $n: {
      AB_CGS_DELEGATION: "delegation",
      AB_SYSTEM_FIELD_INJECTION: "system-field",
    },
  },
  { codeGeneration: { strings: false, wasm: false } },
);
function evaluate(text) {
  return vm.runInContext(text, context, { timeout: 5000 });
}
function loadFunction(name) {
  evaluate(functionNode(name).getText(ast));
}
function loadValue(name) {
  evaluate(`var ${name} = ${valueNode(name).getText(ast)};`);
}
function method(name, className) {
  const pool = className ? valueNode(className).members : nodes;
  const found = pool.filter(
    (n) => ts.isMethodDeclaration(n) && n.name.getText(ast) === name,
  );
  assert.equal(found.length, 1, `one vendor method ${className ?? ""}.${name}`);
  return evaluate(`({${found[0].getText(ast)}}).${name}`);
}

// Real bundled Mustache and dedent: no copied renderer in the fixture.
const mustacheStart = functionNode("o5t");
const mustacheEnd = variableNode("bje").parent.parent;
evaluate(source.slice(mustacheStart.getStart(ast), mustacheEnd.end));
evaluate("bje();");
loadFunction("Sln");
evaluate("var yln = Sln({});");
for (const name of [
  "Bpa",
  "Cq",
  "Dpa",
  "Fpa",
  "G6e",
  "Gpa",
  "Hpa",
  "Jf",
  "KZ",
  "Kpa",
  "Opa",
  "Rje",
  "UXs",
  "Vpa",
  "Wpa",
  "Ypa",
  "Zpa",
  "brr",
  "clr",
  "eO",
  "efa",
  "fbe",
  "iB",
  "jpa",
  "mx",
  "nct",
  "nfa",
  "oEe",
  "ojn",
  "qpa",
  "rfa",
  "rne",
  "sjn",
  "ulr",
  "wme",
  "X7",
  "zpa",
])
  loadFunction(name);
loadValue("Lpa");
loadValue("lfe");
loadValue("trt");
for (const name of [
  "Afe",
  "BXs",
  "GPe",
  "Rfe",
  "Srr",
  "Upa",
  "WPe",
  "Xrt",
  "_rr",
  "djn",
  "dre",
  "jPe",
  "pjn",
  "tU",
  "vrr",
  "wrr",
  "z$o",
])
  loadValue(name);
context.Err = () => false;
context.Lhs = { join };
context.M2 = silent;
context.oB = (message) => message;

const tmp = await mkdtemp(join(tmpdir(), "kiro-prompt-files-"));
const savedHome = process.env.KIRO_HOME;
try {
  const home = join(tmp, "home"),
    global = join(tmp, "kiro"),
    repoA = join(tmp, "a"),
    repoB = join(tmp, "b");
  for (const path of [
    join(global, "settings"),
    join(repoA, ".kiro/settings"),
    join(repoB, ".kiro/settings"),
  ])
    await mkdir(path, { recursive: true });
  process.env.KIRO_HOME = global;
  const writeSettings = (path, mapping) =>
    writeFile(path, JSON.stringify({ "chat.promptFiles": mapping }));
  const globalSettings = join(global, "settings/cli.json");
  const repoSettings = (repo) => join(repo, ".kiro/settings/cli.json");
  await writeFile(join(global, "settings/identity.txt"), "GLOBAL_IDENTITY.");
  await writeFile(
    join(repoA, "identity.txt"),
    "A_IDENTITY `literal` ${notExecuted}.",
  );
  await writeFile(join(repoB, "identity.txt"), "B_IDENTITY.");
  await writeFile(
    join(repoA, "worktree.txt"),
    "A_WORKTREE {{worktree_path}}\n\n",
  );
  await writeFile(
    join(repoA, "check.txt"),
    "A_FILE_CHECK {{worktree_path}}/result.json",
  );
  await writeSettings(globalSettings, { identity: "identity.txt" });
  await writeSettings(repoSettings(repoA), {
    identity: "identity.txt",
    workflowFileCheckGuidance: "check.txt",
    worktreeGuidance: "worktree.txt",
  });
  await writeSettings(repoSettings(repoB), { identity: "identity.txt" });
  const [a, b] = await Promise.all([
    nixPrompts.resolveSnapshot(home, repoA),
    nixPrompts.resolveSnapshot(home, repoB),
  ]);
  assert.equal(a.slots.identity, "A_IDENTITY `literal` ${notExecuted}.");
  assert.equal(b.slots.identity, "B_IDENTITY.");
  assert.equal(
    (await nixPrompts.resolveSnapshot(home)).slots.identity,
    "GLOBAL_IDENTITY.",
  );
  assert.ok(Object.isFrozen(a.slots));
  const metadata = {
    _meta: nixPrompts.snapshotMetadata(
      { sibling: true, kiro: { client: true, nixPromptSnapshot: b } },
      a,
    ),
  };
  assert.equal(metadata._meta.sibling, true);
  assert.equal(metadata._meta.kiro.client, true);
  const cold = nixPrompts.storedSnapshot(JSON.parse(JSON.stringify(metadata)));
  assert.deepEqual(cold, a);
  assert.equal(nixPrompts.storedSnapshot({}), null);
  assert.throws(
    () =>
      nixPrompts.storedSnapshot({
        _meta: { kiro: { nixPromptSnapshot: { version: 2 } } },
      }),
    /snapshot/,
  );
  await writeFile(join(repoA, "identity.txt"), "NEW_IDENTITY.");
  assert.equal(
    (await nixPrompts.resolveSnapshot(home, repoA)).slots.identity,
    "NEW_IDENTITY.",
  );
  await rm(join(repoA, "identity.txt"));
  await assert.rejects(nixPrompts.resolveSnapshot(home, repoA), /identity/);
  const agent = {
    sessionState: (id) =>
      id === "resident" ? { nixPromptSnapshot: a } : undefined,
    persistence: {
      loadSessionMetadata: async (id) => (id === "cold" ? metadata : null),
    },
  };
  assert.equal(await nixPrompts.ownerSnapshot(agent, "resident"), a);
  assert.deepEqual(await nixPrompts.ownerSnapshot(agent, "cold"), a);
  await assert.rejects(
    nixPrompts.ownerSnapshot(agent, "missing"),
    /unavailable/,
  );
  await writeSettings(repoSettings(repoA), { identity: null });
  const reset = await nixPrompts.resolveSnapshot(home, repoA);
  assert.equal(
    reset.slots.identity,
    await readFile(
      join(dirname(server), "prompt-defaults/identity.txt"),
      "utf8",
    ),
  );
  await writeSettings(repoSettings(repoA), { identity: "bad.txt" });
  await writeFile(join(repoA, "bad.txt"), Buffer.from([0xff]));
  await assert.rejects(nixPrompts.resolveSnapshot(home, repoA), /identity/);
  await writeSettings(repoSettings(repoA), { unknownSlot: "x" });
  await assert.rejects(nixPrompts.resolveSnapshot(home, repoA), /unknownSlot/);

  // Resident admission must not invoke the new-session resolver a second time.
  const residentAdmission = method("resolveSessionAdmitted");
  const resident = { nixPromptSnapshot: a };
  const joined = await residentAdmission.call(
    {
      sessions: new Map([["one", resident]]),
      hydrateInflight: new Map(),
      compactionInProgressSessions: new Map(),
      sessionState: () => resident,
    },
    { kind: "load", sessionId: "one" },
    () => {
      throw new Error("resident reread files");
    },
  );
  assert.equal(joined.session.nixPromptSnapshot, a);

  // Real registry methods and refresh: selected bundled definitions are copied;
  // a same-named client/workspace profile and permission objects stay untouched.
  loadValue("wae");
  const creatorSource = valueNode("ioi").text;
  const boundary = creatorSource.indexOf("\n---", 4);
  assert.ok(boundary > 0);
  const creator = {
    id: "wf-workflow-creator",
    prompt: creatorSource.slice(boundary + 4).trim(),
    permissions: { rules: ["fixture-policy"] },
    tools: ["fixture-tool"],
  };
  const registryA = evaluate("new wae()");
  registryA.nixPromptSnapshot = a;
  const registryB = evaluate("new wae()");
  registryB.nixPromptSnapshot = b;
  registryA.register(creator, "bundled-profile", { origin: "bundled" });
  registryB.register(creator, "bundled-profile", { origin: "bundled" });
  assert.ok(
    registryA.get(creator.id).prompt.includes("A_FILE_CHECK {{worktree_path}}"),
  );
  assert.ok(!registryB.get(creator.id).prompt.includes("A_FILE_CHECK"));
  assert.equal(registryA.get(creator.id).permissions, creator.permissions);
  assert.equal(registryA.get(creator.id).tools, creator.tools);
  context.cYr = () => [
    {
      definition: creator,
      source: "bundled-profile",
      origin: { origin: "bundled" },
    },
  ];
  context.Vhr = () => true;
  for (const name of ["FMu", "V3o", "aYr", "sYr"]) loadFunction(name);
  loadValue("LMu");
  context.V3o(registryA, {}, {});
  assert.ok(registryA.get(creator.id).prompt.includes("A_FILE_CHECK"));
  registryA.register(creator, "client-provided");
  context.V3o(registryA, {}, {});
  assert.equal(registryA.get(creator.id).prompt, creator.prompt);
  registryA.unregister(creator.id);
  registryA.register(creator, "bundled-profile");

  const workspace = {
    machineId: "FIXTURE_MACHINE",
    workspaceFolderCount: 1,
    getHomeDir: () => home,
    listWorkspaceFolders: () => ({ folders: [{ uri: { fsPath: repoA } }] }),
    getSteeringDocuments: async () => ({
      documents: [
        { id: "fixture", content: "FILE_STEERING", scope: "workspace" },
      ],
    }),
  };
  const agentContext = {
    client: "kiro-cli",
    environment: "local",
    language: "English",
    nixPromptSnapshot: cold,
    promptClock: () => new Date("2031-01-02T12:00:00Z"),
  };
  const renderer = {
    agentContext,
    delegationToolAvailable: false,
    globalLearnings: ["LEARNING_MARKER"],
    steering: [context.z$o(cold), "STEERING_MARKER"],
    repositories: ["REPOSITORY_MARKER"],
    knowledgeListing: "KNOWLEDGE_MARKER",
  };
  const mainMessages = await method("getSystemPromptMessages", "hbe").call(
    renderer,
    {
      workspace,
      shellTypeInfo: { shellType: "fixture-shell" },
      machineId: workspace.machineId,
      includeFileTree: false,
    },
  );
  const text = mainMessages[0].content;
  for (const marker of [
    a.slots.identity,
    "A_WORKTREE {{worktree_path}}",
    "January 2, 2031",
    "FIXTURE_MACHINE",
    "fixture-shell",
    repoA,
    "STEERING_MARKER",
    "REPOSITORY_MARKER",
    "KNOWLEDGE_MARKER",
    "LEARNING_MARKER",
  ])
    assert.ok(
      text.includes(marker),
      `actual Vibe constructor includes ${marker}`,
    );
  assert.ok(!text.includes(reset.slots.identity));
  assert.equal(mainMessages[0].documents[0].document.content, "FILE_STEERING");
  const custom = await method("getSystemPromptMessages", "W9").call(
    renderer,
    registryA.get(creator.id).prompt,
    workspace,
    { shellType: "fixture-shell" },
  );
  assert.ok(custom[0].content.includes("A_FILE_CHECK {{worktree_path}}"));
  assert.ok(custom[0].content.includes("Machine ID: FIXTURE_MACHINE"));
  assert.ok(!custom[0].content.includes(b.slots.workflowFileCheckGuidance));
  renderer.getSystemPromptMessages = () => {
    throw new Error("saved msg0 was rebuilt");
  };
  renderer.finalizeBuildState = (messages) => messages;
  const replay = await method("build", "W9").call(renderer, {
    input: { prompt: "next", previousMessages: custom },
    imageBase64Urls: [],
    documentAttachments: [],
    chatSessionId: "cold",
    workspace,
    sessionServices: {},
  });
  assert.equal(replay[0], custom[0]);

  // Actual field-selection and SDK-command construction. The conversion adapter
  // captures messages before transport; this is deliberately not an AWS SDK or
  // a claim to exercise vendor history sanitization or a network request.
  context.PLr = () => ({});
  context.jZ = {
    GenerateAssistantResponseCommand: class {
      constructor(input) {
        this.input = input;
      }
    },
  };
  const client = {
    modelType: "fixture",
    agentMode: "vibe",
    extractSystemPrompt: method("extractSystemPrompt"),
    convertToGenerateAssistantMessages: (messages) => ({ messages }),
  };
  for (const enabled of [false, true]) {
    client.featureConfigRegistry = { get: () => enabled };
    const inputMessages = [
      ...mainMessages,
      new Message().withText("user prompt"),
    ];
    const assembled = method("buildConversationState").call(
      client,
      inputMessages,
      [],
    );
    const command = method("buildRequestCommand").call(
      client,
      {},
      assembled.conversationState,
      {},
      assembled.systemPrompt,
      assembled.modelCaller,
    );
    const effective = enabled
      ? command.input.systemPrompt
      : command.input.conversationState.messages[0].content;
    assert.equal(effective, text);
    assert.equal(
      command.input.conversationState.messages.length,
      enabled ? 1 : 2,
    );
  }
  // Actual ACP lifecycle methods; only host services and the heavyweight
  // session-service constructor are inert. The registry constructor is real.
  Object.assign(context, {
    performance,
    setTimeout: silent,
    BVr: () => ({ enabled: false }),
    Brt: () => undefined,
    Cis: () => undefined,
    Di: new Proxy({}, { get: (_, name) => name }),
    GB: { none: () => ({}), of: () => ({}) },
    G9e: { fromSnapshot: () => ({}) },
    HZ: () => false,
    M6t: () => true,
    M7e: () => false,
    N2r: () => undefined,
    N6t: (value) => value,
    Pze: () => undefined,
    U6t: () => undefined,
    Aae: { isAbsolute },
    jf: { isAbsolute },
    Rn: Error,
    Urt: () => false,
    VEe: () => ({}),
    Y9e: "fixture",
    Zdo: () => undefined,
    cR: () => false,
    dis: () => false,
    eU: () => ({ data: {} }),
    fis: [],
    his: silent,
    j0: (state) => state.modeId,
    jB: () => ({}),
    lBr: silent,
    oh: () => false,
    qrt: () => false,
    rrr: () => undefined,
    v5e: () => [],
    AIt: () => undefined,
    zrt: () => ({}),
  });
  for (const name of ["Uke", "tBr", "rBr"]) loadFunction(name);
  loadFunction("Ile");
  loadFunction("K3o");
  // The heavyweight session constructor owns many unrelated host services.
  // Evaluate its actual snapshot field, so the lifecycle fixture cannot pass by
  // manually supplying a carrier that the production constructor dropped.
  const stateCarrier = (property) =>
    unique((node) => {
      if (!ts.isPropertyAssignment(node) || node.name.getText(ast) !== property)
        return false;
      let owner = node.parent;
      while (owner && !ts.isMethodDeclaration(owner)) owner = owner.parent;
      return owner?.name.getText(ast) === "createSessionState";
    }, "createSessionState snapshot carrier");
  const constructCarrier = evaluate(
    `(c) => (${stateCarrier("nixPromptSnapshot").initializer.getText(ast)})`,
  );
  const constructRoots = evaluate(
    `(c) => (${stateCarrier("nixWorkspaceRoots").initializer.getText(ast)})`,
  );
  const states = new Map(),
    records = new Map();
  const outbound = { extNotification: silent };
  const host = {
    homeDir: home,
    agentContext: { client: "kiro-cli" },
    sessions: states,
    hydrateInflight: new Map(),
    compactionInProgressSessions: new Map(),
    sessionState: (id) => states.get(id)?.state,
    disposeSession: (id) => states.delete(id),
    configuration: {
      openSession: () => ({
        settings: {
          value: (key) =>
            key === "sessionEviction" ? { sweep: "off" } : "off",
        },
      }),
    },
    getShellTypeInfo: async () => ({}),
    captureMemoryConfig: () => ({
      memoryConfig: {},
      memoryConfigSource: "explicit",
    }),
    resolveSessionDisableAutoCompaction: () => false,
    syncIdentity: async () => {},
    refreshExperimentConfigInBackground: silent,
    resolveBackendUserAgentGate: async () => {},
    buildFeatureConfigRegistry: () => ({ get: () => false }),
    resolveDynamicDelegation: () => undefined,
    resolveMemoryEnabled: () => false,
    validatePresetIds: () => [],
    runtimeServers: { declareClient: silent, clientRequiresReady: () => false },
    authProvider: { readToken: () => undefined },
    syncActiveAgentKnowledge: silent,
    startWorkflowRecipeCatalog: async () => {},
    noteModeRouted: silent,
    activityPublisher: { startTimer: silent },
    reconcileMcpForAllSessions: silent,
    extractCallerClientId: () => undefined,
    outboundFor: () => outbound,
    workflowRuntime: {
      bindLoadedStepSession: async (state, owner) => {
        assert.equal(state.sessionId, "cold-child");
        assert.equal(owner, "acp-a");
      },
      pushCheckpointAvailability: async () => {},
    },
    governed: {},
    pushGovernanceState: silent,
    emitMcpStatus: silent,
    pushSandboxStatus: silent,
    powersManager: { pushToSession: silent, ensureScanned: async () => {} },
    pushHooksToSession: silent,
    trackSessionInRoster: silent,
    repairStalePersistedStatus: async () => {},
    buildInitialSessionMetadata: method("buildInitialSessionMetadata"),
    buildInitialSessionMeta: method("buildInitialSessionMeta"),
    stripLiftedMetaKeys: method("stripLiftedMetaKeys"),
    persistence: {
      saveSession: async (record) =>
        records.set(record.metadata.id, JSON.parse(JSON.stringify(record))),
      loadSessionMetadata: async (id) => records.get(id)?.metadata,
    },
    buildSessionAgentRegistry: method("buildSessionAgentRegistry"),
    registerFileBasedAgents: async (registry) => {
      registry.register(creator, "bundled-profile");
      return [];
    },
    applyWorkflowAgentVisibility: silent,
    resolveLoadedSessionFeatures: () => ({ featureFlags: { gates: {} } }),
    rebuiltSessionPolicies: { evictSession: silent },
    resolveRegistry: () => undefined,
    restateRuntimeServers: () => [],
    startCloudConfigPull: silent,
    async createSessionState(
      id,
      roots,
      mode,
      model,
      effort,
      shell,
      configuration,
      features,
    ) {
      const built = await this.buildSessionAgentRegistry(
        id,
        roots,
        mode,
        {},
        features,
        { stateClient: silent },
      );
      return {
        sessionId: id,
        rootConversationId: id,
        workspacePaths: roots,
        modeId: mode,
        registry: built.registry,
        nixPromptSnapshot: constructCarrier(features),
        nixWorkspaceRoots: constructRoots(features),
        featureConfig: { get: () => false },
        repositories: [],
        pendingNotifications: [],
      };
    },
  };
  for (const name of [
    "progressiveContextManager",
    "steeringManager",
    "slashCommandManager",
    "availableToolsManager",
    "modelRegistryManager",
  ])
    host[name] = { pushToSession: silent };
  const create = method("createNewSessionState");
  const newLocal = async (id, cwd, internal) =>
    residentAdmission.call(
      host,
      { kind: "create-exclusive", sessionId: id },
      async (register) =>
        create.call(
          host,
          await nixRoots.resolveRequest(
            home,
            {
              cwd,
              _meta: {
                kiro: {
                  nixPromptSnapshot: b,
                  nixWorkspaceRoots: { version: 99 },
                  serverSession: { ownerSessionId: id },
                },
              },
            },
            [cwd],
          ),
          {},
          {},
          id,
          "vibe",
          undefined,
          register,
          undefined,
          true,
          internal,
        ),
    );
  await writeFile(join(repoA, "identity.txt"), "ACP_A.");
  await writeSettings(repoSettings(repoA), { identity: "identity.txt" });
  await writeFile(
    repoSettings(repoB),
    JSON.stringify({
      "chat.promptFiles": { identity: "identity.txt" },
      "chat.additionalDirectories": ["../b-extra"],
    }),
  );
  await Promise.all([newLocal("acp-a", repoA), newLocal("acp-b", repoB)]);
  assert.deepEqual(
    [...states.get("acp-b").state.workspacePaths],
    [repoB, join(tmp, "b-extra")],
  );
  assert.deepEqual(records.get("acp-b").metadata._meta.kiro.nixWorkspaceRoots, {
    version: 1,
    protocol: [repoB],
  });
  assert.equal(
    states.get("acp-a").state.nixPromptSnapshot.slots.identity,
    "ACP_A.",
  );
  assert.equal(
    records.get("acp-a").metadata._meta.kiro.nixPromptSnapshot.slots.identity,
    "ACP_A.",
  );
  assert.equal(
    records.get("acp-b").metadata._meta.kiro.nixPromptSnapshot.slots.identity,
    b.slots.identity,
  );
  await rm(join(repoA, "identity.txt"));
  await newLocal("child", repoA, {
    role: "workflow-step",
    ownerSessionId: "acp-a",
  });
  assert.equal(
    states.get("child").state.nixPromptSnapshot,
    states.get("acp-a").state.nixPromptSnapshot,
  );
  states.delete("acp-a");
  assert.deepEqual(await nixRoots.ownerRoots(host, "acp-a"), [repoA]);
  const hydrated = await method("hydrateSessionForLoad").call(
    host,
    "session/load",
    { sessionId: "acp-a", cwd: repoA },
    records.get("acp-a"),
    {},
    false,
    outbound,
    silent,
  );
  assert.equal(hydrated.session.nixPromptSnapshot.slots.identity, "ACP_A.");
  await writeSettings(repoSettings(repoB), { identity: "identity.txt" });
  const coldRoots = await method("hydrateSessionForLoad").call(
    host,
    "session/load",
    await nixRoots.resolveRequest(home, { sessionId: "acp-b", cwd: repoB }, [
      repoB,
    ]),
    records.get("acp-b"),
    {},
    false,
    outbound,
    silent,
  );
  assert.deepEqual([...coldRoots.session.workspacePaths], [repoB]);
  assert.equal(
    coldRoots.session.nixPromptSnapshot.slots.identity,
    b.slots.identity,
  );

  await newLocal("cold-child", repoA, {
    role: "workflow-step",
    ownerSessionId: "acp-a",
  });
  assert.equal(
    states.get("cold-child").state.nixPromptSnapshot.slots.identity,
    "ACP_A.",
  );
  // Cold child hydration survives owner eviction using current cwd authority.
  const evictedRecord = records.get("acp-a");
  records.delete("acp-a");
  states.delete("acp-a");
  states.delete("cold-child");
  const orphan = await method("hydrateSessionForLoad").call(
    host,
    "session/load",
    await nixRoots.restoreRequest(host, {
      sessionId: "cold-child",
      cwd: repoA,
    }),
    records.get("cold-child"),
    {},
    false,
    outbound,
    silent,
  );
  assert.deepEqual([...orphan.session.workspacePaths], [repoA]);
  assert.equal(orphan.session.nixPromptSnapshot.slots.identity, "ACP_A.");
  records.set("acp-a", evictedRecord);
  Object.assign(context, {
    sx: (value) => value,
    nKi: (messages) => ({ messages }),
    wLt: () => "forked",
    sCe: async () => [],
    b4o: () => [],
    kDu: { rewind: true },
  });
  const forked = await method("forkSession").call(
    {
      loadParentSession: async () => records.get("acp-a"),
      persistence: host.persistence,
    },
    {
      sessionId: "acp-a",
      parentWorkspacePaths: [repoA],
      createdReason: "rewind",
    },
  );
  assert.equal(
    forked.metadata._meta.kiro.nixPromptSnapshot.slots.identity,
    "ACP_A.",
  );
  assert.equal(
    records.get("forked").metadata._meta.kiro.nixPromptSnapshot.slots.identity,
    "ACP_A.",
  );
  const movedFork = await method("forkSession").call(
    {
      loadParentSession: async () => records.get("acp-a"),
      persistence: host.persistence,
    },
    {
      sessionId: "acp-a",
      cwd: repoB,
      additionalDirectories: [join(tmp, "explicit-fork")],
      parentWorkspacePaths: [repoA],
      createdReason: "rewind",
    },
  );
  assert.deepEqual(movedFork.metadata._meta.kiro.nixWorkspaceRoots.protocol, [
    repoB,
    join(tmp, "explicit-fork"),
  ]);
  const restoredFork = await nixRoots.restoreRequest(host, {
    sessionId: "forked",
    cwd: repoB,
  });
  assert.equal(restoredFork.cwd, repoB);
  assert.deepEqual(restoredFork.additionalDirectories, [
    join(tmp, "explicit-fork"),
  ]);
  host.persistence.saveSession = async () => {
    throw new Error("fixture durable save failed");
  };
  await assert.rejects(
    newLocal("save-fails", repoB),
    /fixture durable save failed/,
  );
  assert.equal(states.has("save-fails"), false);
  console.log(
    "PASS: actual ACP creation/hydration and strict save; global/repo/null paths; interleaved snapshots; cold/resident/owner reuse after deletion; malformed files/snapshots; registry refresh and precedence; actual Vibe/custom/msg0 constructors and both request representations",
  );
} finally {
  if (savedHome === undefined) delete process.env.KIRO_HOME;
  else process.env.KIRO_HOME = savedHome;
  await rm(tmp, { recursive: true, force: true });
}
