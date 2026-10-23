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

// std-env in pi 1.3.0 bundle/chunks/jiti-loader: optional process and tuple fallback.
const zt = globalThis.process?.env || Object.create(null);
const Zt = { name: "std-env" };
const Xt=(Zt.name,Zt.name,[["GITHUB_ACTIONS"],["CIRCLE","CIRCLECI"]]);
function ciProvider() {
  for (let e3 of Xt) if (zt[e3[1] || e3[0]]) return { name: e3[0].toLowerCase(), ...e3[2] };
}

const { GIT_DIR, GIT_COMMON_DIR, GIT_WORK_TREE, GIT_INDEX_FILE } = process.env;

// Declared key helpers: oauth-config and shared/env-int.
function readKey(name: string) {
  return process.env[name];
}
const helperKey = "HELPER_CONSTANT";
void readKey("HELPER_LITERAL");
void readKey(helperKey);

// Bundled module initialization assigns a previously declared binding.
let assignedKey: string;
assignedKey = "ASSIGNED_KEY";
void process.env[assignedKey];
