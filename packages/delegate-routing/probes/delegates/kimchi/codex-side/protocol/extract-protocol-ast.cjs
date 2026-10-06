const fs = require("node:fs");
const ts = require(process.env.TYPESCRIPT_JS);
const PI = `${process.env.PI_SRC}/dist`;
const K = `${process.env.KIMCHI_SRC}/src`;
const out = {};
function parse(path) {
  const text = fs.readFileSync(path, "utf8");
  return ts.createSourceFile(
    path,
    text,
    ts.ScriptTarget.Latest,
    true,
    path.endsWith(".d.ts")
      ? ts.ScriptKind.TS
      : path.endsWith(".ts")
        ? ts.ScriptKind.TS
        : ts.ScriptKind.JS,
  );
}
function loc(a, n) {
  return a.getLineAndCharacterOfPosition(n.getStart(a)).line + 1;
}
function extractTop(path, names) {
  const a = parse(path);
  return a.statements
    .filter(
      (n) =>
        names.has(n.name?.text) ||
        (ts.isVariableStatement(n) &&
          n.declarationList.declarations.some((d) =>
            names.has(d.name.getText(a)),
          )),
    )
    .map((n) => ({
      line: loc(a, n),
      kind: ts.SyntaxKind[n.kind],
      name: n.name?.text ?? "",
      text: n.getText(a),
    }));
}
const rpcMode = PI + "/modes/rpc/rpc-mode.js";
out.pi_rpc_runRpcMode = extractTop(rpcMode, new Set(["runRpcMode"]));
out.pi_rpc_protocol_types = extractTop(
  PI + "/modes/rpc/rpc-types.d.ts",
  new Set([
    "RpcCommand",
    "RpcResponse",
    "RpcEvent",
    "RpcSessionState",
    "RpcSlashCommand",
  ]),
);
const agentPath = PI + "/core/agent-session.js";
{
  const a = parse(agentPath),
    c = a.statements.find(
      (n) => ts.isClassDeclaration(n) && n.name?.text === "AgentSession",
    );
  out.pi_agent_session_methods = c.members.map((n) => ({
    line: loc(a, n),
    kind: ts.SyntaxKind[n.kind],
    name: n.name?.getText(a) ?? "",
    text: n.getText(a),
  }));
}
const acpPath = K + "/modes/acp/server.ts";
out.kimchi_acp_top = parse(acpPath).statements.map((n) => ({
  line: loc(parse(acpPath), n),
  kind: ts.SyntaxKind[n.kind],
  name: n.name?.getText(parse(acpPath)) ?? "",
  text: n.getText(parse(acpPath)),
}));
{
  const a = parse(acpPath),
    c = a.statements.find(
      (n) => ts.isClassDeclaration(n) && n.name?.text === "KimchiAcpAgent",
    );
  out.kimchi_acp_methods = c.members.map((n) => ({
    line: loc(a, n),
    kind: ts.SyntaxKind[n.kind],
    name: n.name?.getText(a) ?? "",
    text: n.getText(a),
  }));
}
for (const rel of [
  "modes/acp/acp-prompter.ts",
  "modes/acp/acp-ui-context.ts",
  "extensions/agents/index.ts",
  "extensions/mcp/index.ts",
  "extensions/mcp/probe.ts",
  "integrations/claude-code.ts",
  "integrations/codex.ts",
  "integrations/opencode.ts",
  "commands/claude.ts",
  "commands/codex.ts",
  "commands/opencode.ts",
  "commands/cursor.ts",
  "commands/openclaw.ts",
  "cli-args.ts",
  "cli-modes.ts",
  "cli.ts",
  "modes/acp/ext-methods/steering.ts",
  "modes/acp/permission-prompter-registry.ts",
  "modes/acp/capabilities.ts",
  "modes/acp/state.ts",
  "commands/mcp.ts",
  "commands/registry.ts",
  "integrations/spawn.ts",
  "extensions/agents/manager/agent-manager.ts",
  "extensions/agents/manager/agent-runner.ts",
  "extensions/agents/resume-tool.ts",
  "extensions/remote-run/runner.ts",
  "extensions/remote-run/dispatch-tool.ts",
  "extensions/remote-run/index.ts",
  "extensions/permissions/constants.ts",
  "extensions/permissions/mode-controller.ts",
  "extensions/permissions/mode.ts",
  "extensions/remote-run/runner.ts",
]) {
  const path = K + "/" + rel,
    a = parse(path);
  out["kimchi_" + rel] = a.statements
    .map((n) => ({
      line: loc(a, n),
      kind: ts.SyntaxKind[n.kind],
      name:
        n.name?.getText(a) ??
        (ts.isVariableStatement(n)
          ? n.declarationList.declarations
              .map((d) => d.name.getText(a))
              .join(",")
          : ""),
      text: n.getText(a),
    }))
    .filter((x) => x.name);
}

