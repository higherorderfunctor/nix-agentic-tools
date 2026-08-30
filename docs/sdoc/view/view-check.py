#!/usr/bin/env python3
# cspell:ignore uids sgra
"""view-check -- MECH-VIEW-CHECK. The rules a tree of narratives must satisfy
that strictdoc does not check.

    strictdoc export . --formats=json --output-dir /tmp/sdoc-out
    python3 docs/sdoc/view/view-check.py /tmp/sdoc-out/json/index.json . --root NAR-WHITEBOARD-VIEW

Walks the Contains tree under --root and prints its findings count first,
one line per finding, then any notes. Exit status is 1 on any finding; a
note never fails the check. wireline.py imports `build` from here so the
payload's "checks" list and this program's output are the same findings.

Rules, each with a stable name that appears in the output and the payload:

  contains-is-a-tree             a narrative is contained at most once from
                                 the root, and Contains never closes a cycle
                                 (strictdoc exits 0 on both)
  contains-target-is-narrative   a Contains target is a NARRATIVE
  legend-word                    every row bracket word is in the root's
                                 legend child; rows with no legend child at
                                 all is one finding at the root
  widget-shape                   a narrative's STATEMENT has the shape its
                                 WIDGET says: rows has at least one row,
                                 glossary rows split on the first ": ",
                                 legend rows on two and name a colour from
                                 the vocabulary, a table has a header row
                                 with pipes
  cited-node-superseded          a Cites target has STATUS superseded or
                                 carries Superseded_By
  nothing-depends-on-a-narrative no node outside the representation family
                                 carries a Parent relation or a PARENT_FP
                                 entry to a narrative in the tree
                                 (REQ-NOTHING-DEPENDS-ON-A-NARRATIVE)
  title-holds-a-link             a TITLE holds the inline link token, which
                                 strictdoc leaves inert there

  orphan-narrative               NOTE only: a narrative in the export that is
                                 outside this tree and contained by nothing

What strictdoc already refuses -- a dangling Cites, a dangling inline link,
an unregistered role, a field out of order, a WIDGET word off the list -- is
not repeated here.

This module also holds the STATEMENT parser (the row convention from
DEC-NARRATIVE-IS-THE-VIEW-NODE) and the .sgra reader, because the check and
the wireline must read a statement the same way and this is the one place
both import from. The worktree argument is taken for interface parity with
wireline.py and file-check.py; the check itself reads only the export.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "dev" / "scripts"))
from sdoc_fp import build_uid_index, iter_nodes, load_index, parse_parent_fp  # noqa: E402

SCHEMA = "whiteboard-view/1"

# The renderer's colour vocabulary, per DEC-LEGEND-IS-DATA. A legend row may
# name only these; the renderer maps each to a token that passes the
# colour-vision validator in both themes.
COLOURS = ("green", "slate", "amber", "blue", "red", "teal", "violet", "grey")

# strictdoc's inline link token. The export keeps it literal.
LINK_RE = re.compile(r"\[LINK:\s*([^\]\s]+)\s*\]")
# A trailing "[WORD]" or "[WORD: by]" on a row. LINK is excluded below so a
# row that ends in an inline link is not read as a bracket word.
BRACKET_RE = re.compile(r"^(?P<text>.*?)\s*\[(?P<word>[^\[\]:]+?)(?::\s*(?P<by>[^\[\]]*?))?\]\s*$", re.S)
ROW_MARK = "- "
ROW_WIDGETS = ("rows", "glossary", "legend", "table")
DEFAULT_WIDGET = "prose"


# --------------------------------------------------------------------------
# grammar.sgra
# --------------------------------------------------------------------------

_SGRA_LINE = re.compile(r"^(?P<indent>\s*)(?P<dash>- )?(?P<key>[A-Z_]+):\s*(?P<value>.*?)\s*$")
_TYPE_RE = re.compile(r"^(?P<kind>[A-Za-z]+)(?:\((?P<options>.*)\))?$")


def parse_sgra(path: Path) -> dict:
    """Read a .sgra grammar into {TYPE: {prefix, fields, roles}}.

    The export types every field as String, so the field kinds and the
    option lists can only come from the grammar file itself.
    """
    grammar: dict = {}
    element = None
    section = None
    item = None
    for raw in path.read_text().splitlines():
        m = _SGRA_LINE.match(raw)
        if not m:
            continue
        dash, key, value = m.group("dash"), m.group("key"), m.group("value")
        if dash and key == "TAG":
            element = {"prefix": "", "fields": [], "roles": []}
            grammar[value] = element
            section = None
            item = None
        elif element is None:
            continue
        elif key == "PREFIX":
            element["prefix"] = value
        elif key in ("FIELDS", "RELATIONS") and not dash:
            section = key
            item = None
        elif dash and section == "FIELDS" and key == "TITLE":
            item = {"name": value, "kind": "String", "options": [], "required": False}
            element["fields"].append(item)
        elif dash and section == "RELATIONS" and key == "TYPE":
            item = {"type": value, "role": None}
            element["roles"].append(item)
        elif item is None:
            continue
        elif section == "FIELDS" and key == "TYPE":
            t = _TYPE_RE.match(value)
            item["kind"] = t.group("kind") if t else value
            options = t.group("options") if t else None
            item["options"] = [o.strip() for o in options.split(",")] if options else []
        elif section == "FIELDS" and key == "REQUIRED":
            item["required"] = value == "True"
        elif section == "RELATIONS" and key == "ROLE":
            item["role"] = value
    return grammar


def ladders(grammar: dict) -> dict:
    """Every SingleChoice field's option list, keyed by field name. The same
    field on several types carries the same list; the first seen wins."""
    out: dict = {}
    for element in grammar.values():
        for field in element["fields"]:
            if field["kind"] == "SingleChoice" and field["name"] not in out:
                out[field["name"]] = list(field["options"])
    return out


# --------------------------------------------------------------------------
# STATEMENT parsing
# --------------------------------------------------------------------------


def spans(text: str) -> list:
    """Split text on inline link tokens into {"t": text} and {"link": UID}."""
    out = []
    pos = 0
    for m in LINK_RE.finditer(text):
        if m.start() > pos:
            out.append({"t": text[pos : m.start()]})
        out.append({"link": m.group(1)})
        pos = m.end()
    if pos < len(text):
        out.append({"t": text[pos:]})
    return out


def link_uids(span_list: list) -> list:
    return [s["link"] for s in span_list if "link" in s]


def _blocks(text: str) -> list:
    """Split a STATEMENT into ("para", text) and ("row", text) blocks per the
    row convention: a row starts with "- ", continues on any following line
    that is neither blank nor a row start, and a blank line ends the list."""
    blocks: list = []
    mode = None  # None | "para" | "row"
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped:
            mode = None
            continue
        if line.startswith(ROW_MARK):
            blocks.append(["row", line[len(ROW_MARK) :].strip()])
            mode = "row"
        elif mode == "row":
            blocks[-1][1] += " " + stripped
        elif mode == "para":
            blocks[-1][1] += " " + stripped
        else:
            blocks.append(["para", stripped])
            mode = "para"
    return [(kind, body) for kind, body in blocks]


def _split_row(body: str) -> tuple:
    """(text, word, by) for one row body; word and by are None without a bracket."""
    m = BRACKET_RE.match(body)
    if not m or m.group("word").strip() == "LINK":
        return body, None, None
    by = m.group("by")
    return m.group("text"), m.group("word").strip(), (by.strip() if by is not None else None)


def parse_statement(text: str, widget: str) -> dict:
    """Parse a STATEMENT per its WIDGET into the wireline's shape.

    Returns {"prose", "rows", "terms", "legend", "table", "shape"}: the
    first five are the payload keys, "shape" is a list of widget-shape
    complaints for the check to file. A non-row widget reads the whole
    statement as paragraphs.
    """
    out: dict = {"prose": [], "rows": [], "terms": [], "legend": [], "table": None, "shape": []}
    if widget not in ROW_WIDGETS:
        out["prose"] = [spans(body) for kind, body in _blocks(text)]
        return out

    rows = []
    for kind, body in _blocks(text):
        if kind == "para":
            out["prose"].append(spans(body))
        else:
            rows.append(body)

    if not rows:
        out["shape"].append(f"WIDGET {widget} but the STATEMENT has no '- ' row")
        return out

    if widget == "rows":
        for n, body in enumerate(rows, 1):
            body_text, word, by = _split_row(body)
            out["rows"].append({"n": n, "spans": spans(body_text), "word": word, "by": by, "by_uid": None})
    elif widget == "glossary":
        for n, body in enumerate(rows, 1):
            term, sep, definition = body.partition(": ")
            if not sep:
                out["shape"].append(f"glossary row {n} has no ': ' between term and definition")
                out["terms"].append({"n": n, "term": body.strip(), "spans": []})
            else:
                out["terms"].append({"n": n, "term": term.strip(), "spans": spans(definition)})
    elif widget == "legend":
        for n, body in enumerate(rows, 1):
            parts = body.split(": ", 2)
            if len(parts) < 3:
                out["shape"].append(f"legend row {n} is not 'WORD: colour: meaning'")
                continue
            word, colour, meaning = (p.strip() for p in parts)
            if colour not in COLOURS:
                out["shape"].append(f"legend row {n} colour {colour!r} is not one of {', '.join(COLOURS)}")
            out["legend"].append({"word": word, "colour": colour, "meaning": meaning})
    elif widget == "table":
        cells = [[c.strip() for c in body.split("|")] for body in rows]
        if "|" not in rows[0]:
            out["shape"].append("table has no header row with pipes")
        out["table"] = {"header": cells[0], "rows": cells[1:]}
    return out


# --------------------------------------------------------------------------
# the tree and the rules
# --------------------------------------------------------------------------


def relations(node: dict) -> list:
    return node.get("RELATIONS") or []


def contains_targets(node: dict) -> list:
    return [r["VALUE"] for r in relations(node) if r.get("TYPE") == "Child" and r.get("ROLE") == "Contains"]


def cites_targets(node: dict) -> list:
    return [r["VALUE"] for r in relations(node) if r.get("TYPE") == "Parent" and r.get("ROLE") == "Cites"]


def is_superseded(node: dict) -> bool:
    if node.get("STATUS") == "superseded":
        return True
    return any(r.get("ROLE") == "Superseded_By" for r in relations(node))


def widget_of(node: dict) -> str:
    return node.get("WIDGET") or DEFAULT_WIDGET


def tags_of(node: dict) -> list:
    raw = node.get("TAGS") or ""
    return [t.strip() for t in raw.split(",") if t.strip()]


def _usage_error(text: str) -> None:
    """Exit 2, so a bad root is never mistaken for a finding (exit 1)."""
    print(text, file=sys.stderr)
    raise SystemExit(2)


class View:
    """The Contains tree under one root, every narrative's parsed STATEMENT,
    the root's legend, and the findings the walk produced."""

    def __init__(self, index: dict, root: str):
        self.index = index
        self.by_uid = build_uid_index(index)
        self.root = root
        self.findings: list = []
        self.notes: list = []
        self.order: list = []  # preorder UIDs of the narratives in the tree
        self.children: dict = {}  # uid -> [child uids], Contains order, valid descents only
        self.parsed: dict = {}  # uid -> parse_statement() result
        self.legend_uid = None
        self.legend: list = []

        root_node = self.by_uid.get(root)
        if root_node is None:
            _usage_error(f"no such node: {root}")
        if root_node.get("_NODE_TYPE") != "NARRATIVE":
            _usage_error(f"{root} is a {root_node.get('_NODE_TYPE')}, not a NARRATIVE")

        self._walk(root, [])
        for uid in self.order:
            node = self.by_uid[uid]
            self.parsed[uid] = parse_statement(node.get("STATEMENT") or "", widget_of(node))
        for child in self.children.get(root, []):
            if widget_of(self.by_uid[child]) == "legend":
                self.legend_uid = child
                self.legend = self.parsed[child]["legend"]
                break
        self._rules()

    def _find(self, rule: str, at: str, text: str) -> None:
        self.findings.append({"rule": rule, "at": at, "text": text})

    def _walk(self, uid: str, path: list) -> None:
        self.order.append(uid)
        self.children[uid] = []
        for target in contains_targets(self.by_uid[uid]):
            node = self.by_uid.get(target)
            if node is None or node.get("_NODE_TYPE") != "NARRATIVE":
                kind = "nothing in the export" if node is None else f"a {node.get('_NODE_TYPE')}"
                self._find("contains-target-is-narrative", uid, f"{uid} Contains {target}, which is {kind}")
                continue
            if target in path or target == uid:
                self._find("contains-is-a-tree", uid, f"{uid} Contains {target}, which already contains {uid}: a cycle")
                continue
            if target in self.children:
                self._find("contains-is-a-tree", uid, f"{uid} Contains {target}, which is already contained elsewhere in the tree")
                continue
            self.children[uid].append(target)
            self._walk(target, path + [uid])

    def _rules(self) -> None:
        tree = set(self.order)
        legend_words = {e["word"] for e in self.legend}

        rows_seen = False
        for uid in self.order:
            node = self.by_uid[uid]
            parsed = self.parsed[uid]
            for complaint in parsed["shape"]:
                self._find("widget-shape", uid, complaint)
            if widget_of(node) == "rows" and parsed["rows"]:
                rows_seen = True
                if self.legend_uid is not None:
                    for row in parsed["rows"]:
                        if row["word"] is not None and row["word"] not in legend_words:
                            self._find("legend-word", uid, f"row {row['n']} carries [{row['word']}], which is not in the legend {self.legend_uid}")
            for target in cites_targets(node):
                cited = self.by_uid.get(target)
                if cited is not None and is_superseded(cited):
                    self._find("cited-node-superseded", uid, f"{uid} Cites {target}, which is superseded")
            if LINK_RE.search(node.get("TITLE") or ""):
                self._find("title-holds-a-link", uid, "TITLE holds an inline link token, which is inert there")
        if rows_seen and self.legend_uid is None:
            self._find("legend-word", self.root, f"{self.root} has rows but no child whose WIDGET is legend")

        for _doc, node in iter_nodes(self.index):
            if node.get("_NODE_TYPE") == "NARRATIVE" or "UID" not in node:
                continue
            uid = node["UID"]
            for r in relations(node):
                if r.get("TYPE") == "Parent" and r.get("VALUE") in tree:
                    self._find("nothing-depends-on-a-narrative", uid, f"{uid} carries {r.get('ROLE')} to the narrative {r['VALUE']}")
            for parent, _digest in parse_parent_fp(node.get("PARENT_FP")):
                if parent in tree:
                    self._find("nothing-depends-on-a-narrative", uid, f"{uid} carries a PARENT_FP entry for the narrative {parent}")

        contained_anywhere = {t for n in self.by_uid.values() for t in contains_targets(n)}
        for uid, node in self.by_uid.items():
            if node.get("_NODE_TYPE") == "NARRATIVE" and uid not in tree and uid not in contained_anywhere:
                self.notes.append({"rule": "orphan-narrative", "at": uid, "text": f"{uid} is outside this tree and nothing Contains it"})


def build(index: dict, root: str) -> View:
    return View(index, root)


def check(index: dict, root: str) -> tuple:
    """(findings, notes) for the tree under root."""
    view = build(index, root)
    return view.findings, view.notes


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    parser.add_argument("worktree", type=Path)
    parser.add_argument("--root", required=True, help="UID of the root narrative")
    args = parser.parse_args()
    if not args.worktree.is_dir():
        parser.error(f"worktree {args.worktree} is not a directory")

    findings, notes = check(load_index(args.export_json), args.root)

    noun = "finding" if len(findings) == 1 else "findings"
    print(f"{len(findings)} {noun} under {args.root}")
    for f in findings:
        print(f"  {f['rule']}  at {f['at']}: {f['text']}")
    if notes:
        print(f"{len(notes)} note(s)")
        for n in notes:
            print(f"  {n['rule']}  at {n['at']}: {n['text']}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
