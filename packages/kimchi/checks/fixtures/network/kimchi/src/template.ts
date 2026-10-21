const API = "https://t01-template.test";
// T01 template literal with a leading constant
export async function t01(id: string) {
  return fetch(`${API}/v1/items/${id}`);
}
// T02 concatenation
export async function t02(id: string) {
  return fetch("https://t02-concat.test/v1/" + id);
}
// T03 scheme-less host joined into a template
const HOST = "t03-hostonly.test";
export async function t03() {
  return fetch(`https://${HOST}/v1`);
}
