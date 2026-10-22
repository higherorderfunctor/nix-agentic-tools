export function helper(env: Record<string, string | undefined>) {
  return env.VIA_PARAM;
}
export function unrelated() {
  return process.env.ONLY_IN_LIB;
}
