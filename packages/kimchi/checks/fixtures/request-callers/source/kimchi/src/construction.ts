// Fails dropping new-expression callers: a reached constructor has a caller edge.
class Client {
  constructor() {
    fetch("https://construction.example");
  }
}
const Receiver = Client;
export function construct() {
  new Receiver();
}
