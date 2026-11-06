// Fails treating exports as dead: no observed use is an unreferenced boundary.
export function entry() {
  return fetch("https://entry.example");
}
