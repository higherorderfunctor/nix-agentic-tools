// Patch inspected AST entry points only; never execute the vendor bundle.

import { createHash } from "node:crypto";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const [path, defaultsPath, typescript, corpusPath] = process.argv.slice(2);
const ts = createRequire(import.meta.url)(typescript);
let source = readFileSync(path, "utf8");
const corpus = JSON.parse(readFileSync(corpusPath, "utf8"));
const bytes = Buffer.from(source);
if (createHash("sha256").update(bytes).digest("hex") !== corpus.sourceSha256)
  throw new Error(
    "prompt-files: selected corpus does not describe input source",
  );
const file = ts.createSourceFile(
  path,
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
);
if (file.parseDiagnostics.length)
  throw new Error("prompt-files: invalid input JavaScript");
const printer = ts.createPrinter();
const nodes = [];
function visit(node) {
  nodes.push(node);
  ts.forEachChild(node, visit);
}
visit(file);
const edits = [];
function unique(predicate, label) {
  const matches = nodes.filter(predicate);
  if (matches.length !== 1)
    throw new Error(
      `prompt-files: ${label}: expected one AST node, found ${matches.length}`,
    );
  return matches[0];
}
function replace(text, before, after) {
  if (text.split(before).length !== 2)
    throw new Error(`prompt-files: expected one anchor: ${before}`);
  return text.replace(before, () => after);
}
function edit(node, transform) {
  const text = printer.printNode(ts.EmitHint.Unspecified, node, file);
  edits.push({
    start: node.getStart(file),
    end: node.end,
    text: transform(text),
  });
}
function method(name, transform) {
  edit(
    unique(
      (n) => ts.isMethodDeclaration(n) && n.name.getText(file) === name,
      name,
    ),
    transform,
  );
}
function fn(name, transform) {
  edit(
    unique((n) => ts.isFunctionDeclaration(n) && n.name?.text === name, name),
    transform,
  );
}
function variable(name) {
  return unique(
    (n) => ts.isVariableDeclaration(n) && n.name.getText(file) === name,
    name,
  );
}
const defaults = Object.fromEntries(
  ["identity", "workflowFileCheckGuidance", "worktreeGuidance"].map((name) => [
    name,
    readFileSync(join(defaultsPath, `${name}.txt`), "utf8"),
  ]),
);
const worktree = JSON.parse(
  readFileSync(join(defaultsPath, "worktree-parts.json"), "utf8"),
);
const literal = JSON.stringify;
function corpusNode(range, label) {
  const start = bytes.subarray(0, range.start).toString("utf8").length;
  const end = bytes.subarray(0, range.end).toString("utf8").length;
  return unique(
    (node) => node.getStart(file) === start && node.end === end,
    label,
  );
}

// The identity is a static sentence inside the CLI arm, not the whole system
// prompt. Preserve the terminal-environment suffix and every runtime append.
const identityGroup = corpus.groups.identity;
const identityFunction = corpusNode(
  identityGroup.callable,
  "identity constructor",
);
const identityLiteral = corpusNode(
  corpus.chunks[identityGroup.chunk],
  "CLI identity literal",
);
if (
  !ts.isFunctionDeclaration(identityFunction) ||
  !identityFunction.name ||
  !ts.isNoSubstitutionTemplateLiteral(identityLiteral) ||
  identityLiteral.parent.parent !== identityFunction.body.statements[0]
)
  throw new Error("prompt-files: identity corpus owner shape changed");
const identityName = identityFunction.name.text;
// Validate the exact selected prefix; arbitrary user files are never parsed as JS.
if (
  !identityLiteral.text.startsWith(
    defaults.identity + " You operate in a terminal environment:",
  )
)
  throw new Error("prompt-files: CLI identity suffix changed");
