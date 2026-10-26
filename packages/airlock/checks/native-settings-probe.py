"""Offline controls for Claude's config directory and explicit settings layer."""

import json
import os
import pathlib
import socketserver
import subprocess
import sys
import tempfile
import threading
import time


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.server.lines.append(self.rfile.readline().decode("ascii", "replace").strip())
        self.server.seen.set()
        self.wfile.write(b"HTTP/1.1 502 Offline probe\r\nContent-Length: 0\r\n\r\n")


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def run(binary, project, environment, scope, args, expected, unexpected, authority=None, marker=None):
    if expected is not None:
        expected.seen.clear()
        expected.lines.clear()
        unexpected.seen.clear()
        unexpected.lines.clear()
    process = subprocess.Popen(
        [binary, "--setting-sources", scope, *args, "--print", "--max-turns", "1", "probe"],
        cwd=project,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        if expected is not None:
            for _ in range(300):
                if any(line == f"CONNECT {authority} HTTP/1.1" for line in expected.lines):
                    break
                time.sleep(0.05)
            assert any(line == f"CONNECT {authority} HTTP/1.1" for line in expected.lines), ("missing CONNECT authority", authority, expected.lines)
            assert not unexpected.seen.wait(0.5), "pinned Claude contacted excluded proxy"
        if marker is not None:
            for _ in range(300):
                if marker.exists():
                    break
                time.sleep(0.05)
            assert marker.exists(), "positive helper control was not consumed"
    finally:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()


def main(binary):
    with tempfile.TemporaryDirectory() as temporary, Server(("127.0.0.1", 0), Handler) as intended, Server(("127.0.0.1", 0), Handler) as alternate:
        for server in (intended, alternate):
            server.seen = threading.Event()
            server.lines = []
            threading.Thread(target=server.serve_forever, daemon=True).start()

        root = pathlib.Path(temporary)
        home = root / "home"
        user = home / ".claude"
        other = root / "other"
        project = root / "project"
        project_settings = project / ".claude"
        for path in (user, other, project_settings):
            path.mkdir(parents=True)
        marker = root / "helper-ran"
        helper = f"printf used > {marker}; printf fake-helper-token"
        overlay = root / "overlay.json"
        overlay.write_text(json.dumps({
            "env": {
                "ANTHROPIC_BASE_URL": "",
                "CLAUDE_CODE_OAUTH_TOKEN": "airlock-fake-oauth-token-not-a-credential",
            },
            "apiKeyHelper": "",
        }))
        (user / "settings.json").write_text(json.dumps({
            "env": {
                "ANTHROPIC_BASE_URL": "",
                "CLAUDE_CODE_OAUTH_TOKEN": "airlock-fake-oauth-token-not-a-credential",
            },
            "apiKeyHelper": "",
            "unrelatedSetting": "preserved",
        }))
        environment = {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(root / "xdg"),
            "HTTPS_PROXY": f"http://intended:fake@127.0.0.1:{intended.server_address[1]}",
            "PATH": "/usr/bin:/bin",
            "TERM": "dumb",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_AUTOUPDATER": "1",
        }

        (other / "settings.json").write_text(json.dumps({
            "env": {
                "HTTPS_PROXY": f"http://alternate:fake@127.0.0.1:{alternate.server_address[1]}",
                "CLAUDE_CODE_OAUTH_TOKEN": "other-fake",
            },
            "apiKeyHelper": helper,
        }))
        run(binary, project, environment | {"CLAUDE_CONFIG_DIR": str(other)}, "user", [], alternate, intended, "api.anthropic.com:443")
        marker.unlink(missing_ok=True)

        run(binary, project, environment | {"CLAUDE_CONFIG_DIR": str(user)}, "user", ["--settings", str(overlay)], intended, alternate, "api.anthropic.com:443")
        assert not marker.exists(), "excluded config directory was consumed"

        (other / "settings.json").write_text(json.dumps({
            "env": {
                "ANTHROPIC_BASE_URL": "https://competing.invalid",
                "CLAUDE_CODE_OAUTH_TOKEN": "other-fake",
            },
            "apiKeyHelper": helper,
        }))
        run(binary, project, environment | {"CLAUDE_CONFIG_DIR": str(other)}, "user", [], intended, alternate, "competing.invalid:443", marker)
        marker.unlink()
        run(binary, project, environment | {"CLAUDE_CONFIG_DIR": str(other)}, "user", ["--settings", str(overlay)], intended, alternate, "api.anthropic.com:443")
        assert not marker.exists(), "empty overlay helper did not clear the user helper"
        assert not any("competing.invalid" in line for line in intended.lines)

        (project_settings / "settings.json").write_text((other / "settings.json").read_text())
        run(binary, project, environment | {"CLAUDE_CONFIG_DIR": str(user)}, "project", [], intended, alternate, "competing.invalid:443", marker)
        marker.unlink()
        run(binary, project, environment | {"CLAUDE_CONFIG_DIR": str(user)}, "project", ["--settings", str(overlay)], intended, alternate, "api.anthropic.com:443")
        assert not marker.exists(), "empty overlay helper did not clear the project helper"
        assert not any("competing.invalid" in line for line in intended.lines)
        print("PASS pinned Claude: user/project competing and restored CONNECT authorities, helper controls, pinned user directory")

        intended.shutdown()
        alternate.shutdown()


if __name__ == "__main__":
    main(sys.argv[1])
