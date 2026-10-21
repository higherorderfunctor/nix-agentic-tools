// F07 a module-local function named fetch, a cache lookup and not the global: negative control
const cache = new Map<string, string>();
function fetch(key: string) {
  return cache.get(key);
}
export function f07() {
  return fetch("https://f07-local-fetch.test/v1");
}
