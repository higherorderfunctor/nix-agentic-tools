#!/usr/bin/env python3
"""Mock Anthropic Messages API that records every request body and answers
from a scripted plan. No upstream; zero quota.

Env:
  MOCK_PORT   listen port
  MOCK_DIR    directory for req-NNN.json dumps
  MOCK_PLAN   path to JSON plan: list of {"match": substr, "tool": name, "input": {...}}
              A request whose LAST user message text contains `match` (and is not a
              tool_result turn) is answered with that tool_use. Everything else gets
              text "ok-<n>" and end_turn.
"""
import json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("MOCK_PORT", "18923"))
DIR = os.environ["MOCK_DIR"]
os.makedirs(DIR, exist_ok=True)
PLAN = json.load(open(os.environ["MOCK_PLAN"])) if os.environ.get("MOCK_PLAN") else []
lock = threading.Lock()
counter = [0]
used = set()


def last_user_text(body):
    msgs = body.get("messages", [])
    if not msgs:
        return "", False
    m = msgs[-1]
    c = m.get("content")
    if isinstance(c, str):
        return c, False
    texts, has_tr = [], False
    for b in c or []:
        if b.get("type") == "text":
            texts.append(b.get("text", ""))
        if b.get("type") == "tool_result":
            has_tr = True
    return "\n".join(texts), has_tr


def sse(events):
    out = b""
    for ev, data in events:
        out += f"event: {ev}\ndata: {json.dumps(data)}\n\n".encode()
    return out


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, ctype, payload):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        with lock:
            counter[0] += 1
            n = counter[0]
        open(os.path.join(DIR, f"req-{n:03d}-GET.txt"), "w").write(self.path + "\n" + str(self.headers))
        self._send(404, "application/json", b'{"type":"error","error":{"type":"not_found_error","message":"mock"}}')

    def do_HEAD(self):
        self._send(200, "text/plain", b"")

    def do_POST(self):
        ln = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(ln)
        with lock:
            counter[0] += 1
            n = counter[0]
        try:
            body = json.loads(raw)
        except Exception:
            body = {"_raw": raw.decode("utf-8", "replace")}
        rec = {"path": self.path, "headers": {k: v for k, v in self.headers.items() if k.lower() not in ("authorization", "x-api-key")}, "body": body}
        with open(os.path.join(DIR, f"req-{n:03d}.json"), "w") as f:
            json.dump(rec, f, indent=1)
        if "count_tokens" in self.path:
            return self._send(200, "application/json", b'{"input_tokens": 1000}')
        if not self.path.startswith("/v1/messages"):
            return self._send(404, "application/json", b'{"type":"error","error":{"type":"not_found_error","message":"mock"}}')
        text, has_tr = last_user_text(body)
        content = None
        if not has_tr:
            for i, p in enumerate(PLAN):
                key = (i, p["match"])
                if p["match"] in text and (p.get("repeat") or key not in used):
                    used.add(key)
                    tl = p.get("tools") or [{"name": p["tool"], "input": p["input"]}]
                    content = [{"type": "tool_use", "id": f"toolu_mock{n:03d}_{j}", "name": t["name"], "input": t["input"]} for j, t in enumerate(tl)]
                    break
        if content is None:
            content = [{"type": "text", "text": f"ok-{n}"}]
        stop = "tool_use" if content[0]["type"] == "tool_use" else "end_turn"
        model = body.get("model", "mock")
        usage = {"input_tokens": 10, "output_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
        msg = {"id": f"msg_mock{n:03d}", "type": "message", "role": "assistant", "model": model, "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}
        if not body.get("stream"):
            msg["content"] = content
            msg["stop_reason"] = stop
            return self._send(200, "application/json", json.dumps(msg).encode())
        evs = [("message_start", {"type": "message_start", "message": msg})]
        for j, c in enumerate(content):
            if c["type"] == "text":
                evs.append(("content_block_start", {"type": "content_block_start", "index": j, "content_block": {"type": "text", "text": ""}}))
                evs.append(("content_block_delta", {"type": "content_block_delta", "index": j, "delta": {"type": "text_delta", "text": c["text"]}}))
            else:
                evs.append(("content_block_start", {"type": "content_block_start", "index": j, "content_block": {"type": "tool_use", "id": c["id"], "name": c["name"], "input": {}}}))
                evs.append(("content_block_delta", {"type": "content_block_delta", "index": j, "delta": {"type": "input_json_delta", "partial_json": json.dumps(c["input"])}}))
            evs.append(("content_block_stop", {"type": "content_block_stop", "index": j}))
        evs.append(("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}}))
        evs.append(("message_stop", {"type": "message_stop"}))
        payload = sse(evs)
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
