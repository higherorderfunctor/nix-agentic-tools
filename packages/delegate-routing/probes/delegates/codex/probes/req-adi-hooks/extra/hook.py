#!/usr/bin/env python3
# Probe hook: logs stdin; answers every context-injecting event with a per-event sentinel.
import json, os, sys
inp = json.load(sys.stdin)
home = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(home, "hooks.jsonl"), "a").write(json.dumps(inp) + "\n")
ev = inp.get("hook_event_name")
sent = {"SessionStart": "HOOK-SESSSTART-4002", "UserPromptSubmit": "HOOK-UPS-4003",
        "SubagentStart": "HOOK-SUBSTART-4004", "PostToolUse": "HOOK-POSTTOOL-4005"}.get(ev)
out = {"hookSpecificOutput": {"hookEventName": ev, "additionalContext": sent}} if sent else {}
print(json.dumps(out))
