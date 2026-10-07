"""Print one line per recorded mock request of a `dmu_*` case, then its driver log.

Usage: python3 dmu_show.py <case> [<case> ...]   (reads $CLAUDE_PROBE_WORK/out/<case>/)
Line shape: `<case> n=<n> <kind> model=<model> effort=<effort> agent=<bool> tools=<count> [k=v ...]`.
"""
import json
import os
import pathlib
import sys

WORK = pathlib.Path(os.environ.get("CLAUDE_PROBE_WORK", ""))
EXTRA = ("turn", "child", "step", "node", "tag", "has_skill_body")

if len(sys.argv) < 2 or not WORK.name:
    sys.exit(__doc__ + "\nSet CLAUDE_PROBE_WORK to the harness work dir.")
for case in sys.argv[1:]:
    out = WORK / "out" / case
    summ = json.loads((out / "summary.json").read_text())
    for r in summ["data"].get("reqs", []):
        extra = " ".join(f"{k}={r[k]}" for k in EXTRA if k in r and r[k] not in ("", None))
        print(f"{case} n={r['n']} {r['kind']} model={r['model']} effort={r['effort']} "
              f"agent={'Agent' in r['tools']} tools={len(r['tools'])} {extra}".rstrip())
    for entry in summ["log"]:
        if any(str(x).startswith("CLIENT_CLOSED") for x in entry["reply"]):
            print(f"{case} n={entry['n']} {entry['reply'][0]}")
    tr = summ["data"].get("child_tr")
    if tr:
        print(f"{case} child_tr is_error={tr.get('is_error')} {json.dumps(tr.get('content'))[:90]}")
    log = out / "driver-log.json"
    if log.exists():
        raw = json.loads(log.read_text())
        strip = lambda o: {k: strip(v) for k, v in o.items() if k not in ("_t", "_seen")} if isinstance(o, dict) \
            else [strip(x) for x in o] if isinstance(o, list) else o
        print(f"{case} driver-log: {json.dumps(strip(raw))[:3000]}")
