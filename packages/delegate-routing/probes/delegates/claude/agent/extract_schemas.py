#!/usr/bin/env python3
"""codex:A — print delegate tool input schemas from captured request bodies.

usage: python3 extract_schemas.py <captures-dir> <mcp-serve-transcript.json>
<captures-dir>: output of ../sysprompt/capture.sh (k4-agents/, k6-fork/, k6-nested/).
<mcp-serve-transcript.json>: runs/mcp-serve/transcript.json from ../host/mcp-replay.py.
Parses request JSON `body.tools[]`; it does not infer schema from prose.
"""
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    sys.exit(__doc__)
root = Path(sys.argv[1])
for case in ("k4-agents", "k6-fork", "k6-nested"):
    print(f"## {case}")
    seen = set()
    for request in sorted((root / case).glob("req-*.json")):
        body = json.loads(request.read_text())["body"]
        for tool in body.get("tools", []):
            if tool.get("name") not in {"Agent", "Workflow", "SendMessage", "TaskStop", "TaskGet", "TaskList", "Monitor"}:
                continue
            name = tool["name"]
            if name in seen:
                continue
            seen.add(name)
            print(f"### {name} ({request.name})")
            print(json.dumps(tool.get("input_schema", {}), indent=2, sort_keys=True))

# The separately launched local MCP host advertises a mode-specific schema.
print("## mcp-serve host tool listing")
for tool in json.loads(Path(sys.argv[2]).read_text())["tools_list"]["result"]["tools"]:
    if tool.get("name") in {"Agent", "Workflow", "SendMessage", "TaskStop"}:
        print(f"### {tool['name']} aliases={tool.get('aliases')} backgrounding={tool.get('backgrounding')}")
        print(json.dumps(tool.get("inputSchema", {}), indent=2, sort_keys=True))
