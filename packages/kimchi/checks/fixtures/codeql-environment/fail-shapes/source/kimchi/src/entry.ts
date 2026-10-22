import * as proc from "node:process";
import { destructuredHelper, dynamicKey } from "./lib.js";

proc.env.ALIASED_WRITE = "1";
const { env } = process;
void env.DESTRUCTURED_ENV;
const k = String(Date.now());
process.env[k] = "1";
destructuredHelper(process.env);
const whole = process.env;
void whole;
dynamicKey(process.env);
{
  process.env[k] = "1";
  proc.env.ALIASED_IN_BLOCK = "1";
}
if (Math.random()) {
  process.env[k] = "1";
} else {
  proc.env.ALIASED_IN_ELSE = "1";
}
