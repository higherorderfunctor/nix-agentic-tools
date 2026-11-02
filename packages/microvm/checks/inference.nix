# cspell:ignore canary noproxy writeout
# Sandbox inference: dual-backend option contracts and the refusal matrix, the
# rendered guest configs, and one boot against a stub CPA origin whose canary
# key is generated after these launchers are built.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  factory = self.lib.ai.mkSandbox pkgs;
  backends = {
    devenv = {
      eval = harness.evalDevenv;
      name = "devenv";
      packages = result: result.config.packages;
    };
    hm = {
      eval = harness.evalHm;
      name = "hm";
      packages = result: result.config.home.packages;
    };
  };
  forBackends = name: test:
    lib.mapAttrs' (backend: api: lib.nameValuePair "microvm-sandbox-inference-${name}-${backend}" (harness.mkTest "microvm-sandbox-inference-${name}-${backend}" (test api))) backends;
  # One instance with host and VM clients routing to credentials whose models
  # differ, so an independently resolved VM client is observable in the guest.
  hostKey = redact.file "/run/secrets/check-sandbox-host-key";
  vmKey = redact.file "/run/secrets/check-sandbox-vm-key";
  instance = port: vmRef: {
    inherit port;
    credentials = {
      host.apiKey = {
        apis.anthropic.base-url = "https://host.example/api/anthropic";
        key = hostKey;
        models = ["host-model"];
      };
      vm.apiKey = {
        apis.anthropic.base-url = "https://vm.example/api/anthropic";
        key = vmRef;
        models = ["vm-model"];
      };
    };
    clientKeys = {
      host = {
        key = hostKey;
        routes = [
          {
            credential = "host";
            api = "anthropic";
          }
        ];
      };
      vm = {
        key = vmRef;
        routes = [
          {
            credential = "vm";
            api = "anthropic";
          }
        ];
      };
    };
  };
  selection = {
    clientKey = "host";
    instance = "main";
  };
  fixture.ai = {
    claude = {
      enable = true;
      package = pkgs.hello;
      sandbox.enable = true;
      settings.inference = selection;
    };
    cliproxyapi.instances = {
      main = instance 8417 vmKey;
      off = {
        enable = false;
        port = 8418;
      };
    };
    codex = {
      enable = true;
      package = pkgs.hello;
      sandbox.enable = true;
      settings.inference = selection;
    };
    # The root client both runtimes inherit; runtime values replace it.
    sandbox.inference.clientKey = "vm";
  };
  launcherOf = result: name:
    lib.findFirst (package: package.meta.mainProgram == name)
    (throw "microvm-sandbox-inference: missing ${name} launcher")
    result.config.ai.internal.sandboxPackages;
  renderResult = harness.evalHm fixture;
  inferenceDoors = launcher: builtins.filter (door: door.port == 8317) launcher.allDoors;
  guestService = launcher: launcher.guest.config.systemd.services.sandbox.serviceConfig;
  # readFile attaches the file's context, which carries the key-helper
  # derivation; fromJSON refuses strings with context, and this reader only
  # compares shapes.
  guestSettingsFile = launcher: builtins.unsafeDiscardStringContext (builtins.readFile launcher.homeFiles.".claude/settings.json");
  guestSettings = launcher: builtins.fromJSON (guestSettingsFile launcher);
  failedMessages = result: map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion) result.config.assertions);
  refused = api: fragments: config:
    builtins.any (message: lib.all (fragment: lib.hasInfix fragment message) fragments)
    (failedMessages (api.eval (lib.recursiveUpdate fixture config)));
  mkLintedCheck = import ../../../lib/mk-linted-check.nix {inherit pkgs;};
  strictApplication = import ../../../lib/strict-shell-application.nix pkgs;

  # ── One boot against a stub origin ─────────────────────────────────────
  # The stub answers /v1/models with a models list only for the canary bearer
  # and records request kinds as booleans, never key bytes.
  stubPort = 18400;
  canaryPath = "/tmp/microvm-sandbox-inference-check/key";
  stub = pkgs.writeScriptBin "sandbox-inference-stub" ''
    #!${lib.getExe pkgs.python3}
    import http.server
    import sys

    canary_path, events_path, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(canary_path, "rb") as handle:
        canary = handle.read().strip()
    events = open(events_path, "a")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            # The driver's readiness probe is neither a probe nor a guest
            # request; recording it would poison the equality counts.
            if self.path == "/ready":
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            authorized = self.headers.get("Authorization", "").encode() == b"Bearer " + canary
            # The guest's door request is the one probe-distinct path.
            kind = "guest" if self.path != "/v1/models" else "probe"
            events.write(f"{kind} {'auth_ok' if authorized else 'auth_bad'}\n")
            events.flush()
            body = b'{"object": "list", "data": [{"id": "stub-model"}]}' if authorized else b"{}"
            self.send_response(200 if authorized else 401)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
  '';
  # Runs as the guest's sandbox user: both harness key helpers against the
  # delivered key file, one request through the door, guest key file mode, and
  # no key bytes on the guest kernel command line.
  guestFixture = pkgs.writeScriptBin "sandbox-inference-guest-fixture" ''
    #!${lib.getExe pkgs.bash}
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    codex_config=$1
    key=/run/sandbox-inference/key
    [[ $(stat -c '%U:%a' "$key") == sandbox:400 ]]
    echo GUEST_KEY_MODE_OK=1
    # Lengths only, never key bytes: an empty blob must be diagnosable.
    echo "GUEST_KEY_BYTES=$(stat -c %s "$key")"
    claude_helper=$(jq -r .apiKeyHelper /home/sandbox/.claude/settings.json)
    claude_key=$(${lib.getExe pkgs.bash} -c "$claude_helper")
    echo "GUEST_CLAUDE_KEY_LEN=''${#claude_key}"
    [[ $claude_key == "$(< "$key")" ]]
    echo CLAUDE_HELPER_OK=1
    codex_helper=$(sed -n '/\.auth\]$/,/^command = /p' "$codex_config" | sed -n 's/^command = "\(.*\)"$/\1/p')
    [[ -n $codex_helper ]]
    codex_key=$("$codex_helper")
    [[ $codex_key == "$claude_key" ]]
    echo CODEX_HELPER_OK=1
    status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $claude_key" 'http://10.0.2.100:8317/v1/models?guest=1')
    echo "GUEST_DOOR_STATUS=$status"
    [[ $status == 200 ]]
    echo DOOR_REQUEST_OK=1
    # `! grep` as a statement is errexit-exempt; the if makes absence fail.
    if grep -Fq "$claude_key" /proc/cmdline; then exit 1; fi
    echo CMDLINE_CLEAN=1
  '';
  bootFixture.ai = {
    claude = {
      enable = true;
      package = guestFixture;
      sandbox = {
        enable = true;
        extraPackages = [pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq];
      };
      settings.inference = selection;
    };
    cliproxyapi.instances.main = instance stubPort (redact.file canaryPath);
    codex = {
      enable = true;
      # pkgs.hello is not a Codex package; the daemon pin would refuse it.
      pinDaemonToPackage = false;
      package = pkgs.hello;
      sandbox.enable = true;
      settings.inference = selection;
    };
    sandbox.inference.clientKey = "vm";
  };
  bootResult = harness.evalHm bootFixture;
  bootLauncher = launcherOf bootResult "claude-sandbox";
  codexConfig = (launcherOf bootResult "codex-sandbox").homeFiles.".codex/config.toml";
  # A launcher to run, not a sandboxed build: the boot arm needs KVM, which
  # the Nix build users cannot reach (packages/microvm/checks/sandbox.nix
  # ships its guest fixtures the same way).
  bootDriver = strictApplication {
    name = "microvm-sandbox-inference-boot";
    runtimeInputs = [pkgs.curl pkgs.gnugrep pkgs.gnused pkgs.jq];
    text = ''
      key_dir=$(dirname ${lib.escapeShellArg canaryPath})
      events=$(mktemp)
      # shellcheck disable=SC2329
      cleanup() {
        status=$?
        if (( status != 0 )); then
          cat "$log" 2>/dev/null || :
          cat "$events" 2>/dev/null || :
        fi
        [[ -n ''${stub_pid:-} ]] && kill "$stub_pid" 2>/dev/null || :
        rm -rf -- "$key_dir" "$events" "''${log:-}"
      }
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      # Separately from mkdir: with -p, -m reaches only the deepest directory.
      mkdir -p "$key_dir"
      chmod 0700 "$key_dir"
      # The canary exists only now, after every launcher and file above was
      # built; no store path can contain it.
      head -c 32 /dev/urandom | base64 | tr -d '\n' > ${lib.escapeShellArg canaryPath}
      chmod 0600 ${lib.escapeShellArg canaryPath}
      canary=$(< ${lib.escapeShellArg canaryPath})

      # Refusal with the origin down, proven before QEMU: a runner stub marks
      # its own invocation, and a refusal must leave the marker untouched.
      log=$(mktemp)
      variant="$key_dir/refusal-launcher"
      marker="$key_dir/qemu-invoked"
      sed "s|${bootLauncher.guest.config.microvm.declaredRunner}/bin/microvm-run|touch ${lib.escapeShellArg "$marker"}|" ${lib.getExe bootLauncher} > "$variant"
      chmod 0700 "$variant"
      if "$variant" -- ${codexConfig} > "$log" 2>&1; then
        echo 'FAIL: launch succeeded with the inference origin down' >&2
        exit 1
      fi
      grep -F 'refusing to start the sandbox' "$log"
      [[ ! -e $marker ]]

      # Synthetic values exercise every byte that could alter curl's config;
      # the same runner marker proves refusal before QEMU in each case.
      for unsafe_key in 'quote"key' 'backslash\key' $'line\nkey' $'return\rkey'; do
        printf '%s' "$unsafe_key" > ${lib.escapeShellArg canaryPath}
        if "$variant" -- ${codexConfig} > "$log" 2>&1; then
          echo 'FAIL: launch accepted an unsafe inference key' >&2
          exit 1
        fi
        grep -F 'contains characters unsafe for the inference probe' "$log"
        [[ ! -e $marker ]]
      done
      printf '%s' "$canary" > ${lib.escapeShellArg canaryPath}

      # One boot with the stub up: the probe and the guest door request both
      # authenticate as the canary, and nothing else does.
      rm -f -- "$log"
      log=$(mktemp)
      ${lib.getExe stub} ${lib.escapeShellArg canaryPath} "$events" ${toString stubPort} &
      stub_pid=$!
      for _ in {1..100}; do
        curl -s -o /dev/null --noproxy '*' "http://127.0.0.1:${toString stubPort}/ready" && break
        kill -0 "$stub_pid" 2>/dev/null
        sleep 0.1
      done
      ${lib.getExe bootLauncher} -- ${codexConfig} > "$log" 2>&1
      # The guest console is a forced tty: its lines carry CR, so strip them
      # before whole-line matching (packages/microvm/checks/sandbox.nix does
      # the same for its door marker).
      for marker_line in GUEST_KEY_MODE_OK=1 CLAUDE_HELPER_OK=1 CODEX_HELPER_OK=1 DOOR_REQUEST_OK=1 CMDLINE_CLEAN=1; do
        grep -Fqx "$marker_line" <(tr -d '\r' < "$log")
      done
      grep -Fqx 'probe auth_ok' "$events"
      [[ $(grep -Fc 'guest auth_ok' "$events") == 1 ]]
      # `! grep` as a statement is errexit-exempt; the if makes absence fail.
      if grep -Fq auth_bad "$events"; then exit 1; fi

      # Zero canary bytes anywhere in either launcher's realized closure.
      closure=${pkgs.closureInfo {rootPaths = [bootLauncher (launcherOf bootResult "codex-sandbox")];}}/store-paths
      mapfile -t closure_paths < "$closure"
      hits=$(grep -r -a -F -l -- "$canary" "''${closure_paths[@]}" 2>/dev/null | wc -l || true)
      [[ $hits == 0 ]]
      echo "PASS: closure canary hits: $hits"

      # The launcher's private runtime directory is gone after exit.
      [[ -z $(ls /tmp/claude-sandbox.* 2>/dev/null) ]]
      echo PASS: inference door boot
    '';
  };
