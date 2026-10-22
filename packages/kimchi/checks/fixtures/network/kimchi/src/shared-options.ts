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
