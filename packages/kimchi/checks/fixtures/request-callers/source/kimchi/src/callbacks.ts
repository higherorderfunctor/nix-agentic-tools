// Fails property-name matching: only the inline call argument makes an edge.
function callback() {
  return fetch("https://callbacks.example");
}
function receive(options: unknown) {}
export function register() {
  receive({ fetchImpl: callback });
}
const unrelated = { fetchImpl: callback };
// Fails dropping unresolved callees: the callback gets a registration boundary.
pi.on("x", callback);
// Fails dropping module stores: this reference needs its own stored boundary.
export const stored = callback;
