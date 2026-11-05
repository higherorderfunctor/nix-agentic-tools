// Fails unbounded recursion: the second call closes the current function chain.
function first() {
  fetch("https://recursion.example");
  second();
}
function second() {
  first();
}
