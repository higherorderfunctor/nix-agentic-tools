#!/usr/bin/env python3
# Probe hook: logs its stdin and answers per event (offline replay only).
import json, sys, os
inp = json.load(sys.stdin)
home = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(home, "hooks.jsonl"), "a").write(json.dumps(inp) + "\n")
ev = inp.get("hook_event_name")
out = {}
if ev == "SubagentStart":
    out = {"hookSpecificOutput": {"hookEventName": "SubagentStart", "additionalContext": "HOOK-SUBSTART-CTX for " + str(inp.get("agent_type"))}}
elif ev == "SubagentStop":
    mark = os.path.join(home, "stopped-" + str(inp.get("agent_id")))
    if not os.path.exists(mark) and not inp.get("stop_hook_active"):
        open(mark, "w").write("1")
        out = {"decision": "block", "reason": "HOOK-SUBSTOP-CONTINUE"}
elif ev == "PreToolUse":
    if "DENYME" in json.dumps(inp.get("tool_input")):
        out = {"decision": "block", "reason": "HOOK-DENIED-SPAWN"}
print(json.dumps(out))
