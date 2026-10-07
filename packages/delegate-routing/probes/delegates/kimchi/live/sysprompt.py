"""Prompt-map reader for a drive.py run made with "full_wire": true.

usage: sysprompt.py <outdir>

One line per provider request (wire.jsonl, in send order):
  #<n> <kind> model=<model> sys=<role>:<chars> msgs=<role sequence> | <sentinel placements>
kind: main (Kimchi base), child-replace / child-append (sub-agent personas), title, compaction,
other:<system head>. A placement is SP_X@sys:<pct>%<'## heading' it sits under> or SP_X@<role>[<msg index>].
Sentinels are any SP_[A-Z0-9_]+ token, so every scenario plants its own; the memory notice counts as one.
label= is the first CHILD_*/WF_* token in a non-system, non-PLAN message (which delegate the request belongs to).
"""
import json, re, sys
from pathlib import Path

SENT = re.compile(r"SP_[A-Z0-9_]+|Persistent memory is enabled")
LABEL = re.compile(r"\b(?:CHILD|WF)_[A-Z0-9_]+")


def text_of(c):
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""


def kind(sys_text):
    if sys_text.startswith("You are Kimchi"):
        return "main"
    if sys_text.startswith("You are a kimchi coding agent sub-agent"):
        return "child-replace"
    if "<inherited_system_prompt>" in sys_text[:600]:
        return "child-append"
    if sys_text.startswith("Name the user's actual task"):
        return "title"
    if "summar" in sys_text[:400].lower():
        return "compaction"
    return "other:" + sys_text[:50].replace("\n", " ")


def heading_before(text, pos):
    hs = [m for m in re.finditer(r"^#{1,3} [^\n]*|^<[a-z_]+>$", text[:pos], re.M)]
    return hs[-1].group(0)[:40] if hs else "(top)"


def main():
    out = Path(sys.argv[1])
    for n, line in enumerate((out / "wire.jsonl").read_text().splitlines()):
        r = json.loads(line)
        msgs = r["messages"]
        sys_i = next((i for i, m in enumerate(msgs) if m.get("role") in ("system", "developer")), None)
        sys_text = text_of(msgs[sys_i]["content"]) if sys_i is not None else ""
        places = []
        for i, m in enumerate(msgs):
            t = text_of(m.get("content"))
            for mm in SENT.finditer(t):
                if i == sys_i:
                    pct = round(100 * mm.start() / max(len(t), 1))
                    places.append(f"{mm.group(0)}@sys:{pct}%<{heading_before(t, mm.start())}>")
                else:
                    places.append(f"{mm.group(0)}@{m.get('role')}[{i}]")
        label = next((mm.group(0) for i, m in enumerate(msgs) if i != sys_i and "PLAN=" not in text_of(m.get("content"))
                      for mm in LABEL.finditer(text_of(m.get("content")))), "-")
        roles = ",".join((m.get("role") or "?")[:3] for m in msgs)
        sysrole = msgs[sys_i]["role"] if sys_i is not None else "none"
        print(f"#{n} {kind(sys_text)} label={label} model={r.get('model')} sys={sysrole}:{len(sys_text)} msgs={roles} | {' '.join(places) or '-'}")


main()
