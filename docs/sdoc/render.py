#!/usr/bin/env python3
"""Render the design graph as readable markdown.

    strictdoc export . --formats=json --output-dir /tmp/sdoc-out
    python3 docs/sdoc/render.py /tmp/sdoc-out/json/index.json            # grooming queue
    python3 docs/sdoc/render.py <json> --all                             # everything
    python3 docs/sdoc/render.py <json> --uid DEC-SYSTEM-PURPOSE          # one node + neighbours
    python3 docs/sdoc/render.py <json> --depth sketch --depth needs-design

Every relation and fingerprint is printed with the TARGET'S TITLE, not just its
UID. Chasing a bare identifier to find out what it means is the specific thing
that makes raw sdoc unreadable, and it is the only real work this does.
"""

from __future__ import annotations

import argparse
import json
import sys
import textwrap

PREFIXES = ("DEC", "MECH", "SLICE", "SPIKE", "INV")
BODY = ("STATEMENT", "RATIONALE", "RETIRES_ON", "NOTES")
BADGE = ("DEPTH", "STATUS", "AUTHORED_BY")


def nodes(obj, path=None):
    if isinstance(obj, dict):
        here = obj.get("RELATIVE_PATH") or obj.get("PATH") or path
        uid = obj.get("UID")
        if isinstance(uid, str) and uid.split("-")[0] in PREFIXES:
            yield obj, here
        for value in obj.values():
            yield from nodes(value, here)
    elif isinstance(obj, list):
        for value in obj:
            yield from nodes(value, path)


def wrap(text, indent=""):
    out = []
    for para in (text or "").strip().split("\n\n"):
        flat = " ".join(para.split())
        out.append(textwrap.fill(flat, 78, initial_indent=indent, subsequent_indent=indent))
    return "\n\n".join(out)


def render(node, titles, inbound):
    uid = node["UID"]
    print(f"\n## {node.get('TITLE', uid)}")
    badges = [f"{k.lower()}: {node[k]}" for k in BADGE if node.get(k)]
    print(f"`{uid}`" + (f" — {' · '.join(badges)}" if badges else ""))

    for field in BODY:
        if node.get(field):
            print(f"\n**{field.replace('_', ' ').title()}**\n")
            print(wrap(node[field]))

    out = [(r.get("ROLE") or r.get("TYPE"), r.get("VALUE"))
           for r in (node.get("RELATIONS") or []) if r.get("VALUE")]
    if out:
        print("\n**Depends on**\n")
        for role, target in out:
            print(f"- {role} → {titles.get(target, target + '  (file)')}")

    fps = [e.rsplit(":", 1) for e in str(node.get("PARENT_FP") or "").split() if ":" in e]
    if fps:
        print("\n**Accepted contracts**\n")
        for target, digest in fps:
            state = "never signed" if digest == "0000000" else f"signed {digest}"
            print(f"- {titles.get(target, target)} — {state}")

    if inbound.get(uid):
        print("\n**Depended on by**\n")
        for role, source in sorted(inbound[uid]):
            print(f"- {role} ← {titles.get(source, source)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("json")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--uid", action="append", default=[])
    ap.add_argument("--depth", action="append", default=[])
    args = ap.parse_args()

    found = list(nodes(json.load(open(args.json))))
    by_uid = {n["UID"]: n for n, _ in found}
    titles = {u: f"**{n.get('TITLE', u)}** (`{u}`)" for u, n in by_uid.items()}

    inbound: dict[str, set] = {}
    for node, _ in found:
        for rel in node.get("RELATIONS") or []:
            if rel.get("VALUE") in by_uid:
                inbound.setdefault(rel["VALUE"], set()).add(
                    (rel.get("ROLE") or rel.get("TYPE"), node["UID"]))

    if args.uid:
        picked, seen = [], set()
        for uid in args.uid:
            if uid not in by_uid:
                print(f"no such node: {uid}", file=sys.stderr)
                return 2
            neighbours = {r["VALUE"] for r in (by_uid[uid].get("RELATIONS") or [])
                          if r.get("VALUE") in by_uid}
            neighbours |= {s for _, s in inbound.get(uid, set())}
            for u in [uid, *sorted(neighbours)]:
                if u not in seen:
                    seen.add(u)
                    picked.append((by_uid[u], None))
        title = "Node and neighbours"
    elif args.all:
        picked, title = found, "The whole graph"
    else:
        wanted = args.depth or ["sketch"]
        picked = [(n, p) for n, p in found if n.get("DEPTH") in wanted]
        title = "Grooming queue — " + ", ".join(wanted)

    print(f"# {title}\n\n{len(picked)} nodes")
    for node, _ in picked:
        render(node, titles, inbound)
    return 0


if __name__ == "__main__":
    sys.exit(main())
