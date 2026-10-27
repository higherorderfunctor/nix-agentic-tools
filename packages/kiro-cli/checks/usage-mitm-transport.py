"""Real mitmdump regression using loopback HTTP only and synthetic payloads."""

import argparse
import gzip
import hashlib
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time


def run(mitmdump, addon):
    request_body = json.dumps({"model": "synthetic-model", "metadata": {"kiro:conversation_id": "sess_synthetic"}}).encode()
    request_entity = gzip.compress(request_body)
    output = "é🙂"
    delta = {"type": "response.output_text.delta", "delta": output}
    completed = {"type": "response.completed", "response": {"output": [{"type": "message", "content": [{"type": "output_text", "text": output}]}], "usage": {"kiro:credits": .25, "kiro:context_usage_percentage": 12.3}}}
    body = b"".join(b"data: " + json.dumps(obj, ensure_ascii=False).encode() + b"\r\n\r\n" for obj in (delta, completed))
    entity = gzip.compress(body)
    release = threading.Event()
    upstream_errors = []

    class Upstream(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_POST(self):
            try:
                assert self.path == "/v1/responses?ignored=private-query"
                assert self.rfile.read(int(self.headers["content-length"])) == request_entity
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Encoding", "gzip")
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("x-amzn-requestid", "synthetic-upstream-request")
                self.send_header("Set-Cookie", "private-response-cookie")
                self.end_headers()

                def chunk(data):
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                    self.wfile.flush()

                chunk(entity[:1])
                # Client must receive this first byte before the upstream sends the rest.
                assert release.wait(5), "proxy buffered the first response byte"
                for offset in range(1, len(entity), 7):
                    chunk(entity[offset:offset + 7])
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except BaseException as error:
                upstream_errors.append(error)
                self.close_connection = True

    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    serving = threading.Thread(target=upstream.serve_forever, daemon=True)
    serving.start()
    with tempfile.TemporaryDirectory(prefix="kiro-mitm-offline-") as temporary:
        root = Path(temporary)
        database = root / "usage.sqlite3"
        router = root / "route.py"
        router.write_text(
            "def running():\n"
            "    print('KIRO_OFFLINE_ROUTER_READY', flush=True)\n"
            "def request(flow):\n"
            "    assert flow.request.host == 'runtime.us-east-1.kiro.dev'\n"
            "    flow.request.host = '127.0.0.1'\n"
            f"    flow.request.port = {upstream.server_port}\n"
            "    flow.request.scheme = 'http'\n"
        )
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            proxy_port = reservation.getsockname()[1]
        command = [mitmdump, "--listen-host", "127.0.0.1", "--listen-port", str(proxy_port),
                   "--set", "confdir=" + str(root / "ca"), "--set", "connection_strategy=lazy",
                   "--set", "flow_detail=0", "-s", str(addon), "-s", str(router)]
        environment = {"HOME": str(root), "PATH": os.defpath, "TMPDIR": str(root),
                       "KIRO_USAGE_DB": str(database), "KIRO_USAGE_MAX_BYTES": "1048576"}
        log_path = root / "mitmdump.log"
        with log_path.open("wb") as log:
            process = subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT)
            client = None
            try:
                deadline = time.monotonic() + 15
                while True:
                    if process.poll() is not None:
                        raise AssertionError("mitmdump failed to start: " + log_path.read_text())
                    try:
                        with socket.create_connection(("127.0.0.1", proxy_port), timeout=.1):
                            break
                    except OSError:
                        if time.monotonic() > deadline:
                            raise AssertionError("mitmdump did not listen: " + log_path.read_text())
                        time.sleep(.05)
                # Never send a synthetic public hostname unless loopback routing loaded.
                while "KIRO_OFFLINE_ROUTER_READY" not in log_path.read_text():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise AssertionError("offline router did not load: " + log_path.read_text())
                    time.sleep(.05)
                client = HTTPConnection("127.0.0.1", proxy_port, timeout=3)
                client.request("POST", "http://runtime.us-east-1.kiro.dev/v1/responses?ignored=private-query",
                               body=request_entity, headers={"Content-Encoding": "gzip", "Content-Type": "application/json",
                                                             "Authorization": "Bearer private-authorization", "Cookie": "private-request-cookie"})
                response = client.getresponse()
                assert response.status == 200
                first = response.read(1)
                assert first == entity[:1], "first encoded byte changed"
                release.set()
                received = first + response.read()
                assert received == entity, "response entity bytes changed"
                assert not upstream_errors, upstream_errors
                client.close()
                client = None
                process.send_signal(signal.SIGINT)
                assert process.wait(timeout=10) == 0, log_path.read_text()
            finally:
                release.set()
                if client:
                    client.close()
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                upstream.shutdown()
                upstream.server_close()
                serving.join(timeout=2)
        logs = log_path.read_text()
        assert "Traceback" not in logs and "Addon error" not in logs, logs
        with sqlite3.connect(database) as db:
            db.row_factory = sqlite3.Row
            rows = db.execute("SELECT * FROM captures").fetchall()
            assert len(rows) == 1, [dict(row) for row in rows]
            row = rows[0]
            assert row["state"] == "complete", dict(row)
            assert row["credits"] == .25 and row["context_usage_percentage"] == 12.3
            assert row["input_tokens"] is None and row["output_tokens"] is None
            assert gzip.decompress(row["request_gzip"]) == request_body
            assert row["request_sha256"] == hashlib.sha256(request_body).hexdigest()
            assert row["response_sha256"] == hashlib.sha256(body).hexdigest()
            metadata = row["metadata_json"] + row["response_json"]
            assert "private-" not in metadata, metadata
            assert "synthetic-upstream-request" in metadata
            chunks = db.execute("SELECT * FROM chunks ORDER BY seq").fetchall()
            assert b"".join(gzip.decompress(c["entity_gzip"]) for c in chunks) == entity
            assert b"".join(gzip.decompress(c["application_gzip"]) for c in chunks) == body
            assert db.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 2
            summary = json.loads(row["summary_json"])
            assert summary["output_text_chars"] == 2 and summary["output_text_bytes"] == 6
    print("PASS real mitmdump: loopback only; addon startup/shutdown; immediate first byte; exact gzip request/response; complete SSE evidence; usage NULL for unknown token counts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mitmdump", required=True)
    parser.add_argument("--addon", required=True, type=Path)
    args = parser.parse_args()
    run(args.mitmdump, args.addon.resolve(strict=True))


if __name__ == "__main__":
    main()
