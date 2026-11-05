// Fails classifying source constructors as external callback registrations.
function reconnect() {
  return fetch("https://constructor.example");
}
class Supervisor {
  constructor(options: unknown) {}
}
const Receiver = Supervisor;
export function connect() {
  new Receiver({ reconnect });
}
export function entry() {
  connect();
}
