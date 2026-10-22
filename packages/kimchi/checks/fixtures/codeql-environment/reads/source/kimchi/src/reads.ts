import nodeProcess, * as proc from "node:process";
import { env as namedEnv } from "node:process";
import { PREFIX } from "./lib/consts.js";

const LOCAL_KEY = "S03_CONST_KEY";
const TEMPLATE_KEY = `${PREFIX}_TEMPLATE`;
const lower = "s05_upper";

void process.env.S01_DOT;
void process.env["S02_BRACKET"];
void process.env[LOCAL_KEY];
void process.env[TEMPLATE_KEY];
void process.env[lower.toUpperCase()];
void process.env[`S06_${"INLINE"}`];
void process.env["S07_" + "CONCAT"]; // not folded: no read
const env = process.env;
void env.S08_ALIAS;
export function f(options: { env?: NodeJS.ProcessEnv }) {
  const e2 = options.env ?? process.env;
  void e2.S09_NULLISH_ALIAS;
  const e3 = options.env || process.env;
  void e3.S10_OR_ALIAS;
}
export function g(e4 = process.env) {
  void e4.S11_PARAM_DEFAULT;
}
const { env: e5 } = process;
void e5.S12_DESTRUCTURED_ENV;
const { S14_DESTRUCTURED_NAME } = process.env; // a property pattern: kept out
void S14_DESTRUCTURED_NAME;
void process["env"].S15_PROCESS_BRACKET_ENV;
void globalThis.process.env.S16_GLOBAL_THIS;
void globalThis["process"].env.S17_GLOBAL_THIS_BRACKET;
void proc.env.S18_NAMESPACE_IMPORT;
void nodeProcess.env.S19_DEFAULT_IMPORT;
void namedEnv.S20_NAMED_IMPORT; // a named import of env: kept out
void (process.env as Record<string, string>).S21_AS_PAREN;
void process.env?.S22_OPTIONAL;
void globalThis.process?.env?.S23_OPTIONAL_CHAIN;
process.env.S24_WRITE_ONLY = "1"; // a write: no read
delete process.env.S25_DELETE; // a delete: no read
process.env.S26_COMPOUND += "x";
process.env.S27_NULLISH_ASSIGN ??= "x";
function h(e6: NodeJS.ProcessEnv) {
  return e6.S29_PARAM_NO_DEFAULT; // flow does not cross the call: no read
}
void h(process.env);
const k = Math.random() > 0.5 ? "S30_A" : "S30_B";
void process.env[k]; // not constant: no read
void getProviderEnvValue("S31_PROVIDER");
void getProviderEnvValue(LOCAL_KEY, process.env);
declare function getProviderEnvValue(
  name: string,
  env?: object,
): string | undefined;
const pp = process;
void pp.env.S32_PROCESS_ALIAS;
void { ...process.env, S33_SPREAD_CHILD: "1" }.S33_SPREAD_CHILD; // a derived object: no read
for (const name of ["S34_LOOP"]) void process.env[name]; // no initializer: no read
void Object.keys(process.env);
void require("process").env.S28_REQUIRE;
void process.env.SHARED_BOTH;
