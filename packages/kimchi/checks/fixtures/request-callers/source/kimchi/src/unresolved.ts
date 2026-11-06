// Fails dropping unsupported escapes: returning a function is an explicit boundary.
function request() {
  return fetch("https://unresolved.example");
}
export function returnRequest() {
  return request;
}
