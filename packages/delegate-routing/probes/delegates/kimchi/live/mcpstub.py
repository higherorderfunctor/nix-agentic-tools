"""Minimal stdio MCP server for the exit-after-settle probe. usage: mcpstub.py <log.jsonl>

Answers initialize, tools/list (one tool, stub_echo), tools/call and ping; any other
request gets a method-not-found error. Appends one JSONL record per lifecycle event to
<log.jsonl>: start (pid), every request method, stdin EOF, each SIGTERM/SIGINT/SIGHUP it
receives, and exit. A run whose client never closes the transport shows `start` with no
`eof` and no signal.
"""
import json, os, signal, sys, time

LOG = sys.argv[1]


def log(event, **extra):
    with open(LOG, "a") as f:
        f.write(json.dumps({"t": round(time.time(), 3), "pid": os.getpid(), "event": event, **extra}) + "\n")


def on_signal(signum, _frame):
    log("signal", signal=signal.Signals(signum).name)
    log("exit", reason="signal")
    sys.exit(0)


for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(s, on_signal)


def reply(rid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": rid}
    msg.update({"error": error} if error else {"result": result})
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


log("start")
for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method = msg.get("method")
    log("request" if "id" in msg else "notification", method=method)
    if "id" not in msg:
        continue
    params = msg.get("params") or {}
    if method == "initialize":
        reply(msg["id"], {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                          "capabilities": {"tools": {}}, "serverInfo": {"name": "mcpstub", "version": "0"}})
    elif method == "tools/list":
        reply(msg["id"], {"tools": [{"name": "stub_echo", "description": "Echo the text back.",
                                     "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]})
    elif method == "tools/call":
        reply(msg["id"], {"content": [{"type": "text", "text": json.dumps(params.get("arguments", {}))}]})
    elif method == "ping":
        reply(msg["id"], {})
    else:
        reply(msg["id"], error={"code": -32601, "message": f"method not found: {method}"})
log("eof")
log("exit", reason="eof")
