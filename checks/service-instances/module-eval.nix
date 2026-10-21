# `ai.<owner>.instances` for CLIProxyAPI and CPA Manager Plus through the
# shared helper (packages/ai-module/lib/instances.nix): each instance is one
# `ai.services` entry with a rendered config file, on both backends.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  redact = import ../../lib/redact {inherit lib;};
  services = import ../../packages/ai-module/lib/services.nix {inherit lib;};
  strictShellApplication = import ../../lib/strict-shell-application.nix;

  clientKey = redact.file "/run/secrets/cpa-client-key";
  managementKey = redact.file "/run/secrets/cpa-management-key";
  placeholder = name: "{" + "$" + name + "}";
  declared = {
    cliproxyapi.instances.main = {
      port = 8400;
      settings = {
        access.api-keys = [clientKey];
        management.secret-key = managementKey;
      };
    };
    cpa-manager-plus.instances.main = {
      port = 18400;
      upstream = "main";
    };
  };
  withInstances = ai: {ai = lib.recursiveUpdate declared ai;};
  evaluate = backend:
    if backend == "hm"
    then evalHm
    else evalDevenv;
  stateRoot = {
    devenv = "/tmp/devenv-state";
    hm = "/home/test/.local/state";
  };
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  failures = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);

  # The service entries and claims both backends share.
  entries = backend: let
    inherit (evaluate backend (withInstances {})) config;
    proxy = config.ai.services.cliproxyapi-main;
    manager = config.ai.services.cpa-manager-plus-main;
    root = stateRoot.${backend};
  in
    proxy.files.config.variable
    == "CPA_CONFIG"
    && proxy.files.config.secrets
    == {
      CLIPROXYAPI_ACCESS_API_KEYS_0 = clientKey;
      CLIPROXYAPI_MANAGEMENT_SECRET_KEY = managementKey;
    }
    && builtins.fromJSON proxy.files.config.content
    == {
      access.api-keys = [(placeholder "CLIPROXYAPI_ACCESS_API_KEYS_0")];
      management.secret-key = placeholder "CLIPROXYAPI_MANAGEMENT_SECRET_KEY";
      oauth.auth-dir = "${root}/cliproxyapi/main/auth";
      server = {
        host = "127.0.0.1";
        port = 8400;
      };
    }
    && (evaluate backend (withInstances {cliproxyapi.instances.main.settings.server.host = "192.0.2.1";})).config.ai.cliproxyapi.instances.main.settings.server.host == "192.0.2.1"
    && proxy.environment == {}
    && lib.hasSuffix "/bin/cliproxyapi-main" (lib.head proxy.command)
    && services.triggers proxy == ["/run/secrets/cpa-client-key" "/run/secrets/cpa-management-key"]
    && manager.files.config.variable == "CPA_MANAGER_CONFIG"
    && manager.files.config.secrets == {}
    && builtins.fromJSON manager.files.config.content
    == {
      cpaUpstreamUrl = "http://127.0.0.1:8400";
      dataDir = "${root}/cpa-manager-plus/main";
      httpAddr = "127.0.0.1:18400";
    }
    && manager.environment == {CPA_MANAGEMENT_KEY = managementKey;}
    && config.ai.claims.port
    == {
      "18400" = ["cpa-manager-plus:cpa-manager-plus-main.ports.main"];
      "8400" = ["cliproxyapi:cliproxyapi-main.ports.main"];
    }
    && failures (evaluate backend (withInstances {})) == [];

  # A plaintext secret, a port the instance fixes set to another value, and
  # an upstream that names no enabled instance are all refused.
  refusals = backend: let
    entry = ai: (evaluate backend (withInstances ai)).config.ai.services.cliproxyapi-main.files;
  in
    !(succeeds (entry {cliproxyapi.instances.main.settings.access.api-keys = ["plain-client-key"];}))
    && !(succeeds (entry {cliproxyapi.instances.main.settings.server.port = 9999;}))
    && failures (evaluate backend (withInstances {cpa-manager-plus.instances.main.upstream = "missing";}))
    == ["ai.cpa-manager-plus.instances.main.upstream names `missing`, which is not an `ai.cliproxyapi.instances` entry."]
    && failures (evaluate backend (withInstances {cliproxyapi.instances.main.enable = false;}))
    == ["ai.cpa-manager-plus.instances.main.upstream names `ai.cliproxyapi.instances.main`, which is disabled."];

  devenv = (evalDevenv (withInstances {})).config;
  hm = (evalHm (withInstances {})).config;
  disabled =
    (evalHm (withInstances {
      cliproxyapi.instances.main.enable = false;
      cpa-manager-plus.instances.main.upstream = null;
    })).config;

  # A stand-in CLIProxyAPI that reports its argv, working directory, config
  # and auth directory mode, run through the real launcher and run script.
  fakeProxy = strictShellApplication pkgs {
    name = "cliproxyapi";
    text = ''
      printf '%s\n' "$*" "$PWD" > "$RECEIVED/argv"
      ${pkgs.coreutils}/bin/cp "$2" "$RECEIVED/config.json"
      ${pkgs.coreutils}/bin/stat -c '%a' "$PWD" "$PWD/auth" > "$RECEIVED/modes"
    '';
  };
  runnable =
    (evalHm (withInstances {
      cliproxyapi.instances.main = {
        package = fakeProxy;
        settings = {
          access.api-keys = [(redact.file "/build/client-key")];
          management.secret-key = redact.file "/build/management-key";
        };
        stateDir = "/build/state/main";
      };
    })).config;
