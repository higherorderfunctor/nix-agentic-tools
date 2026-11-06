// Fails silent truncation: the fifth edge is represented by a depth boundary.
function zero() {
  return fetch("https://depth.example");
}
function one() {
  zero();
}
function two() {
  one();
}
function three() {
  two();
}
function four() {
  three();
}
export function five() {
  four();
}
