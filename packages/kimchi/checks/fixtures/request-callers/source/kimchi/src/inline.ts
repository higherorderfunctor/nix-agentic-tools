// Fails identifier-only callbacks: arrows and function expressions are values.
function receive(options: unknown, fn: unknown) {}
export function inline() {
  receive({ fetchImpl: () => fetch("https://arrow.example") }, function () {
    void this;
    return fetch("https://expression.example");
  });
}
