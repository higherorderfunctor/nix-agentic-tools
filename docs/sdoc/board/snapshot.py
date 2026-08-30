#!/usr/bin/env python3
"""Compile the loaded StrictDoc project into the sdoc-board/1 snapshot."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.metadata
import io
import json
import os
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from strictdoc.api import Parallelizer, ProjectConfigLoader, TraceabilityIndexBuilder

SCHEMA = "sdoc-board/1"


@dataclass(frozen=True)
class LoadedProject:
    """The retained StrictDoc objects and the browser-safe view of them."""

    project_config: Any
    traceability_index: Any
    snapshot: dict[str, Any]


def find_project_root(start: Path) -> Path:
    """Walk upward to the StrictDoc project marker."""
    current = start.resolve()
    if current.is_file():
        current = current.parent
    for candidate in (current, *current.parents):
        if (candidate / "strictdoc_config.py").is_file():
            return candidate
    raise FileNotFoundError(f"no strictdoc_config.py above {start}")


def load_project(project_root: Path, cache_dir: Path) -> LoadedProject:
    """Load StrictDoc once and retain its in-memory index beside the snapshot."""
    project_root = find_project_root(project_root)
    previous = Path.cwd()
    chatter = io.StringIO()
    parallelizer = Parallelizer.create(False, dynamic=True)
    try:
        os.chdir(project_root)
        with contextlib.redirect_stdout(chatter):
            project_config = ProjectConfigLoader.load(
                input_path=str(project_root), output_dir=str(cache_dir)
            )
            traceability_index = TraceabilityIndexBuilder.create(
                project_config=project_config,
                parallelizer=parallelizer,
                skip_source_files=True,
            )
    except BaseException:
        print(chatter.getvalue(), end="")
        raise
    finally:
        parallelizer.shutdown()
        os.chdir(previous)

    snapshot = compile_snapshot(project_root, traceability_index)
    return LoadedProject(project_config, traceability_index, snapshot)


def _document_path(document: Any) -> str:
    path = document.meta.input_doc_rel_path
    return path.relative_path_posix


def _iter_unique_nodes(traceability_index: Any) -> Iterable[tuple[Any, str]]:
    seen_objects: set[int] = set()
    for document in traceability_index.document_tree.document_list:
        path = _document_path(document)
        for node in document.iterate_nodes():
            marker = id(node)
            if marker in seen_objects:
                continue
            seen_objects.add(marker)
            yield node, path


def _field_map(node: Any) -> dict[str, str]:
    return {
        field.field_name: field.get_text_value()
        for field in node.enumerate_fields()
    }


def _node_id(node: Any, path: str) -> tuple[str, str]:
    uid = node.reserved_uid
    if uid:
        return uid, "uid"
    mid = str(node.reserved_mid)
    if node.mid_permanent:
        return f"mid:{mid}", "permanent-mid"
    fallback = f"{path}:{node.ng_byte_start}:{node.node_type}"
    digest = hashlib.sha256(fallback.encode("utf-8")).hexdigest()[:20]
    return f"derived:{digest}", "source-location"


def _state_of(fields: dict[str, str]) -> dict[str, str] | None:
    for name in ("STATUS", "DEPTH"):
        if value := fields.get(name):
            return {"field": name, "value": value}
    return None


def _summary_of(fields: dict[str, str]) -> str:
    value = fields.get("STATEMENT") or fields.get("DESCRIPTION") or ""
    return " ".join(value.split())[:280]


def _grammar_descriptor(node: Any) -> dict[str, Any]:
    element = node.get_document().grammar.elements_by_type[node.node_type]
    fields = []
    for field in element.fields:
        descriptor: dict[str, Any] = {
            "name": field.title,
            "required": bool(field.required),
            "type": field.gef_type,
        }
        if options := getattr(field, "options", None):
            descriptor["options"] = list(options)
        fields.append(descriptor)
    relations = [
        {
            "type": relation.relation_type,
            "role": getattr(relation, "relation_role", None),
            "reverseRole": getattr(relation, "reverse_relation_role", None),
        }
        for relation in element.relations
    ]
    return {
        "prefix": element.property_prefix,
        "fields": fields,
        "relations": relations,
    }


def _reverse_roles(grammar: dict[str, Any]) -> dict[tuple[str, str, str | None], str | None]:
    return {
        (tag, relation["type"], relation["role"]): relation["reverseRole"]
        for tag, element in grammar.items()
        for relation in element["relations"]
    }


def _stable_hash(nodes: list[dict[str, Any]], edges: list[dict[str, Any]]) -> str:
    stable_nodes = [
        {
            key: value
            for key, value in node.items()
            if key not in ("mid", "midPermanent")
        }
        for node in nodes
    ]
    payload = json.dumps(
        {"nodes": stable_nodes, "edges": edges},
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def compile_snapshot(project_root: Path, traceability_index: Any) -> dict[str, Any]:
    """Project StrictDoc objects without parsing any source syntax ourselves."""
    records: list[tuple[Any, dict[str, Any]]] = []
    grammar: dict[str, Any] = {}
    diagnostics: list[dict[str, Any]] = []

    for node, path in _iter_unique_nodes(traceability_index):
        node_id, identity = _node_id(node, path)
        fields = _field_map(node)
        record = {
            "id": node_id,
            "identity": identity,
            "mid": str(node.reserved_mid),
            "midPermanent": bool(node.mid_permanent),
            "uid": node.reserved_uid,
            "type": node.node_type,
            "title": fields.get("TITLE") or node_id,
            "summary": _summary_of(fields),
            "state": _state_of(fields),
            "fields": fields,
            "source": {
                "path": path,
                "lineStart": node.ng_line_start,
                "lineEnd": node.ng_line_end,
            },
        }
        records.append((node, record))
        grammar.setdefault(node.node_type, _grammar_descriptor(node))
        if identity == "source-location":
            diagnostics.append(
                {
                    "kind": "derived-identity",
                    "node": node_id,
                    "message": "Node has neither a UID nor a permanent MID.",
                }
            )

    records.sort(
        key=lambda item: (
            item[1]["source"]["path"],
            item[1]["source"]["lineStart"] or 0,
            item[1]["id"],
        )
    )
    nodes = [record for _, record in records]
    ids = {record["id"] for record in nodes}
    uid_to_id = {
        record["uid"]: record["id"] for record in nodes if record["uid"]
    }
    reverse_roles = _reverse_roles(grammar)

    edges: list[dict[str, Any]] = []
    edge_counts: Counter[tuple[str, str, str, str | None]] = Counter()
    for node, source in records:
        files: list[str] = []
        for relation in node.relations:
            relation_type = getattr(relation, "ref_type", None)
            if relation_type == "File":
                files.append(relation.get_posix_path())
                continue
            if relation_type not in ("Parent", "Child"):
                continue
            target_uid = relation.ref_uid
            target_id = uid_to_id.get(target_uid)
            if target_id is None:
                diagnostics.append(
                    {
                        "kind": "unresolved-relation",
                        "node": source["id"],
                        "target": target_uid,
                        "message": "StrictDoc relation target is absent from the board snapshot.",
                    }
                )
                continue
            role = relation.role
            key = (source["id"], target_id, relation_type, role)
            occurrence = edge_counts[key]
            edge_counts[key] += 1
            edges.append(
                {
                    "id": f"{source['id']}:{target_id}:{relation_type}:{role or ''}:{occurrence}",
                    "source": source["id"],
                    "target": target_id,
                    "type": relation_type,
                    "role": role,
                    "reverseRole": reverse_roles.get(
                        (source["type"], relation_type, role)
                    ),
                    "declaredBy": source["id"],
                }
            )
        source["files"] = sorted(files)

    edges.sort(
        key=lambda edge: (
            edge["source"],
            edge["target"],
            edge["type"],
            edge["role"] or "",
            edge["id"],
        )
    )
    if ids != {edge["source"] for edge in edges} | ids:
        raise AssertionError("edge source outside node set")
    if any(edge["target"] not in ids for edge in edges):
        raise AssertionError("edge target outside node set")

    type_counts = Counter(node["type"] for node in nodes)
    role_counts = Counter(edge["role"] or edge["type"] for edge in edges)
    snapshot_hash = _stable_hash(nodes, edges)
    return {
        "schema": SCHEMA,
        "project": {
            "name": project_root.name,
            "root": str(project_root),
            "strictdocVersion": importlib.metadata.version("strictdoc"),
            "loadedAt": datetime.now(timezone.utc).isoformat(),
            "snapshotHash": snapshot_hash,
        },
        "stats": {
            "nodes": len(nodes),
            "edges": len(edges),
            "diagnostics": len(diagnostics),
            "types": dict(sorted(type_counts.items())),
            "roles": dict(sorted(role_counts.items())),
        },
        "grammar": {key: grammar[key] for key in sorted(grammar)},
        "nodes": nodes,
        "edges": edges,
        "diagnostics": diagnostics,
    }
