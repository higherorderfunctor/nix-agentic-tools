"""Offline probe harness: runs the PINNED claude binary against a scripted
Anthropic-API mock on 127.0.0.1. No real account, fake key.

Usage: python3 harness.py <case> [<case> ...]   (cases defined in cases.py)
Scratch lives in $CLAUDE_PROBE_WORK (default: a fresh temp dir, printed first):
fixture/ (rebuilt by mkfixture.sh), cfg/<case>/ (CLAUDE_CONFIG_DIR) and
out/<case>/{NNN.json (request), argv.json, stdout, stderr, debug.log, summary.json}.
The binary is the repository's pinned claude-code (override: CLAUDE_PKG=<store path>).
"""
import json, os, pathlib, subprocess, sys, threading, time, shutil
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S.parent / "common"))
import pin  # noqa: E402

# cases.py re-imports this module, so the scratch dir and binary are fixed once via the environment.
WORK = pathlib.Path(os.environ.get("CLAUDE_PROBE_WORK") or pin.workdir("claude"))
os.environ["CLAUDE_PROBE_WORK"] = str(WORK)
PORT = int(os.environ.get("MOCK_PORT", "18777"))

STATE = {"case": None, "n": 0, "inflight": 0, "max_inflight": 0, "log": [], "fn": None, "data": {}}
LOCK = threading.Lock()


def role(body):
    sys0 = ""
    s = body.get("system")
    if isinstance(s, list) and s:
        sys0 = s[0].get("text", "")
    full = json.dumps(s) if s else ""
    if "cc_is_subagent=true" in sys0:
        if "workflow" in full.lower() and "returning data to a program" in full.lower():
            return "wfchild"
        return "child"
    return "main"


def last_user_has_tool_result(body):
    msgs = body.get("messages", [])
    if not msgs:
        return False
    m = msgs[-1]
    c = m.get("content")
    return m.get("role") == "user" and isinstance(c, list) and any(
        isinstance(x, dict) and x.get("type") == "tool_result" for x in c)


def tool_results(body):
    out = []
    for m in body.get("messages", []):
        c = m.get("content")
        if isinstance(c, list):
            for x in c:
                if isinstance(x, dict) and x.get("type") == "tool_result":
                    out.append(x)
    return out


def text_of(body):
    return json.dumps(body.get("messages", []))


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers()

    def do_POST(self):
        b = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        try:
            d = json.loads(b)
        except Exception:
            d = {"raw": b.decode(errors="replace")}
        if "count_tokens" in self.path:
            r = b'{"input_tokens":100}'
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(r))); self.end_headers(); self.wfile.write(r); return
        out = WORK / "out" / STATE["case"]
        with LOCK:
            STATE["n"] += 1
            n = STATE["n"]
            STATE["inflight"] += 1
            STATE["max_inflight"] = max(STATE["max_inflight"], STATE["inflight"])
            (out / f"{n:03}.json").write_text(json.dumps({"path": self.path, "t": time.time(),
                                                           "headers": dict(self.headers), "body": d}, indent=1))
        try:
            content, stop, delay = STATE["fn"](d, n, STATE)
        except Exception as e:  # never crash the mock
            content, stop, delay = [{"type": "text", "text": f"MOCK_ERROR {e!r}"}], "end_turn", 0
        if delay:
            import select, socket
            end = time.time() + delay
            while time.time() < end:
                r, _, _ = select.select([self.connection], [], [], 0.2)
                if r:
                    try:
                        peek = self.connection.recv(1, socket.MSG_PEEK)
                    except Exception:
                        peek = b""
                    if peek == b"":
                        with LOCK:
                            STATE["inflight"] -= 1
                            STATE["log"].append({"n": n, "role": role(d), "model": d.get("model"), "tools": [],
                                                 "thinking": None, "output_config": None, "effort": None,
                                                 "reply": [f"CLIENT_CLOSED after {round(delay-(end-time.time()),1)}s"]})
                        return
        with LOCK:
            STATE["inflight"] -= 1
            STATE["log"].append({"n": n, "role": role(d), "model": d.get("model"),
                                 "tools": [t.get("name") for t in d.get("tools", [])],
                                 "thinking": d.get("thinking"), "output_config": d.get("output_config"),
                                 "effort": d.get("effort"),
                                 "reply": [c.get("name") or c.get("text", "")[:40] for c in content]})
        msg = {"id": f"msg_{n}", "type": "message", "role": "assistant", "model": d.get("model", "x"),
               "content": content, "stop_reason": stop, "stop_sequence": None,
               "usage": {"input_tokens": 100, "output_tokens": 10}}
        if d.get("stream"):
            chunks = []
            def ev(t, x):
                chunks.append(("event: " + t + "\ndata: " + json.dumps(x) + "\n\n").encode())
            ev("message_start", {"type": "message_start", "message": {**msg, "content": [], "stop_reason": None,
                                                                       "usage": {"input_tokens": 100, "output_tokens": 0}}})
            for i, c in enumerate(content):
                start = {**c, **({"input": {}} if c["type"] == "tool_use" else {"text": ""})}
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": start})
                delta = ({"type": "text_delta", "text": c["text"]} if c["type"] == "text"
                         else {"type": "input_json_delta", "partial_json": json.dumps(c["input"])})
                ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": delta})
                ev("content_block_stop", {"type": "content_block_stop", "index": i})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                 "usage": {"output_tokens": 10}})
            ev("message_stop", {"type": "message_stop"})
            body = b"".join(chunks)
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            r = json.dumps(msg).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(r))); self.end_headers(); self.wfile.write(r)


