"""Scripted fake OpenAI chat-completions provider for offline Kimchi/Pi delegate probes.

Every request is appended to $LOG (JSONL). Decisions:
- A request whose tool list contains "Agent" is a PARENT turn. The first user message
  carries PLAN=<json list of turns>; turn i = number of assistant messages already in the
  conversation; each turn is a list of {"name":..., "args":{...}} tool calls. Past the plan,
  the parent answers text PARENT_DONE.
- Any other request is a CHILD turn. If its first user message has SLEEP=<n>, the server
  streams keep-alive comments for n seconds before answering (a closed socket is logged as
  client_disconnected = cancel reached the HTTP layer). Child answers CHILD_DONE plus every
  STEER_xxx token seen anywhere in its messages.
$NONREASONING (comma list of slugs) advertises those models with reasoning=false.
POST .../embeddings answers a constant unit vector per input (memory store probes).
With $WIRE set, every request body (messages verbatim, tool names) is also appended to $WIRE.
"""
import json, os, re, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.environ["LOG"]
lock = threading.Lock()

def log(rec):
    rec["t"] = round(time.time(), 3)
    with lock, open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")

def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_GET(self):
        log({"kind": "GET", "path": self.path})
        if self.path.startswith("/v1/models/metadata"):
            models = [{"slug": s, "display_name": s, "provider": "ai-enabler", "reasoning": s not in os.environ.get("NONREASONING", "").split(","), "input_modalities": ["text"],
                       "is_serverless": True, "limits": {"context_window": 200000, "max_output_tokens": 8000}} for s in ("fake-a", "fake-b")]
            data = json.dumps({"models": models}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()
    def sse(self, obj):
        data = ("data: " + json.dumps(obj) + "\n\n").encode()
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n"); self.wfile.flush()
    def raw(self, s):
        data = s.encode()
        self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n"); self.wfile.flush()
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("/embeddings"):
            # Memory embedder: one constant unit vector per input, so every stored fact matches every query.
            inputs = body.get("input")
            inputs = inputs if isinstance(inputs, list) else [inputs]
            dims = int(body.get("dimensions") or 1024)
            vec = [1.0 / dims ** 0.5] * dims
            data = json.dumps({"object": "list", "model": body.get("model"), "data": [{"object": "embedding", "index": i, "embedding": vec} for i in range(len(inputs))], "usage": {"prompt_tokens": 1, "total_tokens": 1}}).encode()
            log({"kind": "EMBED", "path": self.path, "model": body.get("model"), "n": len(inputs)})
            self.send_response(200); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data); return
        msgs = body.get("messages", [])
        tools = [t.get("function", {}).get("name") for t in body.get("tools", []) or []]
        system = next((text_of(m.get("content")) for m in msgs if m.get("role") in ("system", "developer")), "")
        users = [text_of(m.get("content")) for m in msgs if m.get("role") == "user"]
        first_user = users[0] if users else ""
        n_asst = sum(1 for m in msgs if m.get("role") == "assistant")
        last = msgs[-1] if msgs else {}
        alltext = "\n".join(text_of(m.get("content")) for m in msgs)
        role = "parent" if "Agent" in tools else "child"
        rec = {"kind": "POST", "path": self.path, "role": role, "model": body.get("model"),
               "reasoning_effort": body.get("reasoning_effort"), "reasoning": body.get("reasoning"),
               "tools": tools, "n_msgs": len(msgs), "n_asst": n_asst, "last_role": last.get("role"),
               "system_head": system[:160], "system_cwd": re.findall(r"(?:Current working directory|cwd)[^\n]{0,160}", system)[:2],
               "first_user_head": first_user[:240], "last_text": text_of(last.get("content"))[:600],
               "steers_seen": sorted(set(re.findall(r"STEER_[A-Z0-9_]+", alltext)))}
        log(rec)
        if os.environ.get("WIRE"):
            # Opt-in full request capture (scenario "full_wire"): every message and tool name, verbatim.
            with lock, open(os.environ["WIRE"], "a") as f:
                f.write(json.dumps({"t": rec["t"], "role": role, "model": body.get("model"), "tools": tools, "messages": msgs}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        cid = "c%d" % int(time.time() * 1000)
        base = {"id": cid, "object": "chat.completion.chunk", "model": body.get("model"), "created": int(time.time())}
        try:
            calls = None
            wm = re.search(r"WFSLEEP=(\d+)", first_user)
            if wm and n_asst == 0:
                end = time.time() + int(wm.group(1))
                while time.time() < end:
                    self.raw(": keepalive\n\n"); time.sleep(0.5)
            if role == "parent":
                # A hook or harness steer can precede the prompt, so read the first user message carrying a PLAN.
                plan_src = next((u for u in users if "PLAN=" in u), first_user)
                m = re.search(r"PLAN=(\[.*\])\s*$", plan_src, re.S)
                plan = json.loads(m.group(1)) if m else []
                if n_asst < len(plan):
                    ids = []
                    for mm in msgs:
                        if mm.get("role") == "tool":
                            for x in re.findall(r"(?:Agent ID: |\"agent_id\": \")([0-9a-f-]{17})", text_of(mm.get("content"))):
                                if x not in ids: ids.append(x)
                    raw = json.dumps(plan[n_asst])
                    for i, x in enumerate(ids):
                        raw = raw.replace(f"@ID{i}@", x)
                    calls = json.loads(raw)
                    rec2 = {"kind": "PLAN_STEP", "n_asst": n_asst, "ids": ids, "calls": [c["name"] for c in calls]}
                    log(rec2)
                answer = "PARENT_DONE"
            else:
                m = re.search(r"SLEEP=(\d+)", first_user)
                if m and n_asst == 0:
                    end = time.time() + int(m.group(1))
                    while time.time() < end:
                        self.raw(": keepalive\n\n"); time.sleep(0.5)
                answer = "CHILD_DONE " + " ".join(rec["steers_seen"])
                cm = re.search(r"CHILDPLAN=(\[.*\])", first_user, re.S)
                if cm:
                    try:
                        cplan = json.loads(cm.group(1))
                    except ValueError:
                        cplan = []
                    if n_asst < len(cplan):
                        calls = cplan[n_asst]
                    else:
                        tool_texts = [text_of(mm.get("content"))[:200] for mm in msgs if mm.get("role") == "tool"]
                        answer = "CHILD_DONE results=" + json.dumps(tool_texts)
            if calls:
                for i, c in enumerate(calls):
                    self.sse({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [{"index": i, "id": f"call_{n_asst}_{i}", "type": "function", "function": {"name": c["name"], "arguments": json.dumps(c["args"])}}]}, "finish_reason": None}]})
                self.sse({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
            else:
                self.sse({**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": answer}, "finish_reason": None}]})
                self.sse({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.sse({**base, "choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
            self.raw("data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            log({"kind": "DONE", "role": role, "n_asst": n_asst})
        except (BrokenPipeError, ConnectionResetError) as e:
            log({"kind": "client_disconnected", "role": role, "n_asst": n_asst, "first_user_head": first_user[:80]})

port = int(sys.argv[1])
srv = ThreadingHTTPServer(("127.0.0.1", port), H)
print(f"listening {port}", flush=True)
srv.serve_forever()
