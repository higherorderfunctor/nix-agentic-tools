// Fails method-name matching: both this and the constructed receiver must resolve.
class Client {
  send() {
    return fetch("https://class.example");
  }
  run() {
    this.send();
  }
}
const client = new Client();
export function invoke() {
  client.run();
}
