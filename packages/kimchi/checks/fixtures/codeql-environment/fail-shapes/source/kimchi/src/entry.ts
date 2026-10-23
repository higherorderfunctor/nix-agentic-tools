const k = String(Date.now());
process.env[k] = "1";
destructuredHelper(process.env);
const whole = process.env;
void whole;
dynamicKey(process.env);
{
  process.env[k] = "1";
}
if (Math.random()) {
  process.env[k] = "1";
} else {
}
export function destructuredHelper({
  VIA_PATTERN,
}: Record<string, string | undefined>) {
  return VIA_PATTERN;
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

void process.env["S07_" + "CONCAT"];
