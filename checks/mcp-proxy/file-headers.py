"""Exercise the generated route with a real process, files and streaming upstream."""

import http.client
import http.server
import json
import os
import re
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


requests = []
release = threading.Event()


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        requests.append((self.path, self.headers, body))
        message = json.loads(body)
        if message["id"] == 3:
            self.connection.close()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(b"data: first\n\n")
        self.wfile.flush()
        if message["id"] == 2:
            assert release.wait(10), "stream was not released"
            self.wfile.write(b"data: second\n\n")
            self.wfile.flush()

    def log_message(self, *_args):
        pass


def request(message_id=1):
    conn = http.client.HTTPConnection("127.0.0.1", 19591, timeout=3)
    body = json.dumps({"jsonrpc": "2.0", "method": "tools/list", "id": message_id})
    conn.request(
        "POST",
        "/client-path",
        body,
        {
            "Accept": "application/json, text/event-stream",
            "aUtHoRiZaTiOn": "client-supplied-token",
            "Content-Type": "application/json",
            "X-Token": "client-supplied-custom-token",
        },
    )
    return conn, conn.getresponse()


def expect_unavailable(case):
    before = len(requests)
    client, response = request()
    try:
        actual = response.status, response.read()
        assert actual == (503, b"Credential unavailable"), (case, actual)
    finally:
        client.close()
    assert len(requests) == before, f"{case}: request reached upstream"


with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    token, second = root / "token", root / "second"

    def publish(path, value):
        pending = path.with_suffix(".pending")
        pending.write_bytes(value)
        pending.replace(path)

    publish(token, b"First.Secret==")
    publish(second, b"Other.Secret")
    config = root / "Caddyfile"
    config.write_text(Path(sys.argv[2]).read_text().replace("/TOKEN", str(token)).replace("/SECOND", str(second)))
    upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    env = os.environ | {
        "MCP_PROXY_FIXTURE_ORIGIN": f"http://127.0.0.1:{upstream.server_port}",
        "MCP_PROXY_FIXTURE_PATH": "/endpoint",
        "XDG_CONFIG_HOME": str(root / "config"),
        "XDG_DATA_HOME": str(root / "data"),
    }
    with (root / "log").open("w+") as log:
        process = subprocess.Popen([sys.argv[1], "run", "--config", str(config), "--adapter", "caddyfile"], env=env, stdout=log, stderr=log)
        try:
            for _ in range(100):
                try:
                    with socket.create_connection(("127.0.0.1", 19591), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError("Caddy did not listen")
            conn, stream = request(2)
            path, headers, body = requests[-1]
            assert path == "/endpoint", "the file-header route skipped upstream path rewriting"
            assert body == b'{"jsonrpc": "2.0", "method": "tools/list", "id": 2}', "the file-header route changed the POST body"
            assert headers.get_all("Authorization") == ["Bearer First.Secret=="], "client Authorization survived or token padding was lost"
            assert headers.get_all("X-Token") == ["Other.Secret"], "custom client header survived or its default prefix was not empty"
            assert stream.readline() + stream.readline() == b"data: first\n\n", "SSE buffered until close"

            # Each line ending has to strip exactly once. The second case also
            # catches a reader that stops refreshing after the first rotation.
            for case, contents, expected in [
                ("LF", b"Rotated.Secret\n", "Bearer Rotated.Secret"),
                ("CRLF", b"CRLF.Secret\r\n", "Bearer CRLF.Secret"),
            ]:
                publish(token, contents)
                client, response = request()
                try:
                    assert response.status == 200, (case, response.status)
                    response.read()
                finally:
                    client.close()
                assert requests[-1][1].get_all("Authorization") == [expected], f"{case}: stale token or untrimmed line ending"

            invalid_contents = {
                "blank": b"",
                "embedded carriage return": b"bad\rline",
                "embedded newline": b"bad\nline",
                "embedded null": b"bad\x00",
                "embedded space": b"bad space",
                "padding without a token": b"=",
                "two trailing newlines": b"bad\n\n",
            }
            for case, contents in invalid_contents.items():
                publish(token, contents)
                expect_unavailable(case)
            token.unlink()
            expect_unavailable("missing file cannot reuse the previous token")
            publish(token, b"Hidden.Secret")
            token.chmod(0)
            try:
                token.read_bytes()
            except PermissionError:
                expect_unavailable("unreadable file cannot reuse the previous token")
            else:
                raise AssertionError("unreadable fixture is readable by this user")
            publish(token, b"Restored.Secret")
            publish(second, b"")
            expect_unavailable("second credential file blank despite a valid first file")
            release.set()
            assert stream.read() == b"data: second\n\n", "rotation interrupted existing stream"
            conn.close()
            publish(second, b"Other.Secret")
            # Exercise the upstream-error log path, not merely clean requests.
            client, response = request(3)
            assert response.status == 502, "the upstream closed without a response; expected Bad Gateway"
            response.read()
            client.close()
            assert requests[-1][1].get_all("Authorization") == ["Bearer Restored.Secret"], "error probe did not use the restored credential"
        finally:
            release.set()
            process.terminate()
            process.wait(timeout=5)
            upstream.shutdown()
        log.seek(0)
        logs = log.read()
        assert re.search(r"\bhttp\.log\.error\b", logs), "upstream error was not logged; no redaction was observed"
        for secret in ["CRLF.Secret", "First.Secret", "Other.Secret", "Restored.Secret", "Rotated.Secret", "client-supplied-custom-token", "client-supplied-token"]:
            assert secret not in logs, "credential leaked to Caddy logs"
    print("PASS: rotation without restart, line endings, overwrite, POST, fail-closed, SSE, log redaction")
