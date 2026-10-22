# The Caddyfile carries only the policy path; see docs/cliproxyapi-front-gate.md.
{
  lib,
  pkgs,
}: let
  caddy = import ../../../lib/ai/caddy.nix {inherit lib pkgs;};
  # The variable that carries the policy file's path.
  policyVariable = "CPA_GATE_POLICY";
in {
  inherit policyVariable;

  # Caddy's error log copies the request before any handler runs: the URI
  # with its query, and every header but the four Caddy redacts. So a key in
  # `?key=`, `X-Api-Key` or `X-Goog-Api-Key` would reach it; both fields go.
  caddyfile = {
    host,
    port,
  }:
    lib.concatStringsSep "\n" [
      (caddy.globalBlock {logDeletes = ["request>headers" "request>uri"];})
      ""
      ":${toString port} {"
      "\tbind ${host}"
      "\troute {"
      # `*` is the matcher token: Caddy takes a first argument starting
      # with `/` as a path matcher, and the policy path is absolute.
      "\t\tcpa_gate * ${caddy.envRef policyVariable}"
      "\t}"
      "}"
      ""
    ];
}
