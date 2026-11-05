// Fails call-start site keys: both registrations in one chain must survive.
function request() {
  return fetch("https://chain.example");
}
export function register() {
  request().then(request).catch(request);
}