edit(identityFunction, (text) => {
  text = replace(text, `${identityName}(e)`, `${identityName}(e, nixSnapshot)`);
  const raw = printer.printNode(ts.EmitHint.Unspecified, identityLiteral, file);
  return replace(
    text,
    raw,
    `((nixSnapshot?.slots.identity ?? ${literal(defaults.identity)}) + ${literal(identityLiteral.text.slice(defaults.identity.length))})`,
  );
});
const identityCall = unique(
  (node) =>
    ts.isCallExpression(node) && node.expression.getText(file) === identityName,
  "identity caller",
);
let identityCaller = identityCall.parent;
while (identityCaller && !ts.isFunctionDeclaration(identityCaller))
  identityCaller = identityCaller.parent;
if (!identityCaller)
  throw new Error("prompt-files: identity caller has no function owner");
edit(identityCaller, (text) =>
  replace(
    text,
    `${identityName}(n)`,
    `${identityName}(n, r.nixPromptSnapshot)`,
  ),
);

const worktreeLiteral = corpusNode(
  corpus.chunks[corpus.groups.workflowOrchestration.chunk],
  "worktree guidance literal",
);
const worktreeVariable = worktreeLiteral.parent;
if (
  !ts.isVariableDeclaration(worktreeVariable) ||
  worktreeVariable.initializer !== worktreeLiteral
)
  throw new Error("prompt-files: worktree corpus owner shape changed");
const worktreeName = worktreeVariable.name.getText(file);
if (
  worktreeVariable.initializer.text !==
  worktree[0] + defaults.worktreeGuidance + worktree[1]
)
  throw new Error(
    "prompt-files: selected worktree template differs from corpus",
  );
edit(
  worktreeVariable.initializer,
  () =>
    `(nixSnapshot) => ${literal(worktree[0])} + (nixSnapshot?.slots.worktreeGuidance ?? ${literal(defaults.worktreeGuidance)}) + ${literal(worktree[1])}`,
);
method("createDefinitionForMode", (text) =>
  replace(
    text,
    `text: ${worktreeName},`,
    `text: ${worktreeName}(t.nixPromptSnapshot),`,
  ),
);
method("sessionAgentContext", (text) =>
  replace(
    text,
    "return t.language ? { ...this.agentContext, language: t.language } : this.agentContext;",
    "return { ...this.agentContext, ...(t.language ? { language: t.language } : {}), nixPromptSnapshot: t.nixPromptSnapshot };",
  ),
);

// Source-aware registration applies on initial load AND every vendor refresh.
// Only this session's bundled creator is copied; tools/permissions/origin stay.
const registry = variable("wae").initializer;
const register = registry.members.find(
  (n) => n.name?.getText(file) === "register",
);
edit(register, (text) =>
  replace(
    text,
    "let i =",
    `t = nixPrompts.profile(t, r, this.nixPromptSnapshot, ${literal(defaults.workflowFileCheckGuidance)}); let i =`,
  ),
);
method("buildSessionAgentRegistry", (text) =>
  replace(
    text,
    "p = new wae,",
    "p = Object.assign(new wae, { nixPromptSnapshot: o.nixPromptSnapshot }),",
  ),
);

// Resolve once before persistence identity lookup; remote/empty sessions retain
// their vendor routes and resident joins retain their constructed policy.
method("newSessionAdmitted", (text) =>
  replace(
    text,
    "let d = o?.overrideSessionId ?? wLt()",
    "if (!o?.isEmptyWorkspace) { const resident = this.sessionState(o?.overrideSessionId); t = resident ? await nixRoots.residentRequest(t, resident) : r?.serverSession ? await nixRoots.workflowRequest(this, t, r.serverSession.ownerSessionId, Uke(t, false)) : await nixRoots.resolveRequest(this.homeDir, t, Uke(t, false)); } let d = o?.overrideSessionId ?? wLt()",
  ),
);
method("loadSessionAdmitted", (text) =>
  replace(
    text,
    "let l = Uke(t, s?.isEmptyWorkspace === !0)",
    "if (!s?.isEmptyWorkspace) { const resident = this.sessionState(t.sessionId); if (!resident && r?.nixRestoreRoots) t = await nixRoots.restoreRequest(this, t); t = resident ? await nixRoots.residentRequest(t, resident) : nixRoots.requestAuthority(t) ? t : await nixRoots.resolveRequest(this.homeDir, t, Uke(t, false)); } let l = Uke(t, s?.isEmptyWorkspace === !0)",
  ),
);

