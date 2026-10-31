"""Real mitmdump regression using loopback HTTP only and synthetic payloads."""

import argparse
import base64
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
import sys
import tempfile
import threading
import time


def run(mitmdump, addon):
    sys.path.insert(0, str(addon.parent))
    from test_capture import EVENTSTREAM, aws_event  # the suite's CRC32 event-stream encoder
    import store
    request_body = json.dumps({"model": "synthetic-model", "metadata": {"kiro:conversation_id": "sess_synthetic"}}).encode()
    output = "é🙂"
    delta = {"type": "response.output_text.delta", "delta": output}
    completed = {"type": "response.completed", "response": {"output": [{"type": "message", "content": [{"type": "output_text", "text": output}]}], "usage": {"kiro:credits": {"unit": "credit", "unit_plural": "credits", "value": .25}, "kiro:context_usage_percentage": 12.3}}}
    body = b"".join(b"data: " + json.dumps(obj, ensure_ascii=False).encode() + b"\r\n\r\n" for obj in (delta, completed))
    stream_request = json.dumps({"conversationState": {"conversationId": "sess_stream", "currentMessage": {"userInputMessage": {"modelId": "synthetic-model"}}}}).encode()
    frames = [aws_event("meteringEvent", {"usage": .5, "unit": "credit", "unitPlural": "credits"}),
              aws_event("contextUsageEvent", {"contextUsagePercentage": 7.5}),
              aws_event("assistantResponseEvent", {"content": output}),
              aws_event("metadataEvent", {"tokenUsage": {"uncachedInputTokens": 10, "cacheReadInputTokens": 80, "cacheWriteInputTokens": 5, "outputTokens": 4}, "stopReason": "END_TURN"})]
    generate, limits = "KiroRuntimeService.GenerateAssistantResponse", "KiroRuntimeService.GetUsageLimits"
    # (path, x-amz-target) -> (request entity, request encoding, response type, response encoding, response entity)
    routes = {("/v1/responses", None): (gzip.compress(request_body), "gzip", "text/event-stream", "gzip", gzip.compress(body)),
              ("/", generate): (stream_request, None, EVENTSTREAM, None, b"".join(frames)),
              # Same RPC path, another operation: must pass through uncaptured.
              ("/", limits): (b"{}", None, "application/x-amz-json-1.0", None, b'{"limits":[]}')}
    releases = {route: threading.Event() for route in routes}
    upstream_errors = []

    class Upstream(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_POST(self):
            try:
                assert self.headers.get("Proxy-Authorization") is None
                path, _, query = self.path.partition("?")
                assert query == "ignored=private-query"
                route = (path, self.headers.get("x-amz-target"))
                request_entity, _, content_type, encoding, entity = routes[route]
                assert self.rfile.read(int(self.headers["content-length"])) == request_entity
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                if encoding:
                    self.send_header("Content-Encoding", encoding)
                self.send_header("Transfer-Encoding", "chunked")
                self.send_header("x-amzn-requestid", "synthetic-upstream-request")
                self.send_header("Set-Cookie", "private-response-cookie")
                self.end_headers()

                def chunk(data):
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                    self.wfile.flush()

                chunk(entity[:1])
                # Client must receive this first byte before the upstream sends the rest.
                assert releases[route].wait(5), "proxy buffered the first response byte"
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
                       "KIRO_USAGE_DB": str(database), "KIRO_USAGE_WARN_BYTES": "1048576"}
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
                marker = "a" * 32
                authorization = "Basic " + base64.b64encode(f"kiro-usage-{marker}:".encode()).decode()
                for (path, target), (request_entity, request_encoding, _, _, entity) in routes.items():
                    if target == limits:
                        releases[path, target].set()  # unselected: mitmproxy buffers it, so no first-byte ordering
                    client = HTTPConnection("127.0.0.1", proxy_port, timeout=3)
                    client.set_tunnel("runtime.us-east-1.kiro.dev", 443, headers={"Proxy-Authorization": authorization})
                    client.request("POST", path + "?ignored=private-query",
                                   body=request_entity, headers={**({"Content-Encoding": request_encoding} if request_encoding else {}),
                                                                 **({"Content-Type": "application/x-amz-json-1.0", "X-Amz-Target": target} if target else {"Content-Type": "application/json"}),
                                                                 "Authorization": "Bearer private-authorization", "Cookie": "private-request-cookie"})
                    response = client.getresponse()
                    assert response.status == 200
                    first = response.read(1)
                    assert first == entity[:1], path + ": first byte changed"
                    releases[path, target].set()
                    received = first + response.read()
                    assert received == entity, path + ": response entity bytes changed"
                    assert not upstream_errors, upstream_errors
                    client.close()
                    client = None
                process.send_signal(signal.SIGINT)
                assert process.wait(timeout=10) == 0, log_path.read_text()
            finally:
                for release in releases.values():
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

            def sealed(ident):
                """(request, chunks, events) of a capture the collector sealed at shutdown, with no staged copy left."""
                staged = db.execute("SELECT (SELECT COUNT(*) FROM capture_facts WHERE capture_id=?),(SELECT COUNT(*) FROM chunks WHERE capture_id=?)"
                                    "+(SELECT COUNT(*) FROM events WHERE capture_id=?),(SELECT request_gzip IS NULL FROM captures WHERE id=?)", (ident,) * 4).fetchone()
                assert tuple(staged) == (1, 0, 1), tuple(staged)
                return store.request_body(db, ident), *store.response_rows(db, ident)

            rows = {json.loads(row["metadata_json"])["path"]: row for row in db.execute("SELECT * FROM captures")}
            assert sorted(rows) == ["/", "/v1/responses"], [dict(row) for row in rows.values()]
            assert db.execute("SELECT COUNT(*) FROM captures").fetchone()[0] == 2  # one row per selected call, no duplicates, GetUsageLimits skipped
            row = rows["/v1/responses"]
            assert row["state"] == "complete", dict(row)
            assert row["credits"] == .25 and row["context_usage_percentage"] == 12.3
            assert row["input_tokens"] is None and row["output_tokens"] is None
            request, chunks, events = sealed(row["id"])
            assert request == request_body
            assert row["request_sha256"] == hashlib.sha256(request_body).hexdigest()
            assert row["response_sha256"] == hashlib.sha256(body).hexdigest()
            assert json.loads(row["metadata_json"])["invocation"] == "a" * 32 and "target" not in json.loads(row["metadata_json"])
            metadata = row["metadata_json"] + row["response_json"]
            assert "private-" not in metadata, metadata
            assert "synthetic-upstream-request" in metadata
            assert b"".join(c.entity for c in chunks) == routes["/v1/responses", None][4]
            assert b"".join(c.application for c in chunks) == body
            assert len(events) == 2
            summary = json.loads(row["summary_json"])
            assert summary["output_text_chars"] == 2 and summary["output_text_bytes"] == 6
            row = rows["/"]
            assert (row["state"], json.loads(row["issues_json"])) == ("complete", []), dict(row)
            assert (row["credits"], row["context_usage_percentage"]) == (.5, 7.5), dict(row)
            assert (row["input_tokens"], row["output_tokens"], row["cache_read_tokens"], row["cache_write_tokens"]) == (95, 4, 80, 5), dict(row)
            request, chunks, events = sealed(row["id"])
            assert request == stream_request
            assert row["response_sha256"] == hashlib.sha256(b"".join(frames)).hexdigest()
            metadata = json.loads(row["metadata_json"])
            assert (metadata["invocation"], metadata["target"], metadata["kiro:conversation_id"], metadata["model"]) == ("a" * 32, generate, "sess_stream", "synthetic-model"), metadata
            assert b"".join(c.application for c in chunks) == b"".join(frames)
            assert [e.name for e in events] == ["meteringEvent", "contextUsageEvent", "assistantResponseEvent", "metadataEvent"], [e.name for e in events]
            assert [e.frame for e in events] == frames
            summary = json.loads(row["summary_json"])
            assert (summary["terminal"], summary["metering_events"], summary["output_text_chars"]) == ("END_TURN", 1, 2), summary
    print("PASS real mitmdump: loopback only; addon startup/shutdown; immediate first byte; exact gzip request/response sealed at shutdown; complete SSE evidence; usage NULL for unknown token counts; GenerateAssistantResponse selected by x-amz-target on POST / with complete event-stream evidence (credits, context, tokens); GetUsageLimits on POST / passed through uncaptured")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mitmdump", required=True)
    parser.add_argument("--addon", required=True, type=Path)
    args = parser.parse_args()
    run(args.mitmdump, args.addon.resolve(strict=True))


if __name__ == "__main__":
    main()
