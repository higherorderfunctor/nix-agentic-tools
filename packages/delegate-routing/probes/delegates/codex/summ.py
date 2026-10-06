#!/usr/bin/env python3
"""summ.py <results/probe> [--tools] — print wire log summary and key app-server events."""
import json, sys
R = sys.argv[1]; show_tools = "--tools" in sys.argv
NOISE = ("item/agentMessage/delta", "item/reasoning", "thread/tokenUsage", "account/rateLimits", "mcpServer/startupStatus", "skills/changed", "turn/diff")
for l in open(R + "/wire/log.jsonl"):
    r = json.loads(l)
    if "start" in r: continue
    tools = [t for t in r["tools"] if t.split(".")[0] in ("collaboration", "multi_agent_v1", "agents")] if not show_tools else r["tools"]
    print(f"#{r['i']:02d} {r['agent']:<12} s{r['step']} model={r['model']} effort={r['effort']} sandbox={r['sandbox']} sub={r['subagent']} aborted={r['aborted']} dur={round(r['t_end']-r['t'],1)}")
    print("     tools:", ",".join(tools))
    for x in r["tail"][-6:]:
        if x[0] in ("function_call_output", "custom_tool_call_output", "agent_message") or (x[0] == "message" and x[1] == "user"):
            print("     ", json.dumps(x)[:400])
started = {json.loads(l)["start"]: json.loads(l) for l in open(R + "/wire/log.jsonl") if '"start"' in l}
ended = {json.loads(l)["i"] for l in open(R + "/wire/log.jsonl") if '"start"' not in l}
for k, v in started.items():
    if k not in ended: print(f"#{k:02d} {v['agent']:<12} s{v['step']} STILL-OPEN-AT-EXIT (started t={v['t']})")
print("---- app-server")
for l in open(R + "/as/as.jsonl"):
    r = json.loads(l); m = r["msg"]
    meth = m.get("method") if isinstance(m, dict) else None
    if meth and any(meth.startswith(n) for n in NOISE): continue
    s = json.dumps(m)
    if meth in ("item/started", "item/completed"):
        it = m["params"].get("item", {}); 
        if it.get("type") in ("userMessage", "agentMessage", "reasoning", "contextCompaction"): 
            if it.get("type") != "agentMessage": continue
        s = json.dumps({"method": meth, "thread": m["params"].get("threadId"), "item": it})
    print(r["t"], r["dir"], s[:700])
