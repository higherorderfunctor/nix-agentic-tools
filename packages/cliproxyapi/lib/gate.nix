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
    healthPort,
    host,
    port,
    upstreamPort,
  }:
    lib.concatStringsSep "\n" ([
        (caddy.globalBlock {logDeletes = ["request>headers" "request>uri"];})
        ""
        ":${toString port} {"
        "\tbind ${host}"
        "\t@listing path /v1/models /v1/models/* /v1beta/models /v1beta/models/*"
        "\troute {"
        # `*` is the matcher token: Caddy takes a first argument starting
        # with `/` as a path matcher, and the policy path is absolute.
        "\t\tcpa_gate * ${caddy.envRef policyVariable} http://127.0.0.1:${toString upstreamPort}"
        "\t\treverse_proxy @listing 127.0.0.1:${toString upstreamPort} {"
      ]
      ++ map (header: "\t\t\theader_up -${header}") caddy.strippedHopHeaders
      ++ map (line: "\t\t\t${line}") caddy.proxyTuning
      ++ [
        "\t\t}"
        "\t}"
        "}"
        ""
        ":${toString healthPort} {"
        "\tbind 127.0.0.1"
        "\tcpa_gate_health * ${caddy.envRef policyVariable}"
        "}"
        ""
      ]);
}
