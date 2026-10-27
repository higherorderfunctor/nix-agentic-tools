# Airlock selection and process-start wiring, without invoking Claude itself.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings;
  inherit (import ./helpers.nix {inherit harness lib pkgs;}) evaluate failures namedTest pythonPath serviceLauncher tokenReader;
  redact = import ../../../lib/redact {inherit lib;};
  backends = ["devenv" "hm"];
  # A runtime case's service port; the mock child checks the proxy URL uses it.
  runtimePort = 18448;
  selected = {
    instance = "main";
    clientKey = "fixture";
  };
  native = {
    apiKeyHelper = "existing-native-helper";
    env = {
      ANTHROPIC_API_KEY = "native-api-key";
      ANTHROPIC_AUTH_TOKEN = "native-auth-token";
      ANTHROPIC_BASE_URL = "https://native.example.invalid";
    };
  };
  base = {
    ai.airlock.instances.main.settings.clients.fixture.token = redact.file "/run/secrets/fixture";
    ai.claude = {
      enable = true;
      proxy = selected;
      native.settings = native;
    };
  };
  changed = extra: lib.recursiveUpdate base extra;
  refusedBy = evaluated: needle: lib.any (lib.hasInfix needle) (failures evaluated);
  mock = pkgs.writeScriptBin "claude" ("#!${pkgs.python3}/bin/python3\n" + builtins.readFile ./airlock-claude-mock.py);
  installed = result: builtins.head (result.config.home.packages or result.config.packages);
  runtimeCase = backend: intercepted: let
    name = "claude-${backend}-${
      if intercepted
      then "tls"
      else "opaque"
    }";
    # The two backends also exercise service overrides vs native settings env.
    nativeDirectory =
      if backend == "hm"
      then "/tmp"
      else "/unused-native-runtime";
    evaluated = evaluate backend {
      ai = {
        airlock.instances.${name} = {
          port = runtimePort;
          stateDir = "/tmp/${name}-state";
          settings = {
            clients.fixture.token = redact.command (lib.getExe tokenReader);
            interception =
              if intercepted
              then {
                destinations = ["localhost:443"];
                upstream_roots = "${pkgs.cacert}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
              }
              else null;
          };
        };
        claude = {
          enable = true;
          package = mock;
          proxy = {
            instance = name;
            clientKey = "fixture";
          };
          native.settings =
            native
            // {
              env =
                native.env
                // {
                  XDG_RUNTIME_DIR = nativeDirectory;
                  TMPDIR = "/unused-native-tmp";
                };
            };
        };
        services."airlock-${name}".environment = lib.optionalAttrs (backend == "devenv") {XDG_RUNTIME_DIR = "/tmp";};
      };
    };
  in {
    inherit backend intercepted name nativeDirectory;
    port = runtimePort;
    clientLauncher = "${installed evaluated}/bin/claude";
    serviceLauncher = serviceLauncher backend evaluated.config "airlock-${name}";
    settings = claudeSettings evaluated;
  };
  runtimeCases = lib.concatMap (backend: map (runtimeCase backend) [false true]) ["hm" "devenv"];
  selectionConditions = backend: let
    eval = evaluate backend;
    good = eval base;
    settings = claudeSettings good;
    missing = eval (changed {ai.claude.proxy.instance = "missing";});
    absentClients = eval (changed {ai.airlock.instances.main.settings.clients = lib.mkForce null;});
    root = eval (changed {
      ai.proxy = selected;
      ai.claude.proxy = lib.mapAttrs (_: _: lib.mkForce null) selected;
    });
    colliding = eval (changed {ai.cliproxyapi.instances.main.port = 18449;});
    secretDirectory = eval (changed {ai.services.airlock-main.environment.XDG_RUNTIME_DIR = redact.file "/run/secrets/runtime-directory";});
    opaqueTrust = eval (changed {ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS = "/native-extra.pem";});
    codex = eval (changed {
      ai.codex = {
        enable = true;
        proxy = selected;
      };
    });
    kiro = eval (changed {
      ai.proxy = selected;
      ai.kiro.cli.enable = true;
    });
    interceptTrust = changed {
      ai.airlock.instances.main.settings.interception.destinations = ["localhost:443"];
      ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS = "/native-extra.pem";
    };
  in
    lib.mapAttrs' (name: lib.nameValuePair "${backend}: ${name}") {
      "a selection resolves to Airlock" =
        good.config.ai.claude.normalized.proxy.owner
        == "airlock"
        && good.config.ai.claude.normalized.proxy.credentials == [];
      "a root selection resolves to Airlock" = root.config.ai.claude.normalized.proxy.owner == "airlock";
      "a secret runtime directory override is refused" = !(builtins.tryEval (builtins.deepSeq (installed secretDirectory).drvPath true)).success;
      "a shared instance name is refused" = refusedBy colliding "ai.claims.proxy-instance.main";
      "a valid selection has no failures" = failures good == [];
      "an absent clients map is refused" = refusedBy absentClients "settings.clients";
      "an unknown client is refused" = refusedBy (eval (changed {ai.claude.proxy.clientKey = "missing";})) "settings.clients";
      "an unknown instance is refused" = refusedBy missing "not an `ai.airlock.instances` or `ai.cliproxyapi.instances` entry";
      "Codex refuses an Airlock selection" = builtins.elem "ai.codex.proxy: codex cannot launch through an `ai.airlock` instance; it supports cliproxyapi." (failures codex);
      "Kiro refuses an inherited Airlock selection" = builtins.elem "ai.proxy: kiro does not use `ai.proxy`, so it cannot launch through the selected `ai.airlock` instance; move that selection to each runtime that supports it, such as `ai.claude.proxy`." (failures kiro);
      "a disabled instance is refused" = refusedBy (eval (changed {ai.airlock.instances.main.enable = false;})) "disabled";
      "a null package is refused" = refusedBy (eval (changed {ai.claude.package = null;})) "requires a managed";
      "native proxy settings are refused" = refusedBy (eval (changed {ai.claude.native.settings.env.HTTPS_PROXY = "http://native.invalid";})) "owns proxy/bypass";
      "native trust is refused with interception" = refusedBy (eval interceptTrust) "interception trust";
      "native trust is kept without interception" = failures opaqueTrust == [];
      "native settings are untouched" =
        settings.apiKeyHelper
        == native.apiKeyHelper
        && builtins.intersectAttrs native.env settings.env == native.env
        && !(settings ? disableClaudeAiConnectors)
        && !(settings.env ? DISABLE_AUTOUPDATER)
        && !(settings ? modelPicker);
      "the instance claims its name" = good.config.ai.claims.proxy-instance.main == ["airlock"];
    };
in {
  checks =
    {
      airlock-claude-selection = namedTest "airlock-claude-selection" (lib.mergeAttrsList (map selectionConditions backends));
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-claude-runtime =
        pkgs.runCommandLocal "airlock-claude-runtime" {
          cases = pkgs.writeText "airlock-claude-cases.json" (builtins.toJSON runtimeCases);
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          PYTHONPATH=${pythonPath} ${pkgs.python3}/bin/python3 ${./airlock-claude-runtime.py} "$cases"
          echo "ok: generated service and mock Claude launchers, both backends" > "$out"
        '';
    };
}
