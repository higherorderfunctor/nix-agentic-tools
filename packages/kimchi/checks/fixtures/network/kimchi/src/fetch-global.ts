// F01 global fetch with a literal
export async function f01() {
  return fetch("https://f01-global-fetch.test/v1");
}
// F02 globalThis.fetch
export async function f02() {
  return globalThis.fetch("https://f02-globalthis-fetch.test/v1");
}
// F03 fetch held in a variable behind ??, like kimchi's fetchWithRetry
export async function f03(opts?: { fetchImpl?: typeof fetch }) {
  const fetchFn = opts?.fetchImpl ?? globalThis.fetch;
  return fetchFn("https://f03-fetch-var.test/v1");
}
// F04 fetch passed in as a parameter, called inside a helper
async function viaParam(fetchImpl: typeof fetch, url: string) {
  return fetchImpl(url);
}
export async function f04() {
  return viaParam(fetch, "https://f04-fetch-param.test/v1");
}
// F05 a wrapper with the URL as a parameter (kimchi src/utils/http.ts shape)
async function fetchWithRetry(url: string, init?: RequestInit) {
  return globalThis.fetch(url, init);
}
export async function f05() {
  return fetchWithRetry("https://f05-wrapper.test/v1");
}
// F06 docs-only URL never requested: negative control
export const F06_DOCS = "https://f06-docs-only.test/readme";
export function f06() {
  console.log(F06_DOCS);
}
