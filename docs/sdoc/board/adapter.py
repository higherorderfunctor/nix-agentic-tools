#!/usr/bin/env python3
"""Adapt one scribe-daemon JSON export into the board's browser payloads.

Pure functions over data already on disk: the daemon's `workspace.export`
JSON, the worktree walk that maps each UID to its declaring file, and the
`.sgra` grammar file. Nothing here talks to the daemon or imports strictdoc,
which is what keeps the whole app runnable under any python3.

Two payloads out of one pass:

  snapshot  sdoc-board/2 -- the graph the Board canvas draws: one record per
            node, one edge per resolved Parent/Child declaration, the grammar
            vocabulary, and diagnostics for what did not resolve.
  rows      sdoc-perspective/2 -- what the Perspective explorer loads as TWO
            named tables. `nodes` is one row per node. `relations` is one row
            per declared relation, denormalized with both endpoints' type,
            title, state and path, so relations are queryable directly --
            the first spike squashed them into comma-joined facet strings on
            the node row, which Perspective cannot explode back into rows.

Every row of a table carries the same key set (absent fields are null):
Perspective infers a column schema from the rows, and a key that appears
only late in the list would otherwise never become a column.

A File relation may name one ITEM in the file rather than the whole of it
(`ELEMENT: function` with `ID: <qualified name>`, or a LINE_RANGE). Both
payloads carry those slots, and both do it ADDITIVELY: `node.files` stays
the sorted list of plain paths every existing consumer reads, and the
element-grained view arrives beside it as `node.fileRelations`. That is why
neither schema string moves here -- a reader written against sdoc-board/2
keeps working unchanged, and one that knows about items reads the new key.

`kind` is the one thing in those payloads that is NOT in the export, and it
is why this module grew an optional import. ELEMENT is strictdoc's closed
vocabulary -- `function` and `class`, nothing else -- so a Nix option, a
module and a plain binding all export as `function` and the card drew all
three identically. The KIND word (`option`, `module`, `binding`) exists only
in the extractor, so the adapter resolves each id against the file it names
and recovers it. Only files an existing relation NAMES are parsed, one
tree-sitter parse each, cached on the file's stat -- never the corpus.

THAT IMPORT IS SOFT, AND DELIBERATELY SO. "Nothing here imports strictdoc,
which is what keeps the whole app runnable under any python3" is worth more
than the kind word: the board is served and tested by a plain `python3`,
while the extractor needs `tree_sitter` and a compiled grammar. A missing
extractor therefore leaves `kind` null and the card falls back to the ELEMENT
it always drew. This degrades a label; it must never take the board down.
"""

from __future__ import annotations

import importlib.util
import sys
from collections import Counter
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "dev" / "scripts"))

from sdoc_fp import iter_nodes, load_index  # noqa: E402,F401
from scribe_grammar import parse_sgra  # noqa: E402,F401


