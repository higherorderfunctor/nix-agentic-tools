#!/usr/bin/env python3
"""Scripted fake OpenAI Responses provider for the pinned Codex delegate probes.

usage: fp.py <port> <outdir> <scenario.json>

scenario.json maps an agent name (from x-codex-turn-metadata.agent_name,
e.g. "/root", "/root/a", "/root/a/g"; "root" when absent; "guardian" for
auto-review requests and "title" for the TUI's title side turn, each only when
that key is present) or "*" (fallback for any
unscripted agent) to a list of steps. The Nth request from an agent gets
step N; past the end it gets a final message "DONE <agent>".

step = {"calls": [[name, args_obj, namespace_or_null], ...],
        "msg": "text",            # final assistant message
        "raw": [item, ...],       # extra output items sent verbatim (e.g. {"type": "compaction", ...})
        "sleep": seconds,         # hold the stream open before completing
        "sleep_before": seconds}  # delay before sending anything

Every request body is saved as reqNN-<agent>-s<step>.json and summarized in
log.jsonl (agent, step, model, effort, sandbox, tool names, tail items,
aborted=true when the client hung up mid-stream).
"""
import http.server, json, sys, os, itertools, threading, time, collections

port = int(sys.argv[1]); out = sys.argv[2]; scen = json.load(open(sys.argv[3]))
os.makedirs(out, exist_ok=True)
n = itertools.count(); lock = threading.Lock(); steps = collections.Counter()
v1labels = {}
logf = open(os.path.join(out, "log.jsonl"), "a")

def ev(e): return f"event: {e['type']}\ndata: {json.dumps(e)}\n\n".encode()
def created(i): return {"type": "response.created", "response": {"id": i}}
def done(i): return {"type": "response.completed", "response": {"id": i, "usage": {"input_tokens": 0, "input_tokens_details": None, "output_tokens": 0, "output_tokens_details": None, "total_tokens": 0}}}
def msg(i, t): return {"type": "response.output_item.done", "item": {"type": "message", "role": "assistant", "id": "m" + i, "content": [{"type": "output_text", "text": t}]}}
def call(cid, name, args, ns):
    if ns == "custom":  # freeform custom tool (e.g. code-mode `exec`): args is the raw input string
        return {"type": "response.output_item.done", "item": {"type": "custom_tool_call", "call_id": cid, "name": name, "input": args}}
    it = {"type": "function_call", "call_id": cid, "name": name, "arguments": json.dumps(args)}
    if ns: it["namespace"] = ns
    return {"type": "response.output_item.done", "item": it}

def tool_names(body):
    res = []
    def walk(ts, pre=""):
        for t in ts or []:
            if "tools" in t: walk(t["tools"], pre + t.get("name", "") + ".")
            else: res.append(pre + str(t.get("name")))
    for it in body.get("input", []):
        if it.get("type") == "additional_tools": walk(it.get("tools"))
    walk(body.get("tools"))
    return res

