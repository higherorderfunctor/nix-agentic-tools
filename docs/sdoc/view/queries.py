#!/usr/bin/env python3
# cspell:ignore uids
"""queries -- MECH-VIEW-QUERIES. The closed list of query words and the table
each computes over the whole export.

A narrative can draw over what it Contains or names with Over. A few tables
no narrative can name by relation without crossing a plan boundary: the
roots of every view, every node of the canon, the systems table, every
ruled term, and the grammar itself. A widget whose subject is one of those
names the query word in its TAGS; the wireline calls this module and puts
the table in the payload. The list is closed: a new word is a canon
decision and an edit here.

  roots    every root narrative: uid, title, dir_class, path
  nodes    every node's count and facets: by type, dir_class, system,
           DEPTH, STATUS, AUTHORED_BY and whether any narrative cites it
  systems  the systems table, parsed from the one narrative tagged systems
           (DEC-SYSTEM-IS-A-TYPE-SET): name, types, roles, meaning
  terms    every narrative tagged term: uid, title, dir_class, path
  grammar  the grammar, as view-check.parse_sgra reads it

Nothing here knows a UID: the systems narrative is found by its tag, the
terms by theirs, the roots by having no container.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path


def _import_view_check():
    spec = importlib.util.spec_from_file_location("view_check", Path(__file__).resolve().with_name("view-check.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vc = _import_view_check()

QUERY_WORDS = vc.QUERY_WORDS
STATE_FIELDS = ("DEPTH", "STATUS", "AUTHORED_BY")


def query_of(tags: list):
    """The query word a narrative's TAGS names, or None. view-check files a
    finding when there are two; the first wins here."""
    return next((t for t in tags if t in QUERY_WORDS), None)


def _split_words(cell: str) -> list:
    return [w.strip() for w in cell.split(",") if w.strip()]


def _row_of(canon, uid: str) -> dict:
    node = canon.by_uid[uid]
    return {"uid": uid, "title": node.get("TITLE", uid), "dir_class": canon.dir_class_of(uid), "path": canon.paths.get(uid)}


def roots(canon) -> list:
    """Every root narrative of the export, spec first, then by directory,
    then UID -- the same order the payload's roots list uses."""
    return [_row_of(canon, uid) for uid in canon.all_roots]


def terms(canon) -> list:
    """Every narrative tagged term (DEC-TERMS-ARE-NARRATIVES), in root order."""
    uids = [uid for uid, node in canon.by_uid.items() if vc.is_narrative(node) and "term" in vc.tags_of(node)]
    return [_row_of(canon, uid) for uid in sorted(uids, key=canon.root_key)]


def tabs(canon) -> list:
    """The tabs table: one entry per row of the narrative tagged tabs, whose
    table widget has the header tab | title | meaning. The strip's order is
    the table's. Empty when no single such narrative exists (view-check's
    tabs-table rule says why)."""
    uid = canon.tabs_narrative()
    if uid is None:
        return []
    node = canon.by_uid[uid]
    if vc.widget_of(node) != "table":
        return []
    table = vc.parse_statement(node.get("STATEMENT") or "", "table")["table"]
    if not table:
        return []
    header = [h.lower() for h in table["header"]]
    if any(h not in header for h in vc.TABS_HEADER):
        return []
    col = {h: header.index(h) for h in vc.TABS_HEADER}
    out = []
    for row in table["rows"]:
        if len(row) < len(header):
            continue
        out.append({"key": row[col["tab"]].strip(), "title": row[col["title"]].strip(), "meaning": row[col["meaning"]]})
    return out


def tab_of(tags: list, table: list):
    """The tab key a narrative's TAGS names, or None. view-check files a
    finding when there are two; the first wins here."""
    keys = [t["key"] for t in table]
    return next((t for t in tags if t in keys), None)


def systems(canon) -> list:
    """The systems table: one entry per row of the narrative tagged systems,
    whose table widget has the header system | sources | switch | meaning.
    Columns are matched by header word, so their order is the author's.
    Empty when no single such narrative exists (view-check's systems-table
    rule says why); wireline refuses to write a payload with no systems
    rather than shipping a page whose switches silently vanish."""
    uid = canon.systems_narrative()
    if uid is None:
        return []
    node = canon.by_uid[uid]
    if vc.widget_of(node) != "table":
        return []
    table = vc.parse_statement(node.get("STATEMENT") or "", "table")["table"]
    if not table:
        return []
    header = [h.lower() for h in table["header"]]
    if any(h not in header for h in vc.SYSTEMS_HEADER):
        return []
    col = {h: header.index(h) for h in vc.SYSTEMS_HEADER}
    out = []
    for row in table["rows"]:
        if len(row) < len(header):
            continue
        out.append(
            {
                "name": row[col["system"]].strip(),
                "sources": _split_words(row[col["sources"]]),
                "switch": row[col["switch"]].strip().lower(),
                "meaning": row[col["meaning"]],
            }
        )
    return out


def systems_of(path, table: list) -> list:
    """The names of the systems whose source directories hold this path: a
    set, not a partition, since one prefix may contain another
    (DEC-SYSTEM-IS-A-SOURCE-SET)."""
    if not path:
        return []
    return [s["name"] for s in table if any(str(path).startswith(src) for src in s["sources"])]


def nodes(canon, table: list, cited: set) -> dict:
    """Every node's count and its facets. `cited` is the set of UIDs some
    narrative Cites; the renderer's node index draws these as its filters
    and recomputes them over the selection, so the numbers here are the
    whole canon's."""
    facets: dict = {"type": {}, "dir_class": {}, "system": {}, "cited": {"cited": 0, "uncited": 0}}
    for field in STATE_FIELDS:
        facets[field] = {}

    def bump(facet: str, key) -> None:
        facets[facet][key] = facets[facet].get(key, 0) + 1

    for uid, node in canon.by_uid.items():
        node_type = node.get("_NODE_TYPE")
        bump("type", node_type)
        bump("dir_class", canon.dir_class_of(uid))
        for name in systems_of(canon.paths.get(uid), table):
            bump("system", name)
        for field in STATE_FIELDS:
            if field in node:
                bump(field, node[field])
        facets["cited"]["cited" if uid in cited else "uncited"] += 1
    return {"count": len(canon.by_uid), "facets": facets}


def grammar(grammar_table: dict) -> dict:
    """The grammar query is the grammar itself; the renderer draws each
    element's fields and roles with live counts over the selection."""
    return grammar_table
