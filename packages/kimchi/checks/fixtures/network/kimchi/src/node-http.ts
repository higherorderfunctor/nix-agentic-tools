import http from "node:http";
import * as https from "node:https";
import { get as httpsGet, request as httpsRequest } from "https";
// H01 http.request with a string URL
export function h01() {
  return http.request("http://h01-http-request.test/v1");
}
// H02 https.get with a string URL
export function h02() {
  return https.get("https://h02-https-get.test/v1");
}
// H03 https.request with an options object (hostname)
export function h03() {
  return https.request({
    hostname: "h03-https-options.test",
    path: "/v1",
    method: "GET",
  });
}
// H04 named-import request with a URL object
export function h04() {
  return httpsRequest(new URL("https://h04-https-named.test/v1"));
}
// H05 named-import get with url + options
export function h05() {
  return httpsGet("https://h05-https-get-named.test/v1", { headers: {} });
}
