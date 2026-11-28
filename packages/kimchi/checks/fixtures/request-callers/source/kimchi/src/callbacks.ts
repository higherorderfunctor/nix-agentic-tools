// Rejects an edge for a stored callback property and keeps the unresolved pi.on registration.
function callback() {
  return fetch("https://callbacks.example");
}
const unrelated = { fetchImpl: callback };
// Fails dropping unresolved callees: the callback gets a registration boundary.
pi.on("x", callback);
