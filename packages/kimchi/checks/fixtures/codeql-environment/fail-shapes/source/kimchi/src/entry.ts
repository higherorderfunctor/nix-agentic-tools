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

unknownForward(process.env);
function unknownForward(env: Record<string, string | undefined>) {
  const { KNOWN: known, ...rest } = env;
  return unknownConsumer(rest);
}

for (const unknownListKey of externalNames()) void process.env[unknownListKey];
for (const mixedKey of ["KNOWN_NAME", externalName()]) void process.env[mixedKey];
for (const [label, names] of [["missing"]]) {
  for (const missingKey of names) void process.env[missingKey];
}

const mutatedNames = ["KNOWN_MUTATION"];
mutatedNames.push(externalName());
for (const mutationKey of mutatedNames) void process.env[mutationKey];
const nestedNames = [["KNOWN_NESTED"]];
nestedNames[0][0] = externalName();
for (const [nestedKey] of nestedNames) void process.env[nestedKey];
for (const [ignored, spreadKey] of [[...externalNames(), "KNOWN_SPREAD"]]) void process.env[spreadKey];
for (const sparseKey of ["KNOWN_SPARSE", ,]) void process.env[sparseKey];

for (let updateKey of ["KNOWN_UPDATE"]) {
  updateKey++;
  void process.env[updateKey];
}
