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
    # Historical gate-off service semantics, with only its executable supplied
    # by the separate full-body check below, never a fixed store hash.
    oldEntry = {
      command = off.ai.services.cliproxyapi-main.command;
      enable = true;
      environment = {};
      files.config = {
        content = oldContent;
        secrets = {
          CLIPROXYAPI_ACCESS_API_KEYS_0 = base.clientKeys.one.key;
          CLIPROXYAPI_ACCESS_KEY_ALLOWLIST_0_API_KEY = base.clientKeys.one.key;
          CLIPROXYAPI_API_KEYS_OPENAI_COMPATIBILITY_0_KEYS_0_API_KEY = base.credentials.first.apiKey.key;
        };
        variable = "CPA_CONFIG";
      };
      ports.main = 8317;
      restart = "on-failure";
      restartOnChange = [];
    };
    launcher = stamp:
      lib.getExe (services.mkLauncher {
        inherit pkgs stamp;
        entry = oldEntry;
        name = "cliproxyapi-main";
      });
    oldBackend =
      if backend == "hm"
      then
        lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
          cliproxyapi-main = {
            Install.WantedBy = ["default.target"];
            Service = {
              ExecStart = launcher true;
              Restart = "on-failure";
              RestartSec = 5;
            };
            Unit = {
              After = ["network.target" "sops-nix.service"];
              Description = "cliproxyapi-main (ai.services)";
              StartLimitBurst = 5;
              StartLimitIntervalSec = 300;
              Wants = ["sops-nix.service"];
            };
          };
        }
      else {
        cliproxyapi-main = {
          exec = launcher false;
          restart = {
            max = 4;
            on = "on_failure";
            window = 300;
          };
          watch.paths = ["/run/secrets/client" "/run/secrets/first"];
        };
      };
    oldBody = pkgs.writeText "cpa-off-command" ''
      ${pkgs.coreutils}/bin/mkdir -p ${lib.escapeShellArgs ["${state}/cliproxyapi/main" "${state}/cliproxyapi/main/auth"]}
      ${pkgs.coreutils}/bin/chmod 0700 ${lib.escapeShellArgs ["${state}/cliproxyapi/main" "${state}/cliproxyapi/main/auth"]}
      cd ${lib.escapeShellArg "${state}/cliproxyapi/main"}
      exec ${lib.getExe off.ai.cliproxyapi.instances.main.package} --config "$CPA_CONFIG" --local-model
    '';
    renamed = name: enabled // {clientKeys.${name} = base.clientKeys.one;};
    tls = value: {
      enable = value;
      cert = "/run/cpa-cert.pem";
      key._redact.file = "/run/secrets/tls";
    };
  in {
    "module-service-instances-gate-${backend}" = harness.mkTest "service-instances-gate-${backend}" (
      lib.all lib.id [
        (accepts backend enabled)
        (!off.ai.cliproxyapi.instances.main.gate.enable)
        (off.ai.services.cliproxyapi-main.files.config.content == oldContent)
        (off.ai.services == explicitOff.ai.services)
        (off.ai.services == {cliproxyapi-main = oldEntry;})
        (lib.length oldEntry.command == 1)
        ((
            if backend == "hm"
            then off.systemd.user.services
            else off.processes
          )
          == oldBackend)
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
        (!settings.server.tls.enable)
        (settings.server.commercial-mode
          && settings.observability.logs
          == {
            debug = false;
            logging-to-file = false;
            request-log = false;
          })
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
        (lib.all (name: accepts backend (renamed name)) ["one" "name with spaces" "prefix-{$CPA_GATE_ENTRIES_0_INTERNAL}"])
        (lib.all (name: !(accepts backend (renamed name))) ["{$CPA_GATE_ENTRIES_0_INTERNAL}" "{$CPA_GATE_ENTRIES_0_KEY}" "{$UNBOUND}"])
        (accepts backend ((renamed "{$CPA_GATE_ENTRIES_0_INTERNAL}") // {gate.enable = false;}))
        (accepts backend (lib.recursiveUpdate enabled {settings.server.tls = tls false;}))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.server.tls = tls true;})))
        (accepts backend (lib.recursiveUpdate base {settings.server.tls = tls true;}))
        (builtins.fromJSON (evaluate backend (lib.recursiveUpdate base {settings.server.tls = tls true;})).config.ai.services.cliproxyapi-main.files.config.content).server.tls.enable
        (accepts backend (overlap null))
        (!(accepts backend (overlap ["m"])))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.server.host = "0.0.0.0";})))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.access.api-keys = [base.clientKeys.one.key];})))
        (!(accepts backend (lib.recursiveUpdate enabled {settings.observability.logs.debug = true;})))
      ]
    );
    "module-service-instances-gate-off-command-${backend}" = pkgs.runCommand "service-instances-gate-off-command-${backend}" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 - ${oldBody} ${lib.head oldEntry.command} ${lib.escapeShellArg (import ../../config/shell-strict.nix).shoptHeader} <<'PYTHON'
      from pathlib import Path
      import sys
      expected = Path(sys.argv[1]).read_text()
      script = Path(sys.argv[2]).read_text()
      header = sys.argv[3] + "\n"
      assert script.count(header) == 1
      body = script.split(header, 1)[1]
      lines = lambda text: [line.strip() for line in text.splitlines() if line.strip()]
      assert lines(body) == lines(expected), "gate-off owner command differs from the historical contract"
      PYTHON
      touch "$out"
    '';
  };
in {
  checks =
    checksFor "devenv"
    // checksFor "hm"
    // {
      module-service-instances-gate-output = let
        fake = (import ../../lib/strict-shell-application.nix pkgs) {
          name = "cliproxyapi";
          text = ''
            printf '%s\n' cpa-output-marker
            printf '%s\n' cpa-error-marker >&2
          '';
        };
        command = enabled:
          lib.head
          (evaluate "hm" (base
            // {
              exactModels = enabled;
              gate.enable = enabled;
              package = fake;
              stateDir = "/build/gate-output";
            })).config.ai.services.cliproxyapi-main.command;
      in
        pkgs.runCommand "service-instances-gate-output" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export CPA_CONFIG=unused
          ${command false} > off.log 2>&1
          ${pkgs.gnugrep}/bin/grep -Fx cpa-output-marker off.log
          ${pkgs.gnugrep}/bin/grep -Fx cpa-error-marker off.log
          ${command true} > on.log 2>&1
          test ! -s on.log
          touch "$out"
        '';
    };
}
