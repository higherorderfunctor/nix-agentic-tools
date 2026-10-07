#!/usr/bin/env python3
"""Drive `codex app-server` (stdio JSON-RPC) through one probe.

usage: asclient.py <CODEX_HOME> <outdir> <cwd> <probe.json>

probe.json:
  {"thread": {thread/start params}, "turn": "user text", "turn_params": {...},
   "actions": [{"at": secs_after_turn_start, "method": "...", "params": {...}}],
   "approval": "decline" | "accept" | "none",  # answer to server approval requests; none = never answer
   "resume": "as/thread_id",  # thread/resume the id in that file (relative to <outdir>/..) instead of thread/start
   "attach": false,  # with resume: set $THREAD only, no thread/resume;   "turn": null starts no turn
   "transport": "daemon",  # attach to the shared daemon in CODEX_HOME (wsuds.py) instead of an embedded app-server
   "timeout": 60, "after": [{"method": ..., "params": ..., "wait": secs_to_pump_after}],
   "extra_args": ["--dangerously-bypass-hook-trust"]}
"$THREAD"/"$TURN" in params are substituted. Everything is logged to
<outdir>/as.jsonl ('>' sent, '<' received) and stderr to <outdir>/as.err.
"""
import subprocess, json, sys, os, time, threading, queue

home, out, cwd, probe = sys.argv[1], sys.argv[2], sys.argv[3], json.load(open(sys.argv[4]))
os.makedirs(out, exist_ok=True)
env = dict(os.environ, CODEX_HOME=home, FAKE_KEY="x")
# "transport": "daemon" attaches to the shared daemon in CODEX_HOME through wsuds.py (its control socket
# speaks WebSocket) instead of an embedded app-server; terminating the bridge is a client disconnect.
if probe.get("transport") == "daemon":
    argv = [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "wsuds.py"),
            os.path.join(home, "app-server-control", "app-server-control.sock")]
else:
    argv = [os.environ.get("CODEX_BIN", "codex"), "--no-daemon", "app-server"] + probe.get("extra_args", [])
p = subprocess.Popen(argv, stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=open(out + "/as.err", "w"), env=env, text=True, cwd=cwd)
q = queue.Queue()
threading.Thread(target=lambda: [q.put(l) for l in p.stdout], daemon=True).start()
log = open(out + "/as.jsonl", "w")
T0 = time.time()
ctx = {"$THREAD": None, "$TURN": None, "$CHILD": None, "$CHILDTURN": None}
nid = [100]

def sub(o):
    if isinstance(o, str): return ctx.get(o, o) if o in ctx else o
    if isinstance(o, dict): return {k: sub(v) for k, v in o.items()}
    if isinstance(o, list): return [sub(v) for v in o]
    return o

def send(o):
    p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
    log.write(json.dumps({"t": round(time.time() - T0, 2), "dir": ">", "msg": o}) + "\n"); log.flush()

def handle(m):
    # remember the first spawned child thread and its latest turn id
    if m.get("method") in ("item/started", "item/completed"):
        it = m.get("params", {}).get("item", {})
        if it.get("type") == "subAgentActivity" and ctx["$CHILD"] is None: ctx["$CHILD"] = it.get("agentThreadId")
    if m.get("method") == "turn/started" and m.get("params", {}).get("threadId") == ctx["$CHILD"] and ctx["$CHILD"]:
        ctx["$CHILDTURN"] = m["params"]["turn"]["id"]
    # answer server->client requests
    if "id" in m and "method" in m:
        meth = m["method"]
        if probe.get("approval") == "none" and ("requestApproval" in meth or meth in ("execCommandApproval", "applyPatchApproval")):
            return  # left unanswered: approval-deadline probes
        if "requestApproval" in meth or meth in ("execCommandApproval", "applyPatchApproval"):
            dec = "accept" if probe.get("approval") == "accept" else "decline"
            if meth in ("execCommandApproval", "applyPatchApproval"):
                dec = "approved" if dec == "accept" else "denied"
            send({"id": m["id"], "result": {"decision": dec}})
        elif meth == "item/tool/requestUserInput":
            send({"id": m["id"], "result": {"answers": {}}})
        else:
            send({"id": m["id"], "error": {"code": -32601, "message": "probe client: unsupported"}})

def pump(until=None, timeout=30, stop_method=None, stop_pred=None):
    end = time.time() + timeout
    while time.time() < end:
        try: l = q.get(timeout=0.2)
        except queue.Empty:
            if p.poll() is not None: return None
            continue
        try: m = json.loads(l)
        except Exception:
            log.write(json.dumps({"t": round(time.time() - T0, 2), "dir": "<raw", "msg": l}) + "\n"); continue
        log.write(json.dumps({"t": round(time.time() - T0, 2), "dir": "<", "msg": m}) + "\n"); log.flush()
        handle(m)
        if until is not None and m.get("id") == until and "method" not in m: return m
        if stop_pred and stop_pred(m): return m
    return None

def req(method, params, timeout=30):
    nid[0] += 1; i = nid[0]
    send({"id": i, "method": method, "params": sub(params)})
    return pump(until=i, timeout=timeout)

send({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "probe", "title": "probe", "version": "0"}, "capabilities": {"experimentalApi": True}}})
pump(until=1); send({"method": "initialized"})
if probe.get("resume"):  # a later client or app-server process picks up a thread an earlier one created
    tid_file = os.path.join(os.path.dirname(os.path.abspath(out)), probe["resume"])  # relative to the results dir
    tid = open(tid_file).read().strip()
    if probe.get("attach", True):
        r = req("thread/resume", dict(probe.get("thread", {}), threadId=tid))
        ctx["$THREAD"] = r["result"]["thread"]["id"]
    else:  # "attach": false: only $THREAD is set; the "after" requests observe without subscribing
        ctx["$THREAD"] = tid
else:
    r = req("thread/start", probe.get("thread", {}))
    ctx["$THREAD"] = r["result"]["thread"]["id"]
open(out + "/thread_id", "w").write(ctx["$THREAD"])
if probe.get("turn", "GO") is not None:  # "turn": null starts no turn
    tp = dict(probe.get("turn_params", {}))
    tp.update({"threadId": "$THREAD", "input": [{"type": "text", "text": probe.get("turn", "GO"), "text_elements": []}]})
    r = req("turn/start", tp)
    ctx["$TURN"] = (r or {}).get("result", {}).get("turn", {}).get("id")
TS = time.time()
root_done = lambda m: m.get("method") == "turn/completed" and m.get("params", {}).get("threadId") == ctx["$THREAD"]
deadline = TS + probe.get("timeout", 60)
finished = None
for a in sorted(probe.get("actions", []), key=lambda a: a["at"]):
    wait = TS + a["at"] - time.time()
    if wait > 0:
        finished = pump(timeout=wait, stop_pred=root_done)
        if finished and not a.get("after_done"): break
    req(a["method"], a.get("params", {}), timeout=a.get("timeout", 15))
if not finished:
    finished = pump(timeout=max(1, deadline - time.time()), stop_pred=root_done)
pump(timeout=probe.get("settle", 3))
for a in probe.get("after", []):
    req(a["method"], a.get("params", {}))
    if a.get("wait"): pump(timeout=a["wait"])
log.write(json.dumps({"t": round(time.time() - T0, 2), "dir": "#", "msg": {"root_turn_completed": bool(finished)}}) + "\n")
if ctx["$CHILD"]: open(out + "/child_id", "w").write(ctx["$CHILD"])  # first spawned child, for a later "resume"
p.terminate()
try: p.wait(5)
except Exception: p.kill()
