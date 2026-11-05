// Fails shallow argument scans: nested literal properties are still callback syntax.
function request() {
  return fetch("https://nested.example");
}
function receive(options: unknown) {}
export function register() {
  receive({ options: { fetchImpl: request } });
}
