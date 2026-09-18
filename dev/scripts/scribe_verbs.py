"""Shared implementations for scribe operations over an already loaded graph.

This module is a library, not a command. ``scribe_cmd.py`` owns argv and the
grammar-derived option surface; ``scribe_ops.py`` owns typed daemon operations.
The small helpers here keep their common graph rendering and path rules in one
place without reopening the corpus or exposing a second executable surface.
"""

from __future__ import annotations

import sys
from pathlib import Path

from sdoc_model import (
    SdocError,
    field_value,
    file_entry_of,
    file_path_of,
    normalize_file_value,
)


def check_prefix(graph, tag: str, uid: str) -> None:
    """Require a new node to carry its grammar element's current prefix."""
    prefix = graph.element(tag).property_prefix
    if not uid.startswith(prefix):
        raise SdocError(
            f"{uid!r} is not a {tag} name: the grammar gives {tag} the prefix "
            f"{prefix!r}. UIDs are hand-chosen and semantic; nothing here mints one."
        )


def prefix_owner(graph, uid: str):
    """Return the element owning this current prefix, or None for history."""
    for tag in graph.tags():
        if uid.startswith(graph.element(tag).property_prefix):
            return tag
    return None


def target_path(raw: str, uid: str, root: Path) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        path = root / path
    if path.is_dir() or raw.endswith("/"):
        path = path / f"{uid.lower()}.sdoc"
    if path.suffix != ".sdoc":
        raise SdocError(f"{path} is not a .sdoc file")
    return path


def describe_file_relation(relation) -> str:
    """Render a file relation, including any element or line selection."""
    entry = file_entry_of(relation)
    text = file_path_of(relation)
    if entry["element"] or entry["id"]:
        text += f"  > {entry['element'] or '?'} {entry['id'] or '?'}"
    if entry["line_range"]:
        text += f"  [{entry['line_range']}]"
    return text


def do_show(graph, args, _root: Path) -> int:
    node = graph.node(args.uid)
    print(graph.render(node.get_document()), end="")
    if node.relations:
        print("\n--- relations resolved ---")
        for relation in node.relations:
            uid = getattr(relation, "ref_uid", None)
            if uid is None:
                print(f"  {'File':<13} {describe_file_relation(relation)}")
                continue
            target = graph.index.get_node_by_uid_weak(uid)
            title = target.reserved_title if target is not None else "(UNRESOLVED)"
            print(f"  {relation.role:<13} {uid}  --  {title}")
    return 0


def do_list(graph, args, root: Path) -> int:
    rows = []
    for node in graph.iter_nodes():
        if args.node_type and node.node_type != args.node_type:
            continue
        status = field_value(node, "STATUS")
        if args.status and status != args.status:
            continue
        rows.append(
            (
                node.reserved_uid,
                node.node_type,
                status or "",
                graph.path_of(node).relative_to(root),
            )
        )
    width = max((len(row[0]) for row in rows), default=0)
    for uid, node_type, state, path in sorted(rows):
        print(f"{uid:<{width}}  {node_type:<9}  {state:<17}  {path}")
    print(f"\n{len(rows)} node(s)", file=sys.stderr)
    return 0


def do_check(graph, _args, root: Path) -> int:
    """Validate nodes, relations, and repository-relative File targets."""
    findings = []
    retyped = []
    for node in graph.iter_nodes():
        uid = node.reserved_uid
        try:
            graph.validate(node)
        except SdocError as error:
            findings.append(f"{uid}: {error}")
        owner = prefix_owner(graph, uid)
        if owner is not None and owner != node.node_type:
            retyped.append(f"{uid}: born {owner}, now {node.node_type}")
        for relation in node.relations:
            target_uid = getattr(relation, "ref_uid", None)
            if target_uid is None:
                value = file_path_of(relation)
                try:
                    normalize_file_value(value)
                except SdocError as error:
                    findings.append(f"{uid}: {error}")
                    continue
                if not (root / value).is_file():
                    findings.append(
                        f"{uid}: File relation {value!r} names no existing file"
                    )
            elif not graph.has_node(target_uid):
                findings.append(
                    f"{uid}: relation to {target_uid!r}, which is not in the graph"
                )
    for note in retyped:
        print(f"NOTE {note}", file=sys.stderr)
    for finding in findings:
        print(f"FAIL {finding}", file=sys.stderr)
    total = sum(1 for _ in graph.iter_nodes())
    print(f"{total} nodes, {len(findings)} finding(s)", file=sys.stderr)
    return 1 if findings else 0
