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
STATE_FIELDS = ("STATUS", "DEPTH")
STRUCTURAL = ("_TOC", "_NODE_TYPE", "RELATIONS")


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


def adapt(index: dict, paths: dict, grammar: dict, project: dict) -> dict:
    """One export in, both payloads out. `project` is passed through verbatim
    into each payload's `project` key (root, generation, and friends)."""
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
        files: list[str] = []
        for relation in record.pop("relations"):
            rel_type = relation.get("TYPE")
            value = relation.get("VALUE")
            role = relation.get("ROLE")
            if rel_type == "File":
                files.append(value)
                relation_rows.append(
                    _relation_row(record, "File", None, value, None)
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
                    _relation_row(record, rel_type, role, value, None)
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
                _relation_row(record, rel_type, role, value, target)
            )
        record["files"] = sorted(files)

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


def _relation_row(source: dict, rel_type: str, role, value, target: dict | None) -> dict:
    row = {
        "SOURCE": source["id"],
        "SOURCE_TYPE": source["type"],
        "SOURCE_TITLE": source["title"],
        "SOURCE_PATH": source["source"]["path"],
        "TYPE": rel_type,
        "ROLE": role,
        "TARGET": value,
        "RESOLVED": target is not None or rel_type == "File",
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
