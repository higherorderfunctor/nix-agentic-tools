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
      files.config = {
        content = builtins.toJSON {key = "{" + "$" + "KEY}";};
        secrets.KEY = redact.file "/run/secrets/third";
        variable = "CONFIG";
      };
      restartOnChange = ["/etc/daemon.conf" "/run/secrets/first"];
    };
  expectedTriggers = ["/etc/daemon.conf" "/run/secrets/first" "/run/secrets/second" "/run/secrets/third"];
  hm = backends.evaluate "hm" {services = entries // {inherit watched;};};
  devenv = backends.evaluate "devenv" {services = entries // {inherit watched;};};
  providerServices = {
    activation.probe = {
      after = ["secrets"];
      command = "true";
    };
    activationOrder.secretProviders.vault = {
      nodes = ["vault:ready"];
      unit = "vault-agent.service";
    };
    services = {
      plain = daemon;
      secret = watched;
    };
  };
  noLegacyNodes = {ai.activationOrder.secretNodes = lib.mkForce [];};
  withProvider = backends.evaluateWith "hm" providerServices [noLegacyNodes];
  withProviderUnits = backends.evaluateWith "hm" providerServices [
    noLegacyNodes
    {
      systemd.user.services = {
        sops-nix.Install.WantedBy = ["graphical-session-pre.target"];
        vault-agent.Install.WantedBy = ["default.target" "graphical-session-pre.target"];
      };
    }
  ];
  withProviderDevenv = backends.evaluateWith "devenv" providerServices [noLegacyNodes];
  withSopsUnit = backends.evaluateWith "hm" {
    services = {
      plain = daemon // {environment.OPTIONAL = null;};
      secret = watched;
    };
  } [{systemd.user.services.sops-nix.Install.WantedBy = ["graphical-session-pre.target"];}];
  withoutSopsUnit = backends.evaluateWith "hm" {
    activation.probe = {
      after = ["secrets"];
      command = "true";
    };
    activationOrder.secretProviders.sops-nix = {
      nodes = ["custom:ready"];
      unit = null;
    };
    services.secret = watched;
  } [noLegacyNodes];
  environmentOnly = backends.evaluate "hm" {
    services.secret = daemon // {environment.TOKEN = redact.file "/run/secrets/env-only";};
  };
  fileOnly = backends.evaluate "hm" {
    services.secret =
      daemon
      // {
        files.config = {
          content = builtins.toJSON {key = "{$KEY}";};
          secrets.KEY = redact.file "/run/secrets/only-file";
          variable = "CONFIG";
        };
      };
  };
  darwin = backends.evaluate "hm" {
    services = {
      live = watched;
      stopped = daemon // {enable = false;};
    };
  };
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
      if [ -n "''${SERVICE_READER_CHECK_SLOTS:-}" ]; then
        test -z "''${_ai_secret_0+x}''${_ai_secret_1+x}"
      fi
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
      files = {};
    };
  };
  # A rendered file: two secrets, one needing JSON escapes and read from a
  # `redact.file` the check writes under the Linux sandbox's /build.
  placeholder = name: "{" + "$" + name + "}";
  fileContent = builtins.toJSON {
    access.api-keys = [(placeholder "KEY")];
    literal = "plain {$text}";
    nested = [{token = placeholder "TOKEN";}];
    port = 8317;
  };
  fileReceiver = strictShellApplication pkgs {
    name = "services-test-file-receiver";
    text = ''
      printf '%s\n' "$SERVICE_CONFIG" > "$RECEIVED/path"
      ${pkgs.coreutils}/bin/stat -c '%a' "$SERVICE_CONFIG" "''${SERVICE_CONFIG%/*}" > "$RECEIVED/modes"
      ${pkgs.coreutils}/bin/cp "$SERVICE_CONFIG" "$RECEIVED/config.json"
      ${pkgs.coreutils}/bin/env > "$RECEIVED/environment"
    '';
  };
  fileEntry = files: {
    command = ["${fileReceiver}/bin/services-test-file-receiver"];
    environment = {};
    inherit files;
  };
  fileLauncher = entry:
    services.mkLauncher {
      inherit entry pkgs;
      name = "files-test";
    };
  config = {
    content = fileContent;
    secrets = {
      KEY = redact.file "/build/secret";
      TOKEN = redact.command "${launcherReader}/bin/services-test-reader";
    };
    variable = "SERVICE_CONFIG";
  };
  refused = entry: !(succeeds (fileLauncher entry).drvPath);
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
        files = {};
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
  checks =
    {
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
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
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
        && hm.systemd.user.services.watched.Unit.After == ["network.target" "sops-nix.service"]
        && hm.systemd.user.services.watched.Install.WantedBy == ["default.target"]
        && fileOnly.systemd.user.services.secret.Unit.After == ["network.target" "sops-nix.service"]
        && fileOnly.systemd.user.services.secret.Install.WantedBy == ["default.target"]
        && environmentOnly.systemd.user.services.secret.Unit.After == ["network.target" "sops-nix.service"]
        && withSopsUnit.systemd.user.services.secret.Install.WantedBy == ["graphical-session-pre.target"]
        && withSopsUnit.systemd.user.services.secret.Unit.After == ["network.target" "sops-nix.service"]
        && withSopsUnit.systemd.user.services.plain.Install.WantedBy == ["default.target"]
        && withSopsUnit.systemd.user.services.plain.Unit.After == ["network.target"]
        && withProvider.systemd.user.services.secret.Unit.After == ["network.target" "sops-nix.service" "vault-agent.service"]
        && withProvider.systemd.user.services.secret.Install.WantedBy == ["default.target"]
        && withProviderUnits.systemd.user.services.secret.Install.WantedBy == ["default.target" "graphical-session-pre.target"]
        && withProviderUnits.systemd.user.services.plain.Install.WantedBy == ["default.target"]
        && withProvider.home.activation.ai-probe.after == ["sops-nix" "vault:ready"]
        && withProvider.home.activation.ai-services-restart-on-change.after == ["linkGeneration" "sops-nix" "vault:ready"]
        && withoutSopsUnit.systemd.user.services.secret.Unit.After == ["network.target"]
        && withoutSopsUnit.home.activation.ai-probe.after == ["custom:ready"]
        && withProviderDevenv.tasks."ai:probe".after == ["vault:ready"]
        && !(builtins.elem "vault-agent.service" withProviderDevenv.tasks."ai:probe".after)
        && !(withProviderDevenv.tasks ? "ai:services-restart-on-change")
        && !(succeeds
          (backends.evaluate "hm" {
            activationOrder.secretProviders.own.unit = "secret.service";
            services.secret = watched;
          }).systemd.user.services.secret.Install.WantedBy)
        && hm.home.activation.ai-services-restart-on-change.after == ["linkGeneration" "sops-nix" "vault:ready"]
        && !(devenv.tasks ? "ai:services-restart-on-change")
        && !((backends.evaluate "hm" {services.plain = daemon;}).home.activation ? ai-services-restart-on-change)
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
        && !(succeeds (backends.evaluate "hm" {services."bad.name" = daemon;}).ai.services)
      );
      # The launcher renders a file at start: placeholders filled as JSON
      # strings, 0600 in a 0700 directory, path exported, secrets never
      # exported; the store copy holds placeholders only. A mismatch between
      # placeholders and secrets, or a reused variable, fails evaluation.
      ai-module-services-files = let
        launcher = fileLauncher (fileEntry {inherit config;});
      in
        assert lib.assertMsg (refused ((fileEntry {inherit config;}) // {environment._ai_dir = "collision";})) "ai-module-services-files: reserved environment variable was accepted";
        assert lib.assertMsg (refused (fileEntry {config = config // {variable = "_ai_dir";};})) "ai-module-services-files: reserved file variable was accepted";
        assert lib.assertMsg (
          refused (fileEntry {config = config // {secrets = builtins.removeAttrs config.secrets ["TOKEN"];};})
          && refused (fileEntry {config = config // {secrets = config.secrets // {UNUSED = redact.file "/run/secrets/unused";};};})
          && refused (fileEntry {
            inherit config;
            other =
              config
              // {
                content = "{}";
                secrets = {};
              };
          })
          && refused (fileEntry {"../escape" = config;})
        ) "ai-module-services-files: a mismatched file was accepted";
          pkgs.runCommandLocal "ai-module-services-files" {} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            printf '%s' 'marker "quoted" \\ value
            line two' > /build/secret
            export XDG_RUNTIME_DIR="$TMPDIR/run" RECEIVED="$TMPDIR/received"
            mkdir -p -m 0755 "$XDG_RUNTIME_DIR/ai-service-files-test" "$RECEIVED"
            touch "$XDG_RUNTIME_DIR/ai-service-files-test/config.json"
            _ai_secret_0=inherited _ai_secret_1=inherited SERVICE_READER_CHECK_SLOTS=1 ${launcher}/bin/ai-service-files-test
            test "$(cat "$RECEIVED/path")" = "$XDG_RUNTIME_DIR/ai-service-files-test/config.json"
            test "$(${pkgs.coreutils}/bin/tr '\n' ' ' < "$RECEIVED/modes")" = '600 700 '
            ${pkgs.jq}/bin/jq -e --rawfile key /build/secret \
              '. == {access: {"api-keys": [$key]}, literal: "plain {$text}", nested: [{token: "secret value"}], port: 8317}' "$RECEIVED/config.json"
            test "$(ls -A "$XDG_RUNTIME_DIR/ai-service-files-test")" = config.json
            if ${pkgs.gnugrep}/bin/grep -Ee '^_ai_secret_[0-9]+=' -e marker -e 'secret value' "$RECEIVED/environment"; then
              echo "a file secret reached the daemon environment" >&2
              exit 1
            fi
            content="$(${pkgs.gnugrep}/bin/grep -o '/nix/store/[a-z0-9]*-ai-service-files-test-config.json' ${launcher}/bin/ai-service-files-test)"
            ${pkgs.diffutils}/bin/cmp "$content" ${pkgs.writeText "expected-content" fileContent}
            # An existing owned directory remains reusable after restart.
            ${launcher}/bin/ai-service-files-test
            # A pre-existing symlink or regular file must fail before writes
            # or chmod on its target.
            mv "$XDG_RUNTIME_DIR/ai-service-files-test" "$TMPDIR/redirect"
            chmod 0755 "$TMPDIR/redirect"
            ln -s "$TMPDIR/redirect" "$XDG_RUNTIME_DIR/ai-service-files-test"
            if ${launcher}/bin/ai-service-files-test; then
              echo "a symlink runtime directory was accepted" >&2
              exit 1
            fi
            test "$(stat -c '%a' "$TMPDIR/redirect")" = 755
            unlink "$XDG_RUNTIME_DIR/ai-service-files-test"
            touch "$XDG_RUNTIME_DIR/ai-service-files-test"
            if ${launcher}/bin/ai-service-files-test; then
              echo "a regular-file runtime directory was accepted" >&2
              exit 1
            fi
            # A shared fallback root separates users by numeric uid.
            mkdir "$TMPDIR/fallback"
            XDG_RUNTIME_DIR= TMPDIR="$TMPDIR/fallback" ${launcher}/bin/ai-service-files-test
            test "$(cat "$RECEIVED/path")" = "$TMPDIR/fallback/ai-service-$(id -u)-files-test/config.json"
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
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      ai-module-services-darwin-warns = mkCheck "ai-module-services-darwin-warns" (
        darwin.systemd.user.services
        == {}
        && darwin.warnings == ["ai.services.live: Home Manager writes services as systemd user units, which this platform lacks; the service is not written"]
        && !(darwin.home.activation ? ai-services-restart-on-change)
      );
    };
}
