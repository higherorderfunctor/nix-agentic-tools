# The Caddyfile carries only the policy path; see docs/cliproxyapi-front-gate.md.
{
  lib,
  pkgs,
}: let
  caddy = import ../../../lib/ai/caddy.nix {inherit lib pkgs;};
  exact = import ./exact-models.nix {inherit lib;};
  redact = import ../../../lib/redact {inherit lib;};
  render = import ../../../lib/extracted/render.nix {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  credentials = exact.routedCredentials;
  models = exact.clientModels;
  internalKey = instance: name:
    redact.command (lib.getExe (strictShellApplication pkgs {
      name = "cpa-internal-key";
      text = "exec ${pkgs.python3}/bin/python3 ${./internal-key.py} ${lib.escapeShellArgs [instance.stateDir (builtins.hashString "sha256" name)]}";
    }));
  policy = instance:
    (render.render {
      prefix = "CPA_GATE";
      settings.entries =
        lib.mapAttrsToList (name: client: {
          inherit name;
          inherit (client) key;
          internal = internalKey instance name;
          # A route chooses an upstream API. CPA translates all three Harness
          # protocols to that API; restricting these to route.api would break it.
          apis = ["anthropic" "chat" "responses"];
          models = models instance client;
          hostedTools = {};
        })
        instance.clientKeys;
    })
    // {variable = policyVariable;};
  # The variable that carries the policy file's path.
  policyVariable = "CPA_GATE_POLICY";
in {
  inherit internalKey models policy policyVariable;
  clientProblems = name: instance:
    lib.concatLists (lib.mapAttrsToList (clientName: client: let
      path = "ai.cliproxyapi.instances.${name}.clientKeys.${clientName}";
      listed = lib.defaultTo [] client.models ++ lib.defaultTo [] client.excludedModels;
      served = exact.routedModels instance client;
    in
      lib.optional ((client.models != null || client.excludedModels != null) && !instance.gate.enable)
      "${path}: client model lists require gate.enable = true; enable the gate or remove models and excludedModels."
      ++ lib.optional (client.models != null && client.excludedModels != null)
      "${path}: set models XOR excludedModels, or leave both unset."
      ++ lib.optional (client.models == [] || client.excludedModels == [])
      "${path}: model lists must not merge to empty."
      ++ lib.optionals instance.gate.enable (
        lib.optional (!(lib.all exact.modelName listed))
        "${path}: gate requires exact printable model names without auto, parentheses, slash, wildcard, cloak prefix or secret placeholder."
        ++ lib.optional (!(lib.all (model: lib.elem model served) listed))
        "${path}: a client model name is not served by any routed credential's selected models."
        ++ lib.optional (models instance client == [])
        "${path}: the client model set must not be empty."
      ))
    instance.clientKeys);
  problems = name: instance:
    lib.optional (!instance.exactModels) "ai.cliproxyapi.instances.${name}: gate.enable requires exactModels."
    ++ lib.optional (instance.clientKeys == {}) "ai.cliproxyapi.instances.${name}: gate.enable requires named clientKeys."
    ++ lib.concatLists (lib.mapAttrsToList (clientName: client: let
      allowed = models instance client;
    in
      # Metadata is rendered with the secrets too. A whole placeholder name
      # would become a secret in unauthenticated health and refusal logs.
      lib.optional (render.placeholderName clientName != null)
      "ai.cliproxyapi.instances.${name}.clientKeys: gate refuses whole-placeholder names, which would substitute secrets into public metadata."
      ++ lib.optional (lib.any (credential: lib.any (model: lib.elem model (exact.catalog credential) && !(lib.elem model (exact.selected credential))) allowed) (credentials instance client))
      "ai.cliproxyapi.instances.${name}.clientKeys.${clientName}: gate model union includes a model excluded by another routed credential's catalog (G3).")
    instance.clientKeys);

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
        "\troute {"
        # `*` is the matcher token: Caddy takes a first argument starting
        # with `/` as a path matcher, and the policy path is absolute.
        "\t\tcpa_gate * ${caddy.envRef policyVariable} http://127.0.0.1:${toString upstreamPort}"
        "\t\treverse_proxy 127.0.0.1:${toString upstreamPort} {"
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
        "\troute {"
        "\t\tcpa_gate_health * ${caddy.envRef policyVariable}"
        "\t}"
        "}"
        ""
      ]);
}
