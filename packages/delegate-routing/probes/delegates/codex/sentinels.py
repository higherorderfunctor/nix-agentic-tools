#!/usr/bin/env python3
"""sentinels.py <wire-dir> SENTINEL... — where each sentinel lands in every captured request.

Reads the reqNN-<agent>-s<step>.json bodies that fp.py (or sysprompt/scripted.py) saved and
prints one line per request and sentinel:

  req03-root_c_none-s0  HOOK-SUBSTART-4004  developer#2,user#5   (input item roles)
  req03-root_c_none-s0  CFG-DEV-4000        -                     (absent)

`instructions` means the top-level `instructions` field (the base). The `<tag>` after a role is
the first XML-ish marker in that item's text, so a managed block reads
`developer<managed_developer_instructions>#1`.
"""
import json, os, re, sys

wire, sents = sys.argv[1], sys.argv[2:]
TAG = re.compile(r"<([a-z_]+)[ >]")

def text_of(item):
    c = item.get("content")
    if isinstance(c, str): return c
    if isinstance(c, list): return "\n".join(str(x.get("text") or x.get("encrypted_content") or "") for x in c)
    return json.dumps(item)

for f in sorted(x for x in os.listdir(wire) if x.startswith("req") and x.endswith(".json")):
    try: body = json.load(open(os.path.join(wire, f)))
    except Exception: continue
    hits = {s: [] for s in sents}
    for s in sents:
        if s in str(body.get("instructions") or ""): hits[s].append("instructions")
    for i, it in enumerate(body.get("input", [])):
        t = text_of(it)
        role = it.get("role") or it.get("type")
        for s in sents:
            if s in t:
                m = TAG.search(t)
                hits[s].append(f"{role}{'<' + m.group(1) + '>' if m else ''}#{i}")
    for s in sents:
        print(f"{f[:-5]:<34} {s:<24} {','.join(hits[s]) or '-'}")
