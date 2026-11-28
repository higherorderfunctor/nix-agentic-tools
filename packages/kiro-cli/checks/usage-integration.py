"""Exercise generated Kiro launchers with a local fake proxy and fake Kiro."""
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

def assert_outer_identity(body, expected_ca):
    """Require a standalone tracked Kiro to receive a single identity in its markers and proxy."""
    proxy = urlsplit(body["proxy"])
    assert (proxy.scheme, proxy.hostname, proxy.port, proxy.password) == ("http", "127.0.0.1", 18091, ""), body
    invocation = body["invocation"]
    assert invocation and re.fullmatch(r"[0-9a-f]{32}", invocation), body
    assert body["outermost_invocation"] == invocation and proxy.username == f"kiro-usage-{invocation}", body
    assert body["ca"] == str(expected_ca), body


package, service, disabled = sys.argv[1:]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    environment = {key: value for key, value in os.environ.items()
                   if key.lower() not in ("all_proxy", "http_proxy", "https_proxy", "no_proxy", "node_extra_ca_certs")
                   and not key.startswith("KIRO_USAGE_")}
    environment.update(HOME=str(root), XDG_STATE_HOME=str(root / "state with spaces"))
    state = root / "state with spaces/kiro-cli/usage"
    cert = state / "ca/mitmproxy-ca-cert.pem"
    node_ca_separator = b"\n# kiro-usage merged certificate authorities\n"

    def launch(binary, env=environment, arguments=None):
        if arguments is None:
            arguments = ["chat", "synthetic"]
        return subprocess.run([str(Path(package) / "bin" / binary), *arguments], env=env, text=True, capture_output=True)

    def reject_launch(env, diagnostic):
        result = launch("kiro-cli", env)
        assert result.returncode == 1 and not result.stdout and diagnostic in result.stderr, result

    # The wrapper must fail before handing execution to Kiro if the service is not ready.
    reject_launch(environment, "Start the kiro-usage service")
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
        body = json.loads(result.stdout)
        assert_outer_identity(body, cert)
        inherited_ca = root / "inherited-ca.pem"
        inherited_bytes = b"integration inherited CA\n"
        inherited_ca.write_bytes(inherited_bytes)
        result = launch("kiro-cli", environment | {"NODE_EXTRA_CA_CERTS": str(inherited_ca)})
        assert result.returncode == 0, result.stderr
        body = json.loads(result.stdout)
        observed_ca = Path(body["ca"])
        assert observed_ca.read_bytes() == inherited_bytes + node_ca_separator + cert.read_bytes()
        assert (state.stat().st_mode & 0o777) == 0o700
        recorded = json.loads((state / "service.json").read_text())
        assert (recorded["payload_retention_days"], recorded["warn_bytes"]) == ("90", "5368709120")
        mitmdump_argv = recorded["argv"]
        settings = [value for flag, value in zip(mitmdump_argv, mitmdump_argv[1:]) if flag == "--set"]
        upstream_ca = [value for setting, _, value in (arg.partition("=") for arg in settings)
                       if setting == "ssl_verify_upstream_trusted_ca"]
        assert upstream_ca == ["/etc/nix/macos-ca.pem"], settings
        for name, value in (("HTTPS_PROXY", "http://invalid.invalid:1"), ("NO_PROXY", "*")):
            reject_launch(environment | {name: value}, f"inherited {name} conflicts")
        # The installed query tool uses the same runtime state root and never
        # needs access to provider traffic or a source checkout.
        def usage(*args, env=environment):
            result = subprocess.run([str(Path(package) / "bin/kiro-usage"), *args], env=env, text=True, capture_output=True)
            assert result.returncode == 0, result
            return result

        # Empty lists still have readable column headers.
        listing = usage("list")
        assert listing.stdout.split()[:1] == ["Capture"], listing.stdout
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
        usage("index", "--sessions", str(sessions))
        result = usage("session", "sess_fixture", "--scope", "tree")
        assert "Session: sess_fixture  Scope: tree" in result.stdout, result.stdout
        assert "observed credits: 1.25" in result.stdout, result.stdout
        # Reuse the HM collector with either its own wrapper or a project's
        # PATH-selected, tracking-disabled Kiro, without project configuration.
        for selected in (package, disabled):
            inherited = environment | {"KIRO_USAGE_TEST_AUTO_INDEX": "1", "PATH": str(Path(selected) / "bin") + os.pathsep + environment.get("PATH", ""),
                                       "HTTPS_PROXY": "http://inherited.invalid:1", "NO_PROXY": "*", "all_proxy": "http://inherited.invalid:2"}
            result = usage("exec", "--", "kiro-cli", "chat", "synthetic spaced argument", "--", "--v3", env=inherited)
            body = json.loads(result.stdout)
            assert_outer_identity(body, cert)
            # Only this run's call: neither the unmarked capture above nor the previous iteration's run joins it.
            assert result.stderr.count("Kiro usage · sess_auto_ind · this run · 1 request · 0.50 credits") == 1, result.stderr
            assert not body["bypass"], body
            assert body["argv"] == ["--v3", "chat", "synthetic spaced argument", "--", "--v3"], body
            indexed = usage("session", "sess_auto_index", "--json")
            disk = json.loads(indexed.stdout)["disk"]
            assert disk["turns"] == 1 and disk["metrics"]["credits"]["observed_sum"] == .75, disk
        # An already-listening proxy is not sufficient: its CA file must still exist.
        cert.unlink()
        reject_launch(environment, f"No such file or directory: {str(cert)!r}")
    finally:
        process.terminate()
        process.communicate(timeout=5)
    result = subprocess.run([str(Path(disabled) / "bin/kiro-cli"), "chat"], env=environment | {"HTTPS_PROXY": "http://inherited:1234"}, text=True, capture_output=True)
    assert result.returncode == 0 and json.loads(result.stdout)["proxy"] == "http://inherited:1234"

print("PASS: opt-in launchers, local service, trust readiness, conflicts, query tool, disabled environment")
