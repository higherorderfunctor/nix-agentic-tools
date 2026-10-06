#!/usr/bin/env python3
import json, os, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

port = int(os.environ["MOCK_PORT"])
out = Path(os.environ["MOCK_OUT"])
out.mkdir(parents=True, exist_ok=True)
lock = threading.Lock()
count = 0
active = 0
peak_active = 0
script = Path(os.environ["MOCK_SCRIPT"]).read_text() if os.environ.get("MOCK_SCRIPT") else None

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def send_finished(self, status, ctype, body):
        global active
        with lock:
            active -= 1
        self.respond(status, ctype, body)
    def respond(self, status, ctype, body):
        self.send_response(status)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        global count, active, peak_active
        body = json.loads(self.rfile.read(int(self.headers.get("content-length", "0"))))
        with lock:
            count += 1
            n = count
            active += 1
            peak_active = max(peak_active, active)
        if "count_tokens" in self.path:
            self.send_finished(200, "application/json", b'{"input_tokens":1000}')
            return
        time.sleep(0.15)
        users = body.get("messages", [])
        last = users[-1].get("content", "") if users else ""
        if isinstance(last, list):
            last = "\n".join(x.get("text", "") for x in last if x.get("type") == "text")
        request_record = {
            "n": n,
            "model": body.get("model"),
            "thinking": body.get("thinking"),
            "max_tokens": body.get("max_tokens"),
            "output_config": body.get("output_config"),
            "active_at_capture": active,
            "peak_active": peak_active,
            "tools": [x.get("name") for x in body.get("tools", [])],
            "user_tail": str(last)[-500:],
        }
        if "<task-notification>" in str(last):
            request_record["task_notification"] = str(last)[-12000:]
            request_record["matching_context"] = [str(m)[max(0, str(m).find(k)-150):str(m).find(k)+350] for m in body.get("messages", []) for c in (m.get("content", []) if isinstance(m.get("content"), list) else [m.get("content", "")]) for b in (c if isinstance(c, list) else [c]) for m in [b.get("text", "") if isinstance(b, dict) else b] for k in ("scriptPath", "transcriptDir", "WorkflowAgentCapError", "wf_") if k in str(m)]
        with lock:
            with (out / "requests.jsonl").open("a") as f:
                f.write(json.dumps(request_record) + "\n")
        if "WF_ROOT_RUN" in str(last):
            script_text = script or '''export const meta = { name: 'offline-node-limit', description: 'offline engine replay' }
const pinned = await agent('NODE_PIN_FIRST', { model: 'sonnet', effort: 'low', label: 'pinned' })
for (let i = 2; i <= 1001; i++) await agent(`NODE_LIMIT_${i}`)
return pinned
'''
            content = [{"type":"tool_use", "id":f"toolu_mock_{n}", "name":"Workflow", "input":{"script":script_text}}]
            stop = "tool_use"
        else:
            content = [{"type":"text", "text":"mock worker result"}]
            stop = "end_turn"
        msg = {"id":f"msg_mock_{n}","type":"message","role":"assistant","model":body.get("model","mock"),"content":content,"stop_reason":stop,"stop_sequence":None,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        if not body.get("stream"):
            self.send_finished(200,"application/json",json.dumps(msg).encode())
            return
        ev = [("message_start", {"type":"message_start","message":{**msg,"content":[],"stop_reason":None}})]
        for i,x in enumerate(content):
            if x["type"] == "text":
                ev.extend([("content_block_start",{"type":"content_block_start","index":i,"content_block":{"type":"text","text":""}}),("content_block_delta",{"type":"content_block_delta","index":i,"delta":{"type":"text_delta","text":x["text"]}})])
            else:
                ev.extend([("content_block_start",{"type":"content_block_start","index":i,"content_block":{"type":"tool_use","id":x["id"],"name":x["name"],"input":{}}}),("content_block_delta",{"type":"content_block_delta","index":i,"delta":{"type":"input_json_delta","partial_json":json.dumps(x["input"])}})])
            ev.append(("content_block_stop",{"type":"content_block_stop","index":i}))
        ev.extend([("message_delta",{"type":"message_delta","delta":{"stop_reason":stop,"stop_sequence":None},"usage":{"output_tokens":5}}),("message_stop",{"type":"message_stop"})])
        payload=b"".join(f"event: {e}\ndata: {json.dumps(d)}\n\n".encode() for e,d in ev)
        self.send_finished(200,"text/event-stream",payload)

ThreadingHTTPServer(("127.0.0.1",port),Handler).serve_forever()