def _view_check():
    """docs/sdoc/view/view-check.py, loaded the way wireline.py loads it --
    the module name carries a hyphen. Only `uid_paths` is used here; the walk
    that maps UIDs to files belongs to the checker and is not duplicated."""
    path = REPO_ROOT / "docs" / "sdoc" / "view" / "view-check.py"
    spec = importlib.util.spec_from_file_location("view_check", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


uid_paths = _view_check().uid_paths

SNAPSHOT_SCHEMA = "sdoc-board/2"
ROWS_SCHEMA = "sdoc-perspective/2"
SEMANTICS_SCHEMA = "sdoc-semantics/2"
STATE_FIELDS = ("STATUS", "DEPTH")
STRUCTURAL = ("_TOC", "_NODE_TYPE", "RELATIONS")


def kind_resolver(source_root):
    """(path, id) -> the extractor's KIND word, or None.

    Returns a resolver that always answers None when the extractor is not
    importable here (no `tree_sitter`, no compiled grammar). Everything below
    treats None as "no kind", which is exactly what a payload written before
    this existed carries, so the card's fallback covers both cases with one
    branch.

    Anything the extractor raises is swallowed BY DESIGN. A file that fails
    to parse, or a path no configured glob covers, is a finding for
    dev/scripts/element-check.py -- the gate whose whole job is to say so,
    loudly, with a node and an id. Repeating it here would put a stack trace
    between the operator and their board over a cosmetic label.
    """
    try:
        from sdoc_extractors import registry
    except ImportError:
        return lambda _path, _identifier: None

    def kind_of(path: str | None, identifier: str | None) -> str | None:
        if not path or not identifier:
            return None
        try:
            item = registry.item_of(
                Path(source_root) / path, identifier, path_root=source_root
            )
        except Exception:  # noqa: BLE001 - a label is never worth a 500
            return None
        return None if item is None else item.kind

    return kind_of


def _state_of(node: dict) -> dict | None:
    for name in STATE_FIELDS:
        if value := node.get(name):
            return {"field": name, "value": value}
    return None


def _summary_of(node: dict) -> str:
    value = node.get("STATEMENT") or ""
    return " ".join(value.split())[:280]


def _fields_of(node: dict) -> dict:
    return {
        name: value
        for name, value in node.items()
        if name not in STRUCTURAL and isinstance(value, str)
    }


def _normalize(rows: list[dict]) -> list[dict]:
    """Give every row the union key set, in first-seen order."""
    names: dict = {}
    for row in rows:
        for name in row:
            names.setdefault(name, None)
    return [{name: row.get(name) for name in names} for row in rows]


def semantics_unavailable(reason: str) -> dict:
    """The payload shape that says "no lifecycles here, and why".

    Every consumer -- the board's Grammars tab included -- reads
    `machines` and `by_type` unconditionally, so the absent case is the
    SAME shape with both empty plus a `unavailable` string. There is no
    missing key and no null to branch on: a semantics engine that will not
    import must not cost the operator their board.
    """
    return {
        "schema": SEMANTICS_SCHEMA,
        "machines": {},
        "by_type": {},
        "gates": [],
        "relation_contracts": [],
        "actors": [],
        "commands": [],
        "events": [],
        "operations": [],
        "milestones": [],
        "checkpoints": [],
        "flows": [],
        "gate_placement": [],
        "unavailable": reason,
    }


def adapt(
    index: dict,
    paths: dict,
    grammar: dict,
    project: dict,
    *,
    semantics=None,
    source_root=None,
) -> dict:
    """One export in, both payloads out. `project` is passed through verbatim
    into each payload's `project` key (root, generation, and friends).

    `semantics` is the `sdoc-semantics/2` payload the engine computes from
    the same parsed grammar (states, transitions and rules per state field).
    The adapter does not compute it and does not validate it -- it carries
    it through onto the snapshot so one fetch answers both questions the
    Grammars tab asks about a type: what it may declare, and how its state
    fields may move. Absent, the snapshot carries the explicit unavailable
    shape rather than a missing key.

    `source_root` is the tree a File relation's path resolves against, for the
    kind lookup. It defaults to `project["root"]` -- the server already puts
    the worktree there -- and to this file's own repository when that key is
    absent, which is the fixture case.
    """
    kind_of = kind_resolver(source_root or project.get("root") or REPO_ROOT)
    records: list[dict] = []
    diagnostics: list[dict] = []
    for _doc_title, node in iter_nodes(index):
        uid = node.get("UID")
        if not uid:
            diagnostics.append(
                {
                    "kind": "missing-uid",
                    "node": node.get("TITLE") or "?",
                    "message": "Exported node carries no UID.",
                }
            )
            continue
        records.append(
            {
                "id": uid,
                "type": node.get("_NODE_TYPE"),
                "title": node.get("TITLE") or uid,
                "summary": _summary_of(node),
                "state": _state_of(node),
                "fields": _fields_of(node),
                "source": {"path": paths.get(uid)},
                "relations": node.get("RELATIONS") or [],
            }
        )

    records.sort(key=lambda r: (r["source"]["path"] or "", r["id"]))
    by_uid = {record["id"]: record for record in records}

    edges: list[dict] = []
    edge_counts: Counter = Counter()
    relation_rows: list[dict] = []
    inbound: Counter = Counter()
    for record in records:
        file_relations: list[dict] = []
        for relation in record.pop("relations"):
            rel_type = relation.get("TYPE")
            value = relation.get("VALUE")
            role = relation.get("ROLE")
            if rel_type == "File":
                kind = kind_of(value, relation.get("ID"))
                file_relations.append(_file_relation(relation, value, kind))
                relation_rows.append(
                    _relation_row(
                        record, "File", None, value, None, relation, kind
                    )
                )
                continue
            if rel_type not in ("Parent", "Child"):
                continue
            target = by_uid.get(value)
            if target is None:
                diagnostics.append(
                    {
                        "kind": "unresolved-relation",
                        "node": record["id"],
                        "target": value,
                        "message": "Relation target is absent from the export.",
                    }
                )
                relation_rows.append(
                    _relation_row(record, rel_type, role, value, None, relation)
                )
                continue
            inbound[value] += 1
            key = (record["id"], value, rel_type, role)
            occurrence = edge_counts[key]
            edge_counts[key] += 1
            edges.append(
                {
                    "id": f"{record['id']}:{value}:{rel_type}:{role or ''}:{occurrence}",
                    "source": record["id"],
                    "target": value,
                    "type": rel_type,
                    "role": role,
                }
            )
            relation_rows.append(
                _relation_row(record, rel_type, role, value, target, relation)
            )
        record["fileRelations"] = sorted(
            file_relations, key=lambda f: (f["path"] or "", f["id"] or "", f["element"] or "")
        )
        # Kept as the sorted DISTINCT paths rather than one entry per
        # relation: two relations naming two items of one file are one file,
        # and FILE_COUNT has always meant files.
        record["files"] = sorted({f["path"] for f in record["fileRelations"]})

    edges.sort(key=lambda e: (e["source"], e["target"], e["type"], e["role"] or "", e["id"]))
    outbound = Counter(edge["source"] for edge in edges)

    node_rows = [
        {
            "UID": record["id"],
            "TYPE": record["type"],
            "PATH": record["source"]["path"],
            "DIR": _dir_of(record["source"]["path"]),
            "OUT_COUNT": outbound.get(record["id"], 0),
            "IN_COUNT": inbound.get(record["id"], 0),
            "FILE_COUNT": len(record["files"]),
            **record["fields"],
        }
        for record in records
    ]

    type_counts = Counter(record["type"] for record in records)
    role_counts = Counter(edge["role"] or edge["type"] for edge in edges)
    stats = {
        "nodes": len(records),
        "edges": len(edges),
        "diagnostics": len(diagnostics),
        "types": dict(sorted(type_counts.items())),
        "roles": dict(sorted(role_counts.items())),
    }
    return {
        "snapshot": {
            "schema": SNAPSHOT_SCHEMA,
            "project": project,
            "stats": stats,
            "grammar": {tag: grammar[tag] for tag in sorted(grammar)},
            "semantics": semantics
            or semantics_unavailable("No semantics payload reached the adapter."),
            "nodes": records,
            "edges": edges,
            "diagnostics": diagnostics,
        },
        "rows": {
            "schema": ROWS_SCHEMA,
            "project": project,
            "stats": stats,
            "nodes": _normalize(node_rows),
            "relations": _normalize(relation_rows),
        },
    }


def _dir_of(path: str | None) -> str | None:
    if not path:
        return None
    head, _, _tail = path.rpartition("/")
    return head or "."


def _file_relation(
    relation: dict, path: str | None, kind: str | None = None
) -> dict:
    """One File relation as the card draws it: the file, the item in it when
    the relation names one, and that item's kind when the extractor knows it."""
    return {
        "path": path,
        "element": relation.get("ELEMENT"),
        "kind": kind,
        "id": relation.get("ID"),
        "lineRange": relation.get("LINE_RANGE"),
    }


def _relation_row(
    source: dict,
    rel_type: str,
    role,
    value,
    target: dict | None,
    relation: dict,
    kind: str | None = None,
) -> dict:
    row = {
        "SOURCE": source["id"],
        "SOURCE_TYPE": source["type"],
        "SOURCE_TITLE": source["title"],
        "SOURCE_PATH": source["source"]["path"],
        "TYPE": rel_type,
        "ROLE": role,
        "TARGET": value,
        "RESOLVED": target is not None or rel_type == "File",
        # In the BASE dict, not added only where a File relation carries
        # them: Perspective infers its columns from the row list, so a key
        # that first appears on some later row never becomes a column at
        # all. A corpus with no element-grained relation still gets the
        # columns, all null.
        "ELEMENT": relation.get("ELEMENT"),
        # The extractor's word for what the item IS, where ELEMENT is
        # strictdoc's two-value marker vocabulary. Null when the extractor is
        # unavailable or the id resolves to nothing -- which is a finding for
        # element-check, not for a table column.
        "ELEMENT_KIND": kind,
        "ELEMENT_ID": relation.get("ID"),
        "LINE_RANGE": relation.get("LINE_RANGE"),
    }
    if target is not None:
        state = target["state"] or {}
        row.update(
            {
                "TARGET_TYPE": target["type"],
                "TARGET_TITLE": target["title"],
                "TARGET_PATH": target["source"]["path"],
                "TARGET_STATE": state.get("value"),
            }
        )
    return row
