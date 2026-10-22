import process from "node:process";
import { helper, templated } from "./lib.js";

const early = process.env.READ_FIRST;
process.env.READ_FIRST = "1";
const viaGlobal = globalThis["process"].env.READ_VIA_GLOBAL_THIS;
process.env.READ_VIA_GLOBAL_THIS = "1";
process.env.FIXED_DOT = "1";
process.env["FIXED_BRACKET"] = "1";
if (Math.random()) {
  process.env.IF_BOTH = "1";
} else {
  process.env.IF_BOTH = "2";
}
if (Math.random()) {
  process.env.IF_ONE = "1";
}
try {
  process.env.IN_TRY = "1";
} catch {}
{
  process.env.IN_BLOCK = "1";
}
process.env.SAME_STMT = process.env.SAME_STMT ?? "d";
helper(process.env);
process.env.VIA_PARAM = "1";
templated(process.env);
process.env.VIA_PARAM_KEY = "1";
process.env.LATER_ARROW = "1";
const later = () => process.env.LATER_ARROW;
function declared() {
  return process.env.IN_FN_DECL;
}
process.env.IN_FN_DECL = "1";
void [(process.env.IN_ARRAY = "1"), 0];
const packageMetadata = { main: "./cli.js" }; // a property key spelled like a suspending main(): no suspension
void [(process.env.ARRAY_BEFORE_AWAIT = "1"), await 0]; // stores before the await suspends
void early;
void viaGlobal;
void later;
void declared;
void packageMetadata;
void process.env.FIXED_DOT;
void process.env.FIXED_BRACKET;
void process.env.IF_BOTH;
void process.env.IF_ONE;
void process.env.IN_TRY;
void process.env.IN_BLOCK;
void process.env.IN_ARRAY;
void process.env.ARRAY_BEFORE_AWAIT;
void process.env.VIA_PARAM_KEY;
