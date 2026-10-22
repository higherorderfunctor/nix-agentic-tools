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
