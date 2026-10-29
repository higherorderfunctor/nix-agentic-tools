# `ai.airlock.instances` on both backends: service contract, claims, rendered
# settings, proxy registration, and what selecting an instance gives Claude
# and Codex, including an intercepting instance's CA at Claude's launch.
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
  enabledWith = backend: settings: (evaluate backend {ai.airlock.instances.main.settings = settings;}).config;
  configured = backend:
    (
      evaluate backend {
        ai.airlock.instances.main.port = 8400;
      }
    )
    .config;
  # A store-backed trust bundle, so the rendered file carries store context.
  interceptionSettings = {
    destinations = ["localhost:443"];
    upstream_roots = "${pkgs.cacert}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
  };
  runtime = backend: intercepting:
    (
      evaluate backend {
        ai.airlock.instances.main = {
          port = 18439;
          settings = lib.optionalAttrs intercepting {interception = interceptionSettings;};
          stateDir = "/tmp/airlock-main-runtime-check-${backend}";
        };
        ai.claude = {
          enable = true;
          package = mockClaude;
          proxy.instance = "main";
        };
      }
    )
    .config;
  # A stand-in for Claude that prints the extra-CA file it was started with.
  mockClaude = pkgs.writeScriptBin "claude" ''
    #!${pkgs.python3}/bin/python3
    import json, os
    print(json.dumps(os.environ.get("NODE_EXTRA_CA_CERTS")))
  '';
  # The Claude command the runtime configuration installs: the managed
  # launcher, or the mock itself when the selection needs none.
  clientLauncher = backend: intercepting: let
    config = runtime backend intercepting;
    installed = lib.findFirst (package: builtins.elem (lib.getName package) ["claude" "claude-code-proxy"]) (throw "no Claude package installed") (config.home.packages or config.packages);
  in "${installed}/bin/claude";
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
  # The services launcher validates placeholders on a context-free copy and
  # keeps the bundle a dependency of the content it renders.
  interceptionRendered = backend: let
    inherit ((enabledWith backend {interception = interceptionSettings;}).ai.services.airlock-main.files.config) content;
  in
    builtins.fromJSON (builtins.unsafeDiscardStringContext content)
    == {
      interception = interceptionSettings;
      listen = "127.0.0.1:8318";
    }
    && builtins.hasContext content;
  # The CA directory belongs to the runtime directory, never to settings.
  invalidInterceptionRefused = backend:
    lib.all (interception:
      !(builtins.tryEval (builtins.deepSeq
        (enabledWith backend {inherit interception;}).ai.services.airlock-main.files.config
        true)).success) [
      {destinations = [443];}
      {
        destinations = ["localhost:443"];
        upstream_roots = 443;
      }
      {
        ca_directory = "/persistent/ca";
        destinations = ["localhost:443"];
      }
    ];
  launcher = backend: intercepting:
    if backend == "hm"
    then (runtime backend intercepting).systemd.user.services.airlock-main.Service.ExecStart
    else (runtime backend intercepting).processes.airlock-main.exec;
  registered = backend: let
    config = enabled backend;
  in
    config.ai.internal.proxyInstances.main
    == {
      backend = "airlock";
      clients = null;
      enable = true;
      trust = null;
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
  # Interception adds one launcher step, reading the instance's trust helper;
  # settings still gain only HTTPS_PROXY.
  intercepted = backend: claudeWith backend {ai.airlock.instances.main.settings.interception.destinations = ["localhost:443"];};
  claudeTrustsCa = backend: let
    evaluated = intercepted backend;
    resolvedProxy = evaluated.config.ai.claude.normalized.proxy;
    flags = claudeProxy.launcherFlags {inherit backend resolvedProxy;};
  in
    failedAssertions evaluated
    == []
    && resolvedProxy.trust == evaluated.config.ai.internal.proxyInstances.main.trust
    && lib.getName resolvedProxy.trust == "airlock-main-trust"
    && builtins.length flags == 1
    && lib.hasInfix "NODE_EXTRA_CA_CERTS" (builtins.head flags)
    && lib.hasInfix (builtins.unsafeDiscardStringContext (lib.getExe resolvedProxy.trust)) (builtins.unsafeDiscardStringContext (builtins.head flags))
    && claudeSettings evaluated == claudeSettings (claudeWith backend {});
  nullPackageWarnsTrust = backend:
    builtins.any (lib.hasInfix "NODE_EXTRA_CA_CERTS")
    (claudeWith backend {
      ai.airlock.instances.main.settings.interception.destinations = ["localhost:443"];
      ai.claude.package = null;
    })
    .config
    .warnings;
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
    "${backend}: Claude trusts an intercepting instance's CA at launch" = claudeTrustsCa backend;
    "${backend}: Claude without a launcher is told to trust the CA" = nullPackageWarnsTrust backend;
    "${backend}: claim collisions are reported" = claimsCollide backend;
    "${backend}: clientKey is refused" = clientKeyRefused backend;
    "${backend}: Codex cannot select an instance" = codexRefused backend;
    "${backend}: disabled instances keep their claims" = disabledClaims backend;
    "${backend}: instances are registered proxies" = registered backend;
    "${backend}: interception renders with its store bundle" = interceptionRendered backend;
    "${backend}: invalid interception is refused" = invalidInterceptionRefused backend;
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
          ${pkgs.writeText "airlock-runtime-cases.json" (builtins.toJSON (lib.concatMap (backend:
          map (intercepting: {
            inherit backend intercepting;
            client = clientLauncher backend intercepting;
            config = (runtime backend intercepting).ai.services.airlock-main.files.config.content;
            launcher = launcher backend intercepting;
          }) [false true]) ["hm" "devenv"]))}
        echo "ok — both generated Airlock launchers serve health, keep an interception CA beside the runtime config and hand it to Claude's launcher" >"$out"
      '';
    };
}
