#!/usr/bin/env python3
"""parity.py <ref.json> <other.json>... — compare captured Responses request bodies item by item.

Volatile text (uuids, absolute scratch paths, dates, times, shell names) is masked before
comparison, so only structural or wording differences remain. Prints, per other request:
top-level keys, tool names, client_metadata keys, then one line per input item whose masked
text differs from the reference ("=" when the whole request matches).
"""
import json, re, sys

MASKS = [
    (re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"), "<uuid>"),
    (re.compile(r"/var/tmp/[^\s<\"']+|/tmp/[^\s<\"']+"), "<path>"),
    (re.compile(r"\d{4}-\d{2}-\d{2}"), "<date>"),
    (re.compile(r"<shell>[^<]*</shell>"), "<shell/>"),
]

def mask(s):
    for rx, rep in MASKS: s = rx.sub(rep, s)
    return s

def items(body):
    out = []
    for it in body.get("input", []):
        if it.get("type") == "additional_tools":
            out.append(("additional_tools", "developer", "tools=" + str(len(json.dumps(it.get("tools"))))))
            continue
        c = it.get("content")
        t = "\n".join(str(x.get("text") or "") for x in c) if isinstance(c, list) else json.dumps(it)
        out.append((it.get("type"), it.get("role"), mask(t)))
    return out

def tools(body):
    res = []
    def walk(ts, pre=""):
        for t in ts or []:
            if "tools" in t: walk(t["tools"], pre + t.get("name", "") + ".")
            else: res.append(pre + str(t.get("name")))
    for it in body.get("input", []):
        if it.get("type") == "additional_tools": walk(it.get("tools"))
    walk(body.get("tools"))
    return res

ref_path, others = sys.argv[1], sys.argv[2:]
ref = json.load(open(ref_path))
ri = items(ref)
for p in others:
    b = json.load(open(p))
    print(f"### {p.rsplit('/', 3)[-3] if p.count('/') > 2 else p} vs ref")
    diffs = []
    for k in sorted(set(ref) | set(b)):
        if k in ("input", "client_metadata", "prompt_cache_key", "tools"): continue
        if mask(json.dumps(ref.get(k))) != mask(json.dumps(b.get(k))):
            diffs.append(f"  key {k}: ref={json.dumps(ref.get(k))[:80]} other={json.dumps(b.get(k))[:80]}")
    if tools(ref) != tools(b):
        diffs.append(f"  tools: ref={tools(ref)} other={tools(b)}")
    rk, bk = sorted((ref.get("client_metadata") or {})), sorted((b.get("client_metadata") or {}))
    if rk != bk:
        diffs.append(f"  client_metadata keys: ref-only={sorted(set(rk) - set(bk))} other-only={sorted(set(bk) - set(rk))}")
    bi = items(b)
    for n in range(max(len(ri), len(bi))):
        a = ri[n] if n < len(ri) else None
        o = bi[n] if n < len(bi) else None
        if a != o:
            def brief(x):
                if x is None: return "<absent>"
                return f"{x[0]}/{x[1]} len={len(x[2])} {x[2][:90]!r}"
            diffs.append(f"  item#{n}: ref={brief(a)}\n          other={brief(o)}")
            if a and o and a[:2] == o[:2]:
                al, ol = a[2].splitlines(), o[2].splitlines()
                extra = [l for l in ol if l not in al][:3]
                gone = [l for l in al if l not in ol][:3]
                if extra: diffs.append(f"          +{extra}")
                if gone: diffs.append(f"          -{gone}")
    print("\n".join(diffs) if diffs else "  =")
