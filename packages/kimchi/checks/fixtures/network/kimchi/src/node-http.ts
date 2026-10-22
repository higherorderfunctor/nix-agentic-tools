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
// H06 https.request with a module constant as its hostname
const H06_HOST = "h06-module-const.test";
export function h06() {
  return https.request({ hostname: H06_HOST, path: "/v1" });
}
// H07 https.request with a local constant as its hostname
export function h07() {
  const host = "h07-local-const.test";
  return https.request({ hostname: host, path: "/v1" });
}
// H08 a host-shaped constant joined into a URL's path, not after "://": not a host origin, negative control
const H08_SEGMENT = "h08-path-segment.test";
export function h08() {
  return https.get("https://h08-base.test/" + H08_SEGMENT);
}