def short(it):
    t = it.get("type")
    if t == "message":
        return [t, it.get("role"), " | ".join(c.get("text", "")[:300] for c in it.get("content", []))]
    if t == "function_call": return [t, it.get("name"), it.get("arguments", "")[:300]]
    if t == "custom_tool_call_output":
        o = it.get("output"); return [t, it.get("call_id"), (o if isinstance(o, str) else json.dumps(o))[:600]]
    if t == "function_call_output":
        o = it.get("output"); return [t, it.get("call_id"), (o if isinstance(o, str) else json.dumps(o))[:600]]
    if t == "agent_message":
        return [t, it.get("author"), it.get("recipient"), " | ".join((c.get("text") or c.get("encrypted_content") or "")[:300] for c in it.get("content", []))]
    return [t, json.dumps(it)[:300]]

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        try: body = json.loads(raw)
        except Exception: body = {}
        cm = body.get("client_metadata") or {}
        try: md = json.loads(cm.get("x-codex-turn-metadata", "{}"))
        except Exception: md = {}
        agent = md.get("agent_name") or "root"
        # auto-review (guardian) requests carry the reviewed session's agent_name; a scenario with a
        # "guardian" key scripts them separately instead of letting them consume that agent's steps
        if "guardian" in scen and cm.get("x-openai-subagent") == "guardian": agent = "guardian"
        # the TUI's title side turn reports the root's agent_name too; a "title" key scripts it apart
        if "title" in scen and b"single-line task title" in raw: agent = "title"
        with lock:
            # V1 children report agent_name "/root"; label them v1c1, v1c2... by first-seen thread id
            if md.get("subagent_kind") == "thread_spawn" and agent == "/root":
                tid = md.get("thread_id")
                if tid not in v1labels: v1labels[tid] = f"v1c{len(v1labels) + 1}"
                agent = v1labels[tid]
            i = next(n); s = steps[agent]; steps[agent] += 1
        plan = scen.get(agent, scen.get("*", []))
        step = plan[s] if s < len(plan) else {"msg": f"DONE {agent}"}
        rid = f"resp_{i}"
        fname = f"req{i:02d}-{agent.strip('/').replace('/', '_') or 'root'}-s{s}.json"
        open(os.path.join(out, fname), "wb").write(raw)
        inp = body.get("input", [])
        # tail = items after the last non-initial developer/user context block
        tail = [short(x) for x in inp if x.get("type") != "additional_tools"][-12:]
        rec = {"i": i, "t": round(time.time(), 2), "agent": agent, "step": s, "model": body.get("model"),
               "effort": (body.get("reasoning") or {}).get("effort"), "sandbox": md.get("sandbox_mode"),
               "subagent": cm.get("x-openai-subagent"), "tools": tool_names(body), "tail": tail, "file": fname}
        with lock:
            logf.write(json.dumps({"start": i, "t": rec["t"], "agent": agent, "step": s}) + "\n"); logf.flush()
        time.sleep(step.get("sleep_before", 0))
        # "$AGENT_ID" in call args -> agent_id from the latest spawn output seen in the input (V1)
        aid = None
        for x in inp:
            if x.get("type") == "function_call_output":
                try: o = json.loads(x.get("output") if isinstance(x.get("output"), str) else "{}")
                except Exception: o = {}
                if isinstance(o, dict) and o.get("agent_id"): aid = o["agent_id"]
        def subst(v):
            if isinstance(v, str): return v.replace("$AGENT_ID", aid or "NO_AGENT_ID")
            if isinstance(v, dict): return {k: subst(w) for k, w in v.items()}
            if isinstance(v, list): return [subst(w) for w in v]
            return v
        evs = [created(rid)]
        for k, c in enumerate(step.get("calls", [])):
            name, args = c[0], c[1]; ns = c[2] if len(c) > 2 else None
            evs.append(call(f"call_{i}_{k}", name, subst(args), ns))
        for item in step.get("raw", []):
            evs.append({"type": "response.output_item.done", "item": item})
        if "msg" in step: evs.append(msg(rid, step["msg"]))
        aborted = False
        try:
            self.send_response(200); self.send_header("content-type", "text/event-stream")
            self.send_header("connection", "close"); self.end_headers()
            self.wfile.write(ev(evs[0])); self.wfile.flush()
            if step.get("sleep"):
                end = time.time() + step["sleep"]
                while time.time() < end:
                    time.sleep(0.5)
                    self.wfile.write(b": keepalive\n\n"); self.wfile.flush()
            for e in evs[1:] + [done(rid)]: self.wfile.write(ev(e))
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            aborted = True
        rec["aborted"] = aborted; rec["t_end"] = round(time.time(), 2)
        with lock:
            logf.write(json.dumps(rec) + "\n"); logf.flush()
        self.close_connection = True
    def do_GET(self):
        self.send_response(404); self.send_header("content-length", "0"); self.end_headers()
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
