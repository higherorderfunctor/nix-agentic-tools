import * as proc from "node:process";
void proc.env.S18_NAMESPACE_IMPORT;
void process["env"].S15_PROCESS_BRACKET_ENV;
void (process.env as Record<string, string>).S21_AS_PAREN;
const pp = process;
void pp.env.S32_PROCESS_ALIAS;
void globalThis["process"].env.S17_GLOBAL_THIS_BRACKET;
void require("process").env.S28_REQUIRE;
process.env.S26_COMPOUND += "x";
void process.env["S07_" + "CONCAT"];

const agents = [
  ["one", ["ITERATED_ONE", "ITERATED_TWO"]],
  ["two", ["ITERATED_THREE", matcher()]],
];
function matcher() { return () => true; }
for (let [agent, names] of agents) {
  for (let key of names) {
    void (typeof key === "string" ? process.env[key] : key());
  }
}

const environmentAlias = process.env;
forwardEnvironment(environmentAlias);
function forwardEnvironment(env: Record<string, string | undefined>) {
  return readEnvironment({ NOT_ENVIRONMENT_ARGUMENT: "local" }, env);
}
function readEnvironment(local: Record<string, string>, env: Record<string, string | undefined>) {
  return local.NOT_ENVIRONMENT_ARGUMENT ?? env.VIA_KNOWN_HELPER;
}
function readUnrelated(local: Record<string, string>) {
  return local.NOT_ENVIRONMENT_HELPER;
}
readUnrelated({ NOT_ENVIRONMENT_HELPER: "local" });