// Retain individual AgentManager methods, extension session-shutdown hooks,
// RPC switch arms and protocol method dispatch arms as AST-derived records.
{
  const p = K + "/extensions/agents/manager/agent-manager.ts",
    a = parse(p),
    c = a.statements.find(
      (n) => ts.isClassDeclaration(n) && n.name?.text === "AgentManager",
    );
  {
    const p = K + "/extensions/mcp/probe.ts",
      a = parse(p),
      c = a.statements.find(
        (n) => ts.isClassDeclaration(n) && n.name?.text === "UpstreamMcpProbe",
      );
    out.mcp_probe_methods = c.members.map((n) => ({
      line: loc(a, n),
      kind: ts.SyntaxKind[n.kind],
      name: n.name?.getText(a) ?? "",
      text: n.getText(a),
    }));
    out.mcp_probe_process_helpers = a.statements
      .filter(
        (n) =>
          ts.isFunctionDeclaration(n) &&
          ["executeProcess", "createProbeHost"].includes(n.name?.text),
      )
      .map((n) => ({ line: loc(a, n), name: n.name.text, text: n.getText(a) }));
  }
  out.agent_manager_methods = c.members.map((n) => ({
    line: loc(a, n),
    kind: ts.SyntaxKind[n.kind],
    name: n.name?.getText(a) ?? "",
    text: n.getText(a),
  }));
}
{
  const p = K + "/extensions/agents/index.ts",
    a = parse(p),
    hits = [];
  const walk = function walk(n) {
    if (
      ts.isCallExpression(n) &&
      n.expression.getText(a) === "pi.on" &&
      n.arguments[0]?.text === "session_shutdown"
    )
      hits.push({ line: loc(a, n), text: n.getText(a) });
    ts.forEachChild(n, walk);
  };
  walk(a);
  out.agent_shutdown_hooks = hits;
}
function calls(path, predicates) {
  const a = parse(path),
    hits = [];
  const walk = function walk(n) {
    if (ts.isCallExpression(n)) {
      const name = n.expression.getText(a);
      if (predicates(name, n, a))
        hits.push({ line: loc(a, n), name, text: n.getText(a) });
    }
    ts.forEachChild(n, walk);
  };
  walk(a);
  return hits;
}
out.agent_tool_registrations = calls(
  K + "/extensions/agents/index.ts",
  (name) => name === "pi.registerTool",
);
out.agent_spawn_calls = calls(
  K + "/extensions/agents/manager/agent-manager.ts",
  (name) =>
    [
      "runAgent",
      "runRemoteAgent",
      "createAgentSession",
      "resumeAgent",
      "attachRemoteAgent",
    ].includes(name),
);
out.agent_session_calls = calls(
  K + "/extensions/agents/manager/agent-runner.ts",
  (name) =>
    [
      "createAgentSession",
      "session.prompt",
      "session.steer",
      "session.abort",
    ].includes(name),
);
out.integration_spawn_calls = calls(
  K + "/integrations/spawn.ts",
  (name) => name === "nodeSpawn",
);
out.cli_protocol_dispatch_calls = calls(K + "/cli.ts", (name) =>
  ["runAcpMode", "main"].includes(name),
);
function processCalls(dir, names) {
  const result = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = require("node:path").join(dir, entry.name);
    if (entry.isDirectory()) {
      result.push(...processCalls(p, names));
      continue;
    }
    if (!p.endsWith(".ts") || p.includes(".test.")) continue;
    const a = parse(p);
    const walk = function walk(n) {
      if (ts.isCallExpression(n)) {
        const name = n.expression.getText(a).split(".").at(-1);
        if (names.includes(name))
          result.push({ file: p, line: loc(a, n), name, text: n.getText(a) });
      }
      ts.forEachChild(n, walk);
    };
    walk(a);
  }
  return result;
}
out.command_process_calls = processCalls(K + "/commands", [
  "spawn",
  "spawnSync",
  "exec",
  "execSync",
  "execFile",
  "execFileSync",
  "fork",
  "nodeSpawn",
]);
out.command_foreground_calls = processCalls(K + "/commands", ["runForeground"]);

function switchCases(path, rootName, switchExpression) {
  const a = parse(path),
    root = a.statements.find(
      (n) =>
        (ts.isFunctionDeclaration(n) || ts.isClassDeclaration(n)) &&
        n.name?.text === rootName,
    ),
    hits = [];
  const walk = function walk(n) {
    if (
      ts.isSwitchStatement(n) &&
      (!switchExpression || n.expression.getText(a) === switchExpression)
    )
      hits.push({
        line: loc(a, n),
        expression: n.expression.getText(a),
        cases: n.caseBlock.clauses.map((c) => ({
          line: loc(a, c),
          case: ts.isCaseClause(c) ? c.expression.getText(a) : "default",
          text: c.getText(a),
        })),
      });
    ts.forEachChild(n, walk);
  };
  walk(root);
  return hits;
}
out.rpc_command_switches = switchCases(
  PI + "/modes/rpc/rpc-mode.js",
  "runRpcMode",
  "command.type",
);
out.acp_ext_method_switches = switchCases(
  K + "/modes/acp/server.ts",
  "KimchiAcpAgent",
  "method",
);