in {
  checks =
    {
      module-service-instances = mkTest "service-instances" (
        lib.all (backend: entries backend && refusals backend) ["devenv" "hm"]
        && devenv.processes.cliproxyapi-main.watch.paths == ["/run/secrets/cpa-client-key" "/run/secrets/cpa-management-key"]
        && devenv.processes.cpa-manager-plus-main.watch.paths == ["/run/secrets/cpa-management-key"]
        && !disabled.ai.services.cliproxyapi-main.enable
        && disabled.ai.claims.port."8400" == ["cliproxyapi:cliproxyapi-main.ports.main"]
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # Start the packaged daemons through the actual instance-derived units,
      # with file references whose dummy values exist only at build time.
      module-service-instances-real-daemons = let
        real =
          (evalHm (withInstances {
            cliproxyapi.instances.main = {
              package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
              port = 28417;
              settings = {
                access.api-keys = [(redact.file "/build/client-key")];
                management.secret-key = redact.file "/build/management-key";
              };
              stateDir = "/build/state/cpa";
            };
            cpa-manager-plus.instances.main = {
              package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cpa-manager-plus;
              port = 28418;
              stateDir = "/build/state/manager";
            };
          })).config;
      in
        pkgs.runCommandLocal "module-test-service-instances-real-daemons" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s' client-test-secret > /build/client-key
          printf '%s' management-test-secret > /build/management-key
          # The user manager sets XDG_RUNTIME_DIR and INVOCATION_ID for every unit.
          export HOME="$TMPDIR/home" XDG_RUNTIME_DIR="$TMPDIR/run" INVOCATION_ID=real-daemons
          mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
          processes=()
          cleanup() {
            for pid in "''${processes[@]}"; do kill -KILL "$pid" 2>/dev/null || :; done
            wait || :
          }
          trap cleanup EXIT
          ready() {
            local pid=$1 url=$2 log=$3
            for attempt in {1..100}; do
              # cspell:ignore noproxy
              if ${pkgs.curl}/bin/curl --noproxy '*' --max-time 1 --silent --fail "$url" > health.json; then
                return 0
              fi
              if ! kill -0 "$pid" 2>/dev/null; then break; fi
              sleep 0.1
            done
            cat "$log" >&2
            echo "service did not become ready: $url" >&2
            return 1
          }
          ${real.systemd.user.services.cliproxyapi-main.Service.ExecStart} > cpa.log 2>&1 &
          processes+=("$!")
          ready "''${processes[0]}" http://127.0.0.1:28417/healthz cpa.log
          ${pkgs.jq}/bin/jq -e '.status == "ok"' health.json
          ${real.systemd.user.services.cpa-manager-plus-main.Service.ExecStart} > manager.log 2>&1 &
          processes+=("$!")
          ready "''${processes[1]}" http://127.0.0.1:28418/health manager.log
          ${pkgs.jq}/bin/jq -e '.ok == true and .service == "cpa-manager-plus"' health.json
          # Each port has exactly one listener, bound to IPv4 loopback.
          for port in 6F01 6F02; do
            ${pkgs.gawk}/bin/awk -v port="$port" '
              $4 == "0A" && $2 ~ ":" port "$" {
                count++
                if ($2 != "0100007F:" port) exit 1
                print "loopback listener: " $2
              }
              END { if (count != 1) exit 1 }
            ' /proc/net/tcp /proc/net/tcp6
          done
          touch "$out"
        '';
      # Linux Home Manager emits the units, and the launcher renders the
      # config the run script hands to CLIProxyAPI from inside its state.
      module-service-instances-run = let
        launcher = services.mkLauncher {
          inherit pkgs;
          entry = runnable.ai.services.cliproxyapi-main;
          name = "cliproxyapi-main";
        };
      in
        assert lib.assertMsg (
          lib.all (name: lib.hasSuffix "/bin/ai-service-${name}" hm.systemd.user.services.${name}.Service.ExecStart) ["cliproxyapi-main" "cpa-manager-plus-main"]
          && !(disabled.systemd.user.services ? cliproxyapi-main)
        ) "module-service-instances-run: Home Manager units";
          pkgs.runCommandLocal "module-test-service-instances-run" {} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            printf '%s' client-secret > /build/client-key
            printf '%s' management-secret > /build/management-key
            export XDG_RUNTIME_DIR="$TMPDIR/run" RECEIVED="$TMPDIR/received"
            mkdir -p "$RECEIVED" "$XDG_RUNTIME_DIR"
            ${launcher}/bin/ai-service-cliproxyapi-main
            printf '%s\n' "--config $XDG_RUNTIME_DIR/ai-service-cliproxyapi-main/config.json" /build/state/main > expected
            ${pkgs.diffutils}/bin/diff -u expected "$RECEIVED/argv"
            test "$(${pkgs.coreutils}/bin/tr '\n' ' ' < "$RECEIVED/modes")" = '700 700 '
            ${pkgs.jq}/bin/jq -e '.access."api-keys" == ["client-secret"] and .management."secret-key" == "management-secret" and .oauth."auth-dir" == "/build/state/main/auth"' "$RECEIVED/config.json"
            touch "$out"
          '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      module-service-instances-darwin-warns = mkTest "service-instances-darwin-warns" (
        hm.systemd.user.services
        == {}
        && lib.all (name: lib.elem "ai.services.${name}: Home Manager writes services as systemd user units, which this platform lacks; the service is not written" hm.warnings) ["cliproxyapi-main" "cpa-manager-plus-main"]
      );
    };
}
