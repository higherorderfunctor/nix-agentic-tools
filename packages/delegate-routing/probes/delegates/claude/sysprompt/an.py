#!/usr/bin/env python3
"""an.py <case-dir> [--dump]: per request, where each sentinel token (e.g. APPINLINE-1313) appears."""
import json, re, sys, glob, os
d = sys.argv[1]; dump = "--dump" in sys.argv
pat = re.compile(r"\b[A-Z]{4,}-\d{4}\b")
for f in sorted(glob.glob(os.path.join(d, "req-*.json"))):
    r = json.load(open(f)); b = r["body"]
    sysb = b.get("system", [])
    if isinstance(sysb, str): sysb = [{"text": sysb}]
    print(f"== {os.path.basename(f)} model={b.get('model')} msgs={len(b.get('messages',[]))} tools={len(b.get('tools',[]))} sysblocks={[len(x.get('text','')) for x in sysb]}")
    print("   sys0..:", " | ".join(x.get("text","")[:90].replace("\n"," ") for x in sysb))
    hits = {}
    for i, x in enumerate(sysb):
        for t in set(pat.findall(x.get("text",""))): hits.setdefault(t, []).append(f"sys[{i}]")
    for mi, m in enumerate(b.get("messages", [])):
        c = m.get("content"); c = [{"type":"text","text":c}] if isinstance(c,str) else c
        for bi, blk in enumerate(c):
            s = json.dumps(blk)
            for t in set(pat.findall(s)): hits.setdefault(t, []).append(f"msg[{mi}].{m['role']}[{bi}]:{blk.get('type')}")
    for t in sorted(hits): print(f"   {t}: {hits[t]}")
    if dump:
        out = f[:-5] + ".txt"
        with open(out, "w") as o:
            for i, x in enumerate(sysb): o.write(f"######## SYSTEM[{i}] cache={x.get('cache_control')}\n{x.get('text','')}\n")
            for mi, m in enumerate(b.get("messages", [])):
                c = m.get("content"); c = [{"type":"text","text":c}] if isinstance(c,str) else c
                for bi, blk in enumerate(c):
                    o.write(f"######## MSG[{mi}] {m['role']} [{bi}] {blk.get('type')}\n{blk.get('text') or json.dumps(blk)[:4000]}\n")
