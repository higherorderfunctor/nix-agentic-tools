const fs = require("node:fs");
const assert = require("node:assert/strict");
const path = require("node:path");
const ts = require(process.env.TYPESCRIPT_JS);
const root = process.env.KIMCHI_SRC;
const picks = {
  "src/extensions/agents/manager/agent-runner.ts": [
    "EXCLUDED_TOOL_NAMES",
    "isExcludedSubagentToolName",
    "getPromptToolNames",
    "getActiveSubagentToolNames",
    "runAgent",
    "withParentSessionEnv",
  ],
  "src/extensions/agents/manager/agent-manager.ts": [
    "setMaxConcurrent",
    "spawn",
    "abort",
    "getResumeBlockReason",
    "cleanup",
  ],
  "src/extensions/agents/resolution/invocation-config.ts": [
    "resolveAgentInvocationConfig",
  ],
  "src/extensions/agents/personas/custom-agents.ts": [
    "loadCustomAgents",
    "loadFromDir",
  ],
  "src/extensions/agents/personas/types.ts": [
    "ThinkingLevel",
    "AgentTaskRef",
    "AgentResumeAttempt",
    "AgentOutcome",
    "AgentConfig",
    "JoinMode",
    "IsolationMode",
  ],
  "src/extensions/agents/settings.ts": [
    "SubagentsSettings",
    "SettingsAppliers",
    "VALID_JOIN_MODES",
    "MAX_CONCURRENT_CEILING",
    "MAX_TURNS_CEILING",
    "GRACE_TURNS_CEILING",
    "sanitize",
    "globalPath",
    "projectPath",
  ],
  "src/extensions/agents/resume-tool.ts": ["registerResumeSubagentTool"],
  "src/extensions/permissions/config.ts": ["configSchema", "modeSchema"],
  "src/extensions/permissions/rules.ts": [
    "parseRule",
    "matchRule",
    "evaluateRules",
  ],
  "src/extensions/agents/manager/output-file.ts": [
    "createOutputFilePath",
    "writeInitialEntry",
  ],
  "src/extensions/agents/manager/session-file.ts": ["prepareAgentSessionFile"],
};
const out = [];
for (const [rel, names] of Object.entries(picks)) {
  const abs = path.join(root, rel);
  const txt = fs.readFileSync(abs, "utf8");
  const sf = ts.createSourceFile(
    abs,
    txt,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  const wanted = new Set(names);
  const visit = function visit(n) {
    let name;
    if (
      ts.isFunctionDeclaration(n) ||
      ts.isMethodDeclaration(n) ||
      ts.isVariableDeclaration(n) ||
      ts.isInterfaceDeclaration(n) ||
      ts.isTypeAliasDeclaration(n) ||
      ts.isEnumDeclaration(n)
    )
      name = n.name?.getText(sf);
    if (name && wanted.has(name)) {
      const p = sf.getLineAndCharacterOfPosition(n.getStart(sf));
      out.push({
        file: rel,
        name,
        line: p.line + 1,
        endLine: sf.getLineAndCharacterOfPosition(n.getEnd()).line + 1,
        nodeKind: ts.SyntaxKind[n.kind],
        source: n.getText(sf),
      });
      wanted.delete(name);
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
  assert.equal(wanted.size, 0, `${rel}: missing ${[...wanted].join(", ")}`);
}
console.log(JSON.stringify(out, null, 2));
