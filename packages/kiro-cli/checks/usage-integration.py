"""Exercise generated Kiro launchers with a local fake proxy and fake Kiro."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

package, service, disabled = sys.argv[1:]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    environment = {key: value for key, value in os.environ.items() if key.lower() not in ("all_proxy", "http_proxy", "https_proxy", "no_proxy", "node_extra_ca_certs")}
    environment.update(HOME=str(root), XDG_STATE_HOME=str(root / "state with spaces"))
    state = root / "state with spaces/kiro-cli/usage"
    def launch(binary, env=environment, arguments=None):
        if arguments is None:
            arguments = ["chat", "synthetic"]
            if binary == "kiro-cli-chat":
                arguments += ["--agent-engine", "v3"]
        return subprocess.run([str(Path(package) / "bin" / binary), *arguments], env=env, text=True, capture_output=True)

    result = launch("kiro-cli")
    assert result.returncode != 0 and "Start the kiro-usage service" in result.stderr, result
    # The generic ai.services launcher must preserve the service command but
    # keep inherited proxy settings out of mitmdump itself.
    service_environment = environment | {"HTTPS_PROXY": "http://invalid.invalid:1"}
    process = subprocess.Popen([service], env=service_environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(100):
            if process.poll() is not None:
                raise AssertionError(process.stderr.read())
            result = launch("kiro-cli")
            if result.returncode == 0:
                break
            time.sleep(0.05)
        assert result.returncode == 0, result.stderr
        for binary in ("kiro-cli", "kiro-cli-chat"):
            result = launch(binary)
            assert result.returncode == 0, result.stderr
            body = json.loads(result.stdout)
            assert body["proxy"] == "http://127.0.0.1:18091", body
            assert body["ca"] == str(state / "ca/mitmproxy-ca-cert.pem"), body
        for binary in ("kiro-cli", "kiro-cli-chat"):
            for override in (["--agent-engine=v1"], ["--agent-engine", "v2"]):
                result = launch(binary, arguments=["chat", *override, "synthetic"])
                assert result.returncode != 0 and "requires the v3 engine" in result.stderr, result
            result = launch(binary, arguments=["chat", "--agent-engine=v3", "synthetic"])
            assert result.returncode == 0, result.stderr
        result = launch("kiro-cli-chat", arguments=["chat", "synthetic"])
        assert result.returncode != 0 and "requires an explicit v3 engine" in result.stderr, result
        result = launch("kiro-cli-chat", arguments=["chat", "--v3", "synthetic"])
        assert result.returncode == 0, result.stderr
        assert (state.stat().st_mode & 0o777) == 0o700
        assert json.loads((state / "service.json").read_text())["warn_bytes"] == "1073741824"
        result = launch("kiro-cli", environment | {"HTTPS_PROXY": "http://invalid.invalid:1"})
        assert result.returncode != 0 and "inherited HTTPS_PROXY conflicts" in result.stderr
        result = launch("kiro-cli", environment | {"NO_PROXY": "*"})
        assert result.returncode != 0 and "inherited NO_PROXY conflicts" in result.stderr
        # The installed query tool uses the same runtime state root and never
        # needs access to provider traffic or a source checkout.
        result = subprocess.run([str(Path(package) / "bin/kiro-usage"), "list"], env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        sessions = root / "synthetic sessions"
        session = sessions / "workspace/sess_fixture"
        session.mkdir(parents=True)
        (session / "session.json").write_text(json.dumps({"modelId": "synthetic"}))
        (session / "messages.jsonl").write_text(json.dumps({"payload": {"type": "usage_summary", "promptTurnSummaries": [{"usage": 1.25, "unit": "credit"}]}}) + "\n")
        # Indexing is capture-scoped: give each fixture session a captured call.
        with sqlite3.connect(state / "usage.sqlite3") as db:
            db.executemany("INSERT INTO captures(id,started_utc_ns,metadata_json) VALUES (?,0,?)",
                           [(name, json.dumps({"kiro:conversation_id": name})) for name in ("sess_fixture", "sess_auto_index")])
        db.close()
        tool = str(Path(package) / "bin/kiro-usage")
        result = subprocess.run([tool, "index", "--sessions", str(sessions)], env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([tool, "session", "sess_fixture", "--scope", "tree"], env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert "Session: sess_fixture  Scope: tree" in result.stdout, result.stdout
        assert "observed credits: 1.25" in result.stdout, result.stdout
        result = subprocess.run([tool, "session", "sess_fixture", "--scope", "tree", "--json"], env=environment, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout)["session"] == "sess_fixture", result.stdout
        # Reuse the HM collector with either its own wrapper or a project's
        # PATH-selected, tracking-disabled Kiro, without project configuration.
        for selected in (package, disabled):
            inherited = environment | {"KIRO_USAGE_TEST_AUTO_INDEX": "1", "PATH": str(Path(selected) / "bin") + os.pathsep + environment.get("PATH", ""),
                                       "HTTPS_PROXY": "http://inherited.invalid:1", "NO_PROXY": "*", "all_proxy": "http://inherited.invalid:2"}
            result = subprocess.run([tool, "exec", "--", "kiro-cli", "chat", "synthetic spaced argument", "--", "--v3"], env=inherited, text=True, capture_output=True)
            assert result.returncode == 0, result.stderr
            body = json.loads(result.stdout)
            proxy = urlsplit(body["proxy"])
            assert (proxy.scheme, proxy.hostname, proxy.port) == ("http", "127.0.0.1", 18091), body
            assert proxy.username.startswith("kiro-usage-") and len(proxy.username) == len("kiro-usage-") + 32, body
            assert proxy.password == "" and body["ca"] == str(state / "ca/mitmproxy-ca-cert.pem"), body
            assert result.stderr.count("Kiro usage summary unavailable:") == 1, result.stderr
            assert "no captured conversation identity for this invocation" in result.stderr, result.stderr
            assert not body["bypass"], body
            assert body["argv"] == ["--v3", "chat", "synthetic spaced argument", "--", "--v3"], body
            indexed = subprocess.run([tool, "session", "sess_auto_index", "--json"], env=environment, text=True, capture_output=True)
            assert indexed.returncode == 0, indexed.stderr
            disk = json.loads(indexed.stdout)["disk"]
            assert disk["turns"] == 1 and disk["metrics"]["credits"]["observed_sum"] == .75, disk
        (state / "ca/mitmproxy-ca-cert.pem").unlink()
        result = launch("kiro-cli")
        assert result.returncode != 0, result
    finally:
        process.terminate()
        process.communicate(timeout=5)
    result = subprocess.run([str(Path(disabled) / "bin/kiro-cli"), "chat"], env=environment | {"HTTPS_PROXY": "http://inherited:1234"}, text=True, capture_output=True)
    assert result.returncode == 0 and json.loads(result.stdout)["proxy"] == "http://inherited:1234"
    for binary in ("kiro-cli", "kiro-cli-chat"):
        arguments = ["chat", "--agent-engine=v2", "synthetic"]
        result = subprocess.run([str(Path(disabled) / "bin" / binary), *arguments], env=environment, text=True, capture_output=True)
        assert result.returncode == 0 and json.loads(result.stdout)["argv"] == arguments, result

print("PASS: opt-in launchers, local service, trust readiness, conflicts, query tool, disabled environment")
