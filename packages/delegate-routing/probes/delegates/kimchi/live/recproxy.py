"""Recording pass-through proxy for LIVE Kimchi prompt captures. usage: recproxy.py <port>

Forwards every request to $UPSTREAM (e.g. https://llm.kimchi.dev) unchanged and streams the response back.
Logs to $LOG (provider.jsonl shape: kind, path, status, model) and, for chat requests, the body's
messages and tool names to $WIRE (fakeprov.py's wire.jsonl shape, read by sysprompt.py). The model
metadata response is reduced to slug + reasoning flag in $LOG. Each chat response also leaves a RESP
record in $LOG: the model and effort sent, the model(s) the SSE chunks name, and the final usage block.
Request headers (the API key) are forwarded, never logged.
"""
import json, os, sys, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ["UPSTREAM"].rstrip("/")
lock = threading.Lock()
HOP = {"host", "content-length", "connection", "accept-encoding", "transfer-encoding"}


def write(path, rec):
    rec["t"] = round(time.time(), 3)
    with lock, open(path, "a") as f:
        f.write(json.dumps(rec) + "\n")


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def relay(self, method):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)) if method == "POST" else None
        body = json.loads(raw) if raw else {}
        if body.get("messages") and os.environ.get("WIRE"):
            tools = [t.get("function", {}).get("name") for t in body.get("tools", []) or []]
            write(os.environ["WIRE"], {"role": "live", "model": body.get("model"), "tools": tools, "messages": body["messages"]})
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        req = urllib.request.Request(UPSTREAM + self.path, data=raw, method=method, headers=headers)
        try:
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as e:
            resp = e
        status = resp.status if hasattr(resp, "status") else resp.code
        rec = {"kind": method, "path": self.path, "status": status, "model": body.get("model"),
               "reasoning_effort": body.get("reasoning_effort")}
        if method == "GET" and "/models/metadata" in self.path:
            data = resp.read()
            try:
                rec["models"] = [{"slug": m.get("slug"), "reasoning": m.get("reasoning")} for m in json.loads(data).get("models", [])]
            except ValueError:
                pass
            write(os.environ["LOG"], rec)
            self.send_response(status)
            self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        write(os.environ["LOG"], rec)
        self.send_response(status)
        for k, v in resp.headers.items():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        seen = bytearray()
        while True:
            chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
            if not chunk:
                break
            if body.get("messages"):
                seen += chunk
            self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
        if body.get("messages"):
            # Usage record: the model(s) the gateway's SSE chunks name and the final usage block.
            models, usage = [], None
            for line in seen.decode("utf-8", "replace").splitlines():
                if not line.startswith("data:") or line.strip() == "data: [DONE]":
                    continue
                try:
                    obj = json.loads(line[5:])
                except ValueError:
                    continue
                if obj.get("model") and obj["model"] not in models:
                    models.append(obj["model"])
                usage = obj.get("usage") or usage
            write(os.environ["LOG"], {"kind": "RESP", "path": self.path, "status": status, "sent_model": body.get("model"),
                                      "sent_effort": body.get("reasoning_effort"), "resp_models": models, "usage": usage})

    def do_GET(self):
        self.relay("GET")

    def do_POST(self):
        self.relay("POST")


srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
print(f"listening {sys.argv[1]}", flush=True)
srv.serve_forever()
