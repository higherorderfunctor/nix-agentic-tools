#!/usr/bin/env python3
# cspell:ignore uids sgra
"""view-check -- MECH-VIEW-CHECK. The rules the narratives of the canon must
satisfy that strictdoc does not check.

    strictdoc export . --formats=json --output-dir /tmp/sdoc-out
    python3 docs/sdoc/view/view-check.py /tmp/sdoc-out/json/index.json .                # every root
    python3 docs/sdoc/view/view-check.py /tmp/sdoc-out/json/index.json . --root NAR-X   # one root

A ROOT is a NARRATIVE nothing Contains. By default every root is walked;
--root walks one. Findings print count first, one line per finding, per
root and then canon-wide, then any notes. Exit status is 1 on any finding;
a note never fails the check. wireline.py imports `build_canon` from here
so the payload's "checks" list and this program's output are the same
findings.

Rules, each with a stable name that appears in the output and the payload:

  contains-is-a-tree             a narrative is contained at most once (in
                                 one root's tree, and by one container over
                                 the whole canon), and Contains never closes
                                 a cycle (strictdoc exits 0 on both)
  contains-target-is-narrative   a Contains target is a NARRATIVE
  place-of-root                  a root carries no PLACE: it is the page
                                 (DEC-NARRATIVE-DECLARES-ITS-PLACE)
  over-target-is-a-narrative     an Over target is a NARRATIVE
  over-in-plan-or-spec           an Over target sits in the same plan as the
                                 widget narrative, or in the spec
  over-unfingerprinted           no PARENT_FP entry names an Over target that
                                 is not also Cited (Over says where to look,
                                 never what is true)
  legend-word                    every row bracket word is in the root's
                                 legend -- the narrative with the legend
                                 widget anywhere in the root's tree
                                 (DEC-LEGEND-IS-DATA-WHERE-PLACED); bracket
                                 words with no legend at all is one finding
                                 at the root
  legend-parts                   a legend row is 'WORD: colour: meaning' or
                                 'WORD: colour: meaning: by-label'
  widget-shape                   a STATEMENT has the shape its WIDGET says:
                                 a row widget has at least one row (unless
                                 its data is elsewhere: an Over target, a
                                 query word, or the terms a glossary
                                 Contains), glossary
                                 rows split on the first ': ', a legend
                                 colour is in the vocabulary, a table has a
                                 header row with pipes ('| a | b |' lines)
                                 and at least one data row
  grid-shape                     grid rows are axis captions ('- word:
                                 caption'), cells ('- [LINK: NAR]: row:
                                 col') or the outside strip ('- [LINK: NAR]:
                                 outside'); every cell axis word has a
                                 caption and every caption is used
  stack-shape                    a stack row is '- NAME: label: description'
  ladder-field-exists            a ladder row's FIELD is a field some
                                 grammar element declares
  facts-shape                    a facts row is '- label: value'
  query-word-known               a TAGS word that is a query word in the
                                 wrong case, or two query words on one
                                 narrative (MECH-VIEW-QUERIES: the list is
                                 closed -- roots, nodes, grammar, systems,
                                 terms)
  systems-table                  exactly one narrative is tagged systems, its
                                 WIDGET is table, and its header holds
                                 system, types, roles and meaning
                                 (DEC-SYSTEM-IS-A-TYPE-SET)
  cited-node-superseded          a Cites target has STATUS superseded or
                                 carries Superseded_By
  nothing-depends-on-a-narrative no node outside the representation family
                                 carries a Parent relation or a PARENT_FP
                                 entry to a narrative
                                 (REQ-NOTHING-DEPENDS-ON-A-NARRATIVE)
  title-holds-a-link             a TITLE holds the inline link token, which
                                 strictdoc leaves inert there
  reference-line-links-resolve   a link on a row's reference line names a
                                 node in the export. strictdoc already
                                 refuses a dangling inline link at export,
                                 so on a real export this never fires; it is
                                 kept because the parser is also run over
                                 payloads built by hand, and the positive
                                 control is an in-memory index with a node
                                 removed

  orphan-narrative               NOTE only, --root mode: another root exists
                                 outside this tree

What strictdoc already refuses -- a dangling Cites, a dangling inline link,
an unregistered role, a field out of order, a WIDGET or PLACE word off the
list -- is not repeated here.

This module also holds the STATEMENT parser (the row conventions from
DEC-ROW-REFERENCE-LINES and MECH-ROW-SOURCE-LINE, the widget row shapes
from the whiteboard-view design) and the .sgra reader, because the check
and the wireline must read a statement the same way and this is the one
place both import from. The worktree is walked to map each UID to its file:
a narrative's directory class (spec, plan:<name>, package) is what the
over-in-plan-or-spec rule compares.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "dev" / "scripts"))
from sdoc_fp import build_uid_index, iter_nodes, load_index, parse_parent_fp  # noqa: E402

SCHEMA = "whiteboard-view/2"

# The renderer's colour vocabulary, per DEC-LEGEND-IS-DATA-WHERE-PLACED. A
# legend row may name only these; the renderer maps each to a token that
# passes the colour-vision validator in both themes.
COLOURS = ("green", "slate", "amber", "blue", "red", "teal", "violet", "grey")

# The closed list of query words (MECH-VIEW-QUERIES). queries.py computes
# each; this module only checks the word.
QUERY_WORDS = ("roots", "nodes", "grammar", "systems", "terms")
SYSTEMS_HEADER = ("system", "sources", "switch", "meaning")
# A system row's switch column. "always" pins the system on; the reader may
# not turn it off (DEC-SYSTEM-IS-A-SOURCE-SET).
SWITCH_WORDS = ("always", "optional")
# The tabs table (DEC-TABS-ARE-A-DECLARED-VOCABULARY). A narrative joins a tab
# by naming its key in TAGS; start and nodes are the page's own and are never
# rows of the table.
TABS_HEADER = ("tab", "title", "meaning")
PAGE_TABS = ("start", "nodes")
# TAGS words the view already reads for something other than a tab.
RESERVED_TAGS = ("systems", "tabs", "term")

# strictdoc's inline link token. The export keeps it literal.
LINK_RE = re.compile(r"\[LINK:\s*([^\]\s]+)\s*\]")
# A line that holds nothing but inline links: a row's reference line.
LINK_ONLY_RE = re.compile(r"^(?:\s*\[LINK:\s*[^\]\s]+\s*\])+\s*$")
# A trailing "[WORD]" or "[WORD: by]" on a row's last line. LINK is excluded
# below so a row that ends in an inline link is not read as a bracket word.
BRACKET_RE = re.compile(r"^(?P<text>.*?)\s*\[(?P<word>[^\[\]:]+?)(?::\s*(?P<by>[^\[\]]*?))?\]\s*$", re.S)
ROW_MARK = "- "
PIPE_MARK = "|"
SOURCE_MARK = "> "
# Widgets whose STATEMENT rows are data. Every other widget reads its whole
# statement as paragraphs. edges and fingerprints take optional rows (the
# allowed targets, the fingerprint ladder); the rest need at least one.
ROW_WIDGETS = ("rows", "glossary", "legend", "table", "facts", "stack", "grid", "ladder", "edges", "fingerprints")
ROWS_OPTIONAL = ("edges", "fingerprints")
DEFAULT_WIDGET = "prose"
SKIP_DIRS = {".git", ".devenv", "output"}


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


def grammar_fields(grammar: dict) -> set:
    return {f["name"] for element in grammar.values() for f in element["fields"]}


# --------------------------------------------------------------------------
# the worktree
# --------------------------------------------------------------------------


def uid_paths(worktree: Path) -> dict:
    """UID -> repo-relative path of the .sdoc that declares it. os.walk, so
    dotted directories such as packages/semble/.sdoc are included."""
    paths: dict = {}
    for dirpath, dirnames, filenames in os.walk(worktree):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if not name.endswith(".sdoc"):
                continue
            full = Path(dirpath) / name
            rel = full.relative_to(worktree).as_posix()
            with open(full, encoding="utf-8") as fh:
                for line in fh:
                    if line.startswith("UID: "):
                        paths.setdefault(line[5:].strip(), rel)
    return paths


def rows_of(parsed) -> list:
    """The systems table's rows as {name, sources, switch}, for the rules that
    have to reason about membership before queries.py is imported."""
    table = parsed.get("table") or {}
    header = [h.lower() for h in table.get("header", [])]
    if any(h not in header for h in SYSTEMS_HEADER):
        return []
    col = {h: header.index(h) for h in SYSTEMS_HEADER}
    out = []
    for row in table.get("rows", []):
        if len(row) < len(header):
            continue
        out.append(
            {
                "name": row[col["system"]].strip(),
                "sources": [w.strip() for w in row[col["sources"]].split(",") if w.strip()],
                "switch": row[col["switch"]].strip().lower(),
            }
        )
    return out


def queries_systems_of(path, rows) -> list:
    """The systems whose source prefixes hold this path. Duplicated from
    queries.systems_of on purpose: view-check must not import the module it
    is the checker for."""
    if not path:
        return []
    return [r["name"] for r in rows if any(str(path).startswith(src) for src in r["sources"])]


def dir_class(path) -> str:
    """spec for docs/spec, plan:<name> for docs/plans/<name>, package for a
    file under a .sdoc directory; other when the path fits none, or is
    unknown."""
    if not path:
        return "other"
    parts = path.split("/")
    if parts[:2] == ["docs", "spec"]:
        return "spec"
    if parts[:2] == ["docs", "plans"] and len(parts) > 3:
        return f"plan:{parts[2]}"
    if ".sdoc" in parts[:-1]:
        return "package"
    return "other"


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


def is_link(text: str) -> bool:
    return LINK_RE.fullmatch(text.strip()) is not None


# ": " outside square brackets -- the inline link token holds one itself.
_PART_SEP = re.compile(r":\s(?![^\[\]]*\])")


def parts_of(text: str, maxsplit: int = 0) -> list:
    """Split a row's headline on ': ' that is not inside a bracket, so a
    '- label: [LINK: UID]' row has two parts, not three."""
    return [p.strip() for p in _PART_SEP.split(text, maxsplit)]


def _blocks(text: str) -> list:
    """Split a STATEMENT into ("para", text), ("row", [lines]) and ("pipe",
    text) blocks: a row starts with "- " and continues on any following
    line that is neither blank nor a row start; a pipe row (a table's) is
    one line starting with "|"; a blank line ends a list. A paragraph's
    lines are joined; a row's lines are kept apart because the row
    conventions read them one by one."""
    blocks: list = []
    mode = None  # None | "para" | "row" | "pipe"
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped:
            mode = None
            continue
        if line.startswith(ROW_MARK):
            blocks.append(["row", [line[len(ROW_MARK) :].strip()]])
            mode = "row"
        elif line.startswith(PIPE_MARK):
            blocks.append(["pipe", stripped])
            mode = "pipe"
        elif mode == "row":
            blocks[-1][1].append(stripped)
        elif mode == "para":
            blocks[-1][1] += " " + stripped
        else:
            blocks.append(["para", stripped])
            mode = "para"
    return [(kind, body) for kind, body in blocks]


def _parse_row(lines: list) -> dict:
    """One row per DEC-ROW-REFERENCE-LINES: the trailing bracket is on the
    LAST line and is split off first; then a line of nothing but links is
    the row's references, a line beginning "> " its source wording, and
    the rest its headline."""
    lines = list(lines)
    word = by = None
    m = BRACKET_RE.match(lines[-1])
    if m and m.group("word").strip() != "LINK":
        word = m.group("word").strip()
        by = m.group("by").strip() if m.group("by") is not None else None
        lines[-1] = m.group("text").strip()
        if not lines[-1]:
            lines.pop()
    headline: list = []
    refs: list = []
    source: list = []
    for i, line in enumerate(lines):
        if line.startswith(SOURCE_MARK):
            source.append(line[len(SOURCE_MARK) :].strip())
        elif i > 0 and LINK_ONLY_RE.match(line):
            refs.extend(LINK_RE.findall(line))
        else:
            headline.append(line)
    return {
        "headline": " ".join(headline).strip(),
        "refs": refs,
        "source": " ".join(source) if source else None,
        "word": word,
        "by": by,
    }


def _table_cells(body: str) -> list:
    cells = [c.strip() for c in body.split("|")]
    if body.startswith("|") and cells and cells[0] == "":
        cells = cells[1:]
    if body.endswith("|") and cells and cells[-1] == "":
        cells = cells[:-1]
    return cells


def _is_separator(cells: list) -> bool:
    return all(re.fullmatch(r":?-+:?", c) for c in cells) if cells else False


def empty_parse() -> dict:
    return {
        "prose": [],
        "rows": [],
        "terms": [],
        "legend": [],
        "table": None,
        "facts": [],
        "stack": [],
        "grid": None,
        "ladder": [],
        "shape": [],
    }


def parse_statement(text: str, widget: str, has_subject: bool = False) -> dict:
    """Parse a STATEMENT per its WIDGET into the wireline's shape.

    Returns the payload keys prose, rows, terms, legend, table, facts,
    stack, grid, ladder, plus "shape": a list of (rule, complaint) pairs
    for the check to file. A non-row widget reads the whole statement as
    paragraphs. `has_subject` says the widget's data lives elsewhere -- an
    Over target whose rows it mirrors (DEC-WIDGET-SUBJECT-IS-ITS-OVER-TARGET),
    a query word in TAGS (MECH-VIEW-QUERIES), or the term narratives a
    glossary Contains (DEC-TERMS-ARE-NARRATIVES) -- so a statement with no
    row is not a shape complaint.
    """
    out = empty_parse()
    if widget not in ROW_WIDGETS:
        out["prose"] = [spans(body) for kind, body in _blocks(text)]
        return out

    rows = []
    for kind, body in _blocks(text):
        if kind == "para":
            out["prose"].append(spans(body))
        elif kind == "pipe":
            if widget == "table":
                rows.append(_parse_row([body]))
            else:
                out["prose"].append(spans(body))
        else:
            rows.append(_parse_row(body))

    if not rows:
        if widget not in ROWS_OPTIONAL and not has_subject:
            out["shape"].append(("widget-shape", f"WIDGET {widget} but the STATEMENT has no '- ' row"))
        return out

    if widget in ("rows", "edges", "fingerprints"):
        for n, row in enumerate(rows, 1):
            out["rows"].append(
                {
                    "n": n,
                    "spans": spans(row["headline"]),
                    "refs": row["refs"],
                    "source": row["source"],
                    "word": row["word"],
                    "by": row["by"],
                    "by_uid": None,
                }
            )
    elif widget == "glossary":
        for n, row in enumerate(rows, 1):
            parts = parts_of(row["headline"], 1)
            term, definition = (parts[0], parts[1]) if len(parts) == 2 else (parts[0], None)
            if definition is None:
                out["shape"].append(("widget-shape", f"glossary row {n} has no ': ' between term and definition"))
                out["terms"].append({"n": n, "term": row["headline"].strip(), "spans": []})
            else:
                out["terms"].append({"n": n, "term": term, "spans": spans(definition)})
    elif widget == "legend":
        for n, row in enumerate(rows, 1):
            parts = parts_of(row["headline"])
            if len(parts) < 3 or len(parts) > 4:
                out["shape"].append(("legend-parts", f"legend row {n} is not 'WORD: colour: meaning' or 'WORD: colour: meaning: by-label'"))
                continue
            word, colour, meaning = parts[:3]
            by_label = parts[3] if len(parts) == 4 else None
            if colour not in COLOURS:
                out["shape"].append(("widget-shape", f"legend row {n} colour {colour!r} is not one of {', '.join(COLOURS)}"))
            out["legend"].append({"word": word, "colour": colour, "meaning": meaning, "by_label": by_label})
    elif widget == "table":
        cells = [_table_cells(row["headline"]) for row in rows]
        if "|" not in rows[0]["headline"]:
            out["shape"].append(("widget-shape", "table has no header row with pipes"))
        out["table"] = {"header": cells[0], "rows": [c for c in cells[1:] if not _is_separator(c)]}
    elif widget == "facts":
        for n, row in enumerate(rows, 1):
            parts = parts_of(row["headline"], 1)
            if len(parts) < 2:
                out["shape"].append(("facts-shape", f"facts row {n} is not '- label: value'"))
                continue
            out["facts"].append({"n": n, "label": parts[0], "spans": spans(parts[1])})
    elif widget == "stack":
        for n, row in enumerate(rows, 1):
            parts = parts_of(row["headline"], 2)
            if len(parts) < 3:
                out["shape"].append(("stack-shape", f"stack row {n} is not '- NAME: label: description'"))
                continue
            out["stack"].append({"n": n, "name": parts[0], "label": parts[1], "spans": spans(parts[2]), "word": row["word"]})
    elif widget == "grid":
        out["grid"] = _parse_grid(rows, out["shape"])
    elif widget == "ladder":
        for n, row in enumerate(rows, 1):
            parts = parts_of(row["headline"])
            if len(parts) < 2:
                out["shape"].append(("widget-shape", f"ladder row {n} is not '- FIELD: rung, rung: note' or '- FIELD: note'"))
                continue
            if len(parts) == 2:
                out["ladder"].append({"field": parts[0], "rungs": None, "note": parts[1]})
            else:
                rungs = [r.strip() for r in parts[1].split(",") if r.strip()]
                out["ladder"].append({"field": parts[0], "rungs": rungs, "note": ": ".join(parts[2:])})
    return out


def _parse_grid(rows: list, shape: list) -> dict:
    """Grid rows: '- word: caption' is an axis caption; '- [LINK: NAR]: row:
    col' places that narrative in a cell; '- [LINK: NAR]: outside' puts it
    in the outside strip. Which captions are row axes and which column axes
    is read off the cells. The grid remembers each row's number (n) so a
    backlink can name the row that placed a narrative."""
    captions: list = []  # (word, caption)
    cells: list = []
    outside: list = []
    for n, row in enumerate(rows, 1):
        parts = parts_of(row["headline"])
        first_is_link = is_link(parts[0])
        if first_is_link and len(parts) == 2 and parts[1] == "outside":
            outside.append({"uid": LINK_RE.match(parts[0]).group(1), "n": n})
        elif first_is_link and len(parts) == 3:
            cells.append({"uid": LINK_RE.match(parts[0]).group(1), "row": parts[1], "col": parts[2], "n": n})
        elif not first_is_link and len(parts) == 2:
            captions.append((parts[0], parts[1]))
        else:
            shape.append(("grid-shape", f"grid row {n} is not an axis caption, a cell ('- [LINK: NAR]: row: col') or '- [LINK: NAR]: outside'"))
    if not cells and not outside:
        shape.append(("grid-shape", "grid has no cell and no outside row"))
    caption_of = dict(captions)
    row_words = []
    col_words = []
    for cell in cells:
        for axis, words in (("row", row_words), ("col", col_words)):
            word = cell[axis]
            if word not in caption_of:
                shape.append(("grid-shape", f"grid row {cell['n']} names {axis} axis {word!r}, which has no caption row"))
            elif word not in words:
                words.append(word)
    used = set(row_words) | set(col_words)
    for word, _caption in captions:
        if word not in used:
            shape.append(("grid-shape", f"axis caption {word!r} is used by no cell"))
    order = [w for w, _ in captions]
    axis = lambda words: [{"word": w, "caption": caption_of[w]} for w in sorted(words, key=order.index)]  # noqa: E731
    return {
        "axes": {"row": axis(row_words), "col": axis(col_words)},
        "cells": [{"uid": c["uid"], "row": c["row"], "col": c["col"], "n": c["n"]} for c in cells],
        "outside": [o["uid"] for o in outside],
        "outside_n": [o["n"] for o in outside],
    }


# --------------------------------------------------------------------------
# node helpers
# --------------------------------------------------------------------------


def relations(node: dict) -> list:
    return node.get("RELATIONS") or []


def contains_targets(node: dict) -> list:
    return [r["VALUE"] for r in relations(node) if r.get("TYPE") == "Child" and r.get("ROLE") == "Contains"]


def cites_targets(node: dict) -> list:
    return [r["VALUE"] for r in relations(node) if r.get("TYPE") == "Parent" and r.get("ROLE") == "Cites"]


def over_targets(node: dict) -> list:
    return [r["VALUE"] for r in relations(node) if r.get("TYPE") == "Parent" and r.get("ROLE") == "Over"]


def is_superseded(node: dict) -> bool:
    if node.get("STATUS") == "superseded":
        return True
    return any(r.get("ROLE") == "Superseded_By" for r in relations(node))


def widget_of(node: dict) -> str:
    return node.get("WIDGET") or DEFAULT_WIDGET


def place_of(node: dict):
    return node.get("PLACE") or None


def tags_of(node: dict) -> list:
    raw = node.get("TAGS") or ""
    return [t.strip() for t in raw.split(",") if t.strip()]


def is_narrative(node) -> bool:
    return node is not None and node.get("_NODE_TYPE") == "NARRATIVE"


def _usage_error(text: str) -> None:
    """Exit 2, so a bad root is never mistaken for a finding (exit 1)."""
    print(text, file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------
# the canon, its roots and the rules
# --------------------------------------------------------------------------


class View:
    """The Contains tree under one root, every narrative's parsed
    STATEMENT, the root's legend, and the findings the walk produced."""

    def __init__(self, canon: "Canon", root: str):
        self.canon = canon
        self.by_uid = canon.by_uid
        self.root = root
        self.findings: list = []
        self.order: list = []  # preorder UIDs of the narratives in the tree
        self.children: dict = {}  # uid -> [child uids], Contains order, valid descents only
        self.parsed: dict = {}  # uid -> parse_statement() result
        self.legend_uid = None
        self.legend: list = []
        self._walk(root, [])
        for uid in self.order:
            node = self.by_uid[uid]
            widget = widget_of(node)
            has_subject = bool(over_targets(node)) or any(t in QUERY_WORDS for t in tags_of(node)) or (widget == "glossary" and bool(self.children.get(uid)))
            self.parsed[uid] = parse_statement(node.get("STATEMENT") or "", widget, has_subject)
        for uid in self.order:
            if widget_of(self.by_uid[uid]) == "legend":
                self.legend_uid = uid
                self.legend = self.parsed[uid]["legend"]
                break
        self._rules()

    def _find(self, rule: str, at: str, text: str) -> None:
        self.findings.append({"root": self.root, "rule": rule, "at": at, "text": text})

    def _walk(self, uid: str, path: list) -> None:
        self.order.append(uid)
        self.children[uid] = []
        for target in contains_targets(self.by_uid[uid]):
            node = self.by_uid.get(target)
            if not is_narrative(node):
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
        legend_words = {e["word"] for e in self.legend}
        fields = self.canon.fields
        root_node = self.by_uid[self.root]
        if place_of(root_node) is not None:
            self._find("place-of-root", self.root, f"{self.root} is a root and carries PLACE {place_of(root_node)}; a root is the page and has no place")

        words_seen = False
        for uid in self.order:
            node = self.by_uid[uid]
            parsed = self.parsed[uid]
            for rule, complaint in parsed["shape"]:
                self._find(rule, uid, complaint)
            for row in parsed["rows"] + parsed["stack"]:
                if row["word"] is None:
                    continue
                words_seen = True
                if self.legend_uid is not None and row["word"] not in legend_words:
                    self._find("legend-word", uid, f"row {row['n']} carries [{row['word']}], which is not in the legend {self.legend_uid}")
            for row in parsed["rows"]:
                for ref in row["refs"]:
                    if ref not in self.by_uid:
                        self._find("reference-line-links-resolve", uid, f"row {row['n']} references {ref}, which is not in the export")
            for entry in parsed["ladder"]:
                if entry["field"] not in fields:
                    self._find("ladder-field-exists", uid, f"ladder row names {entry['field']}, which no grammar element declares as a field")
            for target in cites_targets(node):
                cited = self.by_uid.get(target)
                if cited is not None and is_superseded(cited):
                    self._find("cited-node-superseded", uid, f"{uid} Cites {target}, which is superseded")
            self._over_rules(uid, node)
            self._query_rules(uid, node)
            if LINK_RE.search(node.get("TITLE") or ""):
                self._find("title-holds-a-link", uid, "TITLE holds an inline link token, which is inert there")
        if words_seen and self.legend_uid is None:
            self._find("legend-word", self.root, f"{self.root} has rows with bracket words but no narrative whose WIDGET is legend in its tree")

    def _over_rules(self, uid: str, node: dict) -> None:
        cited = set(cites_targets(node))
        recorded = {p for p, _ in parse_parent_fp(node.get("PARENT_FP"))}
        own_class = self.canon.dir_class_of(uid)
        for target in over_targets(node):
            tnode = self.by_uid.get(target)
            if not is_narrative(tnode):
                kind = "nothing in the export" if tnode is None else f"a {tnode.get('_NODE_TYPE')}"
                self._find("over-target-is-a-narrative", uid, f"{uid} is Over {target}, which is {kind}")
                continue
            tclass = self.canon.dir_class_of(target)
            if tclass != "spec" and tclass != own_class:
                self._find("over-in-plan-or-spec", uid, f"{uid} ({own_class}) is Over {target} ({tclass}); an Over target is in the same plan or in the spec")
            if target in recorded and target not in cited:
                self._find("over-unfingerprinted", uid, f"{uid} carries a PARENT_FP entry for its Over target {target}; Over is never fingerprinted")

    def _query_rules(self, uid: str, node: dict) -> None:
        tags = tags_of(node)
        found = [t for t in tags if t in QUERY_WORDS]
        if len(found) > 1:
            self._find("query-word-known", uid, f"TAGS names {len(found)} query words ({', '.join(found)}); a widget has one subject")
        for tag in tags:
            if tag not in QUERY_WORDS and tag.lower() in QUERY_WORDS:
                self._find("query-word-known", uid, f"TAGS holds {tag!r}; the query word is spelled {tag.lower()!r}")


class Canon:
    """Every root of the export, each with its View, the file each UID
    lives in, and the canon-wide findings no single root owns."""

    def __init__(self, index: dict, paths: dict, grammar: dict, roots=None):
        self.index = index
        self.by_uid = build_uid_index(index)
        self.paths = paths
        self.grammar = grammar
        self.fields = grammar_fields(grammar)
        self.findings: list = []
        self.notes: list = []

        self.container_of: dict = {}
        for uid, node in self.by_uid.items():
            if not is_narrative(node):
                continue
            for target in contains_targets(node):
                first = self.container_of.setdefault(target, uid)
                if first != uid:
                    self._find("contains-is-a-tree", uid, f"{uid} Contains {target}, which {first} already Contains; a narrative has one container")

        self.all_roots = sorted(
            (uid for uid, node in self.by_uid.items() if is_narrative(node) and uid not in self.container_of),
            key=self.root_key,
        )
        if roots is None:
            self.roots = list(self.all_roots)
        else:
            for root in roots:
                node = self.by_uid.get(root)
                if node is None:
                    _usage_error(f"no such node: {root}")
                if not is_narrative(node):
                    _usage_error(f"{root} is a {node.get('_NODE_TYPE')}, not a NARRATIVE")
                if root in self.container_of:
                    _usage_error(f"{root} is not a root: {self.container_of[root]} Contains it")
            self.roots = list(roots)
            for other in self.all_roots:
                if other not in self.roots:
                    self.notes.append({"root": None, "rule": "orphan-narrative", "at": other, "text": f"{other} is another root, outside the tree(s) asked for"})

        self.views = {root: View(self, root) for root in self.roots}
        self._canon_rules()

    def _find(self, rule: str, at: str, text: str) -> None:
        self.findings.append({"root": None, "rule": rule, "at": at, "text": text})

    def dir_class_of(self, uid: str) -> str:
        return dir_class(self.paths.get(uid))

    def root_key(self, uid: str):
        path = self.paths.get(uid)
        cls = dir_class(path)
        directory = path.rsplit("/", 1)[0] if path and "/" in path else (path or "~")
        return (0 if cls == "spec" else 1, directory, uid)

    def tabs_narrative(self):
        """The one narrative tagged tabs, or None. Its shape is checked under
        tabs-table; queries.py parses it."""
        tagged = [uid for uid, node in self.by_uid.items() if is_narrative(node) and "tabs" in tags_of(node)]
        return tagged[0] if len(tagged) == 1 else None

    def systems_narrative(self):
        """The one narrative tagged systems, or None. Its shape is checked
        under systems-table; queries.py parses it."""
        tagged = [uid for uid, node in self.by_uid.items() if is_narrative(node) and "systems" in tags_of(node)]
        return tagged[0] if len(tagged) == 1 else None

    def _canon_rules(self) -> None:
        tagged = sorted(uid for uid, node in self.by_uid.items() if is_narrative(node) and "systems" in tags_of(node))
        if not tagged:
            self._find("systems-table", "canon", "no narrative is tagged systems; the systems table (DEC-SYSTEM-IS-A-TYPE-SET) has nowhere to come from")
        elif len(tagged) > 1:
            self._find("systems-table", tagged[1], f"{len(tagged)} narratives are tagged systems ({', '.join(tagged)}); the table is one narrative")
        else:
            uid = tagged[0]
            node = self.by_uid[uid]
            if widget_of(node) != "table":
                self._find("systems-table", uid, f"{uid} is tagged systems but its WIDGET is {widget_of(node)}, not table")
            else:
                parsed = parse_statement(node.get("STATEMENT") or "", "table")
                header = [h.lower() for h in (parsed["table"] or {}).get("header", [])]
                missing = [h for h in SYSTEMS_HEADER if h not in header]
                if missing:
                    self._find("systems-table", uid, f"{uid}'s header lacks {', '.join(missing)}; the systems table is {' | '.join(SYSTEMS_HEADER)}")
                else:
                    col = {h: header.index(h) for h in SYSTEMS_HEADER}
                    seen = set()
                    always = 0
                    for row in (parsed["table"] or {}).get("rows", []):
                        if len(row) < len(header):
                            continue
                        name = row[col["system"]].strip()
                        if name in seen:
                            self._find("systems-table", uid, f"{uid} names the system {name!r} twice; a name is one row")
                        seen.add(name)
                        switch = row[col["switch"]].strip().lower()
                        if switch not in SWITCH_WORDS:
                            self._find("systems-table", uid, f"{uid}'s system {name!r} has switch {switch!r}; the words are {', '.join(SWITCH_WORDS)}")
                        elif switch == "always":
                            always += 1
                        if not [w for w in row[col["sources"]].split(",") if w.strip()]:
                            self._find("systems-table", uid, f"{uid}'s system {name!r} names no source directory; membership is by path")
                    if seen and not always:
                        self._find("systems-table", uid, f"{uid} pins no system on; the shared model every system cites has to outlive every switch")
                    unheld = sorted({self.dir_class_of(u) for u in self.by_uid if not queries_systems_of(self.paths.get(u), rows_of(parsed))})
                    if unheld:
                        self._find("systems-table", uid, f"no system holds {', '.join(unheld)}; a node no switch can show is unreachable")

        self._tabs_rules()

        for _doc, node in iter_nodes(self.index):
            if is_narrative(node) or "UID" not in node:
                continue
            uid = node["UID"]
            for r in relations(node):
                if r.get("TYPE") == "Parent" and is_narrative(self.by_uid.get(r.get("VALUE"))):
                    self._find("nothing-depends-on-a-narrative", uid, f"{uid} carries {r.get('ROLE')} to the narrative {r['VALUE']}")
            for parent, _digest in parse_parent_fp(node.get("PARENT_FP")):
                if is_narrative(self.by_uid.get(parent)):
                    self._find("nothing-depends-on-a-narrative", uid, f"{uid} carries a PARENT_FP entry for the narrative {parent}")

    def _tabs_rules(self) -> None:
        tagged = sorted(uid for uid, node in self.by_uid.items() if is_narrative(node) and "tabs" in tags_of(node))
        if not tagged:
            self._find("tabs-table", "canon", "no narrative is tagged tabs; the tab strip (DEC-TABS-ARE-A-DECLARED-VOCABULARY) has nowhere to come from")
            return
        if len(tagged) > 1:
            self._find("tabs-table", tagged[1], f"{len(tagged)} narratives are tagged tabs ({', '.join(tagged)}); the table is one narrative")
            return
        uid = tagged[0]
        node = self.by_uid[uid]
        if widget_of(node) != "table":
            self._find("tabs-table", uid, f"{uid} is tagged tabs but its WIDGET is {widget_of(node)}, not table")
            return
        parsed = parse_statement(node.get("STATEMENT") or "", "table")
        header = [h.lower() for h in (parsed["table"] or {}).get("header", [])]
        missing = [h for h in TABS_HEADER if h not in header]
        if missing:
            self._find("tabs-table", uid, f"{uid}'s header lacks {', '.join(missing)}; the tabs table is {' | '.join(TABS_HEADER)}")
            return
        col = {h: header.index(h) for h in TABS_HEADER}
        keys = []
        for row in (parsed["table"] or {}).get("rows", []):
            if len(row) < len(header):
                continue
            key = row[col["tab"]].strip()
            if key in keys:
                self._find("tabs-table", uid, f"{uid} names the tab {key!r} twice; a key is one row")
            if key in PAGE_TABS:
                self._find("tabs-table", uid, f"{uid} declares {key!r}, which the page owns; the table names only the tabs between Start and Nodes")
            if key in RESERVED_TAGS or key in QUERY_WORDS:
                self._find("tabs-table", uid, f"{uid} declares the tab {key!r}, but the view already reads that TAGS word for something else")
            keys.append(key)
        # every PLACE: tab narrative joins exactly one declared tab, and every
        # declared tab has somebody joining it -- a tab nobody joins is a strip
        # entry that opens on nothing
        joined = {}
        for u, nd in self.by_uid.items():
            if not is_narrative(nd) or place_of(nd) != "tab":
                continue
            named = [t for t in tags_of(nd) if t in keys]
            if not named:
                self._find("tab-membership", u, f"{u} has PLACE: tab but its TAGS name no tab; the keys are {', '.join(keys)}")
            elif len(named) > 1:
                self._find("tab-membership", u, f"{u} names {len(named)} tabs ({', '.join(named)}); a contribution joins one")
            else:
                joined.setdefault(named[0], []).append(u)
        for key in keys:
            if key not in joined:
                self._find("tabs-table", uid, f"no narrative joins the tab {key!r}; a declared tab nobody joins opens on nothing")

    def all_findings(self) -> list:
        out = []
        for root in self.roots:
            out.extend(self.views[root].findings)
        out.extend(self.findings)
        return out


def build_canon(index: dict, worktree: Path, grammar: dict, roots=None) -> Canon:
    return Canon(index, uid_paths(worktree), grammar, roots)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    parser.add_argument("worktree", type=Path)
    parser.add_argument("--root", help="UID of one root narrative (default: every root)")
    parser.add_argument("--all-roots", action="store_true", help="every root (the default)")
    parser.add_argument("--grammar", type=Path, help="grammar file (default: <worktree>/docs/sdoc/grammar.sgra)")
    args = parser.parse_args()
    if not args.worktree.is_dir():
        parser.error(f"worktree {args.worktree} is not a directory")
    if args.root and args.all_roots:
        parser.error("--root and --all-roots exclude each other")
    grammar_path = args.grammar or args.worktree / "docs" / "sdoc" / "grammar.sgra"
    if not grammar_path.is_file():
        parser.error(f"grammar {grammar_path} does not exist")

    canon = build_canon(load_index(args.export_json), args.worktree, parse_sgra(grammar_path), [args.root] if args.root else None)

    total = 0
    for root in canon.roots:
        findings = canon.views[root].findings
        total += len(findings)
        noun = "finding" if len(findings) == 1 else "findings"
        print(f"{len(findings)} {noun} under {root}")
        for f in findings:
            print(f"  {f['rule']}  at {f['at']}: {f['text']}")
    total += len(canon.findings)
    noun = "finding" if len(canon.findings) == 1 else "findings"
    print(f"{len(canon.findings)} canon-wide {noun}")
    for f in canon.findings:
        print(f"  {f['rule']}  at {f['at']}: {f['text']}")
    if canon.notes:
        print(f"{len(canon.notes)} note(s)")
        for n in canon.notes:
            print(f"  {n['rule']}  at {n['at']}: {n['text']}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
