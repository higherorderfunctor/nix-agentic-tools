#!/usr/bin/env python3
"""cache.py <work> <baseline-case> <case>...: where the append lands relative to cache breakpoints.

For the first main request of each case prints one line per system block:

  <case> sys[i] len=<n> cache=<cache_control> tokens=<sentinels> vs_base=<same|prefix+N|differs>

`vs_base` compares the block with the same index in <baseline-case>: `same` = byte-identical
(cached prefix unchanged), `prefix+N` = baseline block is a strict prefix and N chars were
added at its end, `differs` = changed before the end. A final line per case gives the first
block index whose bytes differ from the baseline, i.e. where the cached prefix stops matching.
"""
import json
import pathlib
import re
import sys

TOKEN = re.compile(r"\b[A-Z]{4,}-\d{4}\b")


def system(case_dir):
    reqs = sorted(p for p in case_dir.glob("req-*.json") if not p.name.endswith("GET.txt"))
    for path in reqs:
        rec = json.loads(path.read_text())
        if rec["path"].startswith("/v1/messages") and "count_tokens" not in rec["path"]:
            blocks = rec["body"].get("system", [])
            return [{"text": blocks}] if isinstance(blocks, str) else blocks
    raise SystemExit(f"no messages request in {case_dir}")


def compare(block, base):
    if base is None:
        return "new"
    if block["text"] == base["text"]:
        return "same" if block.get("cache_control") == base.get("cache_control") else "same-text-cache-changed"
    if block["text"].startswith(base["text"]):
        return f"prefix+{len(block['text']) - len(base['text'])}"
    return "differs"


def main():
    work = pathlib.Path(sys.argv[1])
    base = system(work / sys.argv[2])
    for case in sys.argv[3:]:
        blocks = system(work / case)
        first_diff = None
        for i, block in enumerate(blocks):
            ref = base[i] if i < len(base) else None
            verdict = compare(block, ref)
            if verdict != "same" and first_diff is None:
                first_diff = i
            tokens = sorted(set(TOKEN.findall(block.get("text", ""))))
            print(f"{case} sys[{i}] len={len(block.get('text', ''))} cache={json.dumps(block.get('cache_control'))} "
                  f"tokens={','.join(tokens) or '-'} vs_base={verdict}")
        print(f"{case} first_changed_block={first_diff if first_diff is not None else 'none'}")


main()
