# `ai.airlock.instances` on both backends: service contract, claims, rendered
# settings, and native Claude settings left untouched.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) claudeSettings;
  inherit (import ./helpers.nix {inherit harness lib pkgs;}) evaluate evaluateModules failures namedTest pythonPath serviceLauncher tokenReader;
  redact = import ../../../lib/redact {inherit lib;};
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
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  interceptionSettings = {
    destinations = ["localhost:443"];
    upstream_roots = "${pkgs.cacert}/etc/ssl/certs/ca-no-trust-rules-bundle.crt";
  };
  protected = backend:
    (evaluate backend {
      ai = {
        activationOrder.secretProviders.vault = {
          nodes = [];
          unit = "vault-agent.service";
        };
        airlock.instances.main.settings = {
          clients.fixture.token = redact.file "/run/secrets/airlock-test-client";
          interception = interceptionSettings;
        };
      };
    }).config;
  runtime = backend: authenticated:
    (
      evaluate backend {
        ai.airlock.instances.main = {
          port = 18439;
          stateDir = "/tmp/airlock-main-runtime-check-${backend}";
          settings = lib.optionalAttrs authenticated {
            clients.fixture.token = redact.command (lib.getExe tokenReader);
            interception = interceptionSettings;
          };
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
    (failures result);
  disabledClaims = backend: let
    inherit (evaluate backend {ai.airlock.instances.main.enable = false;}) config;
  in
    !config.ai.services.airlock-main.enable
    && config.ai.claims.port."8318" == ["airlock:airlock-main.ports.main"];
  protectedContract = backend: let
    config = protected backend;
    service = config.ai.services.airlock-main;
    rendered = builtins.fromJSON (builtins.unsafeDiscardStringContext service.files.config.content);
    native =
      if backend == "devenv"
      then config.processes.airlock-main.watch.paths == ["/run/secrets/airlock-test-client"]
      else if pkgs.stdenv.hostPlatform.isLinux
      then let
        unit = config.systemd.user.services.airlock-main.Unit;
      in
        builtins.elem "vault-agent.service" unit.After
        && builtins.elem "vault-agent.service" unit.Wants
      else true;
  in
    rendered.clients.fixture.token_file
    == "{$AIRLOCK_CLIENTS_FIXTURE_TOKEN_FILE}"
    && rendered.interception == interceptionSettings
    && builtins.hasContext service.files.config.content
    && !(rendered.interception ? ca_directory)
    && service.files.config.secrets.AIRLOCK_CLIENTS_FIXTURE_TOKEN_FILE
    == {_redact.asFile = redact.file "/run/secrets/airlock-test-client";}
    && services.triggers service == ["/run/secrets/airlock-test-client"]
    && config.ai.airlock.activation == {}
    && native;
  invalidSettingsRefused = backend:
    lib.all (settings:
      !(builtins.tryEval (builtins.deepSeq
        (evaluate backend {ai.airlock.instances.main.settings = settings;}).config.ai.services.airlock-main.files.config
        true)).success) [
      {clients.fixture.token = "literal-token-is-refused";}
      {interception.destinations = [443];}
      {
        interception = {
          destinations = ["localhost:443"];
          upstream_roots = 443;
        };
      }
      {
        interception = {
          destinations = ["localhost:443"];
          ca_directory = "/persistent/ca";
        };
      }
    ];
  launcher = backend: authenticated:
    serviceLauncher backend (runtime backend authenticated) "airlock-main";
  selectionIsClear = selection:
    lib.all (field: selection.${field} == null) selectionLeaves;
  nativeClaudeUntouched = evaluated: let
    settings = claudeSettings evaluated;
  in
    selectionIsClear evaluated.config.ai.proxy
    && selectionIsClear evaluated.config.ai.claude.proxy
    && evaluated.config.ai.claude.normalized.proxy == null
    && failures evaluated == []
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
  # Named so a failure reports which condition broke.
  conditions = backend: {
    "${backend}: an empty clients map renders" =
      (evaluate backend {ai.airlock.instances.main.settings.clients = {};}).config.ai.services.airlock-main.files.config.content
      == ''{"clients":{},"listen":"127.0.0.1:8318"}'';
    "${backend}: claim collisions are reported" = claimsCollide backend;
    "${backend}: disabled instances keep their claims" = disabledClaims backend;
    "${backend}: invalid settings are refused" = invalidSettingsRefused backend;
    "${backend}: listen cannot be overridden" = listenOverrideRefused backend;
    "${backend}: native Claude settings are untouched" = nativeClaudeUntouched (claude backend);
    "${backend}: no instance by default" =
      (empty backend).ai.airlock.instances
      == {}
      && !(builtins.any (name: lib.hasPrefix "airlock" name)
        (builtins.attrNames ((empty backend).ai.services or {})))
      && noAirlockActivation (empty backend);
    "${backend}: port derives listen" = portDerived backend;
    "${backend}: protected settings stay out of the store" = protectedContract backend;
    "${backend}: selection opt-out works" = selectionOptOutWorks backend;
    "${backend}: service contract" = serviceContract backend;
  };
in {
  checks =
    {
      airlock-instances = namedTest "airlock-instances" (lib.mergeAttrsList (map conditions ["devenv" "hm"]));
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      airlock-instance-runtime = pkgs.runCommandLocal "airlock-instance-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        PYTHONPATH=${pythonPath} ${pkgs.python3}/bin/python3 ${./airlock-instance-runtime.py} \
          ${pkgs.writeText "airlock-runtime-cases.json" (builtins.toJSON (lib.concatMap (backend:
          map (authenticated: {
            inherit authenticated backend;
            config = (runtime backend authenticated).ai.services.airlock-main.files.config.content;
            launcher = launcher backend authenticated;
          }) [false true]) ["hm" "devenv"]))}
        echo "ok — both generated Airlock launchers render private tokens and initialize/reuse runtime CAs before readiness" >"$out"
      '';
    };
}
