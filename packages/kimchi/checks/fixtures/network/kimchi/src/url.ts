const BASE = "https://n01-new-url-base.test";
// N01 new URL(path, base)
export async function n01(path: string) {
  return fetch(new URL(path, BASE));
}
// N02 new URL with literal path and literal base
export async function n02() {
  return fetch(new URL("/v1/models", "https://n02-new-url-literal.test"));
}
// N03 URL.toString() / href
export async function n03() {
  const u = new URL("https://n03-url-href.test/v1");
  u.searchParams.set("a", "b");
  return fetch(u.href);
}
