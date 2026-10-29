# `ai.airlock.instances` on both backends: service contract, claims, rendered
# settings, proxy registration, and what selecting an instance gives Claude
# through the shared network surface.
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
  redact = import ../../../lib/redact {inherit lib;};
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
      }
    )
    .config;
  # Claude's own environment, which a selection must leave in place.
  nativeEnv = {
    ANTHROPIC_BASE_URL = "https://native.example.invalid";
  };
  # A configured instance and Claude with its own native environment.
  claudeWith = backend: extra:
    evaluate backend (lib.recursiveUpdate {
        ai = {
          airlock.instances.main.port = 8400;
          claude = {
            enable = true;
            native.settings.env = nativeEnv;
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
  # Home Manager keeps the XDG default; devenv roots the CA under the
  # project's runtime root, and only for an instance that intercepts.
  runtimeHome = backend:
    (enabledWith backend {interception = interceptionSettings;}).ai.services.airlock-main.environment
    == lib.optionalAttrs (backend == "devenv") {AIRLOCK_HOME = "/tmp/devenv-runtime/airlock";};
  # The name becomes the CA's runtime directory, so an intercepting instance
  # follows Airlock's name rule at evaluation.
  interceptingNameChecked = backend: let
    launches = name:
      (builtins.tryEval (builtins.deepSeq
        (evaluate backend {ai.airlock.instances.${name}.settings.interception = interceptionSettings;}).config.ai.services."airlock-${name}".command
        true)).success;
  in
    launches "work_2-b" && !(launches "bad.name");
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
        destinations = ["localhost:443"];
        upstream_roots = "/home/alice/certs/roots.pem";
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
      enable = true;
      http = "http://127.0.0.1:8318";
      https = "http://127.0.0.1:8318";
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
    == {
      http = null;
      https = null;
    }
    && lib.intersectAttrs nativeEnv env == nativeEnv
    && !(env ? HTTPS_PROXY);
  # Root and runtime selection share protocol defaults and native delivery.
  external = "http://external.invalid:8080";
  origin = "http://127.0.0.1:8400";
  selectionCases = {
    root = {
      extra.ai.proxy.instance = "main";
      expected = {
        http = origin;
        https = origin;
      };
    };
    root-explicit-http = {
      extra.ai.proxy = {
        http = external;
        instance = "main";
      };
      expected = {
        http = external;
        https = origin;
      };
    };
    runtime = {
      extra.ai.claude.proxy.instance = "main";
      expected = {
        http = origin;
        https = origin;
      };
    };
  };
  selectedCorrectly = backend: test: let
    evaluated = claudeWith backend test.extra;
    expectedEnv = lib.filterAttrs (_: value: value != null) {
      HTTP_PROXY = test.expected.http;
      HTTPS_PROXY = test.expected.https;
      NO_PROXY = "127.0.0.1,localhost,::1";
    };
  in
    failedAssertions evaluated
    == []
    && evaluated.config.ai.claude.normalized.proxy == test.expected
    && claudeSettings evaluated == lib.recursiveUpdate (claudeSettings (unselected backend)) {env = expectedEnv;};
  nativeProxyWins = backend: let
    inherit
      (claudeSettings (claudeWith backend {
        ai.proxy.instance = "main";
        ai.claude.native.settings.env = {
          HTTPS_PROXY = external;
          NO_PROXY = "native.example.invalid";
        };
      }))
      env
      ;
  in
    env.HTTPS_PROXY == external && env.NO_PROXY == "native.example.invalid";
  selectionRefused = backend: scope: disabled: let
    path = ["ai"] ++ lib.optional (scope == "runtime") "claude" ++ ["proxy"];
    name =
      if disabled
      then "main"
      else "missing";
    result = enabled:
      claudeWith backend (lib.recursiveUpdate
        (lib.setAttrByPath (path ++ ["instance"]) name)
        {
          ai.airlock.instances.main.enable = !disabled;
          ai.claude.enable = enabled;
        });
    message = "${lib.showOption path}.instance names `${name}`, which is ${
      if disabled
      then "disabled"
      else "not registered"
    }; registered instances: main.";
  in
    # Inherited invalid selections report only the root; independent runtime
    # selections remain checked even when the runtime is disabled.
    lib.all (enabled: failedAssertions (result enabled) == [message]) [false true];
  inferenceIndependent = backend: let
    evaluated = claudeWith backend {
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
  # Named so a failure reports which condition broke.
  conditions = backend:
    {
      "${backend}: inference and network instance names coexist" = inferenceIndependent backend;
      "${backend}: instances are registered proxies" = registered backend;
      "${backend}: interception renders with its store bundle" = interceptionRendered backend;
      "${backend}: interception sets the CA's runtime base" = runtimeHome backend;
      "${backend}: intercepting instance names follow Airlock's rule" = interceptingNameChecked backend;
      "${backend}: invalid interception is refused" = invalidInterceptionRefused backend;
      "${backend}: listen cannot be overridden" = listenOverrideRefused backend;
      "${backend}: native HTTPS_PROXY and NO_PROXY win" = nativeProxyWins backend;
      "${backend}: no instance by default" =
        (empty backend).ai.airlock.instances
        == {}
        && !(builtins.any (name: lib.hasPrefix "airlock" name)
          (builtins.attrNames ((empty backend).ai.services or {})))
        && noAirlockActivation (empty backend);
      "${backend}: port derives listen" = portDerived backend;
      "${backend}: service contract" = serviceContract backend;
      "${backend}: unselected Claude is untouched" = unselectedUntouched backend;
    }
    // lib.mapAttrs' (name: test: lib.nameValuePair "${backend}: ${name} selection" (selectedCorrectly backend test)) selectionCases
    // lib.concatMapAttrs (scope: _:
      lib.mapAttrs' (kind: disabled:
        lib.nameValuePair "${backend}: ${scope} ${kind} selection refused"
        (selectionRefused backend scope disabled)) {
        disabled = true;
        unknown = false;
      })
    {
      root = null;
      runtime = null;
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
            config = (runtime backend intercepting).ai.services.airlock-main.files.config.content;
            home = (runtime backend intercepting).ai.services.airlock-main.environment.AIRLOCK_HOME or null;
            launcher = launcher backend intercepting;
          }) [false true]) ["hm" "devenv"]))}
        echo "ok — generated Airlock launchers serve health, keep an interception CA in the instance's runtime directory, and refuse a shared runtime root" >"$out"
      '';
    };
}
