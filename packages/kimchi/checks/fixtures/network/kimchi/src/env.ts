// E01 env with a literal fallback
export async function e01() {
  return fetch(process.env.E01_URL ?? "https://e01-env-default.test/v1");
}
// E02 env host only, no literal
export async function e02() {
  return fetch(`${process.env.E02_HOST}/v1`);
}
// E03 env read into a constant first
const E03 = process.env.E03_URL || "https://e03-env-const.test";
export async function e03() {
  return fetch(`${E03}/v1`);
}
