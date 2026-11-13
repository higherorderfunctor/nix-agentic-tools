"""Exercise the generated route with a real process, files and streaming upstream."""

import http.client
import http.server
import json
import os
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


def request(body=b'{"jsonrpc":"2.0","method":"tools/list","id":1}'):
    conn = http.client.HTTPConnection("127.0.0.1", 19591, timeout=3)
    conn.request("POST", "/client-path", body, {"Accept": "application/json, text/event-stream", "aUtHoRiZaTiOn": "attacker", "Content-Type": "application/json"})
    return conn, conn.getresponse()


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
                assert process.poll() is None, "Caddy exited before listening"
                try:
                    with socket.create_connection(("127.0.0.1", 19591), timeout=0.1):
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                raise AssertionError("Caddy did not listen")
            pid = process.pid
            conn, stream = request(b'{"jsonrpc":"2.0","method":"tools/list","id":2}')
            assert stream.status == 200
            assert requests[-1][1].get_all("Authorization") == ["Bearer First.Secret=="]
            assert stream.readline() == b"data: first\n", "SSE buffered until close"
            assert stream.readline() == b"\n"
            for contents, expected in [(b"Rotated.Secret\n", "Bearer Rotated.Secret"), (b"CRLF.Secret\r\n", "Bearer CRLF.Secret")]:
                publish(token, contents)
                client, response = request()
                assert response.status == 200
                response.read()
                client.close()
                path, headers, body = requests[-1]
                assert path == "/endpoint"
                assert headers.get_all("Authorization") == [expected], "client header not overwritten"
                assert headers["X-Token"] == "Other.Secret", "default prefix was not empty"
                assert body == b'{"jsonrpc":"2.0","method":"tools/list","id":1}'
                assert process.pid == pid and process.poll() is None
            for invalid in [b"", b"bad space", b"bad\nline", b"bad\rline", b"bad\x00", b"=", b"bad\n\n"]:
                publish(token, invalid)
                before = len(requests)
                client, response = request()
                assert (response.status, response.read()) == (503, b"Credential unavailable")
                client.close()
                assert len(requests) == before, "invalid token reached upstream"
            for unavailable in ["missing", "unreadable"]:
                publish(token, b"Hidden.Secret")
                if unavailable == "missing":
                    token.unlink()
                else:
                    token.chmod(0)
                    try:
                        token.read_bytes()
                    except PermissionError:
                        pass
                    else:
                        raise AssertionError("unreadable fixture is readable by this user")
                before = len(requests)
                client, response = request()
                assert (response.status, response.read()) == (503, b"Credential unavailable")
                client.close()
                assert len(requests) == before
            publish(token, b"Restored.Secret")
            publish(second, b"")
            before = len(requests)
            client, response = request()
            assert response.status == 503, "only first file was guarded"
            response.read()
            client.close()
            assert len(requests) == before
            release.set()
            assert stream.read() == b"data: second\n\n", "rotation interrupted existing stream"
            conn.close()
            publish(second, b"Other.Secret")
            client, response = request(b'{"jsonrpc":"2.0","method":"tools/list","id":3}')
            assert response.status == 502
            response.read()
            client.close()
        finally:
            release.set()
            process.terminate()
            process.wait(timeout=5)
            upstream.shutdown()
            log.seek(0)
            logs = log.read()
            for secret in ["First.Secret", "Rotated.Secret", "CRLF.Secret", "Hidden.Secret", "Restored.Secret", "Other.Secret", "attacker"]:
                assert secret not in logs, "credential leaked to Caddy logs"
    print("PASS: rotation, newline, overwrite, POST, fail-closed, SSE, log redaction; same Caddy PID")
