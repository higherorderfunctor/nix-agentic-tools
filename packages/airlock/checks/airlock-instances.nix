# `ai.airlock.instances` evaluates to the shared service contract on both
# backends without adding an activation lifecycle of its own. The Claude probe
# clears ordinary preselected CPA root and runtime choices with the documented
# forced leaf opt-out, then checks that Airlock only observes native
# `HTTPS_PROXY`; authentication and TLS settings stay native.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings evalDevenv evalDevenvModules evalHm evalHmModules mkTest;
  redact = import ../../../lib/redact {inherit lib;};
  evaluate = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  evaluateModules = backend:
    if backend == "hm"
    then evalHmModules
    else evalDevenvModules;
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
  selectionLeaves = ["clientKey" "instance" "key" "url"];
  forcedUnselected = {
    clientKey = lib.mkForce null;
    instance = lib.mkForce null;
    key = lib.mkForce null;
    url = lib.mkForce null;
  };
  externalSelection = {
    url = "http://127.0.0.1:9319";
    key = redact.file "/run/secrets/existing-cpa-client";
  };
  baseClaudeModule = {
    config = {
      ai.airlock.instances.main = {};
      ai.claude = {
        enable = true;
        native.settings.env = {
          ANTHROPIC_API_KEY = "existing-api-key";
          ANTHROPIC_AUTH_TOKEN = "existing-auth-token";
          ANTHROPIC_BASE_URL = "https://native.example.invalid";
          HTTPS_PROXY = "http://127.0.0.1:8318";
          NODE_EXTRA_CA_CERTS = "/etc/native-ca.pem";
        };
      };
    };
  };
  rootSelectedModule = {
    config.ai.proxy = externalSelection;
  };
  runtimeSelectedModule = {
    config.ai.claude.proxy = externalSelection;
  };
  unselectModule = {
    config = {
      ai.proxy = forcedUnselected;
      ai.claude.proxy = forcedUnselected;
    };
  };
  claude = backend:
    evaluate backend {
      ai = {
        airlock.instances.main = {};
        claude = {
          enable = true;
          proxy = forcedUnselected;
          native.settings.env = baseClaudeModule.config.ai.claude.native.settings.env;
        };
        proxy = forcedUnselected;
      };
    };
  initiallySelectedRoot = backend:
    evaluateModules backend [baseClaudeModule rootSelectedModule];
  unselectedRoot = backend:
    evaluateModules backend [baseClaudeModule rootSelectedModule unselectModule];
  initiallySelectedRuntime = backend:
    evaluateModules backend [baseClaudeModule runtimeSelectedModule];
  unselectedRuntime = backend:
    evaluateModules backend [baseClaudeModule runtimeSelectedModule unselectModule];
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
  selectionIsClear = selection:
    lib.all (field: selection.${field} == null) selectionLeaves;
  nativeClaudeUntouched = evaluated: let
    settings = claudeSettings evaluated;
  in
    selectionIsClear evaluated.config.ai.proxy
    && selectionIsClear evaluated.config.ai.claude.proxy
    && evaluated.config.ai.claude.normalized.proxy == null
    && failedAssertions evaluated == []
    && !(settings ? apiKeyHelper)
    && settings.env.ANTHROPIC_API_KEY == "existing-api-key"
    && settings.env.ANTHROPIC_AUTH_TOKEN == "existing-auth-token"
    && settings.env.ANTHROPIC_BASE_URL == "https://native.example.invalid"
    && settings.env.HTTPS_PROXY == "http://127.0.0.1:8318"
    && settings.env.NODE_EXTRA_CA_CERTS == "/etc/native-ca.pem";
  selectionOptOutWorks = backend: let
    rootBefore = initiallySelectedRoot backend;
    rootAfter = unselectedRoot backend;
    runtimeBefore = initiallySelectedRuntime backend;
    runtimeAfter = unselectedRuntime backend;
  in
    rootBefore.config.ai.claude.normalized.proxy.url
    == externalSelection.url
    && runtimeBefore.config.ai.claude.normalized.proxy.url == externalSelection.url
    && nativeClaudeUntouched rootAfter
    && nativeClaudeUntouched runtimeAfter;
in {
  checks =
    {
      airlock-instances = mkTest "airlock-instances" (
        lib.all (backend:
          (empty backend).ai.airlock.instances
          == {}
          && !(builtins.any (name: lib.hasPrefix "airlock" name)
            (builtins.attrNames ((empty backend).ai.services or {})))
          && noAirlockActivation (empty backend)
          && claimsCollide backend
          && disabledClaims backend
          && portDerived backend
          && listenOverrideRefused backend
          && serviceContract backend
          && nativeClaudeUntouched (claude backend)
          && selectionOptOutWorks backend)
        ["devenv" "hm"]
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
