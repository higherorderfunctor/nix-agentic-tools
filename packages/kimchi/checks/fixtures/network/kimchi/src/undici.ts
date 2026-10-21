import * as undici from "undici";
import {
  Agent,
  Client,
  EnvHttpProxyAgent,
  getGlobalDispatcher,
  Pool,
  ProxyAgent,
  request,
  stream,
  WebSocket as UndiciWebSocket,
  fetch as undiciFetch,
} from "undici";
// U01 undici.request (named import)
export async function u01() {
  return request("https://u01-undici-request.test/v1");
}
// U02 undici fetch (named import, renamed)
export async function u02() {
  return undiciFetch("https://u02-undici-fetch.test/v1");
}
// U03 namespace import
export async function u03() {
  return undici.request("https://u03-undici-ns.test/v1");
}
// U04 Agent.request with origin option
export async function u04() {
  return new Agent().request({
    origin: "https://u04-agent-origin.test",
    path: "/v1",
    method: "GET",
  });
}
// U05 Pool bound to an origin
export async function u05() {
  return new Pool("https://u05-pool.test").request({
    path: "/v1",
    method: "GET",
  });
}
// U06 Client bound to an origin
export async function u06() {
  return new Client("https://u06-client.test").request({
    path: "/v1",
    method: "GET",
  });
}
// U07 ProxyAgent proxy URL (an egress hop)
export const u07 = new ProxyAgent("http://u07-proxy.test:3128");
// U08 EnvHttpProxyAgent with httpProxy option
export const u08 = new EnvHttpProxyAgent({
  httpProxy: "http://u08-envproxy.test:3128",
});
// U09 global dispatcher request
export async function u09() {
  return getGlobalDispatcher().request({
    origin: "https://u09-global-dispatcher.test",
    path: "/",
    method: "GET",
  });
}
// U10 undici.stream
export async function u10() {
  return stream("https://u10-undici-stream.test/v1", { method: "GET" }, () => {
    throw new Error();
  });
}
// U11 undici WebSocket
export const u11 = () => new UndiciWebSocket("wss://u11-undici-ws.test/socket");
