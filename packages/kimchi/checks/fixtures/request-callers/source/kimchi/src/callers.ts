// Rejects merging the guarded and cross-file callers of one helper into a single edge.
export function helper() {
  return fetch("https://callers.example");
}
export function guarded() {
  if (process.env.ENABLED) helper();
}
