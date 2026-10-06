"""codex:C — delegate tool schemas and executed tool_use/tool_result pairs from the
system-prompt capture cases (sysprompt/capture.sh writes them).

usage: python3 capture_inventory.py <captures-dir> [<out.json>]
<captures-dir> holds k4-agents/, k6-fork/, k6-nested/, k7-workflow/, k3-sdk/, k8-hooks/ with req-*.json.
"""
import json
import sys
from pathlib import Path

if len(sys.argv) < 2:
    sys.exit(__doc__)
prior = Path(sys.argv[1])
wanted = {"Agent", "Task", "Workflow", "SendMessage", "TaskStop", "TaskOutput", "Monitor", "ListAgents", "TeamCreate", "TeamDelete"}
out = {}
for name in ["k4-agents", "k6-fork", "k6-nested", "k7-workflow", "k3-sdk", "k8-hooks"]:
    case = {"schemas": {}, "results": []}
    for f in sorted((prior / name).glob("req-*.json")):
        body = json.loads(f.read_text())["body"]
        for t in body.get("tools", []):
            if t["name"] in wanted:
                case["schemas"].setdefault(t["name"], {"capture": f"{name}/{f.name}", "description": t.get("description"), "input_schema": t.get("input_schema")})
        for m in body.get("messages", []):
            for c in m.get("content", []) if isinstance(m.get("content"), list) else []:
                if c.get("type") in {"tool_use", "tool_result"} and c not in case["results"]:
                    case["results"].append(c)
    out[name] = case
if len(sys.argv) > 2:
    Path(sys.argv[2]).write_text(json.dumps(out, indent=2) + "\n")
for k, v in out.items():
    print(k, "tools", list(v["schemas"]), "events", len(v["results"]))
