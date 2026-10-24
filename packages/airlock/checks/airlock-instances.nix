# `ai.airlock.instances` (modules/instances.nix): both backends render one
# config for one instance, its secrets reach the launcher as secret files,
# its port is claimed, and airlock's own `check-config` accepts the render.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  inherit (import ../../../lib/extracted/render.nix {inherit lib;}) fill;
  redact = import ../../../lib/redact {inherit lib;};
  asFile = value: {_redact.asFile = value;};

  claudeToken = redact.file "/run/secrets/airlock-claude-token";
  harnessToken = redact.file "/run/secrets/airlock-harness-token";
  zaiKey = redact.file "/run/secrets/airlock-zai-key";
  # A fixed stateDir, since each backend defaults it under its own root.
  sample = {
    port = 8400;
    stateDir = "/srv/airlock/main";
    settings = {
      clients.harness = {
        grants = [
          {
            credentials = ["claude" "zai"];
            upstream = "anthropic";
          }
        ];
        token = harnessToken;
      };
      credentials = {
        claude = {
          auth = {
            file = claudeToken;
            type = "oauth_bearer";
          };
          upstream = "anthropic";
        };
        zai = {
          auth = {
            file = zaiKey;
            type = "api_key";
          };
          upstream = "anthropic";
        };
      };
    };
  };
  evaluate = backend: ai:
    (
      if backend == "hm"
      then evalHm
      else evalDevenv
    ) {ai = lib.recursiveUpdate {airlock.instances.main = sample;} ai;};
  fileOf = result: result.config.ai.services.airlock-main.files.config;
  hm = fileOf (evaluate "hm" {});
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);
  thrown = backend: ai: !(builtins.tryEval (builtins.deepSeq (fileOf (evaluate backend ai)).content true)).success;

  # Each secret's placeholder filled with an absolute dummy path, where the
  # launcher would put the 0600 file it writes.
  checked = pkgs.writeText "airlock-config-roundtrip.json" (fill (lib.mapAttrs (name: _: "/run/airlock-check/${name}") hm.secrets) hm.content);
in {
  checks = {
    airlock-config-roundtrip = pkgs.runCommand "airlock-config-roundtrip" {nativeBuildInputs = [pkgs.ai.generic.airlock];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      airlock check-config --config ${checked}
      echo "ok — airlock check-config accepts the rendered instance config" >"$out"
    '';

    airlock-module-eval = mkTest "airlock-module-eval" (
      lib.all (backend: let
        result = evaluate backend {};
        file = fileOf result;
      in
        file
        == hm
        && file.variable == "AIRLOCK_CONFIG"
        # Tagged as secret files: the launcher writes each to a 0600 file and
        # the config receives its path, never the value.
        && file.secrets
        == {
          AIRLOCK_CLIENTS_HARNESS_TOKEN_FILE = asFile harnessToken;
          AIRLOCK_CREDENTIALS_CLAUDE_AUTH_FILE = asFile claudeToken;
          AIRLOCK_CREDENTIALS_ZAI_AUTH_FILE = asFile zaiKey;
        }
        && (builtins.fromJSON file.content).state_dir == sample.stateDir
        && result.config.ai.claims.port."8400" == ["airlock:airlock-main.ports.main"]
        && failures result == []
        # Another owner's service on the instance's port.
        && failures (evaluate backend {cliproxyapi.instances.main.port = 8400;})
        == ["ai.claims.port.8400: claimed by airlock:airlock-main.ports.main and cliproxyapi:cliproxyapi-main.ports.main"]
        # The instance fixes the listen address, and a token takes a reference.
        && thrown backend {airlock.instances.main.settings.listen = "0.0.0.0:8400";}
        && thrown backend {airlock.instances.main.settings.clients.harness.token = "fake-SECRET-token";})
      ["devenv" "hm"]
    );
  };
}
