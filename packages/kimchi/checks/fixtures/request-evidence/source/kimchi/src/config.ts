export function loadConfig() {
  return JSON.parse(process.env.FIXTURE_CONFIG || "{}");
}
