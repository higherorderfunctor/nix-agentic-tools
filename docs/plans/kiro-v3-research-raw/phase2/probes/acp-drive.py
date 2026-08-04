#!/usr/bin/env python3
"""Generalized ACP method driver, derived from the mode-F harness acp-probe.py.

KEEPS (load-bearing, do not simplify away):
  - id-matching inbox loop: the agent interleaves REQUESTS toward the client
    (notably _kiro/auth/getAccessToken); naive send/read pairs wrong messages.
  - token refusal via JSON-RPC ERROR — this client never reads the operator's
    credential store, so nothing here can spend credits.
  - newline-delimited JSON-RPC framing (the ACP SDK splits on newlines).
  - stderr pumped to a list, never a blocked pipe.
  - teardown: close stdin -> wait -> killpg (start_new_session gives us a pgid).

ADDS: scripted step files, ${VAR} substitution, verbatim frame capture to
JSONL, agent->client request logging (which call triggered what), per-step
timeouts with stall attribution.

Usage: acp-drive.py <probe-name> <scratch-home> <workspace> <steps.json> <frames.jsonl> [definition.json]

Step file: JSON list of {"label"?, "method", "params"?, "timeout"?, "save"?: {"VAR": "dotted.path"}}.
String values equal to "${DEFINITION}" are replaced by the loaded definition
object; "${VAR}" tokens inside strings are replaced textually.
"""

import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time

PROBE = sys.argv[1]
SCRATCH = sys.argv[2]
WORKSPACE = sys.argv[3]
SCRIPT_PATH = sys.argv[4]
FRAMES = sys.argv[5]
DEFINITION = json.load(open(sys.argv[6])) if len(sys.argv) > 6 else None

KIRO = "/nix/store/3xcnc3lw1r36ngzkifxjxd82r2sh8jz2-kiro-cli-2.15.1/bin/kiro-cli"

env = dict(os.environ)
env["HOME"] = SCRATCH
env["KIRO_LOG_LEVEL"] = "debug"
# XDG_DATA_HOME deliberately untouched (real): redirecting it empties the auth
# DB and triggers an interactive browser login.

frames_fh = open(FRAMES, "a")


def log_frame(direction, obj):
    frames_fh.write(json.dumps({"t": round(time.time(), 3), "dir": direction, "msg": obj}) + "\n")
    frames_fh.flush()


proc = subprocess.Popen(
    [KIRO, "acp", "--agent-engine", "v3"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    env=env, text=True, bufsize=1, start_new_session=True,
)

inbox: "queue.Queue" = queue.Queue()
err_lines = []
client_requests = []  # every agent->client request we refused


def pump_out(stream):
    for line in stream:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log_frame("in-unparsed", line)
            continue
        log_frame("in", msg)
        inbox.put(msg)
    inbox.put(None)


def pump_err(stream):
    for line in stream:
        err_lines.append(line.rstrip("\n"))


threading.Thread(target=pump_out, args=(proc.stdout,), daemon=True).start()
threading.Thread(target=pump_err, args=(proc.stderr,), daemon=True).start()


def send(obj):
    log_frame("out", obj)
    try:
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()
        return True
    except (BrokenPipeError, ValueError):
        return False


def await_id(target_id, during, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            msg = inbox.get(timeout=max(0.5, deadline - time.time()))
        except queue.Empty:
            break
        if msg is None:
            return {"__eof__": True, "exit": proc.poll()}
        if "method" in msg and "id" in msg:
            # agent->client request: refuse, never read the credential store
            client_requests.append({"during": during, "method": msg["method"],
                                    "params": msg.get("params")})
            send({"jsonrpc": "2.0", "id": msg["id"],
                  "error": {"code": -32601, "message": "probe client supplies no tokens"}})
            continue
        if "method" in msg:
            continue  # notification; already in frames
        if msg.get("id") == target_id:
            return msg
    return {"__timeout__": True, "exit": proc.poll()}


variables = {"WORKSPACE": WORKSPACE, "SCRATCH": SCRATCH}


def subst(x):
    if isinstance(x, str):
        if x == "${DEFINITION}":
            return DEFINITION
        for k, v in variables.items():
            x = x.replace("${" + k + "}", str(v))
        return x
    if isinstance(x, dict):
        return {k: subst(v) for k, v in x.items()}
    if isinstance(x, list):
        return [subst(v) for v in x]
    return x


def dig(obj, path):
    for part in path.split("."):
        if not isinstance(obj, dict):
            return None
        obj = obj.get(part)
    return obj


steps = json.load(open(SCRIPT_PATH))
out = []
i = 0
for step in steps:
    i += 1
    if proc.poll() is not None:
        out.append({"label": step.get("label"), "skipped": "engine exited", "exit": proc.poll()})
        continue
    params = subst(step.get("params", {}))
    label = step.get("label", step["method"])
    send({"jsonrpc": "2.0", "id": i, "method": step["method"], "params": params})
    resp = await_id(i, label, step.get("timeout", 45))
    out.append({"label": label, "method": step["method"], "params": params, "resp": resp})
    for var, path in (step.get("save") or {}).items():
        val = dig(resp.get("result") if isinstance(resp, dict) else None, path)
        if val is not None:
            variables[var] = val

# teardown: close stdin -> wait -> killpg, then verify
try:
    proc.stdin.close()
except Exception:
    pass
try:
    proc.wait(timeout=8)
except subprocess.TimeoutExpired:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=5)

print(json.dumps({
    "probe": PROBE,
    "kasid_expected": "2.15.1",
    "steps": out,
    "client_requests_refused": client_requests,
    "variables": {k: v for k, v in variables.items() if k not in ("WORKSPACE", "SCRATCH")},
    "engine_exit": proc.poll(),
    "stderr_tail": err_lines[-20:],
}, indent=2, default=str))
