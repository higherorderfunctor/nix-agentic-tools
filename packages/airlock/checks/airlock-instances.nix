# `ai.airlock.instances` on both backends: service contract, claims, proxy
# registration, and what selecting an instance gives Claude
# through the shared network surface.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows claudeSettings evalDevenv evalHm launchdAgentRunsLauncher mkTest;
  evaluate = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  redact = import ../../../lib/redact {inherit lib;};
  empty = backend: (evaluate backend {}).config;
  enabled = backend:
    (
      evaluate backend {
        ai.airlock.instances.main = {};
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
  # Claude's own environment, which a selection must leave in place.
  nativeEnv = {
    ANTHROPIC_BASE_URL = "https://native.example.invalid";
  };
  # Airlock and Claude with its own native environment.
  claudeWith = backend: instance: extra:
    evaluate backend (lib.recursiveUpdate {
        ai = {
          airlock.instances.main = instance;
          claude = {
            enable = true;
            native.settings.env = nativeEnv;
          };
        };
      }
      extra);
  configuredClaude = backend: claudeWith backend {port = 8400;};
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
        # Darwin: fails when airlock-main is missing from launchd or runs
        # something other than its launcher.
        launchdAgentRunsLauncher config "airlock-main";
  in
    config.ai.claims.service.airlock-main
    == ["airlock"]
    && config.ai.claims.port."8318" == ["airlock:airlock-main.ports.main"]
    && entry.environment == {}
    && entry.files == {}
    && native
    && noAirlockActivation config;
  portDerived = backend: let
    inherit (configuredClaude backend {}) config;
  in
    config.ai.claims.port."8400" == ["airlock:airlock-main.ports.main"];
  # Read the launchers the native managers actually run, not the inner service command.
  launcher = backend:
    if backend == "hm"
    then (runtime backend).systemd.user.services.airlock-main.Service.ExecStart
    else (runtime backend).processes.airlock-main.exec;
  registered = backend: let
    config = enabled backend;
  in
    config.ai.internal.proxyInstances.main
    == {
      enable = true;
      http = "http://127.0.0.1:8318";
      https = "http://127.0.0.1:8318";
    }
    && config.ai.claims.proxy-instance.main == ["airlock"];
  # Declaring the default instance must not inject any proxy variables.
  unselectedUntouched = backend: let
    evaluated = claudeWith backend {} {};
    inherit (claudeSettings evaluated) env;
  in
    lib.intersectAttrs nativeEnv env
    == nativeEnv
    && !(env ? HTTP_PROXY || env ? HTTPS_PROXY || env ? NO_PROXY);
  external = "http://external.invalid:8080";
  origin = "http://127.0.0.1:8400";
  # Fixed proxy defaults from the configured instance, not from the registry.
  proxyDefaults = {
    http = origin;
    https = origin;
  };
  defaultEnv = {
    HTTP_PROXY = origin;
    HTTPS_PROXY = origin;
    NO_PROXY = "127.0.0.1,localhost,::1";
  };
  selectionCases = {
    "native HTTPS and bypass override generated defaults without dropping HTTP" = {
      env =
        defaultEnv
        // {
          HTTPS_PROXY = external;
          NO_PROXY = "native.example.invalid";
        };
      extra.ai = {
        claude.native.settings.env = {
          HTTPS_PROXY = external;
          NO_PROXY = "native.example.invalid";
        };
        proxy.instance = "main";
      };
      # Native HTTPS would hide an incorrect normalized origin in settings.
      proxy = proxyDefaults;
    };
    "root explicit HTTP does not replace the instance HTTPS default" = {
      env = defaultEnv // {HTTP_PROXY = external;};
      extra.ai.proxy = {
        http = external;
        instance = "main";
      };
    };
    "runtime selector works without a root selector" = {
      env = defaultEnv;
      extra.ai.claude.proxy.instance = "main";
    };
  };
  selectedCorrectly = backend: row: let
    evaluated = configuredClaude backend row.extra;
    settings = claudeSettings evaluated;
  in
    failedAssertions evaluated
    == []
    && (!(row ? proxy) || evaluated.config.ai.claude.normalized.proxy == row.proxy)
    && settings == lib.recursiveUpdate (claudeSettings (configuredClaude backend {})) {inherit (row) env;};
  # Exact assertion messages distinguish disabled registered instances from
  # unknown names. A root failure must not be repeated by an inheriting
  # runtime; a runtime's own selector must be checked even while disabled.
  rejectionCases = {
    "root disabled rejected with Claude enabled" = {
      enableClaude = true;
      extra.ai = {
        airlock.instances.main.enable = false;
        proxy.instance = "main";
      };
      message = "ai.proxy.instance names `main`, which is disabled; registered instances: main.";
    };
    "root unknown rejected with Claude disabled" = {
      extra.ai.proxy.instance = "missing";
      message = "ai.proxy.instance names `missing`, which is not registered; registered instances: main.";
    };
    "runtime disabled rejected with Claude disabled" = {
      extra.ai = {
        airlock.instances.main.enable = false;
        claude.proxy.instance = "main";
      };
      message = "ai.claude.proxy.instance names `main`, which is disabled; registered instances: main.";
    };
    "runtime unknown rejected with Claude disabled" = {
      extra.ai.claude.proxy.instance = "missing";
      message = "ai.claude.proxy.instance names `missing`, which is not registered; registered instances: main.";
    };
  };
  inferenceIndependent = backend: let
    evaluated = configuredClaude backend {
      ai = {
        cliproxyapi.instances.main = {
          clientKeys.main = {
            key = redact.file "/run/secrets/inference-key";
            routes = [{credential = "login";}];
          };
          credentials.login.oauth = {
            account = redact.file "/run/secrets/inference-account";
            vendor = "claude";
          };
        };
        proxy.instance = "main";
        settings.inference = {
          clientKey = "main";
          instance = "main";
        };
      };
    };
    inherit (evaluated) config;
  in
    failedAssertions evaluated
    == []
    && config.ai.claims.inference-instance.main == ["cliproxyapi"]
    && config.ai.claims.proxy-instance.main == ["airlock"]
    && config.ai.internal.inferenceInstances.main.url == "http://127.0.0.1:8317"
    && config.ai.internal.proxyInstances.main.https == origin
    && (claudeSettings evaluated).env.NO_PROXY == "127.0.0.1,localhost,::1";
  conditions = backend:
    {
      "configured port produces the expected claim" = portDerived backend;
      "default instance produces the native service and claims, not activation" = serviceContract backend;
      "inference and network instances with the same name remain independent" = inferenceIndependent backend;
      "instance is registered with both proxy origins and an Airlock claim" = registered backend;
      "no declaration creates no service or activation" = let
        config = empty backend;
      in
        !(builtins.any (name: lib.hasPrefix "airlock" name)
          (builtins.attrNames (config.ai.services or {})))
        && noAirlockActivation config;
      "unselected Claude stays free of proxy settings" = unselectedUntouched backend;
    }
    // lib.mapAttrs (_: selectedCorrectly backend) selectionCases
    // lib.mapAttrs (_: row: let
      evaluated = configuredClaude backend (lib.recursiveUpdate row.extra {ai.claude.enable = row.enableClaude or false;});
    in
      failedAssertions evaluated == [row.message])
    rejectionCases;
in {
  checks =
    {
      airlock-instances = mkTest "airlock-instances" (
        lib.all (backend: checkRows "airlock-instances/${backend}" (conditions backend)) ["devenv" "hm"]
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-instance-runtime = pkgs.runCommandLocal "airlock-instance-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        ${pkgs.python3}/bin/python3 ${./airlock-instance-runtime.py} \
          127.0.0.1:18439 \
          ${launcher "hm"} \
          ${launcher "devenv"}
        echo "ok — both generated Airlock launchers serve health at the configured nondefault port" >"$out"
      '';
    };
}
