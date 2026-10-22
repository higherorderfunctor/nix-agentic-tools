# The cpa-gate Caddyfile, built from the shared lib/ai/caddy.nix pieces. It
# carries the policy file's PATH as a `{$VAR}` token and never a key: Caddy
# splices a `{$VAR}` value in before parsing and keeps it in the adapted
# config.
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
      "\t\tcpa_gate ${caddy.envRef policyVariable}"
      "\t}"
      "}"
      ""
    ];
}
