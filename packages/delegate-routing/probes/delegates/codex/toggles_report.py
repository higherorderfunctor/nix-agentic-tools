#!/usr/bin/env python3
"""toggles_report.py <variants.txt> <results-dir> — multi-agent tool surface of each toggles-<variant> run."""
import json, glob, os, re, sys
if len(sys.argv) != 3:
    sys.exit(__doc__)
V, R = sys.argv[1], sys.argv[2]
for line in open(V):
    name = line.split("|")[0]
    reqs = sorted(glob.glob(f"{R}/toggles-{name}/wire/req00-*.json"))
    if not reqs:
        err = open(f"{R}/toggles-{name}/as/as.err").read()[-300:] if os.path.exists(f"{R}/toggles-{name}/as/as.err") else ""
        print(f"{name:24} NO REQUEST {err!r}"); continue
    b = json.load(open(reqs[0]))
    ts = (b["input"][0].get("tools") if b["input"] and b["input"][0].get("type") == "additional_tools" else None) or b.get("tools") or []
    agent_tools, nested, spawn_params = [], [], None
    for t in ts:
        for x in t.get("tools", [t]):
            nm = f"{t.get('name')}.{x.get('name')}" if "tools" in t else x.get("name")
            if any(k in (nm or "") for k in ("agent", "send_", "followup", "list_agents", "close", "resume")): agent_tools.append(nm)
            if x.get("name") == "spawn_agent": spawn_params = sorted(x["parameters"]["properties"])
            if x.get("name") == "exec" and x.get("description"):
                nested = [n for n in re.findall(r"### `([a-z_0-9]+)`", x["description"]) if "agent" in n or n in ("send_message", "followup_task", "send_input")]
    blocks = [c.get("text", "")[:18] for it in b["input"] if it.get("type") == "message" and it.get("role") == "developer" for c in it["content"] if c.get("text", "").startswith("<multi_agent")]
    print(f"{name:24} model={b['model']:<13} tools={','.join(agent_tools) or '-'} nested_in_exec={','.join(nested) or '-'} spawn_params={spawn_params} blocks={blocks}")
