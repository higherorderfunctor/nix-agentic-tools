// Fails path enumeration: the last edge has distance two even via a longer route.
function sink() {
  return fetch("https://distance.example");
}
function middle() {
  sink();
}
function outer() {
  sink();
  middle();
}
export function entry() {
  outer();
}
