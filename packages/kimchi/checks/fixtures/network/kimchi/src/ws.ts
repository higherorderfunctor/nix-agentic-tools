import WebSocket from "ws";
// W01 global WebSocket
export const w01 = () =>
  new globalThis.WebSocket("wss://w01-global-ws.test/socket");
// W02 ws library
export const w02 = () => new WebSocket("wss://w02-ws-lib.test/socket");
// W03 ws with a URL from a field (kimchi teleport shape)
export class Transport {
  constructor(private url: string) {}
  open() {
    return new WebSocket(this.url, { headers: {} });
  }
}
export const w03 = () => new Transport("wss://w03-ws-field.test/pty").open();