in {
  checks =
    forBackends "core" (api: let
      # pkgs.hello is no Codex package: Home Manager's daemon pin would refuse
      # it, and devenv declares no such option to disable.
      pinDaemon = lib.optionalAttrs (api.name == "hm") {ai.codex.pinDaemonToPackage = false;};
      eval = config: api.eval (lib.recursiveUpdate config pinDaemon);
      result = eval fixture;
      claudeLauncher = launcherOf result "claude-sandbox";
      codexLauncher = launcherOf result "codex-sandbox";
      guest = guestSettings claudeLauncher;
      host = harness.claudeSettings result;
      optedOut = eval (lib.recursiveUpdate fixture {ai.codex.sandbox.inference.clientKey = null;});
      defaultReplaced = eval (lib.recursiveUpdate fixture {ai.codex.sandbox.inference.clientKey = lib.mkDefault "other";});
      absent = eval (lib.recursiveUpdate fixture {ai.sandbox.inference.clientKey = null;});
      inferenceOptOut = eval (lib.recursiveUpdate fixture {
        ai = {
          claude.settings.inference.instance = null;
          settings.inference = selection;
        };
      });
      inactive = launcher: {
        doors = inferenceDoors launcher == [];
        blob = !(builtins.elem "name=opt/sandbox.inference-key,file=inference-key" launcher.guest.config.microvm.qemu.extraArgs);
        keyInstall = !lib.any (lib.hasInfix "sandbox-inference") (guestService launcher).ExecStartPre;
        homeFiles = launcher.homeFiles == {};
        service = (guestService launcher).RuntimeDirectory == ["sandbox"];
      };
    in
      # Host selections are untouched by the sandbox client.
      result.config.ai.claude.settings.inference.clientKey
      == "host"
      && result.config.ai.codex.settings.inference.clientKey == "host"
      # Root inheritance and whole-value runtime replacement.
      && result.config.ai.claude.sandbox.inference.clientKey == "vm"
      && result.config.ai.codex.sandbox.inference.clientKey == "vm"
      && optedOut.config.ai.codex.sandbox.inference.clientKey == null
      && defaultReplaced.config.ai.codex.sandbox.inference.clientKey == "other"
      # Exactly one inference door, socat to the instance's native port.
      && builtins.length (inferenceDoors claudeLauncher) == 1
      && (builtins.head (inferenceDoors claudeLauncher)).arguments == ["STDIO" "TCP:127.0.0.1:8417"]
      # The VM client resolves independently: guest rows carry its own
      # credential, host rows stay on the host credential and origin. The host
      # picker travels as launcher flags on devenv, so only Home Manager's
      # settings.json carries it.
      && guest.modelPicker.options
      == [
        {
          description = "vm through CLIProxyAPI";
          model = "vm-model";
        }
      ]
      && host.env.ANTHROPIC_BASE_URL == "http://127.0.0.1:8417"
      && (api.name
        != "hm"
        || host.modelPicker.options
        == [
          {
            description = "host through CLIProxyAPI";
            model = "host-model";
          }
        ])
      && guest.env.ANTHROPIC_BASE_URL == "http://10.0.2.100:8317"
      # The guest file carries the helper (escapeShellArg leaves store paths
      # bare) and the door URL, never the host key reference.
      && lib.hasPrefix "/nix/store/" guest.apiKeyHelper
      && !lib.hasInfix "/run/secrets" (guestSettingsFile claudeLauncher)
      # Guest receipt of the private blob and both guest home files.
      && builtins.elem "+${pkgs.coreutils}/bin/install -m 0400 -o sandbox /sys/firmware/qemu_fw_cfg/by_name/opt/sandbox.inference-key/raw /run/sandbox-inference/key" (guestService claudeLauncher).ExecStartPre
      && builtins.elem "${pkgs.coreutils}/bin/install -D -m 0444 ${toString claudeLauncher.homeFiles.".claude/settings.json"} /home/sandbox/.claude/settings.json" (guestService claudeLauncher).ExecStartPre
      && builtins.elem "${pkgs.coreutils}/bin/install -D -m 0444 ${toString codexLauncher.homeFiles.".codex/config.toml"} /home/sandbox/.codex/config.toml" (guestService codexLauncher).ExecStartPre
      && (guestService claudeLauncher).RuntimeDirectory == ["sandbox" "sandbox-inference"]
      # An opted-out runtime and an absent root client produce no door, blob,
      # key install, home file or extra service directory.
      && (let plain = inactive (launcherOf optedOut "codex-sandbox"); in plain.doors && plain.blob && plain.keyInstall && plain.homeFiles && plain.service)
      && (let plain = inactive (launcherOf absent "claude-sandbox"); in plain.doors && plain.blob && plain.keyInstall && plain.homeFiles && plain.service)
      && inferenceOptOut.config.ai.claude.sandbox.inference.clientKey == "vm"
      && (let plain = inactive (launcherOf inferenceOptOut "claude-sandbox"); in plain.doors && plain.blob && plain.keyInstall && plain.homeFiles && plain.service)
      # An inactive configuration asserts nothing.
      && failedMessages absent == []
      && failedMessages inferenceOptOut == []
      # A replaced client that does not exist is refused, not silently inert.
      && lib.any (lib.hasInfix "not a client of") (failedMessages defaultReplaced))
    // forBackends "refusals" (api:
      # Generic resolver diagnostics name the sandbox option path themselves;
      # the sandbox-only refusals are the unsupported backend and host reuse.
        refused api ["ai.claude.sandbox.inference.clientKey" "which no proxy owner registers"] {ai.claude.settings.inference.instance = "ghost";}
        && refused api ["ai.claude.sandbox.inference.clientKey" "is disabled"] {ai.claude.settings.inference.instance = "off";}
        && refused api ["ai.claude.sandbox.inference.clientKey" "not a client of"] {ai.claude.sandbox.inference.clientKey = "ghost";}
        && refused api ["ai.claude.sandbox.inference.clientKey" "explicitly requests a sandbox client without an inference instance"] {
          ai.claude = {
            sandbox.inference.clientKey = lib.mkDefault "vm";
            settings.inference = {
              clientKey = null;
              instance = null;
            };
          };
        }
        && refused api ["ai.claude.sandbox.inference.clientKey" "is set without `instance`"] {
          ai.claude.settings.inference = {
            instance = null;
            key = vmKey;
            url = "http://127.0.0.1:9999";
          };
        }
        && refused api ["sandbox inference supports cliproxyapi instances only"] {
          ai.claude.settings.inference.instance = "relay";
          ai.internal.inferenceInstances.relay = {
            backend = "relay";
            clients.vm.key = vmKey;
            enable = true;
            url = "http://127.0.0.1:8500";
          };
        }
        && refused api ["also selected by ai.claude.settings.inference"] {ai.claude.settings.inference.clientKey = "vm";}
        && refused api ["key reference is also selected by ai.codex.settings.inference"] {
          ai = {
            cliproxyapi.instances.other = instance 8517 vmKey;
            codex.settings.inference = {
              clientKey = "vm";
              instance = "other";
            };
          };
        }
        && refused api ["key reference is also selected by ai.claude.settings.inference"] {ai.cliproxyapi.instances.main.clientKeys.vm.key = hostKey;}
        && refused api ["claude and codex guest routes only"] {
          ai.kiro =
            (harness.setEnable "kiro" true).ai.kiro
            // {
              sandbox = {
                enable = true;
                inference.clientKey = "vm";
              };
            };
        })
    // {
      microvm-sandbox-inference-boot = bootDriver;
      microvm-sandbox-inference-factory = harness.mkTest "microvm-sandbox-inference-factory" (
        let
          base = {
            exe = lib.getExe pkgs.hello;
            outName = "sandbox-inference-factory";
          };
          valid = {
            client = "vm";
            instance = "main";
            key = vmKey;
            option = "ai.claude.sandbox.inference.clientKey";
            port = 8417;
          };
          rejects = arguments: !(builtins.tryEval (factory (base // arguments)).drvPath).success;
          accepts = arguments: (builtins.tryEval (factory (base // arguments)).drvPath).success;
          storeFile = builtins.toFile "home-file" "content";
        in
          accepts {inference = valid;}
          && rejects {inference = valid // {port = 0;};}
          && rejects {inference = valid // {extra = true;};}
          && rejects {inference = valid // {key = null;};}
          && rejects {inference = valid // {key = "synthetic-plaintext-key";};}
          && rejects {inference = valid // {key._redact = {};};}
          && rejects {inference = valid // {client = "";};}
          # The inference door's guest port collides with an explicit door.
          && rejects {
            doors = [
              {
                command = "${pkgs.socat}/bin/socat";
                port = 8317;
              }
            ];
            inference = valid;
          }
          && accepts {homeFiles = {".harness/config" = storeFile;};}
          && rejects {homeFiles = {"/absolute" = storeFile;};}
          && rejects {homeFiles = {"../escape" = storeFile;};}
          && rejects {homeFiles = {"ok/path" = "not-a-store-path";};}
          && rejects {homeFiles = {"trailing/" = storeFile;};}
      );
      microvm-sandbox-inference-render = let
        claudeConfig = (launcherOf renderResult "claude-sandbox").homeFiles.".claude/settings.json";
        # escapeShellArg renders store paths bare, so the helper needs no
        # quote-stripping before use as a path.
        claudeHelper = (guestSettings (launcherOf renderResult "claude-sandbox")).apiKeyHelper;
        codexConfig = (launcherOf renderResult "codex-sandbox").homeFiles.".codex/config.toml";
      in
        mkLintedCheck "microvm-sandbox-inference-render" {
          runtimeInputs = [pkgs.gnugrep];
          text = ''
            result=$(${pkgs.jq}/bin/jq -r '.env.ANTHROPIC_BASE_URL' ${claudeConfig})
            [[ $result == 'http://10.0.2.100:8317' ]]
            codex_config=${codexConfig}
            grep -F 'base_url = "http://10.0.2.100:8317/v1"' "$codex_config"
            grep -F 'requires_openai_auth = false' "$codex_config"
            # `! grep` as a statement is errexit-exempt; the if makes absence fail.
            if grep -Fq '/run/secrets' "$codex_config"; then exit 1; fi
            # Both guest key helpers read the guest file, never the host
            # reference; TOML nests the command under the provider's auth table.
            codex_helper=$(sed -n '/\.auth\]$/,/^command = /p' "$codex_config" | sed -n 's/^command = "\(.*\)"$/\1/p')
            [[ -n $codex_helper ]]
            for helper in "$codex_helper" ${claudeHelper}; do
              grep -F '/run/sandbox-inference/key' "$helper"
              if grep -Fq '/run/secrets/check-sandbox-vm-key' "$helper"; then exit 1; fi
            done
            echo PASS: rendered guest configs
          '';
        };
    };
}
