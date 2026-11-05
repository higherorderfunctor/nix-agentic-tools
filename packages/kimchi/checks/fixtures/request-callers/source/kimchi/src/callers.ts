// Fails merging by callee: guarded and plain callers remain separate edges.
export function helper() {
  return fetch("https://callers.example");
}
export function guarded() {
  if (process.env.ENABLED) helper();
}
export function plain() {
  helper();
}
