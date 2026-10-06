#!/usr/bin/env python3
"""Run pinned Claude SDK stdin controls against a deterministic loopback API."""
import json, os, pathlib, queue, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import sys as _sys
_sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "common"))
import pin  # noqa: E402
ROOT = pin.workdir("claude-host")  # runs/<case>/ land here; printed at the end
BIN = os.environ.get("CLAUDE_BIN") or str(pin.package("claude-code") / "bin" / "claude")
PORT = int(os.environ.get("MOCK_PORT", "18766"))
requests = []
request_event = threading.Event()
delay_response = False
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw)
        requests.append({"path": self.path, "body": body})
        if "count_tokens" in self.path:
            payload = b'{"input_tokens":100}'
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
            return
        request_event.set()
        if delay_response: time.sleep(5)
        payload = json.dumps({"id":"msg_capture","type":"message","role":"assistant",
            "model":body.get("model","claude-haiku-4-5-20251001"),"content":[{"type":"text","text":"CAPTURE_COMPLETE"}],
            "stop_reason":"end_turn","stop_sequence":None,"usage":{"input_tokens":100,"output_tokens":2}}).encode()
        try:
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload))); self.end_headers(); self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

def run_case(name, frames, interrupt_after_request=False):
    global delay_response, requests, request_event
    delay_response = interrupt_after_request
    requests = []; request_event = threading.Event()
    case_dir = ROOT / "runs" / name
    case_dir.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    for key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"): env.pop(key, None)
    env.update({"CLAUDE_CONFIG_DIR": str(case_dir / "config"),
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{PORT}", "ANTHROPIC_API_KEY":"offline-capture-key",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1", "DISABLE_AUTOUPDATER":"1"})
    argv = [BIN, "-p", "--model", "haiku", "--setting-sources", "", "--strict-mcp-config",
        "--mcp-config", '{"mcpServers":{}}', "--tools", "", "--permission-mode", "dontAsk", "--effort", "low",
        "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--await-initialize"]
    proc = subprocess.Popen(argv, cwd=case_dir, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, bufsize=1)
    lines = queue.Queue()
    def read_stdout():
        for line in proc.stdout: lines.put(line.rstrip("\n"))
    threading.Thread(target=read_stdout, daemon=True).start()
    for frame in frames:
        proc.stdin.write(json.dumps(frame) + "\n"); proc.stdin.flush()
    if interrupt_after_request:
        if not request_event.wait(30): raise RuntimeError("mock API was never called")
        proc.stdin.write(json.dumps({"type":"control_request","request_id":"r_interrupt",
            "request":{"subtype":"interrupt","scope":"turn"}}) + "\n"); proc.stdin.flush()
    out=[]
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        try: line=lines.get(timeout=0.25)
        except queue.Empty:
            if proc.poll() is not None: break
            continue
        out.append(line)
        try: event=json.loads(line)
        except json.JSONDecodeError: continue
        if event.get("type")=="result":
            proc.stdin.close()
            break
    if not proc.stdin.closed: proc.stdin.close()
    try: proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.terminate(); proc.wait(timeout=3)
    while not lines.empty(): out.append(lines.get_nowait())
    err=proc.stderr.read()
    events=[]
    for line in out:
        try: event=json.loads(line)
        except json.JSONDecodeError: continue
        kind=event.get("type")
        if kind=="control_response":
            response=event.get("response",{})
            answer=response.get("response") or {}
            events.append({"type":kind,"request_id":response.get("request_id"),"subtype":response.get("subtype"),
                "response":({"mode":answer.get("mode")} if "mode" in answer else
                    {"still_queued":answer.get("still_queued")} if "still_queued" in answer else
                    {"capabilities":answer.get("capabilities"),"current_permission_mode":answer.get("current_permission_mode")} if "capabilities" in answer else {})})
        elif kind=="system": events.append({"type":kind,"subtype":event.get("subtype")})
        elif kind=="assistant": events.append({"type":kind,"text":"".join(c.get("text","") for c in event.get("message",{}).get("content",[]) if c.get("type")=="text")})
        elif kind=="user": events.append({"type":kind,"text":"".join(c.get("text","") for c in event.get("message",{}).get("content",[]) if c.get("type")=="text")})
        elif kind=="result": events.append({"type":kind,"subtype":event.get("subtype"),"is_error":event.get("is_error"),"result":event.get("result")})
    (case_dir / "stdout.jsonl").write_text("\n".join(json.dumps(e) for e in events)+("\n" if events else ""))
    (case_dir / "stderr.txt").write_text(err)
    request_summaries=[]
    for rec in requests:
        body=rec["body"]
        request_summaries.append({"path":rec["path"],"model":body.get("model"),"output_config":body.get("output_config"),
            "system_text":[x.get("text","") for x in body.get("system",[])],"stream":body.get("stream"),
            "tool_names":[x.get("name") for x in body.get("tools",[])]})
    (case_dir / "requests.json").write_text(json.dumps(request_summaries, indent=2)+"\n")
    (case_dir / "argv.json").write_text(json.dumps({"argv":argv,"cwd":str(case_dir),"endpoint":"127.0.0.1 loopback deterministic fake"},indent=2)+"\n")
    print(name, "exit", proc.returncode, "requests", len(requests), "stdout_lines", len(out))

initialize={"type":"control_request","request_id":"r_initialize","request":{"subtype":"initialize",
    "systemPrompt":"HOST_SYSTEM_SENTINEL","appendSystemPrompt":"HOST_APPEND_SENTINEL"}}
set_model={"type":"control_request","request_id":"r_model","request":{"subtype":"set_model","model":"sonnet"}}
set_permission={"type":"control_request","request_id":"r_permission","request":{"subtype":"set_permission_mode","mode":"acceptEdits"}}
user={"type":"user","message":{"role":"user","content":"Return CAPTURE_COMPLETE."}}
run_case("initialize-model-permission", [initialize,set_model,set_permission,user])
request_event.clear()
run_case("interrupt-during-turn", [initialize,user], interrupt_after_request=True)
server.shutdown()
print(f"runs: {ROOT / 'runs'}")
