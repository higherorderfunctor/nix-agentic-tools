{
  harness,
  lib,
  pkgs,
  ...
}: let
  backends = import ./backends.nix {inherit harness lib pkgs;};
  redact = import ../../../lib/redact {inherit lib;};
  services = import ../lib/services.nix {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix;
  daemon = {command = ["/bin/daemon" "an argument"];};
  entries = lib.genAttrs ["always" "never" "on-failure"] (restart: daemon // {inherit restart;});
  watched =
    daemon
    // {
      environment = {
        CONCAT = redact.concat ["prefix " (redact.file "/run/secrets/second")];
        DIRECT = redact.file "/run/secrets/first";
        LITERAL = "literal $(false) ' quote";
      };
      restartOnChange = ["/etc/daemon.conf" "/run/secrets/first"];
    };
  expectedTriggers = ["/etc/daemon.conf" "/run/secrets/first" "/run/secrets/second"];
  hm = backends.evaluateWith harness.linuxPkgs "hm" {services = entries // {inherit watched;};};
  devenv = backends.evaluate "devenv" {services = entries // {inherit watched;};};
  unsupported = isDarwin:
    (lib.evalModules {
      specialArgs = {
        inherit (backends.sinks.hm) lib;
        pkgs = harness.pkgsOn {
          inherit isDarwin;
          isLinux = false;
        };
      };
      modules = [
        harness.hmStubs
        ../modules/homeManager/default.nix
        {
          ai.services = {
            live = watched;
            stopped = daemon // {enable = false;};
          };
        }
      ];
    }).config;
  darwin = unsupported true;
  other = unsupported false;
  evaluateOwners = backend: definitions:
    (lib.evalModules {
      specialArgs = {
        inherit (backends.sinks.${backend}) lib;
        inherit pkgs;
      };
      modules = [
        backends.sinks.${backend}.stubs
        backends.sinks.${backend}.module
        (import ../lib/runtime.nix {
          name = "alpha";
          enabled = true;
        })
        (import ../lib/runtime.nix {
          name = "beta";
          enabled = true;
        })
        {ai = definitions;}
      ];
    }).config;
  succeeds = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  failures = config: map (item: item.message) (builtins.filter (item: !item.assertion) config.assertions);
  collision = backend: definitions: expected: failures (evaluateOwners backend definitions) == [expected];
  positive = backend: let
    config = evaluateOwners backend {
      alpha.services = {
        "help" = daemon // {ports.main = 9200;};
        two = daemon // {ports.main = 9201;};
      };
    };
    native =
      if backend == "hm"
      then config.systemd.user.services
      else config.processes;
  in
    builtins.attrNames native
    == ["help" "two"]
    && config.ai.claims.port
    == {
      "9200" = ["alpha:help.ports.main"];
      "9201" = ["alpha:two.ports.main"];
    }
    && failures config == [];
  disabled = evaluateOwners "hm" {
    alpha.services.one =
      daemon
      // {
        enable = false;
        ports.http = 9200;
      };
  };
  launcherReader = strictShellApplication pkgs {
    name = "services-test-reader";
    text = ''
      if [ -n "''${SERVICE_READER_FAIL:-}" ]; then exit 1; fi
      printf '%s' 'secret value'
    '';
  };
  receiver = strictShellApplication pkgs {
    name = "services-test-receiver";
    text = ''
      printf '%s\n' "$LITERAL" "$PRIVATE" "$@"
    '';
  };
  launcher = services.mkLauncher {
    inherit pkgs;
    name = "test";
    entry = {
      command = ["${receiver}/bin/services-test-receiver" "argument $(false)" "space ' quote"];
      environment = {
        LITERAL = "literal $(false) ' quote";
        PRIVATE = redact.command "${launcherReader}/bin/services-test-reader";
      };
    };
  };
  restartRecorder = strictShellApplication pkgs {
    name = "systemctl";
    text = ''
      if [ "$2" = is-system-running ]; then
        printf '%s\n' "''${SERVICE_MANAGER_STATE:-running}"
        exit 0
      fi
      printf '%s\n' "$*" >> "$SERVICE_RESTART_LOG"
      test -z "''${SERVICE_RESTART_FAIL:-}"
    '';
  };
  restartCommand =
    (services.hmRestart (pkgs // {systemd = restartRecorder;}) {
      help = {
        enable = true;
        environment = {};
        restartOnChange = ["/build/missing-trigger" "/build/trigger"];
      };
    }).services-restart-on-change.command;
  mkCheck = name: condition:
    assert lib.assertMsg condition "${name}: service contract failed";
      pkgs.runCommandLocal name {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        touch "$out"
      '';
in {
  checks = {
    ai-module-services-backends = mkCheck "ai-module-services-backends" (
      lib.all (restart: let
        unit = hm.systemd.user.services.${restart};
        process = devenv.processes.${restart};
      in
        unit
        == {
          Install.WantedBy = ["default.target"];
          Service = {
            ExecStart = process.exec;
            Restart =
              if restart == "never"
              then "no"
              else restart;
            RestartSec = 5;
          };
          Unit = {
            After = ["network.target"];
            Description = "${restart} (ai.services)";
          };
        }
        && process.restart.on
        == (
          if restart == "on-failure"
          then "on_failure"
          else restart
        )
        && !(process ? watch)) (builtins.attrNames entries)
      && devenv.processes.watched.watch.paths == expectedTriggers
      && services.triggers hm.ai.services.watched == expectedTriggers
      && hm.home.activation.ai-services-restart-on-change.after == ["linkGeneration" "sops-nix" "vault:ready"]
      && !(devenv.tasks ? "ai:services-restart-on-change")
      && !((backends.evaluateWith harness.linuxPkgs "hm" {services.plain = daemon;}).home.activation ? ai-services-restart-on-change)
      && darwin.systemd.user.services == {}
      && darwin.warnings == ["ai.services.live: Home Manager writes services as systemd user units, which this platform lacks; the service is not written"]
      && other.warnings == darwin.warnings
      && other.systemd.user.services == {}
      && !(darwin.home.activation ? ai-services-restart-on-change)
    );
    ai-module-services-claims = mkCheck "ai-module-services-claims" (
      lib.all (
        backend:
          positive backend
          && collision backend {
            alpha.services.same = daemon;
            beta.services.same = daemon;
          }
          "ai.claims.service.same: claimed by alpha and beta"
          && collision backend {
            alpha.services.same = daemon // {enable = false;};
            beta.services.same = daemon;
          }
          "ai.claims.service.same: claimed by alpha and beta"
          && collision backend {
            alpha.services.one = daemon // {ports.main = 9200;};
            beta.services.two = daemon // {ports.main = 9200;};
          }
          "ai.claims.port.9200: claimed by alpha:one.ports.main and beta:two.ports.main"
          && collision backend {
            alpha.services.one =
              daemon
              // {
                ports = {
                  http = 9200;
                  metrics = 9200;
                };
              };
          }
          "ai.claims.port.9200: claimed by alpha:one.ports.http and alpha:one.ports.metrics"
          && collision backend {
            alpha.files.same = {enable = false;};
            beta.files.same = {content.text = "different";};
          }
          "ai.claims.path.same: claimed by alpha and beta"
      ) ["devenv" "hm"]
      && disabled.ai.claims.service.one == ["alpha"]
      && disabled.ai.claims.port."9200" == ["alpha:one.ports.http"]
      && disabled.systemd.user.services == {}
      && !(succeeds (backends.evaluate "hm" {services."bad.name" = daemon;}).systemd.user.services)
    );
    ai-module-services-launcher = pkgs.runCommandLocal "ai-module-services-launcher" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      if SERVICE_READER_FAIL=1 ${launcher}/bin/ai-service-test > failed; then
        echo "failed reader started the receiver" >&2
        exit 1
      fi
      test ! -s failed
      ${launcher}/bin/ai-service-test > actual
      ${pkgs.diffutils}/bin/diff -u ${pkgs.writeText "services-expected" "literal $(false) ' quote\nsecret value\nargument $(false)\nspace ' quote\n"} actual
      ${pkgs.gnugrep}/bin/grep -F 'export PRIVATE' ${launcher}/bin/ai-service-test
      ${pkgs.gnugrep}/bin/grep -F 'redact-read' ${launcher}/bin/ai-service-test
      touch "$out"
    '';
    ai-module-services-rotation = pkgs.runCommandLocal "ai-module-services-rotation" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export XDG_STATE_HOME="$TMPDIR/state"
      export SERVICE_RESTART_LOG="$TMPDIR/restarts"
      hash_file="$XDG_STATE_HOME/nix-agentic-tools/services/help.sha256"
      run() { ${pkgs.bash}/bin/bash -euETo pipefail -c ${lib.escapeShellArg restartCommand}; }
      touch "$SERVICE_RESTART_LOG"
      printf '%s' first > /build/trigger
      SERVICE_MANAGER_STATE=offline run
      test ! -e "$hash_file"
      run
      test -s "$hash_file"
      test ! -s "$SERVICE_RESTART_LOG"
      run
      test ! -s "$SERVICE_RESTART_LOG"
      printf '%s' second > /build/trigger
      run
      test "$(${pkgs.coreutils}/bin/wc -l < "$SERVICE_RESTART_LOG")" -eq 1
      test "$(${pkgs.coreutils}/bin/head -1 "$SERVICE_RESTART_LOG")" = '--user try-restart help'
      ${pkgs.coreutils}/bin/cp "$hash_file" previous
      printf '%s' third > /build/trigger
      if SERVICE_RESTART_FAIL=1 run; then
        echo "restart failure was swallowed" >&2
        exit 1
      fi
      ${pkgs.diffutils}/bin/cmp previous "$hash_file"
      run
      test "$(${pkgs.coreutils}/bin/wc -l < "$SERVICE_RESTART_LOG")" -eq 3
      touch "$out"
    '';
  };
}
