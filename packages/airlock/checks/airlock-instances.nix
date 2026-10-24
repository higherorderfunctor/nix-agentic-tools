# `ai.airlock.instances` (modules/instances.nix): both backends render one
# config for one instance, its secrets reach the launcher as secret files,
# its port is claimed, and airlock's own `check-config` accepts the render.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
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
  packageRefused = backend: ai: !(builtins.tryEval (builtins.deepSeq (toString (builtins.head ((evaluate backend ai).config.home.packages or (evaluate backend ai).config.packages))) true)).success;
  darwinPkgs =
    pkgs
    // {
      stdenv =
        pkgs.stdenv
        // {
          hostPlatform =
            pkgs.stdenv.hostPlatform
            // {
              isLinux = false;
              system = "x86_64-darwin";
            };
        };
    };
  evaluateDarwin = backend: ai:
    (
      if backend == "hm"
      then harness.evalHmWithSpecialArgs {pkgs = darwinPkgs;}
      else harness.evalDevenvWithSpecialArgs {pkgs = darwinPkgs;}
    ) {ai = lib.recursiveUpdate {airlock.instances.main = sample;} ai;};

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
        == [
          "ai.claims.port.8400: claimed by airlock:airlock-main.ports.main and cliproxyapi:cliproxyapi-main.ports.main"
          "ai.claims.proxy-instance.main: claimed by airlock and cliproxyapi"
        ]
        # The instance fixes the listen address, and a token takes a reference.
        && thrown backend {airlock.instances.main.settings.listen = "0.0.0.0:8400";}
        && thrown backend {airlock.instances.main.settings.clients.harness.token = "fake-SECRET-token";})
      ["devenv" "hm"]
    );

    airlock-claude-selection = mkTest "airlock-claude-selection" (
      lib.all (backend: let
        selection = {
          instance = "main";
          clientKey = "harness";
        };
        selected = evaluate backend {
          claude = {
            enable = true;
            proxy = selection;
            jail.enable = true;
          };
        };
        settings = claudeSettings selected;
        noJail = evaluate backend {
          claude = {
            enable = true;
            proxy = selection;
          };
        };
        configOnly = evaluate backend {
          claude = {
            enable = true;
            proxy = selection;
            package = null;
          };
        };
        unknown = evaluate backend {
          claude = {
            enable = true;
            proxy = {
              instance = "main";
              clientKey = "missing";
            };
            jail.enable = true;
          };
        };
        codex = evaluate backend {
          codex = {
            enable = true;
            proxy = selection;
          };
        };
        rootCpa = evaluate backend {
          proxy = {
            url = "http://127.0.0.1:8317";
            key = redact.file "/run/secrets/fake-cpa-client";
          };
          claude = {
            enable = true;
            proxy = selection;
            jail.enable = true;
          };
        };
        inheritedCodex = evaluate backend {
          proxy = selection;
          codex.enable = true;
        };
        disabled = evaluate backend {
          airlock.instances.main.enable = false;
          claude = {
            enable = true;
            proxy = selection;
            jail.enable = true;
          };
        };
        partial = evaluate backend {claude.proxy.clientKey = "harness";};
        configuredProxy = evaluate backend {
          claude = {
            enable = true;
            proxy = selection;
            jail.enable = true;
            native.settings.env.HTTPS_PROXY = "http://bypass.invalid";
          };
        };
        normalizedNull = evaluate backend {
          claude = {
            enable = true;
            jail.enable = true;
            proxy = selection;
            normalized.proxy = lib.mkForce null;
          };
        };
        normalizedIncomplete = evaluate backend {
          claude = {
            enable = true;
            jail.enable = true;
            proxy = selection;
            normalized.proxy = lib.mkForce {
              owner = "airlock";
              url = "http://127.0.0.1:8400";
            };
          };
        };
        jailExcludesProxy = {
          claude = {
            enable = true;
            jail = {
              enable = true;
              exclude.environment = ["HTTPS_PROXY"];
            };
            proxy = selection;
          };
        };
        jailSetsProxy = {
          claude = {
            enable = true;
            jail = {
              enable = true;
              permissions = c: [(c.set-env "HTTPS_PROXY" "http://bypass.invalid")];
            };
            proxy = selection;
          };
        };
        jailUnsetsProxy = {
          claude = {
            enable = true;
            jail = {
              enable = true;
              permissions = c: [(c.unset-env "HTTPS_PROXY")];
            };
            proxy = selection;
          };
        };
        jailSetsAlias = {
          claude = {
            enable = true;
            jail = {
              enable = true;
              permissions = c: [(c.set-env "no_proxy" "*")];
            };
            proxy = selection;
          };
        };
        jailDeferredSetsProxy = {
          claude = {
            enable = true;
            jail = {
              enable = true;
              permissions = c: [(c.defer (c.set-env "HTTPS_PROXY" "http://bypass.invalid"))];
            };
            proxy = selection;
          };
        };
        jailDeferredUnsetsProxy = {
          claude = {
            enable = true;
            jail = {
              enable = true;
              permissions = c: [(c.defer (c.unset-env "HTTPS_PROXY"))];
            };
            proxy = selection;
          };
        };
        jailSetsUnrelated = evaluate backend {
          claude = {
            enable = true;
            jail = {
              enable = true;
              permissions = c: [(c.set-env "AIRLOCK_TEST_UNRELATED" "kept")];
            };
            proxy = selection;
          };
        };
        darwinResult = evaluateDarwin backend {
          claude = {
            enable = true;
            jail.enable = true;
            proxy = selection;
          };
        };
      in
        selected.config.ai.claude.normalized.proxy.owner
        == "airlock"
        && selected.config.ai.claude.normalized.proxy.client == "harness"
        && settings.env.ANTHROPIC_BASE_URL == ""
        && settings.env.CLAUDE_CODE_OAUTH_TOKEN == "airlock-fake-oauth-token-not-a-credential"
        && settings.apiKeyHelper == ""
        && lib.hasInfix "claude-jail" (toString (builtins.head (selected.config.home.packages or selected.config.packages)))
        && failures selected == []
        && builtins.any (lib.hasInfix "enable ai.claude.jail") (failures noJail)
        && builtins.any (lib.hasInfix "no managed airlock launcher") configOnly.config.warnings
        && builtins.any (lib.hasInfix "not an `ai.airlock.instances.main.settings.clients` entry") (failures unknown)
        && rootCpa.config.ai.claude.normalized.proxy.owner == "airlock"
        && builtins.any (lib.hasInfix "only Claude supports") (failures codex)
        && builtins.any (lib.hasInfix "only Claude supports") (failures inheritedCodex)
        && builtins.any (lib.hasInfix "which is disabled") (failures disabled)
        && builtins.any (lib.hasInfix "is set without `instance`") (failures partial)
        && builtins.any (lib.hasInfix "native.settings.env must not set proxy variables") (failures configuredProxy)
        && normalizedNull.config.ai.claude.normalized.proxy == null
        && !(builtins.hasAttr "apiKeyHelper" (claudeSettings normalizedNull))
        && failures normalizedNull == []
        && builtins.any (lib.hasInfix "needs client, instance and port") (failures normalizedIncomplete)
        && packageRefused backend jailExcludesProxy
        && packageRefused backend jailSetsProxy
        && packageRefused backend jailUnsetsProxy
        && packageRefused backend jailSetsAlias
        && packageRefused backend jailDeferredSetsProxy
        && packageRefused backend jailDeferredUnsetsProxy
        && builtins.isString (toString (builtins.head (jailSetsUnrelated.config.home.packages or jailSetsUnrelated.config.packages)))
        && builtins.any (lib.hasInfix "bubblewrap is Linux-only; no airlock launcher is delivered on x86_64-darwin") darwinResult.config.warnings
        && (darwinResult.config.home.packages or darwinResult.config.packages) == [])
      ["devenv" "hm"]
    );
  };
}
