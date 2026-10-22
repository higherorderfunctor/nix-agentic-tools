// Environment origins
// E01 env with a literal fallback
export async function e01() {
  return fetch(process.env.E01_URL ?? "https://e01-env-default.test/v1");
}

// Fetch parameter and docs-only negative
// F04 fetch passed in as a parameter, called inside a helper
async function viaParam(fetchImpl: typeof fetch, url: string) {
  return fetchImpl(url);
}
export async function f04() {
  return viaParam(fetch, "https://f04-fetch-param.test/v1");
}
// F06 docs-only URL never requested: negative control
export const F06_DOCS = "https://f06-docs-only.test/readme";
export function f06() {
  console.log(F06_DOCS);
}

// Host value flow and path negative
import * as https from "node:https";
// H03 https.request with an options object (hostname)
export function h03() {
  return https.request({
    hostname: "h03-https-options.test",
    path: "/v1",
    method: "GET",
  });
}
// H06 https.request with a module constant as its hostname
const H06_HOST = "h06-module-const.test";
export function h06() {
  return https.request({ hostname: H06_HOST, path: "/v1" });
}
// H08 a host-shaped constant joined into a URL's path, not after "://": not a host origin, negative control
const H08_SEGMENT = "h08-path-segment.test";
export function h08() {
  return https.get("https://h08-base.test/" + H08_SEGMENT);
}

// Computed keys and spread
// Region table used through a computed key and spread
export const REGIONS = {
  us: {
    webAppUrl: "https://r01-app-us.test",
    castApiUrl: "https://r01-api-us.test",
  },
  eu: {
    webAppUrl: "https://r01-app-eu.test",
    castApiUrl: "https://r01-api-eu.test",
  },
} as const;
type RegionId = keyof typeof REGIONS;
// R02 the web app URL only opened in a browser, never fetched: negative control
export function r02() {
  console.log(`${REGIONS.us.webAppUrl}/login`);
}
// R06 kimchi's spread: endpoints built by spreading a resolved region
function regionEndpoints(r: { castApiUrl: string }) {
  return { castApiUrl: r.castApiUrl, statsUrl: `${r.castApiUrl}/stats` };
}
function endpointsSpread(id: RegionId) {
  const resolved = REGIONS[id];
  const e = regionEndpoints(resolved);
  return { ...e, extra: process.env.R06_EXTRA ?? e.statsUrl };
}
export const r06 = (id: RegionId) => fetch(endpointsSpread(id).extra);

// SDK model rows
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import axios from "axios";
// S03 MCP streamable HTTP transport
export const s03 = () =>
  new StreamableHTTPClientTransport(new URL("https://s03-mcp-http.test/mcp"));
// S04 MCP SSE transport
export const s04 = () =>
  new SSEClientTransport(new URL("https://s04-mcp-sse.test/sse"));
// S05 axios control (modeled upstream)
export const s05 = () => axios.get("https://s05-axios.test/v1");

// Shared options and logger negatives
import Anthropic from "@anthropic-ai/sdk";
import OpenAI from "openai";
import pino from "pino";
import { Agent } from "undici";
// O01 SDK options also passed to console.log: the logger call is not a call site, negative control
export function o01() {
  const opts = {
    baseURL: "https://o01-shared-sdk-options.test/v1",
    apiKey: "x",
  };
  console.log(opts);
  return new OpenAI(opts);
}
// O02 undici per-call options also passed to console.info: the logger call is not a call site, negative control
export function o02() {
  const o = {
    origin: "https://o02-shared-undici-options.test",
    path: "/",
    method: "GET",
  };
  console.info(o);
  return new Agent().request(o);
}
// O03 SDK options also passed to an imported logger: the logger call is not a call site, negative control
const log = pino();
export function o03() {
  const opts = {
    baseURL: "https://o03-shared-logger-options.test/v1",
    apiKey: "x",
  };
  log.info(opts);
  return new OpenAI(opts);
}
// O04 one options object handed to two modeled SDKs: each call keeps its own package
export function o04() {
  const opts = {
    baseURL: "https://o04-two-sdks-one-options.test/v1",
    apiKey: "x",
  };
  const openai = new OpenAI(opts);
  const anthropic = new Anthropic(opts);
  return [openai, anthropic];
}

// Host joined after a scheme
// T03 scheme-less host joined into a template
const HOST = "t03-hostonly.test";
export async function t03() {
  return fetch(`https://${HOST}/v1`);
}

// Undici model rows
import {
  EnvHttpProxyAgent,
  getGlobalDispatcher,
  Pool,
  ProxyAgent,
  WebSocket as UndiciWebSocket,
} from "undici";
// U05 Pool bound to an origin
export async function u05() {
  return new Pool("https://u05-pool.test").request({
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
// U11 undici WebSocket
export const u11 = () => new UndiciWebSocket("wss://u11-undici-ws.test/socket");

// URL construction and property reads
const BASE = "https://n01-new-url-base.test";
// N01 new URL(path, base)
export async function n01(path: string) {
  return fetch(new URL(path, BASE));
}
// N03 URL.toString() / href
export async function n03() {
  const u = new URL("https://n03-url-href.test/v1");
  u.searchParams.set("a", "b");
  return fetch(u.href);
}

// WebSocket through a field
import WebSocket from "ws";
// W03 ws with a URL from a field (kimchi teleport shape)
export class Transport {
  constructor(private url: string) {}
  open() {
    return new WebSocket(this.url, { headers: {} });
  }
}
export const w03 = () => new Transport("wss://w03-ws-field.test/pty").open();
