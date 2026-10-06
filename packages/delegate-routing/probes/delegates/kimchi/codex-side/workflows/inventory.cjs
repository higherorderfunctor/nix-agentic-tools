const fs = require("node:fs");
const path = require("node:path");
const ts = require(process.env.TYPESCRIPT_JS);
const root = process.env.KIMCHI_WORKFLOWS_SRC;
const targets = {
  "src/host/extension.ts": ["piWorkflowsExtension"],
  "src/host/commands/run.ts": ["handleRun", "handleCreate", "startRun"],
  "src/host/commands/lifecycle.ts": [
    "handleCancel",
    "soleBlockedRun",
    "handleDelete",
  ],
  "src/host/commands/status.ts": ["handleStatus"],
  "src/flow/create-agent-step.ts": [
    "CreateAgentStepOptions",
    "createAgentStep",
  ],
  "src/flow/create-workflow.ts": [
    "CreateWorkflowOptions",
    "DEFAULT_MAX_CONCURRENCY",
    "DEFAULT_FOREACH_CONCURRENCY",
    "createWorkflow",
    "assertConcurrencyWithinCeiling",
  ],
  "src/flow/isolation.ts": [
    "resolveIsolation",
    "walk",
    "resolveNode",
    "resolveBody",
    "resolveStep",
  ],
  "src/engine/scheduler.ts": ["createConcurrencyGate"],
  "src/engine/step-runner.ts": [
    "DEFAULT_MAX_OUTPUT_REPAIRS",
    "resolveBudgetMs",
    "resolveResumeKey",
    "runAgentStep",
  ],
  "src/engine/types.ts": ["AgentRequest"],
  "src/engine/resume-workflow.ts": ["resumeWorkflow", "resumeWithAnswer"],
  "src/host/resume-router.ts": ["resumeAction"],
  "src/host/active-runs.ts": ["createActiveRun", "createActiveRuns"],
  "src/host/subagent-process.ts": [
    "SIGKILL_GRACE_MS",
    "killOnAbort",
    "runSubagent",
  ],
  "src/host/naming.ts": [
    "resumeSessionFile",
    "traceSessionFile",
    "stepSessionName",
  ],
  "src/host/pi-agent.ts": [
    "resolvePiInvocation",
    "inheritedExtensionArgs",
    "stepOutputToolsStem",
    "sessionPath",
    "backgroundSession",
    "createPiAgentBridge",
  ],
  "src/host/step-output-tools.ts": [
    "registerStepOutputTools",
    "activeToolsForStep",
    "registerStepOutputToolsFromEnv",
  ],
};
const files = {};
for (const [relative, names] of Object.entries(targets)) {
  const file = path.join(root, relative),
    text = fs.readFileSync(file, "utf8");
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const items = [];
  const visit = (node) => {
    let name;
    if (
      (ts.isFunctionDeclaration(node) ||
        ts.isClassDeclaration(node) ||
        ts.isInterfaceDeclaration(node) ||
        ts.isTypeAliasDeclaration(node) ||
        ts.isEnumDeclaration(node)) &&
      node.name
    )
      name = node.name.text;
    if (ts.isVariableStatement(node))
      for (const d of node.declarationList.declarations)
        if (ts.isIdentifier(d.name)) {
          const n = d.name.text;
          if (names.includes(n))
            items.push({
              name: n,
              kind: "variable",
              startLine:
                sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1,
              endLine: sf.getLineAndCharacterOfPosition(node.end).line + 1,
              source: node.getText(sf),
            });
        }
    if (name && names.includes(name))
      items.push({
        name,
        kind: ts.SyntaxKind[node.kind],
        startLine: sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1,
        endLine: sf.getLineAndCharacterOfPosition(node.end).line + 1,
        source: node.getText(sf),
      });
    if (ts.isSwitchStatement(node)) {
      const cases = node.caseBlock.clauses.map((c) => ({
        case: ts.isCaseClause(c) ? c.expression.getText(sf) : "default",
        startLine: sf.getLineAndCharacterOfPosition(c.getStart(sf)).line + 1,
        endLine: sf.getLineAndCharacterOfPosition(c.end).line + 1,
      }));
      if (relative.endsWith("extension.ts"))
        items.push({
          name: "workflow command dispatch switch",
          kind: "SwitchStatement",
          startLine:
            sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1,
          endLine: sf.getLineAndCharacterOfPosition(node.end).line + 1,
          cases,
        });
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  files[relative] = items;
}
const out = {
  source: root,
  typescript: "5.9.3",
  method: "TypeScript AST declaration and command-switch inventory",
  files,
};
fs.writeFileSync(
  path.join(process.cwd(), "inventory.json"),
  JSON.stringify(out, null, 2) + "\n",
);
