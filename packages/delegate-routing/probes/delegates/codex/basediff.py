#!/usr/bin/env python3
"""basediff.py <wire-dir> [ref-request-prefix] — compare the vendor base each request carries.

The base is the top-level `instructions` field, or, when that is empty (catalog models that have
no system slot), the first developer message's first text part. Prints one line per request
(sha256 prefix, byte length, source) and, for every base that differs from the reference request
(default: the first one), the changed lines as a compact unified diff.
"""
import difflib, hashlib, json, os, sys

wire = sys.argv[1]
ref_prefix = sys.argv[2] if len(sys.argv) > 2 else None

def base_of(body):
    if body.get("instructions"):
        return body["instructions"], "instructions"
    for it in body.get("input", []):
        if it.get("type") == "message" and it.get("role") == "developer":
            parts = it.get("content") or []
            if parts and isinstance(parts, list):
                return parts[0].get("text") or "", "developer[0]"
    return "", "-"

reqs = []
for f in sorted(x for x in os.listdir(wire) if x.startswith("req") and x.endswith(".json")):
    try: body = json.load(open(os.path.join(wire, f)))
    except Exception: continue
    text, src = base_of(body)
    reqs.append((f[:-5], text, src))
    print(f"{f[:-5]:<34} sha={hashlib.sha256(text.encode()).hexdigest()[:12]} len={len(text):<6} {src}")

ref = next((r for r in reqs if ref_prefix and r[0].startswith(ref_prefix)), reqs[0] if reqs else None)
seen = {ref[1]} if ref else set()
for name, text, _ in reqs:
    if text in seen: continue
    seen.add(text)
    print(f"--- {ref[0]} → {name}")
    for line in difflib.unified_diff(ref[1].splitlines(), text.splitlines(), lineterm="", n=0):
        if line.startswith(("---", "+++")): continue
        print("   ", line[:200])
