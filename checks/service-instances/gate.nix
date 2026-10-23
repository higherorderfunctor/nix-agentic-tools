# Gate wiring on both backends; runtime behavior is in runtime-providers.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  gate = import ../../packages/cliproxyapi/lib/gate.nix {inherit lib pkgs;};
  services = import ../../packages/ai-module/lib/services.nix {inherit lib;};
  upstream = name: excludedModels: {
    inherit excludedModels;
    apiKey = {
      apis.chat.base-url = "https://${name}.invalid/v1";
      key._redact.file = "/run/secrets/${name}";
      models = ["m" "n"];
    };
  };
  base = {
    clientKeys.one = {
      key._redact.file = "/run/secrets/client";
      routes = [{credential = "first";}];
    };
    credentials.first = upstream "first" null;
  };
  evaluate = backend: instance:
    (
      if backend == "hm"
      then harness.evalHm
      else harness.evalDevenv
    ) {
      ai.cliproxyapi.instances.main = instance;
    };
  accepts = backend: instance: let
    result = evaluate backend instance;
    attempt = builtins.tryEval (builtins.deepSeq result.config.ai.services (lib.all (item: item.assertion) result.config.assertions));
  in
    attempt.success && attempt.value;
  enabled =
    base
    // {
      exactModels = true;
      gate.enable = true;
    };
  checksFor = backend: let
    on = (evaluate backend enabled).config;
    off = (evaluate backend base).config;
    explicitOff = (evaluate backend (base // {gate.enable = false;})).config;
    cpa = on.ai.services.cliproxyapi-main;
    front = on.ai.services.cpa-gate-main;
    instance = on.ai.cliproxyapi.instances.main;
    policy = builtins.fromJSON front.files.policy.content;
    settings = builtins.fromJSON cpa.files.config.content;
    overlap = excluded:
      lib.recursiveUpdate enabled {
        clientKeys.one.routes = [{credential = "first";} {credential = "second";}];
        credentials.second = upstream "second" excluded;
      };
    state =
      if backend == "hm"
      then "/home/test/.local/state"
      else "/tmp/devenv-state";
    oldContent = builtins.toJSON {
      access = {
        api-keys = ["{$CLIPROXYAPI_ACCESS_API_KEYS_0}"];
        key-allowlist = [
          {
            api-key = "{$CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_API_KEY}";
            credentials = [
              {
                base-urls = ["https://first.invalid/v1"];
                kind = "apikey";
                provider = "openai-compatible-first";
              }
            ];
          }
        ];
      };
      api-keys.openai-compatibility = [
        {
          base-url = "https://first.invalid/v1";
          name = "first";
          keys = [{api-key = "{$CLIPROXYAPI_API_KEYS_OPENAI_COMPATIBILITY_0_KEYS_0_API_KEY}";}];
          models = [{name = "m";} {name = "n";}];
        }
      ];
      management.disable-auto-update-panel = true;
      oauth.auth-dir = "${state}/cliproxyapi/main/auth";
      server = {
        host = "127.0.0.1";
        port = 8317;
      };
    };
  in {
    "module-service-instances-gate-${backend}" = harness.mkTest "service-instances-gate-${backend}" (
      lib.all lib.id [
        (accepts backend enabled)
        (!off.ai.cliproxyapi.instances.main.gate.enable)
        (off.ai.services.cliproxyapi-main.files.config.content == oldContent)
        (off.ai.services == explicitOff.ai.services)
        (
          if backend == "hm"
          then off.systemd.user.services == explicitOff.systemd.user.services
          else off.processes == explicitOff.processes
        )
        (!(off.ai.services ? cpa-gate-main))
        (cpa.ports.main == 18317)
        (front.ports.main == 8317)
        (front.ports.health == 28317)
        (settings.server.host == "127.0.0.1")
        (settings.server.port == 18317)
        (builtins.attrNames on.ai.claims.port == ["18317" "28317" "8317"])
        (cpa.restartOnChange == front.restartOnChange)
        (services.triggers cpa == services.triggers front)
        (lib.elem "/run/secrets/client" (services.triggers cpa))
        ((lib.head policy.entries).models == ["m" "n"])
        (front.environment == {})
        (front.files.policy.secrets.CPA_GATE_ENTRIES_0_KEY == base.clientKeys.one.key)
        (cpa.files.config.secrets.CLIPROXYAPI_ACCESS_API_KEYS_0 == gate.internalKey instance "one")
        (!(lib.elem base.clientKeys.one.key (builtins.attrValues cpa.files.config.secrets)))
        (!(accepts backend (base // {gate.enable = true;})))
        (!(accepts backend (enabled // {clientKeys = {};})))
        (accepts backend (overlap null))
        (!(accepts backend (overlap ["m"])))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.server.host = "0.0.0.0";})))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.access.api-keys = [base.clientKeys.one.key];})))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.observability.logs.debug = true;})))
      ]
    );
  };
in {checks = checksFor "devenv" // checksFor "hm";}
