#!/usr/bin/env python3
"""Minimal stdio MCP server for codex:P1.mcp-hook: one tool, `ctx`, called by `mcp_tool` hook handlers.

It answers with command-hook output JSON whose additionalContext is a per-event sentinel, and logs
every tools/call to mcphook.jsonl beside this file.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SENT = {"SessionStart": "MCPHOOK-SESSSTART-4012", "UserPromptSubmit": "MCPHOOK-UPS-4013",
        "SubagentStart": "MCPHOOK-SUBSTART-4014", "PostToolUse": "MCPHOOK-POSTTOOL-4015"}
TOOL = {"name": "ctx", "description": "probe hook context",
        "inputSchema": {"type": "object", "properties": {"event": {"type": "string"}}}}


def reply(mid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    msg = json.loads(line)
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:
        continue  # notifications
    if method == "initialize":
        reply(mid, {"protocolVersion": msg["params"].get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "hookmcp", "version": "0"}})
    elif method == "tools/list":
        reply(mid, {"tools": [TOOL]})
    elif method == "tools/call":
        args = msg["params"].get("arguments") or {}
        with open(os.path.join(HERE, "mcphook.jsonl"), "a") as log:
            log.write(json.dumps(msg["params"]) + "\n")
        ev = args.get("event")
        out = {"hookSpecificOutput": {"hookEventName": ev, "additionalContext": SENT[ev]}} if ev in SENT else {}
        reply(mid, {"content": [{"type": "text", "text": json.dumps(out)}], "isError": False})
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": method}}) + "\n")
        sys.stdout.flush()