def base_env(cfg):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE") and k not in ("ANTHROPIC_API_KEY",)}
    env.update({"CLAUDE_CONFIG_DIR": str(cfg), "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{PORT}",
                "ANTHROPIC_API_KEY": "mock-not-a-real-key", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "DISABLE_AUTOUPDATER": "1"})
    return env


def run_case(name, spec):
    out = WORK / "out" / name
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    cfg = WORK / "cfg" / name
    if cfg.exists():
        shutil.rmtree(cfg)
    cfg.mkdir(parents=True)
    if spec.get("prep"):
        spec["prep"]()
    STATE.pop("pw_type", None)
    STATE.update({"case": name, "n": 0, "inflight": 0, "max_inflight": 0, "log": [], "fn": spec["fn"], "data": {}})
    env = base_env(cfg)
    env.update(spec.get("env", {}))
    cwd = spec.get("cwd", str(WORK / "fixture"))
    argv = [os.environ["CLAUDE_BIN"]] + spec["argv"] + ["--debug-file", str(out / "debug.log")]
    (out / "argv.json").write_text(json.dumps({"argv": argv, "cwd": cwd, "env_overrides": spec.get("env", {}),
                                               "stdin": spec.get("stdin")}, indent=1))
    t0 = time.time()
    if spec.get("driver"):
        rc, so, se = spec["driver"](argv, cwd, env, out)
    else:
        try:
            r = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True,
                               timeout=spec.get("timeout", 90), input=spec.get("stdin", ""))
            rc, so, se = r.returncode, r.stdout, r.stderr
        except subprocess.TimeoutExpired as e:
            rc, so, se = "TIMEOUT", (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), str(e)
    (out / "stdout").write_text(so or "")
    (out / "stderr").write_text(se or "")
    summ = {"rc": rc, "secs": round(time.time() - t0, 1), "requests": STATE["n"],
            "max_inflight": STATE["max_inflight"], "log": STATE["log"], "data": STATE["data"]}
    (out / "summary.json").write_text(json.dumps(summ, indent=1, default=str))
    print(f"== {name}: rc={rc} secs={summ['secs']} requests={STATE['n']} max_inflight={STATE['max_inflight']}")
    for l in STATE["log"]:
        print("  ", l["n"], l["role"], l["model"], "tools=", len(l["tools"]), "eff=", l["output_config"] or l["effort"],
              "think=", (l["thinking"] or {}).get("type"), "->", l["reply"])
    print("  stderr tail:", (se or "")[-300:].replace("\n", " | "))


def serve():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    os.environ.setdefault("CLAUDE_BIN", str(pin.package("claude-code") / "bin" / "claude"))
    print(f"work: {WORK}")
    if not (WORK / "fixture").exists():
        subprocess.run([str(S / "mkfixture.sh"), str(WORK / "fixture")], check=True)
    sys.path.insert(0, str(S))
    import cases
    srv = serve()
    for c in sys.argv[1:]:
        run_case(c, cases.CASES[c])
    srv.shutdown()
