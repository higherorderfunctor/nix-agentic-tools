import * as proc from "node:process";
import { destructuredHelper } from "./lib.js";

proc.env.ALIASED_WRITE = "1";
const { env } = process;
void env.DESTRUCTURED_ENV;
const k = String(Date.now());
process.env[k] = "1";
destructuredHelper(process.env);
const whole = process.env;
void whole;
