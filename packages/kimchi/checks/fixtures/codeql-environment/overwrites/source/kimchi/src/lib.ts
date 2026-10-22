export function helper(env: Record<string, string | undefined>) {
  return env.VIA_PARAM;
}
export function templated(env: Record<string, string | undefined>) {
  const suffix = "_KEY";
  return env[`VIA_PARAM${suffix}`];
}
export function unrelated() {
  return process.env.ONLY_IN_LIB;
}
