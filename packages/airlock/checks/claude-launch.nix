# Execute the generated service and jailed Claude launchers against local mocks.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  services = import ../../ai-module/lib/services.nix {inherit lib;};
  strictShellApplication = import ../../../lib/strict-shell-application.nix pkgs;
  tokenReader = strictShellApplication {
    name = "airlock-test-token-reader";
    text = ''printf '%s' "$AIRLOCK_TEST_TOKEN"'';
  };
  mockService = strictShellApplication {
    name = "airlock";
    text = ''printf '%s' "$AIRLOCK_CONFIG" > "$AIRLOCK_TEST_CONFIG_PATH"'';
  };
  mockClaudeSource = pkgs.writeText "airlock-mock-claude.py" ''
    import base64
    import json
    import os
    import socket
    import sys
    import time
    from pathlib import Path
    from urllib.parse import unquote_to_bytes, urlsplit

    args = sys.argv[1:]
    assert args[:2] == ["--setting-sources", os.environ["AIRLOCK_TEST_BACKEND"]]
    assert args[2] == "--settings"
    overlay = json.loads(Path(args[3]).read_text())
    assert args[4:] in (["--print", "two words", "--flag=literal"], ["--exit=23"], ["--sleep"], ["--stdin"])
    rows = [
        {"description": "upstream through airlock", "model": "claude-declared"},
        {"description": "zai through airlock", "model": "glm-4.7"},
    ]
    expected_rows = rows if os.environ["AIRLOCK_TEST_CLIENT"] == "harness" else []
    if args[1] == "project":
        if expected_rows:
            assert overlay["modelPicker"]["options"] == expected_rows
        else:
            assert "modelPicker" not in overlay
    else:
        assert "modelPicker" not in overlay
    assert "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR" not in os.environ
    assert not any(name in os.environ for name in (
        "HTTP_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"))
    settings = Path(os.environ["CLAUDE_CONFIG_DIR"]) / "settings.json" if args[1] == "user" else Path.cwd() / ".claude/settings.json"
    data = json.loads(settings.read_text())
    environment = os.environ | data["env"] | overlay["env"]
    assert data["unrelatedSetting"] == "preserved"
    assert environment["ANTHROPIC_BASE_URL"] == ""
    assert data["apiKeyHelper"] == ""
    assert environment["CLAUDE_CODE_OAUTH_TOKEN"] == "airlock-fake-oauth-token-not-a-credential"
    if args[1] == "user" and expected_rows:
        assert data["modelPicker"]["options"] == expected_rows
    if args[4:] == ["--sleep"]:
        Path(os.environ["AIRLOCK_TEST_CHILD_PID"]).write_text(str(os.getpid()))
        time.sleep(120)
        raise AssertionError("sleep was not interrupted")
    if args[4:] == ["--stdin"]:
        assert sys.stdin.buffer.read() == b"piped input through wrapper\n"
    proxy = urlsplit(environment["HTTPS_PROXY"])
    assert proxy.hostname == "127.0.0.1" and proxy.port == int(os.environ["AIRLOCK_TEST_PORT"])
    client = unquote_to_bytes(proxy.username)
    token = unquote_to_bytes(proxy.password)
    assert token not in Path(args[3]).read_bytes()
    assert client.decode() == os.environ["AIRLOCK_TEST_CLIENT"]
    authorization = base64.b64encode(client + b":" + token).decode()
    with socket.create_connection((proxy.hostname, proxy.port), timeout=5) as stream:
        stream.sendall(f"CONNECT api.anthropic.com:443 HTTP/1.1\r\nProxy-Authorization: Basic {authorization}\r\n\r\n".encode())
        assert stream.recv(4096).startswith(b"HTTP/1.0 200")
    Path(os.environ["AIRLOCK_TEST_RESULT"]).write_text(json.dumps({"args": args[4:], "client": client.decode(), "oauth": environment["CLAUDE_CODE_OAUTH_TOKEN"]}))
    print("mock claude completed")
    if args[4:] == ["--exit=23"]:
        print("mock claude rejected", file=sys.stderr)
        sys.exit(23)
  '';
  mockClaude = strictShellApplication {
    name = "claude";
    text = ''exec ${pkgs.python3}/bin/python3 ${mockClaudeSource} "$@"'';
  };
  mockBwrapSource = pkgs.writeText "airlock-mock-bwrap.py" ''
    import json
    import os
    import sys
    from pathlib import Path

    args = sys.argv[1:]
    binds = [(args[i + 1], args[i + 2]) for i, arg in enumerate(args[:-2]) if arg == "--ro-bind-data"]
    assert len(binds) == 1, binds
    source, destination = binds[0]
    descriptor = int(source)
    bundle = os.read(descriptor, 1048576).decode()
    inode = os.fstat(descriptor).st_ino
    os.close(descriptor)
    assert destination == os.path.realpath(os.environ["AIRLOCK_TEST_DESTINATION"])
    assert args.count("--") == 1
    environment = os.environ.copy()
    for index, arg in enumerate(args[:args.index("--")]):
        if arg == "--unsetenv":
            environment.pop(args[index + 1], None)
        elif arg == "--setenv":
            environment[args[index + 1]] = args[index + 2]
    with Path(os.environ["AIRLOCK_TEST_BWRAP_LOG"]).open("a") as log:
        log.write(json.dumps({"argv": args, "source": source, "inode": inode, "destination": destination, "bundle": bundle}) + "\n")
    os.execvpe(args[args.index("--") + 1], args[args.index("--") + 1:], environment)
  '';
  mockBwrap = strictShellApplication {
    name = "bwrap";
    text = ''exec ${pkgs.python3}/bin/python3 ${mockBwrapSource} "$@"'';
  };
  mockCat = strictShellApplication {
    name = "cat";
    text = ''
      if [ "''${AIRLOCK_TEST_FAIL_ROOTS:-}" = 1 ] && [ "''${2:-}" = "''${SSL_CERT_FILE:-}" ]; then
        printf 'partial fake roots'
        exit 77
      fi
      if [ "''${AIRLOCK_TEST_PAUSE_ROOTS:-}" = 1 ] && [ "''${2:-}" = "''${SSL_CERT_FILE:-}" ]; then
        : > "$AIRLOCK_TEST_PREPARE_MARKER"
        ${pkgs.coreutils}/bin/sleep 120
      fi
      exec ${pkgs.coreutils}/bin/cat "$@"
    '';
  };
  mockRm = strictShellApplication {
    name = "rm";
    text = ''
      if [ "''${AIRLOCK_TEST_PAUSE_UNLINK:-}" = 1 ] && [ ! -e "$AIRLOCK_TEST_PREPARE_MARKER" ]; then
        for argument in "$@"; do
          case "$argument" in
            */airlock-launch.*)
              : > "$AIRLOCK_TEST_PREPARE_MARKER"
              ${pkgs.coreutils}/bin/sleep 120
              ;;
            *) ;;
          esac
        done
      fi
      exec ${pkgs.coreutils}/bin/rm "$@"
    '';
  };
  mockCoreutils = pkgs.symlinkJoin {
    name = "airlock-test-coreutils";
    paths = [pkgs.coreutils];
    postBuild = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      rm "$out/bin/cat"
      rm "$out/bin/rm"
      ln -s ${mockCat}/bin/cat "$out/bin/cat"
      ln -s ${mockRm}/bin/rm "$out/bin/rm"
    '';
  };
  destination = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  mockJail =
    self.lib.ai.jail
    // {
      combinators = pkgs': c: let
        original = self.lib.ai.jail.combinators (pkgs' // {coreutils = mockCoreutils;}) c;
      in
        original
        // {
          airlock-client = args: original.airlock-client (args // {inherit destination;});
        };
      extend = args: self.lib.ai.jail.extend (args // {bubblewrapPackage = mockBwrap;});
    };
  airlockInstance = port: client: {
    package = mockService;
    inherit port;
    stateDir = "/build/airlock-${client}-state";
    settings = {
      clients.${client} = {
        grants = ["anthropic"];
        token = redact.command (lib.getExe tokenReader);
      };
      credentials = {
        upstream = {
          auth = {
            file = redact.command (lib.getExe tokenReader);
            type = "oauth_bearer";
          };
          provider = "claude";
        };
        zai = {
          auth = {
            file = redact.command (lib.getExe tokenReader);
            type = "api_key";
          };
          provider = "zai";
        };
      };
      groups.anthropic = {
        intercept = ["api.anthropic.com"];
        members = {
          upstream.models = ["claude-declared"];
          zai.models = ["glm-4.7"];
        };
        primary = "upstream";
        protocol = "anthropic";
      };
      providers = {
        claude.preset = "claude";
        zai.preset = "zai";
      };
    };
  };
  fixture = backend: let
    evaluate =
      if backend == "hm"
      then harness.evalHm
      else harness.evalDevenv;
    aiFixture = {
      airlock = {
        instances.alternate = airlockInstance 18419 "second";
        instances.main = airlockInstance 18418 "harness";
        services.airlock-alternate.environment.XDG_RUNTIME_DIR = "/build/airlock-service-runtime";
        services.airlock-main.environment.XDG_RUNTIME_DIR = "/build/airlock-service-runtime";
      };
      claude = {
        enable = true;
        jail.enable = true;
        package = mockClaude;
        proxy = {
          clientKey = "harness";
          instance = "main";
        };
      };
      internal.jail = lib.mkForce mockJail;
    };
    result = evaluate {ai = aiFixture;};
    installed = builtins.head (result.config.home.packages or result.config.packages);
    alternate = evaluate {
      ai = lib.recursiveUpdate aiFixture {
        claude.normalized.proxy = lib.mkForce {
          client = "second";
          credentials = [];
          instance = "alternate";
          owner = "airlock";
          port = 18419;
          url = "http://127.0.0.1:18419";
        };
      };
    };
    withCleanup = evaluate {
      ai = lib.recursiveUpdate aiFixture {
        claude.jail.permissions = c: [
          (c.add-cleanup ''printf 'cleanup ran\n' > "$AIRLOCK_TEST_CLEANUP_MARKER"'')
        ];
      };
    };
    service = services.mkLauncher {
      inherit pkgs;
      entry = result.config.ai.services.airlock-main;
      name = "airlock-main";
    };
    alternateService = services.mkLauncher {
      inherit pkgs;
      entry = result.config.ai.services.airlock-alternate;
      name = "airlock-alternate";
    };
  in {
    inherit destination;
    alternateLauncher = "${builtins.head (alternate.config.home.packages or alternate.config.packages)}/bin/claude";
    alternateService = "${alternateService}/bin/ai-service-airlock-alternate";
    cleanupLauncher = "${builtins.head (withCleanup.config.home.packages or withCleanup.config.packages)}/bin/claude";
    launcher = "${installed}/bin/claude";
    service = "${service}/bin/ai-service-airlock-main";
    settings = harness.claudeSettings result;
  };
  fixtures = {
    devenv = fixture "devenv";
    hm = fixture "hm";
  };
  testSource = pkgs.writeText "airlock-claude-launch-test.py" ''
    import base64
    import http.server
    import json
    import os
    import shutil
    import signal
    import socketserver
    import subprocess
    import sys
    import threading
    import time
    from concurrent.futures import ThreadPoolExecutor
    from pathlib import Path

    fixture = json.loads(Path(sys.argv[1]).read_text())
    root = Path(os.environ["TMPDIR"])
    service_root = Path("/build/airlock-service-runtime")
    service_root.mkdir(mode=0o700, exist_ok=True)
    token = (os.urandom(24).hex() + ":@ /$()'\\%").encode()
    expected = base64.b64encode(b"harness:" + token).decode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_CONNECT(self):
            assert self.path == "api.anthropic.com:443"
            assert self.headers["Proxy-Authorization"] == "Basic " + self.server.expected
            self.send_response(200)
            self.end_headers()
        def log_message(self, *_args):
            pass

    class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True

    with Server(("127.0.0.1", 18418), Handler) as server, Server(("127.0.0.1", 18419), Handler) as alternate_server:
        server.expected = expected
        alternate_server.expected = base64.b64encode(b"second:" + token).decode()
        for active in (server, alternate_server):
            threading.Thread(target=active.serve_forever, daemon=True).start()
        for backend, paths in fixture.items():
            workspace = root / backend
            workspace.mkdir()
            home = workspace / "home"
            home.mkdir()
            (home / ".claude").mkdir()
            (workspace / ".claude").mkdir()
            settings = home / ".claude/settings.json" if backend == "hm" else workspace / ".claude/settings.json"
            settings.write_text(json.dumps(paths["settings"] | {"unrelatedSetting": "preserved"}))
            ignored = workspace / ".claude/settings.json" if backend == "hm" else home / ".claude/settings.json"
            ignored.write_text(json.dumps({"env": {"ANTHROPIC_BASE_URL": "http://cpa.invalid", "HTTPS_PROXY": "http://bypass.invalid"}, "apiKeyHelper": "bad-helper"}))
            alternate_config = workspace / "alternate-config"
            alternate_config.mkdir()
            (alternate_config / "settings.json").write_text(json.dumps({"env": {"ANTHROPIC_BASE_URL": "http://cpa.invalid", "HTTPS_PROXY": "http://bypass.invalid"}, "apiKeyHelper": "bad-helper"}))
            result = workspace / "result.json"
            config_path = workspace / "config-path"
            bwrap_log = workspace / "bwrap.jsonl"
            env = os.environ | {
                "AIRLOCK_TEST_BACKEND": "user" if backend == "hm" else "project",
                "AIRLOCK_TEST_BWRAP_LOG": str(bwrap_log),
                "AIRLOCK_TEST_CLIENT": "harness",
                "AIRLOCK_TEST_CONFIG_PATH": str(config_path),
                "AIRLOCK_TEST_DESTINATION": paths["destination"],
                "AIRLOCK_TEST_RESULT": str(result),
                "AIRLOCK_TEST_PORT": "18418",
                "AIRLOCK_TEST_CHILD_PID": str(workspace / "child-pid"),
                "AIRLOCK_TEST_TOKEN": token.decode(),
                "CLAUDE_CONFIG_DIR": str(alternate_config),
                "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR": "9",
                "HTTPS_PROXY": "http://bypass.invalid",
                "HTTP_PROXY": "http://bypass.invalid",
                "NO_PROXY": "*",
                "HOME": str(home),
                "XDG_RUNTIME_DIR": str(workspace / "different-harness-runtime"),
            }
            started = subprocess.run([paths["service"]], cwd=workspace, env=env, capture_output=True)
            if started.returncode:
                raise AssertionError(started.stderr.decode().replace(token.decode(), "<redacted>"))
            config = json.loads(Path(config_path.read_text()).read_text())
            token_file = Path(config["clients"]["harness"]["token_file"])
            assert token_file.read_bytes() == token
            assert token_file.stat().st_mode & 0o777 == 0o600
            ca_dir = service_root / "airlock-18418"
            ca_dir.mkdir(mode=0o700, exist_ok=True)
            ca = ca_dir / "ca.pem"
            alternate_config_path = workspace / "alternate-config-path"
            alternate_env = env | {
                "AIRLOCK_TEST_CLIENT": "second",
                "AIRLOCK_TEST_CONFIG_PATH": str(alternate_config_path),
                "AIRLOCK_TEST_PORT": "18419",
            }
            alternate_started = subprocess.run([paths["alternateService"]], cwd=workspace, env=alternate_env, capture_output=True)
            assert alternate_started.returncode == 0, alternate_started.stderr.decode().replace(token.decode(), "<redacted>")
            alternate_config = json.loads(Path(alternate_config_path.read_text()).read_text())
            assert Path(alternate_config["clients"]["second"]["token_file"]).read_bytes() == token
            alternate_ca_dir = service_root / "airlock-18419"
            alternate_ca_dir.mkdir(mode=0o700, exist_ok=True)
            (alternate_ca_dir / "ca.pem").write_text("FAKE ALTERNATE AIRLOCK CA\n")
            launch_env = env | {"SSL_CERT_FILE": str(workspace / "roots.pem")}
            roots = Path(launch_env["SSL_CERT_FILE"])
            roots.write_text("FAKE SYSTEM ROOTS\n")
            def launch(*arguments):
                return subprocess.run([paths["launcher"], *arguments], cwd=workspace, env=launch_env, capture_output=True)
            def secret_absent(*payloads):
                assert all(token not in payload for payload in payloads)
            for index in (1, 2):
                ca.write_text(f"FAKE AIRLOCK CA {index}\n")
                completed = launch("--print", "two words", "--flag=literal")
                if completed.returncode:
                    raise AssertionError(completed.stderr.decode().replace(token.decode(), "<redacted>"))
                secret_absent(completed.stdout, completed.stderr)
                payload = json.loads(result.read_text())
                assert payload["oauth"] == "airlock-fake-oauth-token-not-a-credential"
                assert payload["args"] == ["--print", "two words", "--flag=literal"]
                rows = [json.loads(line) for line in bwrap_log.read_text().splitlines()]
                assert len(rows) == index
                assert rows[-1]["bundle"] == "FAKE SYSTEM ROOTS\n\nFAKE AIRLOCK CA " + str(index) + "\n"
                secret_absent(json.dumps(rows[-1]["argv"]).encode(), result.read_bytes())
                assert not list(service_root.glob("airlock-launch.*"))
            with ThreadPoolExecutor(max_workers=2) as executor:
                parallel = list(executor.map(lambda _: launch("--print", "two words", "--flag=literal"), range(2)))
            assert all(run.returncode == 0 for run in parallel)
            assert all(token not in run.stdout + run.stderr for run in parallel)
            rows = [json.loads(line) for line in bwrap_log.read_text().splitlines()]
            assert len(rows) == 4
            assert rows[2]["inode"] != rows[3]["inode"]
            assert not list(service_root.glob("airlock-launch.*"))
            nonzero = launch("--exit=23")
            assert nonzero.returncode == 23
            assert b"mock claude completed" in nonzero.stdout and b"mock claude rejected" in nonzero.stderr
            secret_absent(nonzero.stdout, nonzero.stderr)
            cleanup_marker = workspace / "cleanup-marker"
            cleanup_env = launch_env | {"AIRLOCK_TEST_CLEANUP_MARKER": str(cleanup_marker)}
            cleaned = subprocess.run([paths["cleanupLauncher"], "--print", "two words", "--flag=literal"], cwd=workspace, env=cleanup_env, capture_output=True)
            assert cleaned.returncode == 0, cleaned.stderr.decode().replace(token.decode(), "<redacted>")
            assert cleanup_marker.read_text() == "cleanup ran\n"
            cleanup_marker.unlink()
            alternate_launch_env = launch_env | {
                "AIRLOCK_TEST_CLIENT": "second",
                "AIRLOCK_TEST_PORT": "18419",
            }
            alternate_run = subprocess.run([paths["alternateLauncher"], "--print", "two words", "--flag=literal"], cwd=workspace, env=alternate_launch_env, capture_output=True)
            assert alternate_run.returncode == 0, alternate_run.stderr.decode().replace(token.decode(), "<redacted>")
            assert json.loads(result.read_text())["client"] == "second"
            secret_absent(alternate_run.stdout, alternate_run.stderr)
            piped = subprocess.run([paths["launcher"], "--stdin"], cwd=workspace, env=launch_env, input=b"piped input through wrapper\n", capture_output=True)
            assert piped.returncode == 0 and b"mock claude completed" in piped.stdout
            secret_absent(piped.stdout, piped.stderr)
            for group_signal, selected_signal, expected_status in (
                (False, signal.SIGHUP, 129),
                (False, signal.SIGINT, 130),
                (False, signal.SIGTERM, 143),
                (True, signal.SIGINT, 130),
                (True, signal.SIGTERM, 143),
            ):
                child_pid = workspace / "child-pid"
                child_pid.unlink(missing_ok=True)
                process = subprocess.Popen([paths["launcher"], "--sleep"], cwd=workspace, env=launch_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                for _ in range(100):
                    if child_pid.exists():
                        break
                    time.sleep(0.05)
                assert child_pid.exists(), "long-lived harness did not start"
                child = int(child_pid.read_text())
                if group_signal:
                    os.killpg(process.pid, selected_signal)
                else:
                    process.send_signal(selected_signal)
                output, errors = process.communicate(timeout=8)
                assert process.returncode == -selected_signal, (selected_signal, process.returncode)
                secret_absent(output, errors)
                for _ in range(100):
                    if not Path(f"/proc/{child}").exists():
                        break
                    time.sleep(0.05)
                assert not Path(f"/proc/{child}").exists(), "long-lived harness survived signal"
                rows = [json.loads(line) for line in bwrap_log.read_text().splitlines()]
                assert not list(service_root.glob("airlock-launch.*")), "trust bundle survived signal"
            prepare_marker = workspace / "prepare-marker"
            child_pid.unlink(missing_ok=True)
            before = len(bwrap_log.read_text().splitlines())
            preparing = subprocess.Popen(
                [paths["cleanupLauncher"], "--sleep"],
                cwd=workspace,
                env=cleanup_env | {
                    "AIRLOCK_TEST_PAUSE_UNLINK": "1",
                    "AIRLOCK_TEST_PREPARE_MARKER": str(prepare_marker),
                },
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            for _ in range(100):
                if prepare_marker.exists():
                    break
                time.sleep(0.05)
            assert prepare_marker.exists(), "preparation did not reach bundle unlink"
            assert list(service_root.glob("airlock-launch.*")), "preparation did not hold a named bundle"
            assert not child_pid.exists(), "harness started before bundle population"
            os.killpg(preparing.pid, signal.SIGTERM)
            output, errors = preparing.communicate(timeout=8)
            assert preparing.returncode == 143, preparing.returncode
            secret_absent(output, errors)
            assert cleanup_marker.read_text() == "cleanup ran\n"
            cleanup_marker.unlink()
            assert len(bwrap_log.read_text().splitlines()) == before
            assert not list(service_root.glob("airlock-launch.*")), "preparation left a named bundle"
            failing_write = subprocess.run(
                [paths["cleanupLauncher"], "--print", "two words", "--flag=literal"],
                cwd=workspace,
                env=cleanup_env | {"AIRLOCK_TEST_FAIL_ROOTS": "1"},
                capture_output=True,
            )
            assert failing_write.returncode != 0 and b"system roots cannot be read" in failing_write.stderr
            secret_absent(failing_write.stdout, failing_write.stderr)
            assert cleanup_marker.read_text() == "cleanup ran\n"
            assert len(bwrap_log.read_text().splitlines()) == before
            assert not list(service_root.glob("airlock-launch.*")), "failed write left a named bundle"
            def refused(artifact):
                before = len(bwrap_log.read_text().splitlines())
                result.unlink(missing_ok=True)
                run = launch("--print", "two words", "--flag=literal")
                assert run.returncode != 0 and artifact in run.stderr.decode()
                assert token not in run.stdout + run.stderr
                assert not result.exists()
                assert len(bwrap_log.read_text().splitlines()) == before
                assert not list(service_root.glob("airlock-launch.*"))
            ca.unlink()
            refused("CA is unavailable")
            ca.mkdir()
            refused("CA cannot be read")
            ca.rmdir()
            ca.write_text("FAKE AIRLOCK CA 2\n")
            roots.unlink()
            refused("system roots are unavailable")
            roots.mkdir()
            refused("system roots cannot be read")
            roots.rmdir()
            roots.write_text("FAKE SYSTEM ROOTS\n")
            token_file.unlink()
            refused("client token file is unavailable")
            token_file.write_bytes(b"")
            refused("client token file is unavailable")
            token_file.write_bytes(token)
            rendered = Path(config_path.read_text())
            rendered.rename(rendered.with_suffix(".absent"))
            refused("service config is unavailable")
            rendered.with_suffix(".absent").rename(rendered)
            hostile = workspace / "token $(touch injected) '"
            hostile.write_bytes(token)
            config["clients"]["harness"]["token_file"] = str(hostile)
            rendered.write_text(json.dumps(config))
            assert launch("--print", "two words", "--flag=literal").returncode == 0 and not (workspace / "injected").exists()
            for artifact in (paths["launcher"], paths["service"], paths["alternateLauncher"], paths["alternateService"]):
                secret_absent(Path(artifact).resolve().read_bytes())
            secret_absent(settings.read_bytes(), bwrap_log.read_bytes())
            print(f"PASS {backend}: service writer, CONNECT identity, fake OAuth, settings scope, CA refresh, parallel and signal cleanup, argv/status, mandatory failures")
        server.shutdown()
        alternate_server.shutdown()
  '';
in {
  checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    airlock-claude-native-settings = pkgs.runCommand "airlock-claude-native-settings" {nativeBuildInputs = [pkgs.python3];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${./native-settings-probe.py} ${lib.getExe pkgs.ai.claude-code} | tee "$out"
    '';
    airlock-claude-launch =
      pkgs.runCommand "airlock-claude-launch" {
        nativeBuildInputs = [pkgs.python3];
        fixturesFile = pkgs.writeText "airlock-claude-fixtures.json" (builtins.toJSON fixtures);
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        python3 ${testSource} "$fixturesFile" | tee "$out"
      '';
  };
}
