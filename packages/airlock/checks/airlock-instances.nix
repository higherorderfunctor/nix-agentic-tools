# `ai.airlock.instances` on both backends: service contract, claims, rendered
# settings, proxy registration, and what selecting an instance gives Claude
# and Codex.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalHm mkTest;
  evaluate = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  empty = backend: (evaluate backend {}).config;
  enabled = backend:
    (
      evaluate backend {
        ai.airlock.instances.main = {};
      }
    )
    .config;
  configured = backend:
    (
      evaluate backend {
        ai.airlock.instances.main.port = 8400;
      }
    )
    .config;
  runtime = backend:
    (
      evaluate backend {
        ai.airlock.instances.main = {
          port = 18439;
          stateDir = "/tmp/airlock-main-runtime-check-${backend}";
        };
      }
    )
    .config;
  claudeProxy = import ../../claude-code/lib/proxy.nix {inherit lib pkgs;};
  # Claude's own environment, which a selection must leave in place.
  nativeEnv = {
    ANTHROPIC_API_KEY = "existing-api-key";
    ANTHROPIC_AUTH_TOKEN = "existing-auth-token";
    ANTHROPIC_BASE_URL = "https://native.example.invalid";
    NODE_EXTRA_CA_CERTS = "/etc/native-ca.pem";
  };
  # The consumer's opt-in: an instance and a Claude selection naming it.
  claudeWith = backend: extra:
    evaluate backend (lib.recursiveUpdate {
        ai = {
          airlock.instances.main.port = 8400;
          claude = {
            enable = true;
            native.settings.env = nativeEnv;
            proxy.instance = "main";
          };
        };
      }
      extra);
  failedAssertions = result:
    map (item: item.message)
    (builtins.filter (item: !item.assertion) result.config.assertions);
  noAirlockActivation = config:
    config.ai.airlock.activation
    == {}
    && !(builtins.any (name: lib.hasPrefix "airlock" name)
      (builtins.attrNames (config.home.activation or config.tasks)));
  serviceContract = backend: let
    config = enabled backend;
    entry = config.ai.services.airlock-main;
    native =
      if backend != "hm"
      then config.processes ? "airlock-main"
      else if pkgs.stdenv.hostPlatform.isLinux
      then config.systemd.user.services ? "airlock-main"
      else
        builtins.any (
          warning:
            warning
            == "ai.services.airlock-main: Home Manager writes services as systemd user units, which this platform lacks; the service is not written"
        )
        config.warnings;
  in
    config.ai.airlock.instances.main.port
    == 8318
    && config.ai.claims.service.airlock-main == ["airlock"]
    && config.ai.claims.port."8318" == ["airlock:airlock-main.ports.main"]
    && entry.enable
    && entry.ports.main == 8318
    && entry.environment == {}
    && builtins.attrNames entry.files == ["config"]
    && entry.files.config
    == {
      content = ''{"listen":"127.0.0.1:8318"}'';
      secrets = {};
      variable = "AIRLOCK_CONFIG";
    }
    && builtins.length entry.command == 1
    && native
    && noAirlockActivation config;
  portDerived = backend: let
    config = configured backend;
    entry = config.ai.services.airlock-main;
  in
    entry.files.config.content
    == ''{"listen":"127.0.0.1:8400"}''
    && entry.ports.main == 8400
    && config.ai.claims.port."8400" == ["airlock:airlock-main.ports.main"];
  listenOverrideRefused = backend:
    !(
      builtins.tryEval (
        builtins.deepSeq
        (evaluate backend {
          ai.airlock.instances.main.settings.listen = "0.0.0.0:8400";
        })
          .config
          .ai
          .services
          .airlock-main
          .files
          .config
        true
      )
    ).success;
  claimsCollide = backend: let
    result = evaluate backend {
      ai.airlock.instances = {
        first.port = 8400;
        second.port = 8400;
      };
    };
  in
    builtins.elem
    "ai.claims.port.8400: claimed by airlock:airlock-first.ports.main and airlock:airlock-second.ports.main"
    (failedAssertions result);
  disabledClaims = backend: let
    inherit (evaluate backend {ai.airlock.instances.main.enable = false;}) config;
  in
    !config.ai.services.airlock-main.enable
    && config.ai.claims.port."8318" == ["airlock:airlock-main.ports.main"];
  launcher = backend:
    if backend == "hm"
    then (runtime backend).systemd.user.services.airlock-main.Service.ExecStart
    else (runtime backend).processes.airlock-main.exec;
  registered = backend: let
    config = enabled backend;
  in
    config.ai.internal.proxyInstances.main
    == {
      backend = "airlock";
      clients = null;
      enable = true;
      url = "http://127.0.0.1:8318";
    }
    && config.ai.claims.proxy-instance.main == ["airlock"];
  # Declaring an instance selects nothing.
  unselected = backend:
    evaluate backend {
      ai = {
        airlock.instances.main = {};
        claude = {
          enable = true;
          native.settings.env = nativeEnv;
        };
      };
    };
  unselectedUntouched = backend: let
    evaluated = unselected backend;
    inherit (claudeSettings evaluated) env;
  in
    evaluated.config.ai.claude.normalized.proxy
    == null
    && lib.intersectAttrs nativeEnv env == nativeEnv
    && !(env ? HTTPS_PROXY);
  # The selection adds only HTTPS_PROXY: no CPA settings, no launcher flags.
  claudeSelected = backend: let
    evaluated = claudeWith backend {};
  in
    failedAssertions evaluated
    == []
    && claudeSettings evaluated
    == lib.recursiveUpdate (claudeSettings (unselected backend)) {env.HTTPS_PROXY = "http://127.0.0.1:8400";}
    && claudeProxy.launcherFlags {
      inherit backend;
      resolvedProxy = evaluated.config.ai.claude.normalized.proxy;
    }
    == [];
  nativeProxyWins = backend:
    (claudeSettings (claudeWith backend {ai.claude.native.settings.env.HTTPS_PROXY = "http://127.0.0.1:9999";})).env.HTTPS_PROXY
    == "http://127.0.0.1:9999";
  clientKeyRefused = backend:
    builtins.elem
    "ai.claude.proxy.clientKey is set, but `ai.airlock.instances.main` declares no clients."
    (failedAssertions (claudeWith backend {ai.claude.proxy.clientKey = "main";}));
  # Codex has no airlock lowering, so selecting one fails evaluation.
  codexRefused = backend:
    !(builtins.tryEval (builtins.deepSeq
      (evaluate backend {
        ai = {
          airlock.instances.main = {};
          codex = {
            enable = true;
            proxy.instance = "main";
          };
        };
      })
      .config
      .ai
      .codex
      .native
      .settings
      true))
    .success;
  # Named so a failure reports which condition broke.
  conditions = backend: {
    "${backend}: Claude selection sets only HTTPS_PROXY" = claudeSelected backend;
    "${backend}: claim collisions are reported" = claimsCollide backend;
    "${backend}: clientKey is refused" = clientKeyRefused backend;
    "${backend}: Codex cannot select an instance" = codexRefused backend;
    "${backend}: disabled instances keep their claims" = disabledClaims backend;
    "${backend}: instances are registered proxies" = registered backend;
    "${backend}: listen cannot be overridden" = listenOverrideRefused backend;
    "${backend}: native HTTPS_PROXY wins" = nativeProxyWins backend;
    "${backend}: no instance by default" =
      (empty backend).ai.airlock.instances
      == {}
      && !(builtins.any (name: lib.hasPrefix "airlock" name)
        (builtins.attrNames ((empty backend).ai.services or {})))
      && noAirlockActivation (empty backend);
    "${backend}: port derives listen" = portDerived backend;
    "${backend}: service contract" = serviceContract backend;
    "${backend}: unselected Claude is untouched" = unselectedUntouched backend;
  };
  failing = lib.concatMap (backend:
    builtins.attrNames (lib.filterAttrs (_: passed: !passed) (conditions backend)))
  ["devenv" "hm"];
in {
  checks =
    {
      airlock-instances = mkTest "airlock-instances" (
        lib.assertMsg (failing == []) "failing: ${lib.concatStringsSep ", " failing}"
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-instance-runtime = pkgs.runCommandLocal "airlock-instance-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${pkgs.python3}/bin/python3 ${./airlock-instance-runtime.py} \
          ${lib.escapeShellArg (runtime "hm").ai.services.airlock-main.files.config.content} \
          ${launcher "hm"} \
          ${launcher "devenv"}
        echo "ok — both generated Airlock launchers serve health at the configured nondefault port" >"$out"
      '';
    };
}
