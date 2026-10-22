import * as proc from "node:process";

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
export function destructuredHelper({
  VIA_PATTERN,
}: Record<string, string | undefined>) {
  return VIA_PATTERN;
}
export function nested() {
  const {
    env: { NESTED_PATTERN: nestedPattern },
  } = process;
  return nestedPattern;
}
export function shadow() {
  const process = { env: { SHADOWED: "" } };
  return process.env.SHADOWED;
}
export function dynamicKey(
  env: Record<string, string | undefined>,
  key = String(Date.now()),
) {
  return env[key];
}
