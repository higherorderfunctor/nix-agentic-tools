// Fails bare-identifier-only resolution: the receiver binding owns this method.
const client = {
  send() {
    return fetch("https://method.example");
  },
};
export function invoke() {
  client.send();
}
export function maybe() {
  client?.send(); // Fails a resolver that drops optional member calls.
}
