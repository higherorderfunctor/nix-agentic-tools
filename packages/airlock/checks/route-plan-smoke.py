"""Exercise the prototype with loopback providers and throwaway credentials."""

import base64
import http.client
import json
import os
from pathlib import Path
import ssl
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

START = b'data: {"message":{"usage":{"input_tokens":7}}}\n\n'
FINISH = b'data: {"usage":{"output_tokens":3}}\n\n'
CLIENT = "probe-client"
DECISIONS = "decisions-client"
OPERATOR = "operator-token"


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        key = self.headers.get("x-api-key") or self.headers.get("Authorization")
        self.server.calls.append((self.path, key, payload["model"]))
        if self.path == "/decision-free" or (
            self.path == "/primary" and payload.get("fallback")
        ):
            self.send_response(429)
            self.end_headers()
        elif self.path == "/decision-alt":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"result":{"answer":"yes","usage":{"input_tokens":2}}}')
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            if payload.get("break_stream"):
                self.send_header("Content-Length", str(len(START) + len(FINISH)))
            self.end_headers()
            self.wfile.write(START)
            self.wfile.flush()
            if self.server.release.wait(5) and not payload.get("break_stream"):
                self.wfile.write(FINISH)


def post(connection, token, path, payload, **headers):
    headers.update({"Content-Type": "application/json", "x-api-key": "client-placeholder"})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    connection.request("POST", path, json.dumps(payload), headers)
    return connection.getresponse()


def stream(response, server):
    assert response.status == 200, response.status
    assert response.readline() == START.splitlines(keepends=True)[0]
    server.release.set()
    assert response.read() == b"\n" + FINISH
    server.release.clear()


def run(binary, provider, root):
    def secret(value):
        path = root / value
        path.write_text(value)
        path.chmod(0o600)
        return str(path)

    def target(path, key, **options):
        return {
            "uri": f"http://127.0.0.1:{provider.server_port}/{path}",
            "key_file": secret(key),
            "pool": path,
            **options,
        }

    plan = root / "routes.json"
    plan.write_text(json.dumps({
        "clients": {"probe": secret(CLIENT), "decisions": secret(DECISIONS)},
        "intercept": "anthropic.test:443",
        "management": {"listen": "127.0.0.1:0", "token_file": secret(OPERATOR)},
        "routes": [
            {
                "client": "probe", "path": "/v1/messages", "model": "sample",
                "primary": target("primary", "primary-key"),
                "fallback": target("backup", "backup-key", model="alternate"),
            },
            {
                "client": "decisions", "path": "/v1/passthrough", "model": "decision",
                "primary": target("decision-free", "decision-free-key", auth="bearer"),
                "fallback": target("decision-alt", "decision-alt-key", auth="bearer",
                                   unwrap="/result"),
            },
        ],
    }))
    env = os.environ.copy()
    env.pop("AIRLOCK_HOME", None)
    env["XDG_RUNTIME_DIR"] = str(root)
    process = subprocess.Popen(
        [binary, "serve", "--listen", "127.0.0.1:0", "--route-plan", str(plan)],
        stdout=subprocess.PIPE, text=True, env=env,
    )
    try:
        management, proxy = [int(process.stdout.readline().rsplit(":", 1)[1]) for _ in range(2)]
        local = http.client.HTTPConnection("127.0.0.1", proxy, timeout=3)
        messages = "/v1/messages"
        denied = post(local, DECISIONS, messages, {"model": "sample"})
        assert denied.status == 403 and denied.read()
        assert provider.calls == []
        stream(post(local, CLIENT, messages, {"model": "sample"}), provider)

        ca = root / "airlock" / "default" / "ca.pem"
        native = http.client.HTTPSConnection(
            "127.0.0.1", proxy, context=ssl.create_default_context(cafile=str(ca)), timeout=3,
        )
        proxy_token = base64.b64encode(f"probe:{CLIENT}".encode()).decode()
        native.set_tunnel("anthropic.test", 443, {"Proxy-Authorization": f"Basic {proxy_token}"})
        stream(post(native, None, messages, {"model": "sample", "fallback": True},
                    Host="anthropic.test"), provider)

        broken = post(local, CLIENT, messages, {"model": "sample", "break_stream": True})
        assert broken.status == 200 and broken.read(len(START)) == START
        provider.release.set()
        try:
            broken.read()
        except http.client.IncompleteRead:
            pass
        else:
            raise AssertionError("truncated upstream response looked complete")
        finally:
            provider.release.clear()
            local.close()

        decision = post(local, DECISIONS, "/v1/passthrough", {"model": "decision"})
        assert decision.status == 200 and json.loads(decision.read())["answer"] == "yes"
        assert provider.calls == [
            ("/primary", "primary-key", "sample"),
            ("/primary", "primary-key", "sample"),
            ("/backup", "backup-key", "alternate"),
            ("/primary", "primary-key", "sample"),
            ("/decision-free", "Bearer decision-free-key", "decision"),
            ("/decision-alt", "Bearer decision-alt-key", "decision"),
        ]

        control = http.client.HTTPConnection("127.0.0.1", management, timeout=3)
        control.request("GET", "/usage", headers={"Authorization": f"Bearer {OPERATOR}"})
        usage = json.loads(control.getresponse().read())
        assert [(row["pool"], row["status"]) for row in usage] == [
            ("primary", 200), ("primary", 429), ("backup", 200), ("primary", 200),
            ("decision-free", 429), ("decision-alt", 200),
        ]
        assert (usage[2]["input_tokens"], usage[2]["output_tokens"]) == (7, 3)
        assert not usage[3]["completed"]
        assert usage[-1]["input_tokens"] == 2
        for connection in (local, native, control):
            connection.close()
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory, ThreadingHTTPServer(
        ("127.0.0.1", 0), Provider
    ) as provider:
        provider.calls = []
        provider.release = threading.Event()
        worker = threading.Thread(target=provider.serve_forever, daemon=True)
        worker.start()
        try:
            run(sys.argv[1], provider, Path(directory))
        finally:
            provider.shutdown()
    print("route plan smoke passed")
