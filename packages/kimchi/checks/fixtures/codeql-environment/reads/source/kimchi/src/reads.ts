import * as proc from "node:process";
void proc.env.S18_NAMESPACE_IMPORT;
void process["env"].S15_PROCESS_BRACKET_ENV;
void (process.env as Record<string, string>).S21_AS_PAREN;
const pp = process;
void pp.env.S32_PROCESS_ALIAS;
void globalThis["process"].env.S17_GLOBAL_THIS_BRACKET;
void require("process").env.S28_REQUIRE;
process.env.S26_COMPOUND += "x";

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

// Pinned Google auth CommonJS export property.
function certificateConfig(exports) {
  exports.CERTIFICATE_CONFIGURATION_ENV_VARIABLE = "GOOGLE_API_CERTIFICATE_CONFIG";
  return process.env[exports.CERTIFICATE_CONFIGURATION_ENV_VARIABLE];
}

// Pinned AWS bundled reexport, destructured under a different local name.
let ENV_PROFILE;
ENV_PROFILE = "AWS_PROFILE";
const config_exports = {};
__export(config_exports, { ENV_PROFILE: () => ENV_PROFILE });
const { ENV_PROFILE: ENV_PROFILE2 } = (init_config(), __toCommonJS(config_exports));
void process.env[ENV_PROFILE2];

// Pinned PR-cost CI callback.
const CI_VARIABLES = ["CI", "GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "JENKINS_URL", "TEAMCITY_VERSION", "CIRCLECI", "TF_BUILD"];
const ci = CI_VARIABLES.find((name) => process.env[name]?.trim() && !disabled(process.env[name]));

// Pinned steer table indexed by the runtime kind.
const STEER_DISABLE_FLAGS = { todo_early_nudge: "KIMCHI_DISABLE_NUDGE_TODO_EARLY", loop_guard: "KIMCHI_DISABLE_GUARD_LOOP" };
function isSteerDisabled(kind) { return process.env[STEER_DISABLE_FLAGS[kind]] === "1"; }

// Pinned bug-report arrow reader; function expressions use the same helper rule.
const env = (name) => process.env[name] || null;
void env("TERM_PROGRAM");
const functionEnv = function(name) { return process.env[name]; };
void functionEnv("FUNCTION_EXPRESSION_KEY");

// Pinned jiti forwards the key through a boolean reader into the JSON reader.
function _booleanEnv(name, fallback) { return !!_jsonEnv(name, fallback); }
function _jsonEnv(name, fallback) { return process.env[name] || fallback; }
void _booleanEnv("JITI_FS_CACHE", true);