// Spec reuse hydrates directly instead of calling session/load. Keep its
// resident arm, but feed one resolved request to cold lookup and construction.
method("getOrCreateSpecSession", (text) => {
  text = replace(
    text,
    "let u = await this.persistence.loadSession(o, r);",
    "const nixRequest = r.length ? await nixRoots.resolveRequest(this.homeDir, { cwd: r[0] }, r) : undefined; let u = await this.persistence.loadSession(o, nixRequest ? Uke(nixRequest, false) : []);",
  );
  return replace(
    text,
    "f = { sessionId: o, cwd: l, mcpServers: [], ...d.length > 0 ? { additionalDirectories: d } : {} }",
    "f = { ...nixRequest, sessionId: o, cwd: l, mcpServers: [] }",
  );
});

method("residentSessionState", (text) =>
  replace(
    text,
    "isEmptyWorkspace: n.workspacePaths.length === 0 } } })",
    "isEmptyWorkspace: n.workspacePaths.length === 0 } } }, { nixRestoreRoots: true })",
  ),
);
method("loadSessionOnDemand", (text) =>
  replace(
    text,
    "isEmptyWorkspace: n } } })",
    "isEmptyWorkspace: n } } }, { nixRestoreRoots: true })",
  ),
);
fn("A9r", (text) =>
  replace(
    text,
    "e.loadSession($xo(t), {",
    "e.loadSession($xo(t), { nixRestoreRoots: true,",
  ),
);

// MCP configuration belongs to each session's cwd, not its added roots. Limit
// registration before the manager combines roots across concurrent sessions.
method("setWorkspacePaths", (text) =>
  replace(
    text,
    "this.items.openSession(r, t, n)",
    "this.items.openSession(r, t = t.slice(0, 1), n)",
  ),
);
edit(
  unique(
    (n) =>
      ts.isMethodDeclaration(n) &&
      n.name.getText(file) === "stateWorkspace" &&
      ts.isVariableDeclaration(n.parent.parent) &&
      n.parent.parent.name.getText(file) === "S8e",
    "MCP workspace staging",
  ),
  (text) =>
    replace(
      text,
      "this.readWorkspaceFiles(t)",
      "this.readWorkspaceFiles(t.slice(0, 1))",
    ),
);

method("createNewSessionState", (text) => {
  text = replace(
    text,
    "{ let p =",
    "{ const nixSnapshot = l ? await nixPrompts.ownerSnapshot(this, l.ownerSessionId, t.cwd) : await nixPrompts.resolveSnapshot(this.homeDir, r?.isEmptyWorkspace ? undefined : t.cwd, nixWorktrees.requestRoot(t)); let p =",
  );
  text = replace(
    text,
    "{ semanticReviewEnabled: T,",
    "{ nixWorkspaceRoots: nixRoots.requestAuthority(t) ?? { version: 1, protocol: h }, nixPromptSnapshot: nixSnapshot, semanticReviewEnabled: T,",
  );
  return replace(
    text,
    "S.error(`[KiroAgent] Failed to save session ${i}:`, pe);",
    // Creation must be durable before the caller receives a session.
    "S.error(`[KiroAgent] Failed to save session ${i}:`, pe); throw pe;",
  );
});
method("hydrateSessionForLoad", (text) =>
  replace(
    text,
    "lBr(w); let v =",
    "lBr(w); m.nixWorkspaceRoots = nixRoots.requestAuthority(r) ?? { version: 1, protocol: Uke(r, d) }; m.nixPromptSnapshot = n ? nixPrompts.storedSnapshot(n.metadata) : await nixPrompts.resolveSnapshot(this.homeDir, d ? undefined : r.cwd, nixWorktrees.requestRoot(r)); let v =",
  ),
);
method("createSessionState", (text) =>
  replace(
    text,
    "gt = { sessionId: t,",
    "gt = { nixWorkspaceRoots: c.nixWorkspaceRoots, nixPromptSnapshot: c.nixPromptSnapshot, sessionId: t,",
  ),
);
method("buildInitialSessionMetadata", (text) =>
  replace(
    text,
    "...this.buildInitialSessionMeta(r.requestMeta, r.serverSession)",
    "...this.buildInitialSessionMeta(r.requestMeta, r.serverSession), _meta: nixRoots.authorityMetadata(nixPrompts.snapshotMetadata(this.buildInitialSessionMeta(r.requestMeta, r.serverSession)._meta, t.nixPromptSnapshot), t.nixWorkspaceRoots)",
  ),
);
// Forks intentionally copy a selected metadata subset. Carry this durable
// conversation policy without copying unrelated parent runtime metadata.
method("forkSession", (text) =>
  replace(
    text,
    "m = { schemaVersion: i.metadata.schemaVersion,",
    "m = { _meta: nixRoots.authorityMetadata(nixPrompts.snapshotMetadata(undefined, nixPrompts.storedSnapshot(i.metadata)), nixRoots.forkAuthority(t, i.metadata)), schemaVersion: i.metadata.schemaVersion,",
  ),
);
for (const name of ["stripAgentAuthoredMetaKeys", "stripLiftedMetaKeys"])
  method(name, (text) =>
    replace(
      text,
      "{ let r =",
      "{ t = nixRoots.stripAuthority(nixPrompts.stripSnapshot(t)); let r =",
    ),
  );

