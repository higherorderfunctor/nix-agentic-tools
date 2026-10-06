const { fs, nodes, code } = require("./ast.cjs");
const out = nodes
  .filter(
    (n) =>
      n.type === "MethodDefinition" &&
      [
        "runNode",
        "executeNode",
        "executeParallel",
        "runParallel",
        "invoke",
        "pause",
        "cancel",
        "applyStepUpdate",
        "runStep",
        "executeStep",
        "createStepSession",
        "resumeStep",
        "withDeadline",
        "getSubExecutions",
        "getActiveSubAgentExecutions",
      ].includes(n.key.name),
  )
  .map((n) => ({ name: n.key.name, line: n.loc.start.line, source: code(n) }));
fs.writeFileSync(process.cwd() + "/runner.json", JSON.stringify(out, null, 2));
console.log(
  out.map((x) => ({ name: x.name, line: x.line, chars: x.source.length })),
);