// Public Pi agent-session factory contract and Kimchi permission/resource wiring.
out.pi_sdk_agent_session_declarations = extractTop(
  PI + "/core/sdk.d.ts",
  new Set(["CreateAgentSessionOptions", "createAgentSession"]),
);
out.pi_cli_parse_args_declarations = extractTop(
  PI + "/cli/args.js",
  new Set(["parseArgs", "CliArgs"]),
);
out.pi_cli_main_declaration = extractTop(PI + "/main.js", new Set(["main"]));
for (const rel of [
  "modes/acp/server.ts",
  "extensions/permissions/index.ts",
  "extensions/permissions/config.ts",
  "config.ts",
  "resources/store.ts",
  "resources/definitions.ts",
  "resources/filter.ts",
  "resources/extension.ts",
  "cli.ts",
  "cli-args.ts",
]) {
  const p = K + "/" + rel,
    a = parse(p);
  out["protocol_" + rel] = a.statements
    .map((n) => ({
      line: loc(a, n),
      kind: ts.SyntaxKind[n.kind],
      name:
        n.name?.getText(a) ??
        (ts.isVariableStatement(n)
          ? n.declarationList.declarations
              .map((d) => d.name.getText(a))
              .join(",")
          : ""),
      text: n.getText(a),
    }))
    .filter((x) => x.name);
}
out.acp_session_factory_declarations = extractTop(
  K + "/modes/acp/server.ts",
  new Set(["defaultSessionFactory", "createSessionSettings", "RunAcpOptions"]),
);
out.permission_functions = extractTop(
  K + "/extensions/permissions/index.ts",
  new Set(["canPrompt", "resolvePrompter", "handleConfirm"]),
);
out.resource_store_declarations = extractTop(
  K + "/resources/store.ts",
  new Set([
    "SETTINGS_KEY",
    "getResourceSettingsPath",
    "isResourceEnabled",
    "setResourceOverride",
    "resetResourceOverride",
  ]),
);
out.resource_agent_definitions = extractTop(
  K + "/resources/definitions.ts",
  new Set(["STATIC_RESOURCE_DEFINITIONS", "getResourceDefinitions"]),
);
out.cli_extension_calls = calls(
  K + "/cli.ts",
  (name) =>
    name.includes("Extension") ||
    name.includes("extension") ||
    name === "createAgentSession",
);

// Dedicated daemon and session-scoped background Bash surfaces. Extract every
// top-level declaration, class member, and process/control call as real TS AST.
for (const rel of [
  "extensions/daemon/daemon-tool.ts",
  "extensions/daemon/daemon-control-tool.ts",
  "extensions/daemon/spawn.ts",
  "extensions/daemon/state.ts",
  "extensions/daemon/index.ts",
  "extensions/bash-background/bash-background-tool.ts",
  "extensions/bash-background/bash-control-tool.ts",
  "extensions/bash-background/process-registry.ts",
  "extensions/bash-background/index.ts",
  "extensions/bash-background/bash-control-extension.ts",
  "extensions/bash-background/session-registry.ts",
  "extensions/bash-tool-guard.ts",
  "extensions/experimental.ts",
]) {
  const p = K + "/" + rel,
    a = parse(p);
  out["kimchi_" + rel] = a.statements
    .map((n) => ({
      line: loc(a, n),
      kind: ts.SyntaxKind[n.kind],
      name:
        n.name?.getText(a) ??
        (ts.isVariableStatement(n)
          ? n.declarationList.declarations
              .map((d) => d.name.getText(a))
              .join(",")
          : ""),
      text: n.getText(a),
    }))
    .filter((x) => x.name);
  const classes = a.statements.filter((n) => ts.isClassDeclaration(n));
  for (const c of classes)
    out["members_" + rel + "_" + (c.name?.text ?? "anonymous")] = c.members.map(
      (n) => ({
        line: loc(a, n),
        kind: ts.SyntaxKind[n.kind],
        name: n.name?.getText(a) ?? "",
        text: n.getText(a),
      }),
    );
}
const daemonDir = K + "/extensions/daemon";
out.daemon_process_calls = processCalls(daemonDir, [
  "spawn",
  "spawnSync",
  "exec",
  "execSync",
  "execFile",
  "execFileSync",
  "fork",
  "nodeSpawn",
  "process.kill",
]);
const bgDir = K + "/extensions/bash-background";
out.bash_background_process_calls = processCalls(bgDir, [
  "spawn",
  "spawnSync",
  "exec",
  "execSync",
  "execFile",
  "execFileSync",
  "fork",
  "nodeSpawn",
  "process.kill",
]);
out.daemon_tool_registrations = calls(
  K + "/extensions/daemon/index.ts",
  (name) => name === "pi.registerTool",
);
out.daemon_extension_hooks = calls(
  K + "/extensions/daemon/index.ts",
  (name) => name === "pi.on",
);
out.background_extension_hooks = calls(
  K + "/extensions/bash-background/index.ts",
  (name) => name === "pi.on",
);
fs.writeFileSync(
  process.cwd() + "/protocol-ast.json",
  JSON.stringify(out, null, 2),
);
console.log(
  JSON.stringify(
    Object.fromEntries(Object.entries(out).map(([k, v]) => [k, v.length])),
  ),
);