// Detached workflow rebuilds already know their owner. Forward that one value
// through the existing host seam; never infer ownership from cwd or public meta.
fn("T9r", (text) =>
  replace(text, "e.buildRegistryForRoots(s)", "e.buildRegistryForRoots(s, r)"),
);
const forward = unique(
  (n) =>
    ts.isPropertyAssignment(n) &&
    n.name.getText(file) === "buildRegistryForRoots" &&
    ts.isArrowFunction(n.initializer) &&
    !ts.isBlock(n.initializer.body),
  "workflow registry host forwarding",
);
edit(forward, (text) =>
  replace(
    text,
    "_ => this.host.buildRegistryForRoots(_)",
    "(_, owner) => this.host.buildRegistryForRoots(_, owner)",
  ),
);
const rebuild = unique(
  (n) =>
    ts.isPropertyAssignment(n) &&
    n.name.getText(file) === "buildRegistryForRoots" &&
    ts.isArrowFunction(n.initializer) &&
    ts.isBlock(n.initializer.body),
  "detached registry construction",
);
edit(rebuild, (text) => {
  text = replace(text, "async (d) =>", "async (d, owner) =>");
  return replace(
    text,
    "let p = new wae,",
    "await nixRoots.validateWorkflowRoots(this, owner, d); let p = Object.assign(new wae, { nixPromptSnapshot: await nixPrompts.ownerSnapshot(this, owner, d[0]) }),",
  );
});

edits.sort((a, b) => b.start - a.start);
for (let index = 0; index < edits.length; index++) {
  const item = edits[index];
  if (index > 0 && item.end > edits[index - 1].start)
    throw new Error("prompt-files: overlapping AST edits");
  source = source.slice(0, item.start) + item.text + source.slice(item.end);
}
const importAt = source.startsWith("#!") ? source.indexOf("\n") + 1 : 0;
source =
  source.slice(0, importAt) +
  `import * as nixPrompts from "./prompt-files.mjs";\nimport * as nixWorktrees from "./worktree-policy.mjs";\nimport * as nixRoots from "./additional-roots.mjs";\n` +
  source.slice(importAt);
const diagnostics = ts.createSourceFile(
  path,
  source,
  ts.ScriptTarget.Latest,
  true,
  ts.ScriptKind.JS,
).parseDiagnostics;
if (diagnostics.length) {
  const d = diagnostics[0];
  throw new Error(
    `prompt-files: ${ts.flattenDiagnosticMessageText(d.messageText, " ")} near ${source.slice(d.start - 100, d.start + 100)}`,
  );
}
writeFileSync(path, source);
unlinkSync(join(defaultsPath, "worktree-parts.json"));
console.log(`PASS: ${edits.length} unique prompt/session AST hooks`);
