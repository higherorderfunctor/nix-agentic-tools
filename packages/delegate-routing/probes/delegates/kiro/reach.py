import json, re, sys
# Prompt-reach summary of a capserver2 wire.jsonl: one line per GenerateAssistantResponse request.
# Usage: reach.py <wire.jsonl> [MARKER ...]
# One line per request: rule, conversation, agentTaskType, history length, the KAS base marker offset, the
# first line of history[0], every key named like cache*, then after "hits:" the offset of each MARKER
# inside history[0] (h0@N) or where else it occurs (cur = current message, h<i> = later history entry,
# top = outside conversationState), in argument order.
BASE = "You are Kiro, an agentic AI"
p = sys.argv[1]
marks = sys.argv[2:]


def keys(o, out, path=""):
    if isinstance(o, dict):
        for k, v in o.items():
            if "cache" in k.lower():
                out.append(path + "." + k)
            keys(v, out, path + "." + k)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            keys(v, out, path + f"[{i}]")


def text(m):
    u = m.get("userInputMessage") or m.get("assistantResponseMessage") or {}
    return json.dumps(u)


n = 0
for line in open(p):
    d = json.loads(line)
    if "body" not in d or "GenerateAssistant" not in d.get("target", ""):
        continue
    try:
        b = json.loads(d["body"])
    except Exception:
        print(d["t"], "unparsable")
        continue
    n += 1
    cs = b.get("conversationState", {})
    hist = cs.get("history", [])
    h0 = (hist[0].get("userInputMessage") or {}).get("content", "") if hist else ""
    cur = json.dumps(cs.get("currentMessage", {}))
    top = json.dumps({k: v for k, v in b.items() if k != "conversationState"})
    ck = []
    keys(b, ck)
    first = h0.split("\n", 1)[0][:70] if h0 else (cs.get("currentMessage", {}).get("userInputMessage", {}).get("content", "")[:70])
    base = h0.find(BASE)
    hits = []
    for m in marks:
        where = [f"h0@{mm.start()}" for mm in re.finditer(re.escape(m), h0)]
        where += [f"h{i}" for i, e in enumerate(hist[1:], 1) if m in text(e)]
        if m in cur:
            where.append("cur")
        if m in top:
            where.append("top")
        if where:
            hits.append(f"{m}:{','.join(where)}")
    print(
        f"#{n} t={d['t']} rule={d['rule']} conv={cs.get('conversationId', '')[:13]} task={cs.get('agentTaskType')} "
        f"hist={len(hist)} h0len={len(h0)} base@{base} cache={','.join(ck) or '-'} first={first!r} hits: {' '.join(hits) or '-'}"
    )
print(f"requests={n}")
