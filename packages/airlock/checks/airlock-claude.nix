# Airlock selection and process-start wiring, without invoking Claude itself.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  redact = import ../../../lib/redact {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  evals = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  failures = evaluated: map (item: item.message) (lib.filter (item: !item.assertion) evaluated.config.assertions);
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
  refused = eval: needle: extra: lib.any (lib.hasInfix needle) (failures (eval (changed extra)));
  tokenReader = strictShellApplication pkgs {
    name = "airlock-claude-test-token";
    text = ''exec ${pkgs.coreutils}/bin/cat "$R10_TOKEN_SOURCE"'';
  };
  mock = pkgs.writeScriptBin "claude" ''
    #!${pkgs.python3}/bin/python3
    exec(compile(open(${builtins.toJSON "${./airlock-claude-mock.py}"}, "rb").read(), "airlock-claude-mock.py", "exec"))
  '';
  installed = result: builtins.head (result.config.home.packages or result.config.packages);
  runtimeCase = backend: intercepted: let
    name = "r10-${backend}-${
      if intercepted
      then "tls"
      else "opaque"
    }";
    # The two backends also exercise service overrides vs native settings env.
    nativeDirectory =
      if backend == "hm"
      then "/tmp"
      else "/unused-native-runtime";
    evaluated = evals.${backend} {
      ai = {
        airlock.instances.${name} = {
          port = 18448;
          stateDir = "/tmp/${name}-state";
          settings =
            {
              clients.fixture.token = redact.command (lib.getExe tokenReader);
              interception = lib.optionalAttrs intercepted {
                destinations = ["localhost:443"];
                upstream_roots = "${pkgs.cacert}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
              };
            }
            // lib.optionalAttrs (!intercepted) {interception = null;};
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
    inherit (evaluated) config;
  in {
    inherit backend intercepted name nativeDirectory;
    clientLauncher = "${installed evaluated}/bin/claude";
    serviceLauncher =
      if backend == "hm"
      then config.systemd.user.services."airlock-${name}".Service.ExecStart
      else config.processes."airlock-${name}".exec;
    settings = claudeSettings evaluated;
  };
in {
  checks =
    {
      airlock-claude-selection = mkTest "airlock-claude-selection" (lib.all (eval: let
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
        interceptTrust = changed {
          ai.airlock.instances.main.settings.interception.destinations = ["localhost:443"];
          ai.claude.native.settings.env.NODE_EXTRA_CA_CERTS = "/native-extra.pem";
        };
      in
        failures good
        == []
        && settings.apiKeyHelper == native.apiKeyHelper
        && builtins.intersectAttrs native.env settings.env == native.env
        && !(settings ? disableClaudeAiConnectors)
        && !(settings.env ? DISABLE_AUTOUPDATER)
        && !(settings ? modelPicker)
        && good.config.ai.claude.normalized.proxy.owner == "airlock"
        && good.config.ai.claude.normalized.proxy.credentials == []
        && good.config.ai.claims.proxy-instance.main == ["airlock"]
        && root.config.ai.claude.normalized.proxy.owner == "airlock"
        && !(builtins.tryEval (builtins.deepSeq (installed secretDirectory).drvPath true)).success
        && failures opaqueTrust == []
        && lib.any (lib.hasInfix "not an `ai.cliproxyapi.instances` entry") (failures missing)
        && lib.any (lib.hasInfix "settings.clients") (failures absentClients)
        && lib.any (lib.hasInfix "ai.claims.proxy-instance.main") (failures colliding)
        && refused eval "disabled" {ai.airlock.instances.main.enable = false;}
        && refused eval "settings.clients" {ai.claude.proxy.clientKey = "missing";}
        && refused eval "requires a managed" {ai.claude.package = null;}
        && refused eval "owns proxy/bypass" {ai.claude.native.settings.env.HTTPS_PROXY = "http://native.invalid";}
        && lib.any (lib.hasInfix "interception trust") (failures (eval interceptTrust))
        && refused eval "Claude Code only" {
          ai.codex = {
            enable = true;
            proxy = selected;
          };
        }
        && refused eval "Claude Code only" {
          ai.proxy = selected;
          ai.kiro.cli.enable = true;
        }) (builtins.attrValues evals));
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-claude-runtime =
        pkgs.runCommandLocal "airlock-claude-runtime" {
          cases = pkgs.writeText "airlock-claude-cases.json" (builtins.toJSON (lib.concatMap (backend: map (runtimeCase backend) [false true]) ["hm" "devenv"]));
          passthru.launchCases = lib.concatMap (backend: map (runtimeCase backend) [false true]) ["hm" "devenv"];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${pkgs.python3}/bin/python3 ${./airlock-claude-runtime.py} "$cases"
          echo "ok: generated service and mock Claude launchers, both backends" > "$out"
        '';
    };
}
