#!/usr/bin/env python3
"""Recording pass-through proxy for LIVE Codex captures (codex:L3.live-guardian).

usage: liveproxy.py <port> <outdir>      UPSTREAM env, default https://chatgpt.com

Codex reaches it through `openai_base_url = "http://127.0.0.1:<port>/backend-api/codex"`. Every
request is forwarded unchanged to UPSTREAM + path and the response is streamed back. Request
headers (the bearer token, account id) are forwarded and never logged. Logged to <outdir>:
  log.jsonl          one line per request: n, method, path, status, model, x-openai-subagent
  reqNN.json         each POST body (the prompt as actually sent; request compression must be off)
  models.json        the catalog response of GET .../models
A WebSocket upgrade gets 426, which makes Codex fall back to HTTP for the session.
"""
import http.client, json, os, ssl, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, OUT = int(sys.argv[1]), sys.argv[2]
UP = urllib.parse.urlsplit(os.environ.get("UPSTREAM", "https://chatgpt.com"))
HOP = {"host", "content-length", "connection", "accept-encoding", "transfer-encoding", "upgrade", "keep-alive"}
os.makedirs(OUT, exist_ok=True)
lock = threading.Lock()
count = [0]


def log(rec):
    with lock, open(os.path.join(OUT, "log.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def relay(self, method):
        with lock:
            n = count[0]
            count[0] += 1
        if self.headers.get("Upgrade", "").lower() == "websocket":
            log({"n": n, "method": method, "path": self.path, "status": 426, "note": "websocket refused"})
            self.send_response(426)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)) if method == "POST" else None
        rec = {"n": n, "method": method, "path": self.path}
        if raw:
            with open(os.path.join(OUT, f"req{n:02d}.json"), "wb") as f:
                f.write(raw)
            try:
                body = json.loads(raw)
                meta = body.get("client_metadata") or {}
                rec.update(model=body.get("model"), subagent=meta.get("x-openai-subagent"))
            except ValueError:
                rec["note"] = "body is not JSON (request compression on?)"
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Host"] = UP.netloc
        conn_cls = http.client.HTTPSConnection if UP.scheme == "https" else http.client.HTTPConnection
        kwargs = {"context": ssl.create_default_context()} if UP.scheme == "https" else {}
        conn = conn_cls(UP.netloc, timeout=300, **kwargs)
        conn.request(method, self.path, body=raw, headers=headers)
        resp = conn.getresponse()
        rec["status"] = resp.status
        log(rec)
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        keep = bytearray() if method == "GET" and "/models" in self.path else None
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            if keep is not None:
                keep += chunk
            self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        if keep is not None and resp.status == 200:
            with open(os.path.join(OUT, "models.json"), "wb") as f:
                f.write(bytes(keep))
        conn.close()

    def do_GET(self):
        self.relay("GET")

    def do_POST(self):
        self.relay("POST")


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
