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
        vault-agent.Install.WantedBy = ["graphical-session-pre.target"];
      };
    }
  ];
  # Providers wanted by different targets: a reader under both would start one
  # provider early, under the other's target.
  withMismatchedUnits = backends.evaluateWith "hm" providerServices [
    noLegacyNodes
    {
      systemd.user.services = {
        sops-nix.Install.WantedBy = ["graphical-session-pre.target"];
        vault-agent.Install.WantedBy = ["default.target"];
      };
    }
  ];
  # Only sops-nix is defined; the undefined vault unit adds no target.
  withOneDefinedUnit = backends.evaluateWith "hm" providerServices [
    noLegacyNodes
    {systemd.user.services.sops-nix.Install.WantedBy = ["graphical-session-pre.target"];}
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
  # A trigger path is read at start, as a reference is.
  triggerOnly = backends.evaluate "hm" {
    services.secret = daemon // {restartOnChange = ["/run/secrets/trigger-only"];};
  };
  darwinServices.services =
    entries
    // {
      live = watched;
      stopped = daemon // {enable = false;};
    };
  darwin = backends.evaluate "hm" darwinServices;
  # A Home Manager host with neither systemd nor launchd.
  otherHostPkgs = pkgs // {stdenv = pkgs.stdenv // {hostPlatform = lib.systems.elaborate "x86_64-freebsd";};};
  darwinDevenv = backends.evaluate "devenv" darwinServices;
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
  rejectsLauncherChange = valid: invalid:
    harness.rejectsChange (entry: builtins.isString (fileLauncher entry).drvPath) {
      inherit invalid valid;
      expected = true;
    };
  # Secret files: what a redact.types.secretFile option hands ai.services.
  # Each reference kind is written to a 0600 file whose path reaches the
  # variable or the config field; a plain reference beside them still
  # delivers its value.
  asFile = value: {_redact.asFile = value;};
  secretFileReceiver = strictShellApplication pkgs {
    name = "services-test-secret-file-receiver";
    text = ''
      printf '%s\n' "$COMMAND_FILE" "$CONCAT_FILE" "$FILE_FILE" > "$RECEIVED/paths"
      printf '%s' "$VALUE" > "$RECEIVED/value"
      ${pkgs.coreutils}/bin/cp "$SERVICE_CONFIG" "$RECEIVED/config.json"
    '';
  };
  secretFiles = {
    command = ["${secretFileReceiver}/bin/services-test-secret-file-receiver"];
    environment = {
      COMMAND_FILE = asFile (redact.command "${launcherReader}/bin/services-test-reader");
      CONCAT_FILE = asFile (redact.concat ["Bearer " (redact.file "/build/secret-file")]);
      FILE_FILE = asFile (redact.file "/build/secret-file");
      VALUE = redact.file "/build/secret-file";
    };
    files.config = {
      content = builtins.toJSON {
        key-file = placeholder "KEY_FILE";
        token = placeholder "TOKEN";
      };
      secrets = {
        KEY_FILE = asFile (redact.file "/build/secret-file");
        TOKEN = redact.file "/build/secret-file";
      };
      variable = "SERVICE_CONFIG";
    };
    restartOnChange = [];
  };
  commandOnly = backends.evaluate "hm" {
    services.secret = daemon // {environment.KEY_FILE = asFile (redact.command "/run/current-system/sw/bin/read-key");};
  };
  stampEntry = {
    command = ["${pkgs.coreutils}/bin/true"];
    enable = true;
    environment = {};
    files = {};
    restartOnChange = ["/build/trigger"];
  };
  stampLauncher = services.mkLauncher {
    inherit pkgs;
    entry = stampEntry;
    name = "help";
    stamp = true;
  };
  # A user manager with one provider and one reader, `help.service`, whose
  # state lives in files under $SERVICE_UNIT. A restart is a new invocation
  # that runs the stamping launcher unless SERVICE_NO_STAMP is set.
  managerDouble = strictShellApplication pkgs {
    name = "systemctl";
    text = ''
      printf '%s\n' "$*" >> "$SERVICE_LOG"
      case "$*" in
        '--user is-system-running') printf '%s\n' "''${SERVICE_MANAGER:-running}" ;;
        "--system show --property=ActiveState --value user@$(${pkgs.coreutils}/bin/id -u).service")
          if [ -n "''${SERVICE_NO_SYSTEM_MANAGER:-}" ]; then
            echo 'System has not been booted with systemd as init system (PID 1).' >&2
            false
          fi
          printf '%s\n' "''${SERVICE_USER_UNIT:-active}"
          ;;
        '--user show --property=LoadState --value provider.service') printf '%s\n' "''${SERVICE_PROVIDER_LOAD:-loaded}" ;;
        '--user show --property=Result --value provider.service') printf '%s\n' "''${SERVICE_PROVIDER_RESULT:-success}" ;;
        '--user show --property=ActiveState --value help.service') ${pkgs.coreutils}/bin/cat "$SERVICE_UNIT/active" ;;
        '--user show --property=SubState --value help.service') ${pkgs.coreutils}/bin/cat "$SERVICE_UNIT/sub" ;;
        '--user show --property=InvocationID --value help.service') ${pkgs.coreutils}/bin/cat "$SERVICE_UNIT/invocation" ;;
        '--user try-restart help.service')
          if [ -n "''${SERVICE_RESTART_FAIL:-}" ]; then
            echo 'Job for help.service failed' >&2
            false
          fi
          invocation="$(( $(${pkgs.coreutils}/bin/cat "$SERVICE_UNIT/invocation") + 1 ))"
          printf '%s\n' "$invocation" > "$SERVICE_UNIT/invocation"
          if [ -z "''${SERVICE_NO_STAMP:-}" ]; then
            INVOCATION_ID="$invocation" ${stampLauncher}/bin/ai-service-help
          fi
          ;;
        *)
          printf 'unexpected systemctl arguments: %s\n' "$*" >&2
          false
          ;;
      esac
    '';
  };
  reconcileCommand =
    (services.hmReconcile pkgs {help = stampEntry;} {
      providerUnits = ["provider.service"];
      systemctlPath = "${managerDouble}/bin/systemctl";
      # Long enough for the in-flight start below, which stamps after 1 s.
      stampTimeout = 5;
    }).services-reconcile.command;
  mkCheck = name: condition:
    assert lib.assertMsg condition "${name}: service contract failed";
      pkgs.runCommandLocal name {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        touch "$out"
      '';
  mkRulesCheck = name: rows: mkCheck name (harness.checkRows name rows);
in {
  checks =
    {
      ai-module-services-launcher = pkgs.runCommandLocal "ai-module-services-launcher" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        if SERVICE_READER_FAIL=1 ${launcher}/bin/ai-service-test > failed 2> failure; then
          echo "failed reader started the receiver" >&2
          exit 1
        fi
        ${pkgs.gnugrep}/bin/grep -F 'ai.services.test.environment.PRIVATE: reference command failed' failure
        test ! -s failed
        ${launcher}/bin/ai-service-test > actual
        ${pkgs.diffutils}/bin/diff -u ${pkgs.writeText "services-expected" "literal $(false) ' quote\nsecret value\nargument $(false)\nspace ' quote\n"} actual
        touch "$out"
      '';
      # Rejects silence, or a warning that skips a service, on a Home Manager
      # host with neither backend. It calls hmWarnings directly rather than
      # reading the module's `warnings`, because no Home Manager evaluation
      # for such a host exists here; the result does not depend on the
      # evaluating host, so it runs on every CI platform.
      ai-module-services-other-host = mkRulesCheck "ai-module-services-other-host" {
        "unsupported Home Manager host names every service it skips" =
          services.hmWarnings otherHostPkgs hm.ai.services
          == ["ai.services: this platform has neither systemd user units nor launchd agents, so these services are not written: always, never, on-failure, watched"];
      };
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      ai-module-services-backends = mkRulesCheck "ai-module-services-backends" (let
        restartCases = {
          always = {
            devenv = "always";
            hm = "always";
          };
          never = {
            devenv = "never";
            hm = "no";
          };
          "on-failure" = {
            devenv = "on_failure";
            hm = "on-failure";
          };
        };
        restartRows = lib.mapAttrs' (restart: expected: let
          unit = hm.systemd.user.services.${restart};
          process = devenv.processes.${restart};
        in
          lib.nameValuePair "plain service with restart=${restart} maps policy, shares the launcher and has no watcher" (
            unit
            == {
              Install.WantedBy = ["default.target"];
              Service = {
                ExecStart = process.exec;
                Restart = expected.hm;
                RestartSec = 5;
              };
              Unit = {
                After = ["network.target"];
                Description = "${restart} (ai.services)";
                StartLimitBurst = 5;
                StartLimitIntervalSec = 300;
              };
            }
            && process.restart
            == {
              max = 4;
              on = expected.devenv;
              window = 300;
            }
            && lib.hasSuffix "/bin/ai-service-${restart}" process.exec
            && !(process ? watch)
          ))
        restartCases;
        plain = backends.evaluate "hm" {services.plain = daemon;};
        providerTargets = result: result.systemd.user.services.secret.Install.WantedBy;
        selfProvider = unit:
          backends.evaluate "hm" {
            activationOrder.secretProviders.own = {inherit unit;};
            services.secret = watched;
          };
        watchedUnit = hm.systemd.user.services.watched;
      in
        restartRows
        // {
          "command without trigger paths emits no HM reconcile entry" = !(plain.home.activation ? ai-services-reconcile);
          "configured providers supply both unit dependencies and activation readiness" =
            withProvider.systemd.user.services.secret.Unit.After
            == ["network.target" "sops-nix.service" "vault-agent.service"]
            && withProvider.systemd.user.services.secret.Unit.Wants == ["sops-nix.service" "vault-agent.service"]
            && withProvider.home.activation.ai-probe.after == ["sops-nix" "vault:ready"]
            && withProvider.home.activation.ai-services-reconcile.after == ["linkGeneration" "sops-nix" "vault:ready" "reloadSystemd"];
          "devenv consumes readiness nodes rather than native units and never reconciles systemd" =
            withProviderDevenv.tasks."ai:probe".after
            == ["vault:ready"]
            && !(withProviderDevenv.tasks ? "ai:services-reconcile")
            && !(devenv.tasks ? "ai:services-reconcile");
          "legacy readiness without a unit does not invent a systemd dependency" =
            withoutSopsUnit.systemd.user.services.secret.Unit.After
            == ["network.target"]
            && withoutSopsUnit.home.activation.ai-probe.after == ["custom:ready"];
          "Linux emits no launchd agents" = hm.launchd.agents == {};
          "plain service never inherits provider dependencies or targets" =
            withSopsUnit.systemd.user.services.plain.Install.WantedBy
            == ["default.target"]
            && withSopsUnit.systemd.user.services.plain.Unit.After == ["network.target"]
            && withMismatchedUnits.systemd.user.services.plain.Install.WantedBy == ["default.target"];
          "provider with no defined unit adds no target" = providerTargets withOneDefinedUnit == ["graphical-session-pre.target"];
          "providers under different targets reject the secret reader's WantedBy" = harness.rejectsChange providerTargets {
            valid = withProviderUnits;
            invalid = withMismatchedUnits;
            expected = ["graphical-session-pre.target"];
          };
          "reader cannot serve as its own secret provider" = harness.rejectsChange (unit: providerTargets (selfProvider unit)) {
            valid = "other.service";
            invalid = "secret.service";
            expected = ["default.target"];
          };
          "trigger path alone gives both ordering and Wants" =
            triggerOnly.systemd.user.services.secret.Unit.After
            == ["network.target" "sops-nix.service"]
            && triggerOnly.systemd.user.services.secret.Unit.Wants == ["sops-nix.service"];
          "undefined provider units leave the reader on the default target" = providerTargets withProvider == ["default.target"];
          "watched service keeps the same rate limits as plain services on both backends" =
            watchedUnit.Unit.StartLimitBurst
            == 5
            && watchedUnit.Unit.StartLimitIntervalSec == 300
            && devenv.processes.watched.restart.max == 4
            && devenv.processes.watched.restart.window == 300;
          "watcher gets every explicit, environment and file trigger once" = devenv.processes.watched.watch.paths == expectedTriggers;
          "watching uses distinct HM and devenv launchers" =
            lib.hasSuffix "/bin/ai-service-watched" watchedUnit.Service.ExecStart
            && lib.hasSuffix "/bin/ai-service-watched" devenv.processes.watched.exec
            && watchedUnit.Service.ExecStart != devenv.processes.watched.exec;
        });
      ai-module-services-claims = mkRulesCheck "ai-module-services-claims" (let
        forBackend = backend:
          lib.mapAttrsToList (name: holds: lib.nameValuePair "${backend}: ${name}" holds) {
            "distinct service names and ports reach the backend" = positive backend;
            "disabled entry still blocks another owner of its service name" = collision backend {
              alpha.services.same = daemon // {enable = false;};
              beta.services.same = daemon;
            } "ai.claims.service.same: claimed by alpha and beta";
            "two named ports within one service cannot share a number" = collision backend {
              alpha.services.one =
                daemon
                // {
                  ports = {
                    http = 9200;
                    metrics = 9200;
                  };
                };
            } "ai.claims.port.9200: claimed by alpha:one.ports.http and alpha:one.ports.metrics";
          };
      in
        builtins.listToAttrs (lib.concatMap forBackend ["devenv" "hm"])
        // {
          "devenv: two owners cannot share a port number" = collision "devenv" {
            alpha.services.one = daemon // {ports.main = 9200;};
            beta.services.two = daemon // {ports.main = 9200;};
          } "ai.claims.port.9200: claimed by alpha:one.ports.main and beta:two.ports.main";
          "disabled service retains its name and port but emits no unit" =
            disabled.ai.claims.service.one
            == ["alpha"]
            && disabled.ai.claims.port."9200" == ["alpha:one.ports.http"]
            && disabled.systemd.user.services == {};
          "service name grammar rejects dots" = harness.rejectsChange (name: builtins.attrNames (backends.evaluate "hm" {services.${name} = daemon;}).ai.services) {
            valid = "good-name";
            invalid = "bad.name";
            expected = ["good-name"];
          };
        });
      # The launcher renders a file at start: placeholders filled as JSON
      # strings, 0600 in a 0700 directory, path exported, secrets never
      # exported; the store copy holds placeholders only. A mismatch between
      # placeholders and secrets, or a reused variable, fails evaluation.
      ai-module-services-files = let
        control = fileEntry {inherit config;};
        launcher = fileLauncher control;
        rejects = rejectsLauncherChange control;
      in
        assert harness.checkRows "service config file restrictions" {
          "a file key cannot escape the runtime directory" = rejects (fileEntry {"../escape" = config;});
          "a file variable cannot reuse another file's export" = rejects (fileEntry {
            inherit config;
            other =
              config
              // {
                content = "{}";
                secrets = {};
              };
          });
          "file variable cannot use the launcher's reserved prefix" = rejects (fileEntry {config = config // {variable = "_ai_dir";};});
          "placeholder must have a matching secret" = rejects (fileEntry {config = config // {secrets = builtins.removeAttrs config.secrets ["TOKEN"];};});
          "service environment cannot use the launcher's reserved prefix" = rejects (control // {environment._ai_dir = "collision";});
          "unused secret is rejected instead of silently unread" = rejects (fileEntry {config = config // {secrets = config.secrets // {UNUSED = redact.file "/run/secrets/unused";};};});
        };
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
            # A pre-existing symlink or regular file must fail before writes
            # or chmod on its target.
            mv "$XDG_RUNTIME_DIR/ai-service-files-test" "$TMPDIR/redirect"
            chmod 0755 "$TMPDIR/redirect"
            ln -s "$TMPDIR/redirect" "$XDG_RUNTIME_DIR/ai-service-files-test"
            if ${launcher}/bin/ai-service-files-test 2> refusal; then
              echo "a symlink runtime directory was accepted" >&2
              exit 1
            fi
            ${pkgs.gnugrep}/bin/grep -F 'ai.services.files-test: runtime directory must be an owned directory, not a symlink:' refusal
            test "$(stat -c '%a' "$TMPDIR/redirect")" = 755
            unlink "$XDG_RUNTIME_DIR/ai-service-files-test"
            touch "$XDG_RUNTIME_DIR/ai-service-files-test"
            if ${launcher}/bin/ai-service-files-test 2> refusal; then
              echo "a regular-file runtime directory was accepted" >&2
              exit 1
            fi
            ${pkgs.gnugrep}/bin/grep -F 'ai.services.files-test: runtime directory must be an owned directory, not a symlink:' refusal
            # A shared fallback root separates users by numeric uid.
            mkdir "$TMPDIR/fallback"
            XDG_RUNTIME_DIR= TMPDIR="$TMPDIR/fallback" ${launcher}/bin/ai-service-files-test
            test "$(cat "$RECEIVED/path")" = "$TMPDIR/fallback/ai-service-$(id -u)-files-test/config.json"
            touch "$out"
          '';
      # A declared XDG_RUNTIME_DIR or TMPDIR picks the runtime directory, as it
      # picks the daemon's own: the files and the daemon agree on a root that
      # differs from the one the launcher inherited.
      ai-module-services-declared-root = let
        launcherWith = environment:
          fileLauncher ((fileEntry {inherit config;}) // {inherit environment;});
        runtime = launcherWith {XDG_RUNTIME_DIR = "/build/declared-runtime";};
        temporary = launcherWith {TMPDIR = "/build/declared-temporary";};
      in
        pkgs.runCommandLocal "ai-module-services-declared-root" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          printf '%s' value > /build/secret
          export RECEIVED="$TMPDIR/received"
          mkdir -p "$RECEIVED" /build/inherited-runtime /build/inherited-temporary /build/declared-runtime /build/declared-temporary
          # The declared runtime root wins over the inherited one.
          XDG_RUNTIME_DIR=/build/inherited-runtime ${runtime}/bin/ai-service-files-test
          test "$(cat "$RECEIVED/path")" = /build/declared-runtime/ai-service-files-test/config.json
          ${pkgs.gnugrep}/bin/grep -Fx XDG_RUNTIME_DIR=/build/declared-runtime "$RECEIVED/environment"
          test ! -e /build/inherited-runtime/ai-service-files-test
          # So does a declared TMPDIR, where no runtime root is set.
          XDG_RUNTIME_DIR= TMPDIR=/build/inherited-temporary ${temporary}/bin/ai-service-files-test
          test "$(cat "$RECEIVED/path")" = "/build/declared-temporary/ai-service-$(id -u)-files-test/config.json"
          ${pkgs.gnugrep}/bin/grep -Fx TMPDIR=/build/declared-temporary "$RECEIVED/environment"
          test ! -e "/build/inherited-temporary/ai-service-$(id -u)-files-test"
          touch "$out"
        '';
      ai-module-services-secret-files = let
        launcher = services.mkLauncher {
          inherit pkgs;
          entry = secretFiles;
          name = "secret-files-test";
        };
      in
        assert harness.checkRows "secret file launcher" {
          "command-backed secret file needs provider ordering but adds no file trigger" =
            services.triggers commandOnly.ai.services.secret
            == []
            && commandOnly.systemd.user.services.secret.Unit.Wants == ["sops-nix.service"];
          "secret-file environment name must start with an alphanumeric character" =
            rejectsLauncherChange secretFiles (secretFiles // {environment._KEY_FILE = asFile (redact.file "/build/secret-file");});
        };
          pkgs.runCommandLocal "ai-module-services-secret-files" {} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            printf '%s\n\n' 'file "value"' > /build/secret-file
            export XDG_RUNTIME_DIR="$TMPDIR/run" RECEIVED="$TMPDIR/received"
            mkdir -p "$XDG_RUNTIME_DIR" "$RECEIVED"
            dir="$XDG_RUNTIME_DIR/ai-service-secret-files-test"
            # Holds exactly the value, 0600, in the 0700 runtime directory.
            holds() {
              test "$(${pkgs.coreutils}/bin/stat -c '%a' "$1")" = 600
              printf '%s' "$2" | ${pkgs.diffutils}/bin/cmp - "$1"
            }
            ${launcher}/bin/ai-service-secret-files-test
            test "$(${pkgs.coreutils}/bin/stat -c '%a' "$dir")" = 700
            printf '%s\n' "$dir/COMMAND_FILE" "$dir/CONCAT_FILE" "$dir/FILE_FILE" | ${pkgs.diffutils}/bin/diff -u - "$RECEIVED/paths"
            holds "$dir/COMMAND_FILE" 'secret value'
            holds "$dir/CONCAT_FILE" 'Bearer file "value"'
            holds "$dir/FILE_FILE" 'file "value"'
            holds "$dir/config-KEY_FILE" 'file "value"'
            # Negative control: a plain reference delivers the value itself.
            printf '%s' 'file "value"' | ${pkgs.diffutils}/bin/cmp - "$RECEIVED/value"
            ${pkgs.jq}/bin/jq -e --arg path "$dir/config-KEY_FILE" --arg value 'file "value"' '. == {"key-file": $path, token: $value}' "$RECEIVED/config.json"
            test "$(ls -A "$dir" | ${pkgs.coreutils}/bin/tr '\n' ' ')" = 'COMMAND_FILE CONCAT_FILE FILE_FILE config-KEY_FILE config.json '
            # A changed reference is copied again at the next start.
            printf '%s' rotated > /build/secret-file
            ${launcher}/bin/ai-service-secret-files-test
            holds "$dir/FILE_FILE" rotated
            holds "$dir/config-KEY_FILE" rotated
            # A failed read aborts the start before the daemon runs.
            rm "$RECEIVED/paths"
            if SERVICE_READER_FAIL=1 ${launcher}/bin/ai-service-secret-files-test 2> refusal; then
              echo "a failed secret-file read started the daemon" >&2
              exit 1
            fi
            ${pkgs.gnugrep}/bin/grep -F 'ai.services.secret-files-test.environment.COMMAND_FILE: reference command failed' refusal
            test ! -e "$RECEIVED/paths"
            touch "$out"
          '';
      ai-module-services-rotation = pkgs.runCommandLocal "ai-module-services-rotation" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export SERVICE_LOG="$TMPDIR/systemctl" SERVICE_UNIT="$TMPDIR/unit" XDG_RUNTIME_DIR="$TMPDIR/run"
        mkdir "$SERVICE_UNIT" "$XDG_RUNTIME_DIR"
        stamp="$XDG_RUNTIME_DIR/ai-service-help.stamp"
        run() { ${pkgs.bash}/bin/bash -euETo pipefail -c ${lib.escapeShellArg reconcileCommand}; }
        refused() {
          if run 2> refused.log; then
            echo "activation accepted: $1" >&2
            exit 1
          fi
          grep -F -e "$2" refused.log
        }
        restarts() { grep -c -x -F -- '--user try-restart help.service' "$SERVICE_LOG" || :; }
        unit() { printf '%s\n' "$1" > "$SERVICE_UNIT/active"; printf '%s\n' "$2" > "$SERVICE_UNIT/sub"; }
        printf '%s' first > /build/trigger
        printf '%s\n' 1 > "$SERVICE_UNIT/invocation"
        unit active running

        # Before login: skipped only while the user manager's unit is inactive.
        SERVICE_MANAGER=offline SERVICE_USER_UNIT=inactive run
        test "$(cat "$SERVICE_LOG")" = "--user is-system-running
        --system show --property=ActiveState --value user@$(id -u).service"
        SERVICE_MANAGER=offline refused "unreachable manager" 'user@'"$(id -u)"'.service is active, but its manager reports: offline'
        # No system manager to ask, or user@ coming up or going down: skipped.
        SERVICE_MANAGER=offline SERVICE_NO_SYSTEM_MANAGER=1 run > skipped.log
        grep -F 'skipping service reconciliation' skipped.log
        SERVICE_MANAGER=offline SERVICE_USER_UNIT=activating run
        SERVICE_MANAGER=offline SERVICE_USER_UNIT=deactivating run
        # A user manager starting or stopping is skipped while user@ is active,
        # as Home Manager's own reload skips.
        SERVICE_MANAGER=starting run > starting.log
        grep -F 'not running (starting); skipping service reconciliation' starting.log
        SERVICE_MANAGER=stopping run
        if grep -v -e '^--user is-system-running$' -e '^--system show ' "$SERVICE_LOG"; then
          echo "a skipped reconcile queried a unit" >&2
          exit 1
        fi

        unit failed failed
        refused "failed reader" 'help.service is failed (failed)'
        unit activating auto-restart
        refused "crash-looping reader" 'help.service is activating (auto-restart)'

        # A stopped reader stays stopped, and an absent provider is not read.
        unit inactive dead
        SERVICE_PROVIDER_LOAD=not-found SERVICE_PROVIDER_RESULT=exit-code run
        test "$(restarts)" -eq 0

        # An active reader with no stamp waits, then restarts once and stamps.
        unit active running
        run
        test "$(restarts)" -eq 1
        test "$(stat -c '%a' "$stamp")" = 600
        test "$(cut -d ' ' -f2 "$stamp")" = 2

        # A start still in flight is waited for, not restarted.
        printf '%s\n' 3 > "$SERVICE_UNIT/invocation"
        (sleep 1 && INVOCATION_ID=3 ${stampLauncher}/bin/ai-service-help) &
        run
        wait
        test "$(restarts)" -eq 1

        # A failed restart, or one that never stamps, fails activation.
        cp "$stamp" previous
        printf '%s' third > /build/trigger
        SERVICE_RESTART_FAIL=1 refused "restart failure" 'Job for help.service failed'
        ${pkgs.diffutils}/bin/cmp previous "$stamp"
        SERVICE_NO_STAMP=1 refused "unstamped restart" 'help.service did not restart onto its current trigger files (unstamped)'
        run

        # A missing trigger fails both the check and the start, naming it.
        rm /build/trigger
        refused "missing trigger" /build/trigger
        if INVOCATION_ID=9 ${stampLauncher}/bin/ai-service-help 2> missing.log; then
          echo "a start with a missing trigger succeeded" >&2
          exit 1
        fi
        grep -F /build/trigger missing.log
        touch "$out"
      '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Rejects an agent that is absent or `enable = false`, one that runs the
      # daemon command or the stamped launcher, one that copies `environment`
      # into the plist, a wrong restart mapping, and a missing or reworded
      # launchd gap warning.
      ai-module-services-darwin-launchd = mkRulesCheck "ai-module-services-darwin-launchd" {
        "only enabled agents land, with the expected KeepAlive values" =
          lib.mapAttrs (_: agent: agent.config.KeepAlive) darwin.launchd.agents
          == {
            always = true;
            live = {SuccessfulExit = false;};
            never = false;
            "on-failure" = {SuccessfulExit = false;};
          };
        "live agent uses the unstamped launcher and does not copy the environment into the plist" =
          darwin.launchd.agents.live
          == {
            config = {
              ExitTimeOut = 90;
              KeepAlive = {SuccessfulExit = false;};
              ProgramArguments = [darwinDevenv.processes.live.exec];
              RunAtLoad = true;
              StandardErrorPath = "/home/test/Library/Logs/ai-service-live.log";
              StandardOutPath = "/home/test/Library/Logs/ai-service-live.log";
              ThrottleInterval = 5;
              WorkingDirectory = "/home/test";
            };
            enable = true;
          };
        "launchd never emits systemd reconciliation" = !(darwin.home.activation ? ai-services-reconcile);
        "Darwin emits no systemd units" = darwin.systemd.user.services == {};
        "Darwin warns which services lack rotation, ordering or restart limits" =
          darwin.warnings
          == [
            "ai.services: launchd does not restart a service when a file it read at start changes (a restartOnChange path or a file a reference reads); restart it with `launchctl kickstart -k gui/$(id -u)/org.nix-community.home.<name>`. Services: live"
            "ai.services: launchd has no start ordering, so a service can start before its secret provider has run or before the files it reads are in place; only its restart policy retries a failed start. Services: live"
            "ai.services: launchd has no start limit, so a crash loop restarts every 5 seconds instead of ending failed after 5 starts in 300 seconds. Services: always, live, on-failure"
          ];
      };
    };
}
